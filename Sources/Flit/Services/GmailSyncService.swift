import Foundation

enum GmailSyncServiceError: Error, LocalizedError {
  case bodyFetchTimedOut

  var errorDescription: String? {
    "Gmail took too long to return this message."
  }
}

actor GmailSyncService {
  private static let bodyFetchTimeoutNanoseconds: UInt64 = 15_000_000_000
  private let store: MailStore
  private var providers: [Int64: GmailIMAPProvider] = [:]
  private var exhaustedOlderAccounts: Set<Int64> = []
  private var completedRemoteSearches: Set<String> = []
  private var bodyFetchTasks: [Int64: Task<URL, Error>] = [:]
  private var speculativeBodyFetchIDs: Set<Int64> = []
  private var demandBodyFetchCount = 0
  private var isSyncing = false

  init(store: MailStore) {
    self.store = store
  }

  func syncAllAccounts() async throws -> Int {
    guard !isSyncing else { return 0 }
    isSyncing = true
    defer { isSyncing = false }

    let accounts = try await store.accounts(provider: "gmail")
    guard !accounts.isEmpty else { return 0 }
    exhaustedOlderAccounts.subtract(accounts.map(\.id))

    let configuration = try GoogleOAuthConfigurationLoader.load()
    var synchronizedMessageCount = 0

    for account in accounts {
      let provider = provider(
        accountID: account.id,
        email: account.email,
        configuration: configuration
      )
      let result = try await provider.syncInbox(from: account.syncCursor)
      try await store.applyInboxSync(result, accountID: account.id)
      try await reconcileInbox(for: account, provider: provider)
      _ = try await flushPendingOperations(for: account, provider: provider)
      synchronizedMessageCount += result.messages.count
    }
    try await store.pruneBodyCache(maximumFiles: BodyPrefetchPlanner.maximumCachedBodies)
    return synchronizedMessageCount
  }

  func fetchOlderInboxPage(limit: Int = 100) async throws -> Int {
    guard !isSyncing else { return 0 }
    isSyncing = true
    defer { isSyncing = false }

    let accounts = try await store.accounts(provider: "gmail")
    guard !accounts.isEmpty else { return 0 }
    let configuration = try GoogleOAuthConfigurationLoader.load()
    var discoveredCount = 0

    for account in accounts where !exhaustedOlderAccounts.contains(account.id) {
      guard let oldestUID = try await store.oldestInboxRemoteUID(accountID: account.id) else {
        exhaustedOlderAccounts.insert(account.id)
        continue
      }
      let provider = provider(
        accountID: account.id,
        email: account.email,
        configuration: configuration
      )
      let messages = try await provider.fetchOlderInbox(
        beforeRemoteUID: oldestUID,
        limit: limit
      )
      try await store.applyInboxDiscovery(messages, accountID: account.id)
      discoveredCount += messages.count
      if messages.count < limit {
        exhaustedOlderAccounts.insert(account.id)
      }
    }
    return discoveredCount
  }

  func searchInbox(query: String, limit: Int = 100) async throws -> Int {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count >= 2 else { return 0 }

    let accounts = try await store.accounts(provider: "gmail")
    guard !accounts.isEmpty else { return 0 }
    let configuration = try GoogleOAuthConfigurationLoader.load()
    var discoveredCount = 0

    for account in accounts {
      let searchKey = "\(account.id):\(normalized.lowercased())"
      guard !completedRemoteSearches.contains(searchKey) else { continue }
      let provider = provider(
        accountID: account.id,
        email: account.email,
        configuration: configuration
      )
      let messages = try await provider.searchInbox(query: normalized, limit: limit)
      try await store.applyInboxDiscovery(messages, accountID: account.id)
      completedRemoteSearches.insert(searchKey)
      discoveredCount += messages.count
    }
    return discoveredCount
  }

  func hydrateThread(for message: MessageSummary, limit: Int = 50) async throws
    -> [MessageSummary]
  {
    guard message.accountProvider == "gmail", !message.threadRemoteID.isEmpty else {
      return [message]
    }
    let configuration = try GoogleOAuthConfigurationLoader.load()
    let provider = provider(
      accountID: message.accountID,
      email: message.accountEmail,
      configuration: configuration
    )
    let discovered = try await provider.fetchThread(
      remoteThreadID: message.threadRemoteID,
      limit: limit
    )
    try await store.applyInboxDiscovery(discovered, accountID: message.accountID)
    return try await store.threadMessages(
      accountID: message.accountID,
      remoteThreadID: message.threadRemoteID,
      limit: limit
    )
  }

  func fetchBody(for message: MessageSummary) async throws -> URL {
    demandBodyFetchCount += 1
    defer { demandBodyFetchCount -= 1 }

    cancelSpeculativeBodyFetches(except: message.id)
    do {
      return try await sharedBodyFetch(for: message, speculative: false)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let shouldRetry = error is IMAPTransportError || error is GmailSyncServiceError
      guard shouldRetry else { throw error }
      try Task.checkCancellation()
      return try await sharedBodyFetch(for: message, speculative: false)
    }
  }

  func prefetchBody(for message: MessageSummary) async throws -> URL? {
    guard message.accountProvider == "gmail", message.mailboxState == .inbox,
      demandBodyFetchCount == 0
    else { return nil }
    return try await sharedBodyFetch(for: message, speculative: true)
  }

  private func sharedBodyFetch(for message: MessageSummary, speculative: Bool) async throws
    -> URL
  {
    if let existingTask = bodyFetchTasks[message.id] {
      if !speculative {
        speculativeBodyFetchIDs.remove(message.id)
      }
      return try await existingTask.value
    }

    let task = Task { [self] in
      try await Self.withBodyFetchDeadline {
        try await self.performBodyFetch(for: message)
      }
    }
    bodyFetchTasks[message.id] = task
    if speculative {
      speculativeBodyFetchIDs.insert(message.id)
    }
    do {
      let url = try await task.value
      bodyFetchTasks.removeValue(forKey: message.id)
      speculativeBodyFetchIDs.remove(message.id)
      return url
    } catch {
      bodyFetchTasks.removeValue(forKey: message.id)
      speculativeBodyFetchIDs.remove(message.id)
      throw error
    }
  }

  private func cancelSpeculativeBodyFetches(except demandedMessageID: Int64) {
    for messageID in speculativeBodyFetchIDs where messageID != demandedMessageID {
      bodyFetchTasks[messageID]?.cancel()
    }
  }

  static func withBodyFetchDeadline<T: Sendable>(
    nanoseconds: UInt64? = nil,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask(operation: operation)
      group.addTask {
        try await Task.sleep(nanoseconds: nanoseconds ?? bodyFetchTimeoutNanoseconds)
        throw GmailSyncServiceError.bodyFetchTimedOut
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw GmailSyncServiceError.bodyFetchTimedOut
      }
      return result
    }
  }

  private func performBodyFetch(for message: MessageSummary) async throws -> URL {
    guard message.accountProvider == "gmail" else {
      throw GmailIMAPProviderError.featureUnavailable
    }
    let configuration = try GoogleOAuthConfigurationLoader.load()
    let provider = provider(
      accountID: message.accountID,
      email: message.accountEmail,
      configuration: configuration
    )
    let storedRemoteUID = try await store.remoteUID(
      messageID: message.id,
      mailboxState: message.mailboxState
    )
    guard let remoteUID = storedRemoteUID ?? message.remoteUID else {
      throw GmailIMAPProviderError.messageNotFound
    }
    let url = try await provider.fetchPlainTextBody(
      remoteID: message.remoteID,
      remoteUID: remoteUID,
      mailboxState: message.mailboxState
    )
    guard !Task.isCancelled else {
      try? FileManager.default.removeItem(at: url)
      throw CancellationError()
    }
    if message.mailboxState == .inbox {
      guard try await store.cacheBody(at: url.path, messageID: message.id) else {
        try? FileManager.default.removeItem(at: url)
        throw CancellationError()
      }
      try await store.pruneBodyCache(
        maximumFiles: BodyPrefetchPlanner.maximumCachedBodies
      )
    }
    return url
  }

  func flushPendingOperations() async throws -> Int {
    guard !isSyncing else { return 0 }
    let accounts = try await store.accounts(provider: "gmail")
    guard !accounts.isEmpty else { return 0 }

    let configuration = try GoogleOAuthConfigurationLoader.load()
    var completedCount = 0
    for account in accounts {
      let provider = provider(
        accountID: account.id,
        email: account.email,
        configuration: configuration
      )
      completedCount += try await flushPendingOperations(for: account, provider: provider)
    }
    return completedCount
  }

  private func provider(
    accountID: Int64,
    email: String,
    configuration: GoogleOAuthConfiguration
  ) -> GmailIMAPProvider {
    if let provider = providers[accountID] { return provider }
    let provider = GmailIMAPProvider(
      accountID: accountID,
      email: email,
      oauth: GoogleOAuthService(configuration: configuration)
    )
    providers[accountID] = provider
    return provider
  }

  private func reconcileInbox(
    for account: MailAccount,
    provider: GmailIMAPProvider
  ) async throws {
    let batchSize = 100
    var afterID: Int64?

    while true {
      let localMessages = try await store.inboxMessageStates(
        accountID: account.id,
        afterID: afterID,
        limit: batchSize
      )
      guard !localMessages.isEmpty else { return }

      let result = try await provider.reconcileInbox(localMessages)
      try await store.applyInboxReconciliation(result, accountID: account.id)
      afterID = localMessages.last?.id
      if localMessages.count < batchSize { return }
    }
  }

  private func flushPendingOperations(
    for account: MailAccount,
    provider: GmailIMAPProvider
  ) async throws -> Int {
    let operations = try await store.pendingOperations(accountID: account.id, limit: 100)
    guard !operations.isEmpty else { return 0 }

    let result = try await provider.applyPendingOperations(operations)
    for operationID in result.succeededIDs {
      try await store.completePendingOperation(id: operationID)
    }
    if let failedID = result.failedID {
      try await store.recordPendingOperationFailure(id: failedID)
    }
    return result.succeededIDs.count
  }
}
