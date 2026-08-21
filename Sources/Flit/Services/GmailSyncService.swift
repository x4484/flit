import Foundation

actor GmailSyncService {
  private let store: MailStore
  private var providers: [Int64: GmailIMAPProvider] = [:]
  private var exhaustedOlderAccounts: Set<Int64> = []
  private var completedRemoteSearches: Set<String> = []
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
    try await store.pruneBodyCache(maximumFiles: 8)
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

  func fetchBody(for message: MessageSummary) async throws -> URL {
    guard message.accountProvider == "gmail" else {
      throw GmailIMAPProviderError.featureUnavailable
    }
    let configuration = try GoogleOAuthConfigurationLoader.load()
    let provider = provider(
      accountID: message.accountID,
      email: message.accountEmail,
      configuration: configuration
    )
    guard let remoteUID = message.remoteUID else {
      throw GmailIMAPProviderError.messageNotFound
    }
    let url = try await provider.fetchPlainTextBody(
      remoteID: message.remoteID,
      remoteUID: remoteUID
    )
    guard !Task.isCancelled else {
      try? FileManager.default.removeItem(at: url)
      throw CancellationError()
    }
    guard try await store.cacheBody(at: url.path, messageID: message.id) else {
      try? FileManager.default.removeItem(at: url)
      throw CancellationError()
    }
    try await store.pruneBodyCache(maximumFiles: 8)
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
