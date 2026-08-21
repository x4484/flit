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

  func reconcileInbox(_ messages: [LocalInboxMessageState]) async throws
    -> InboxReconciliationResult
  {
    guard !messages.isEmpty else {
      return InboxReconciliationResult(messages: [], removals: [])
    }

    await acquireSession()
    defer { releaseSession() }
    try Task.checkCancellation()
    let transport = try await authenticatedTransport()

    do {
      let selected = try await transport.execute("EXAMINE \"INBOX\"")
      let mailbox = try GmailIMAPParser.mailboxState(from: selected)
      let currentUIDMessages = messages.filter {
        $0.uidValidity == mailbox.uidValidity
          && $0.remoteUID.map { (1...Int64(UInt32.max)).contains($0) } == true
      }
      let currentRemoteIDs = Set(currentUIDMessages.map(\.remoteID))
      let staleUIDMessages = messages.filter {
        !currentRemoteIDs.contains($0.remoteID)
      }

      let currentStates = try await fetchRemoteStates(
        uids: currentUIDMessages.compactMap(\.remoteUID),
        uidValidity: mailbox.uidValidity,
        transport: transport
      )
      let currentResult = Self.reconciliation(
        localMessages: currentUIDMessages,
        remoteStates: currentStates
      )
      var reconciledMessages = currentResult.messages
      var missingRemoteIDs = currentResult.removals.map(\.remoteID)

      for message in staleUIDMessages {
        try Task.checkCancellation()
        guard !message.remoteID.isEmpty, message.remoteID.allSatisfy(\.isNumber) else {
          continue
        }
        let search = try await transport.execute("UID SEARCH X-GM-MSGID \(message.remoteID)")
        guard let uid = GmailIMAPParser.searchedUIDs(from: search, greaterThan: 0).first else {
          missingRemoteIDs.append(message.remoteID)
          continue
        }
        let states = try await fetchRemoteStates(
          uids: [uid],
          uidValidity: mailbox.uidValidity,
          transport: transport
        )
        if let state = states.first(where: { $0.remoteID == message.remoteID }) {
          reconciledMessages.append(state)
        } else {
          missingRemoteIDs.append(message.remoteID)
        }
      }

      reconciledMessages = Array(
        Dictionary(
          reconciledMessages.map { ($0.remoteID, $0) },
          uniquingKeysWith: { _, latest in latest }
        ).values
      ).sorted { $0.remoteUID < $1.remoteUID }
      let removals = try await classifyRemovals(
        remoteIDs: Array(Set(missingRemoteIDs)).sorted(),
        transport: transport
      )
      return InboxReconciliationResult(
        messages: reconciledMessages,
        removals: removals
      )
    } catch {
      invalidateTransport(transport)
      throw error
    }
  }

  static func reconciliation(
    localMessages: [LocalInboxMessageState],
    remoteStates: [RemoteInboxMessageState]
  ) -> InboxReconciliationResult {
    let presentRemoteIDs = Set(remoteStates.map(\.remoteID))
    return InboxReconciliationResult(
      messages: remoteStates,
      removals: localMessages.map(\.remoteID).filter {
        $0.allSatisfy(\.isNumber) && !presentRemoteIDs.contains($0)
      }.map {
        RemoteInboxRemoval(remoteID: $0, destination: .archive)
      }
    )
  }

  static func classifiedRemovals(
    missingRemoteIDs: [String],
    trashRemoteIDs: Set<String>,
    allMailRemoteIDs: Set<String>
  ) -> [RemoteInboxRemoval] {
    Array(Set(missingRemoteIDs)).sorted().map { remoteID in
      let destination: RemoteRemovalDestination
      if trashRemoteIDs.contains(remoteID) {
        destination = .trash
      } else if allMailRemoteIDs.contains(remoteID) {
        destination = .archive
      } else {
        destination = .delete
      }
      return RemoteInboxRemoval(remoteID: remoteID, destination: destination)
    }
  }

  func fetchOlderInbox(beforeRemoteUID: Int64, limit: Int) async throws -> [NewMessage] {
    guard (1...Int64(UInt32.max)).contains(beforeRemoteUID), limit > 0 else { return [] }
    await acquireSession()
    defer { releaseSession() }
    try Task.checkCancellation()
    let transport = try await authenticatedTransport()

    do {
      let selected = try await transport.execute("EXAMINE \"INBOX\"")
      let mailbox = try GmailIMAPParser.mailboxState(from: selected)
      let search = try await transport.execute("SEARCH UID \(beforeRemoteUID)")
      guard let anchorSequence = GmailIMAPParser.searchedNumbers(from: search).first else {
        return []
      }
      let sequences = Self.olderSequenceNumbers(
        beforeSequence: anchorSequence,
        limit: min(limit, Self.maximumMessagesPerSync)
      )
      return try await fetchMetadata(
        sequenceNumbers: sequences,
        useUIDCommand: false,
        uidValidity: mailbox.uidValidity,
        transport: transport
      )
    } catch {
      invalidateTransport(transport)
      throw error
    }
  }

  func searchInbox(query: String, limit: Int) async throws -> [NewMessage] {
    guard let inboxCommand = Self.inboxSearchCommand(query: query), limit > 0 else { return [] }
    await acquireSession()
    defer { releaseSession() }
    try Task.checkCancellation()
    let transport = try await authenticatedTransport()

    do {
      let boundedLimit = min(limit, Self.maximumMessagesPerSync)
      let selectedInbox = try await transport.execute("EXAMINE \"INBOX\"")
      let inbox = try GmailIMAPParser.mailboxState(from: selectedInbox)
      let inboxSearch = try await transport.execute(inboxCommand)
      let inboxUIDs = Array(
        GmailIMAPParser.searchedUIDs(from: inboxSearch, greaterThan: 0)
          .suffix(boundedLimit)
      )
      let inboxMessages = try await fetchMetadata(
        sequenceNumbers: inboxUIDs,
        useUIDCommand: true,
        uidValidity: inbox.uidValidity,
        mailboxState: .inbox,
        transport: transport
      )

      let remainingLimit = max(0, boundedLimit - inboxMessages.count)
      guard remainingLimit > 0,
        let archiveCommand = Self.inboxSearchCommand(query: "\(query) -label:inbox")
      else { return inboxMessages }

      let selectedAllMail = try await transport.execute("EXAMINE \"[Gmail]/All Mail\"")
      let allMail = try GmailIMAPParser.mailboxState(from: selectedAllMail)
      let archiveSearch = try await transport.execute(archiveCommand)
      let archiveUIDs = Array(
        GmailIMAPParser.searchedUIDs(from: archiveSearch, greaterThan: 0)
          .suffix(remainingLimit)
      )
      let archiveMessages = try await fetchMetadata(
        sequenceNumbers: archiveUIDs,
        useUIDCommand: true,
        uidValidity: allMail.uidValidity,
        mailboxState: .archive,
        transport: transport
      )

      var messagesByRemoteID = Dictionary(
        archiveMessages.map { ($0.remoteID, $0) },
        uniquingKeysWith: { _, latest in latest }
      )
      for message in inboxMessages {
        messagesByRemoteID[message.remoteID] = message
      }
      return messagesByRemoteID.values.sorted { $0.receivedAt > $1.receivedAt }
    } catch {
      invalidateTransport(transport)
      throw error
    }
  }

  static func olderSequenceNumbers(beforeSequence: Int64, limit: Int) -> [Int64] {
    guard beforeSequence > 1, limit > 0 else { return [] }
    let end = beforeSequence - 1
    let start = max(1, end - Int64(limit) + 1)
    return Array(start...end)
  }

  static func inboxSearchCommand(query: String) -> String? {
    let normalized = query.replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    let escaped = normalized.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "UID SEARCH X-GM-RAW \"\(escaped)\""
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
        mailboxState: .inbox,
        transport: transport
      )
      return url
    } catch {
      invalidateTransport(transport)
      throw error
    }
  }

  func fetchPlainTextBody(
    remoteID: String,
    remoteUID: Int64,
    mailboxState: MailboxState = .inbox
  ) async throws -> URL {
    await acquireSession()
    defer { releaseSession() }
    try Task.checkCancellation()
    guard !remoteID.isEmpty, remoteID.allSatisfy(\.isNumber) else {
      throw GmailIMAPProviderError.messageNotFound
    }
    let transport = try await authenticatedTransport()
    do {
      _ = try await transport.execute("EXAMINE \"\(Self.mailboxName(for: mailboxState))\"")
      let url = try await fetchPlainTextBody(
        remoteID: remoteID,
        remoteUID: remoteUID,
        mailboxState: mailboxState,
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

  static func mailboxName(for state: MailboxState) -> String {
    switch state {
    case .inbox: return "INBOX"
    case .archive: return "[Gmail]/All Mail"
    case .trash: return "[Gmail]/Trash"
    }
  }

  private func fetchPlainTextBody(
    remoteID: String,
    remoteUID: Int64,
    mailboxState: MailboxState,
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
    return try cacheBody(
      body,
      remoteID: remoteID,
      transient: mailboxState != .inbox
    )
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

  private func cacheBody(
    _ body: PreferredMIMEBody,
    remoteID: String,
    transient: Bool
  ) throws -> URL {
    let safeRemoteID = remoteID.map { character in
      character.isLetter || character.isNumber ? character : "_"
    }
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
      .appendingPathComponent(
        transient ? "Flit/TransientBodies/\(accountID)" : "Flit/Bodies-v4/\(accountID)",
        isDirectory: true
      )
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

  private func classifyRemovals(
    remoteIDs: [String],
    transport: IMAPTransport
  ) async throws -> [RemoteInboxRemoval] {
    guard !remoteIDs.isEmpty else { return [] }

    let trashRemoteIDs = try await remoteIDsPresent(
      remoteIDs,
      mailbox: "[Gmail]/Trash",
      transport: transport
    )
    let notInTrash = remoteIDs.filter { !trashRemoteIDs.contains($0) }
    let allMailRemoteIDs = try await remoteIDsPresent(
      notInTrash,
      mailbox: "[Gmail]/All Mail",
      transport: transport
    )
    return Self.classifiedRemovals(
      missingRemoteIDs: remoteIDs,
      trashRemoteIDs: trashRemoteIDs,
      allMailRemoteIDs: allMailRemoteIDs
    )
  }

  private func remoteIDsPresent(
    _ remoteIDs: [String],
    mailbox: String,
    transport: IMAPTransport
  ) async throws -> Set<String> {
    guard !remoteIDs.isEmpty else { return [] }
    _ = try await transport.execute("EXAMINE \"\(mailbox)\"")
    var present: Set<String> = []
    for remoteID in remoteIDs where remoteID.allSatisfy(\.isNumber) {
      try Task.checkCancellation()
      let search = try await transport.execute("UID SEARCH X-GM-MSGID \(remoteID)")
      if !GmailIMAPParser.searchedUIDs(from: search, greaterThan: 0).isEmpty {
        present.insert(remoteID)
      }
    }
    return present
  }

  private func fetchRemoteStates(
    uids: [Int64],
    uidValidity: Int64,
    transport: IMAPTransport
  ) async throws -> [RemoteInboxMessageState] {
    var states: [RemoteInboxMessageState] = []
    states.reserveCapacity(uids.count)

    for batchStart in stride(from: 0, to: uids.count, by: Self.fetchBatchSize) {
      let batchEnd = min(batchStart + Self.fetchBatchSize, uids.count)
      let sequenceSet = uids[batchStart..<batchEnd].map(String.init).joined(separator: ",")
      guard !sequenceSet.isEmpty else { continue }
      let result = try await transport.execute(
        "UID FETCH \(sequenceSet) (UID X-GM-MSGID FLAGS)")
      for response in result.responses {
        if let state = try GmailIMAPParser.remoteMessageState(
          from: response,
          uidValidity: uidValidity
        ) {
          states.append(state)
        }
      }
    }
    return states
  }

  private func fetchMetadata(
    sequenceNumbers: [Int64],
    useUIDCommand: Bool,
    uidValidity: Int64,
    mailboxState: MailboxState = .inbox,
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
          uidValidity: uidValidity,
          mailboxState: mailboxState
        ) {
          messages.append(message)
        }
      }
    }
    return messages
  }
}
