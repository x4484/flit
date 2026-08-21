import Foundation

enum GmailIMAPProviderError: Error, LocalizedError {
  case featureUnavailable
  case messageNotFound
  case missingBodyData
  case mailboxChanged

  var errorDescription: String? {
    switch self {
    case .featureUnavailable:
      return "This Gmail action is not available yet."
    case .messageNotFound:
      return "The message is no longer in the Gmail inbox."
    case .missingBodyData:
      return "Gmail did not return a readable message body."
    case .mailboxChanged:
      return "The Gmail inbox changed before the action could be applied."
    }
  }
}

struct GmailOperationBatchResult: Sendable, Equatable {
  let succeededIDs: [Int64]
  let failedID: Int64?
}

actor GmailIMAPProvider: MailProvider {
  private static let maximumMessagesPerSync = 200
  private static let fetchBatchSize = 25
  private static let metadataItems =
    "UID X-GM-MSGID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID FROM TO CC SUBJECT DATE)]"

  private let accountID: Int64
  private let email: String
  private let oauth: GoogleOAuthService
  private var activeTransport: IMAPTransport?
  private var sessionInUse = false
  private var sessionWaiters: [CheckedContinuation<Void, Never>] = []

  init(accountID: Int64, email: String, oauth: GoogleOAuthService) {
    self.accountID = accountID
    self.email = email
    self.oauth = oauth
  }

  func syncInbox(from cursor: SyncCursor?) async throws -> SyncResult {
    await acquireSession()
    defer { releaseSession() }
    try Task.checkCancellation()
    let transport = try await authenticatedTransport()

    do {
      let selected = try await transport.execute("EXAMINE \"INBOX\"")
      let mailbox = try GmailIMAPParser.mailboxState(from: selected)
      let isIncremental = cursor?.uidValidity == mailbox.uidValidity && cursor?.highestUID != nil
      let messages: [NewMessage]

      if isIncremental, let highestUID = cursor?.highestUID {
        messages = try await fetchIncrementalMessages(
          after: highestUID,
          uidValidity: mailbox.uidValidity,
          transport: transport
        )
      } else {
        messages = try await fetchInitialMessages(
          mailbox: mailbox,
          transport: transport
        )
      }

      let highestFetchedUID = messages.compactMap(\.remoteUID).max()
      let highestUID =
        isIncremental
        ? max(cursor?.highestUID ?? 0, highestFetchedUID ?? 0)
        : highestFetchedUID
      let result = SyncResult(
        messages: messages,
        removedRemoteIDs: [],
        cursor: SyncCursor(
          uidValidity: mailbox.uidValidity,
          highestUID: highestUID,
          highestModSequence: mailbox.highestModSequence
        )
      )

      return result
    } catch {
      invalidateTransport(transport)
      throw error
    }
  }

  func fetchPlainTextBody(remoteID: String) async throws -> URL {
    await acquireSession()
    defer { releaseSession() }
    try Task.checkCancellation()
    guard !remoteID.isEmpty, remoteID.allSatisfy(\.isNumber) else {
      throw GmailIMAPProviderError.messageNotFound
    }
    let transport = try await authenticatedTransport()
    do {
      _ = try await transport.execute("EXAMINE \"INBOX\"")
      let search = try await transport.execute("UID SEARCH X-GM-MSGID \(remoteID)")
      guard let uid = GmailIMAPParser.searchedUIDs(from: search, greaterThan: 0).first else {
        throw GmailIMAPProviderError.messageNotFound
      }
      let url = try await fetchPlainTextBody(
        remoteID: remoteID,
        remoteUID: uid,
        transport: transport
      )
      return url
    } catch {
      invalidateTransport(transport)
      throw error
    }
  }

  func fetchPlainTextBody(remoteID: String, remoteUID: Int64) async throws -> URL {
    await acquireSession()
    defer { releaseSession() }
    try Task.checkCancellation()
    guard !remoteID.isEmpty, remoteID.allSatisfy(\.isNumber) else {
      throw GmailIMAPProviderError.messageNotFound
    }
    let transport = try await authenticatedTransport()
    do {
      _ = try await transport.execute("EXAMINE \"INBOX\"")
      let url = try await fetchPlainTextBody(
        remoteID: remoteID,
        remoteUID: remoteUID,
        transport: transport
      )
      return url
    } catch {
      invalidateTransport(transport)
      throw error
    }
  }

  func markRead(remoteID: String) async throws {
    throw GmailIMAPProviderError.featureUnavailable
  }

  func archive(remoteID: String) async throws {
    throw GmailIMAPProviderError.featureUnavailable
  }

  func moveToTrash(remoteID: String) async throws {
    throw GmailIMAPProviderError.featureUnavailable
  }

  func applyPendingOperations(_ operations: [PendingMailOperation]) async throws
    -> GmailOperationBatchResult
  {
    await acquireSession()
    defer { releaseSession() }
    try Task.checkCancellation()
    guard !operations.isEmpty else {
      return GmailOperationBatchResult(succeededIDs: [], failedID: nil)
    }

    let transport = try await authenticatedTransport()
    do {
      let selected = try await transport.execute("SELECT \"INBOX\"")
      let mailbox = try GmailIMAPParser.mailboxState(from: selected)
      var succeededIDs: [Int64] = []

      for operation in operations {
        guard operation.uidValidity == nil || operation.uidValidity == mailbox.uidValidity else {
          throw GmailIMAPProviderError.mailboxChanged
        }
        do {
          switch operation.kind {
          case .markRead:
            _ = try await transport.execute(
              "UID STORE \(operation.remoteUID) +FLAGS.SILENT (\\Seen)")
          case .archive:
            guard let command = Self.mailboxMoveCommand(
              kind: .archive, remoteUID: operation.remoteUID)
            else { throw GmailIMAPProviderError.featureUnavailable }
            _ = try await transport.execute(command)
          case .trash:
            guard let command = Self.mailboxMoveCommand(
              kind: .trash, remoteUID: operation.remoteUID)
            else { throw GmailIMAPProviderError.featureUnavailable }
            _ = try await transport.execute(command)
          case .send:
            return GmailOperationBatchResult(
              succeededIDs: succeededIDs,
              failedID: operation.id
            )
          }
          succeededIDs.append(operation.id)
        } catch {
          invalidateTransport(transport)
          return GmailOperationBatchResult(
            succeededIDs: succeededIDs,
            failedID: operation.id
          )
        }
      }

      return GmailOperationBatchResult(succeededIDs: succeededIDs, failedID: nil)
    } catch {
      invalidateTransport(transport)
      throw error
    }
  }

  func send(_ message: OutgoingMessage) async throws {
    let smtp = GmailSMTPService(oauth: oauth)
    try await smtp.send(message)
  }

  static func mailboxMoveCommand(kind: PendingOperationKind, remoteUID: Int64) -> String? {
    switch kind {
    case .archive:
      return "UID MOVE \(remoteUID) \"[Gmail]/All Mail\""
    case .trash:
      return "UID MOVE \(remoteUID) \"[Gmail]/Trash\""
    case .markRead, .send:
      return nil
    }
  }

  private func fetchPlainTextBody(
    remoteID: String,
    remoteUID: Int64,
    transport: IMAPTransport
  ) async throws -> URL {
    let result = try await transport.execute(
      "UID FETCH \(remoteUID) (X-GM-MSGID BODY.PEEK[]<0.1048576>)"
    )
    guard let response = result.responses.first(where: { $0.literal != nil }),
      GmailIMAPParser.gmailMessageID(from: response) == remoteID,
      let messageData = response.literal,
      let separator = messageData.range(of: Data([13, 10, 13, 10]))
    else {
      throw GmailIMAPProviderError.missingBodyData
    }

    try Task.checkCancellation()
    let headerData = Data(messageData[..<separator.lowerBound])
    let bodyData = Data(messageData[separator.upperBound...])
    let body = MIMETextExtractor.preferredBody(headerData: headerData, bodyData: bodyData)
    return try cacheBody(body, remoteID: remoteID)
  }

  private func acquireSession() async {
    if !sessionInUse {
      sessionInUse = true
      return
    }
    await withCheckedContinuation { continuation in
      sessionWaiters.append(continuation)
    }
  }

  private func releaseSession() {
    if sessionWaiters.isEmpty {
      sessionInUse = false
    } else {
      sessionWaiters.removeFirst().resume()
    }
  }

  private func authenticatedTransport() async throws -> IMAPTransport {
    if let activeTransport { return activeTransport }

    let accessSession = try await oauth.refreshAccessToken(email: email)
    let transport = try IMAPTransport(host: "imap.gmail.com", port: 993)
    do {
      _ = try await transport.connect()
      let xoauth2 = GmailXOAUTH2.initialClientResponse(
        email: email,
        accessToken: accessSession.accessToken
      )
      _ = try await transport.execute(
        "AUTHENTICATE XOAUTH2 \(xoauth2)",
        answerContinuationWithEmptyLine: true
      )
      activeTransport = transport
      return transport
    } catch {
      transport.close()
      throw error
    }
  }

  private func invalidateTransport(_ transport: IMAPTransport) {
    if activeTransport === transport {
      activeTransport = nil
    }
    transport.close()
  }

  private func cacheBody(_ body: PreferredMIMEBody, remoteID: String) throws -> URL {
    let safeRemoteID = remoteID.map { character in
      character.isLetter || character.isNumber ? character : "_"
    }
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
      .appendingPathComponent("Flit/Bodies-v4/\(accountID)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let file: (extension: String, data: Data)
    switch body {
    case .plainText(let text):
      file = ("txt", Data(text.utf8))
    case .html(let html):
      file = ("html", Data(html.utf8))
    }
    let url = directory.appendingPathComponent(
      String(safeRemoteID) + "." + file.extension
    )
    try file.data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
    return url
  }

  private func fetchInitialMessages(
    mailbox: IMAPMailboxState,
    transport: IMAPTransport
  ) async throws -> [NewMessage] {
    guard mailbox.messageCount > 0 else { return [] }
    let firstSequence = max(1, mailbox.messageCount - Self.maximumMessagesPerSync + 1)
    let sequences = (firstSequence...mailbox.messageCount).map(Int64.init)
    return try await fetchMetadata(
      sequenceNumbers: sequences,
      useUIDCommand: false,
      uidValidity: mailbox.uidValidity,
      transport: transport
    )
  }

  private func fetchIncrementalMessages(
    after highestUID: Int64,
    uidValidity: Int64,
    transport: IMAPTransport
  ) async throws -> [NewMessage] {
    let search = try await transport.execute("UID SEARCH UID \(highestUID + 1):*")
    let uids = Array(
      GmailIMAPParser.searchedUIDs(from: search, greaterThan: highestUID)
        .prefix(Self.maximumMessagesPerSync)
    )
    return try await fetchMetadata(
      sequenceNumbers: uids,
      useUIDCommand: true,
      uidValidity: uidValidity,
      transport: transport
    )
  }

  private func fetchMetadata(
    sequenceNumbers: [Int64],
    useUIDCommand: Bool,
    uidValidity: Int64,
    transport: IMAPTransport
  ) async throws -> [NewMessage] {
    var messages: [NewMessage] = []
    messages.reserveCapacity(sequenceNumbers.count)

    for batchStart in stride(from: 0, to: sequenceNumbers.count, by: Self.fetchBatchSize) {
      let batchEnd = min(batchStart + Self.fetchBatchSize, sequenceNumbers.count)
      let sequenceSet = sequenceNumbers[batchStart..<batchEnd]
        .map(String.init)
        .joined(separator: ",")
      let prefix = useUIDCommand ? "UID " : ""
      let result = try await transport.execute(
        "\(prefix)FETCH \(sequenceSet) (\(Self.metadataItems))")

      for response in result.responses where response.literal != nil {
        if let message = try GmailIMAPParser.message(
          from: response,
          accountID: accountID,
          uidValidity: uidValidity
        ) {
          messages.append(message)
        }
      }
    }
    return messages
  }
}
