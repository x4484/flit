import Foundation
import Testing

@testable import Flit

struct MailStoreTests {
  @Test
  func archiveRemovesMessageFromInboxButKeepsItSearchable() async throws {
    let context = try await makeStore()
    defer { context.cleanup() }

    let messageID = try await context.store.addMessage(
      NewMessage(
        accountID: context.accountID,
        remoteID: "gmail-1",
        remoteUID: 42,
        uidValidity: 7,
        receivedAt: 1_700_000_000,
        sender: "Maya Chen",
        recipients: "me@example.com",
        cc: "team@example.com",
        internetMessageID: "<quarterly@example.com>",
        subject: "Quarterly planning",
        preview: "Notes for the planning session",
        isRead: false,
        mailboxState: .inbox,
        bodyPath: nil
      ))

    let inbox = try await context.store.fetchInbox()
    #expect(inbox.count == 1)
    #expect(inbox.first?.cc == "team@example.com")
    #expect(try await context.store.inboxCount() == 1)

    try await context.store.archive(messageID: messageID)

    #expect(try await context.store.fetchInbox().isEmpty)
    #expect(try await context.store.inboxCount() == 0)
    let results = try await context.store.search("quarterly")
    #expect(results.map(\.id) == [messageID])
    #expect(results.first?.mailboxState == .archive)
  }

  @Test
  func loadsBoundedThreadMembersNewestFirst() async throws {
    let context = try await makeStore()
    defer { context.cleanup() }
    for (remoteID, receivedAt, state) in [
      ("thread-old", Int64(100), MailboxState.archive),
      ("thread-new", Int64(200), MailboxState.inbox),
    ] {
      try await context.store.addMessage(
        NewMessage(
          accountID: context.accountID,
          remoteID: remoteID,
          threadRemoteID: "gmail-thread-1",
          remoteUID: receivedAt,
          uidValidity: 1,
          receivedAt: receivedAt,
          sender: remoteID,
          recipients: "me@example.com",
          cc: "",
          internetMessageID: "<\(remoteID)@example.com>",
          subject: "Thread",
          preview: "",
          isRead: true,
          mailboxState: state,
          bodyPath: nil
        ))
    }

    let messages = try await context.store.threadMessages(
      accountID: context.accountID,
      remoteThreadID: "gmail-thread-1",
      limit: 50
    )

    #expect(messages.map(\.remoteID) == ["thread-new", "thread-old"])
    #expect(messages.map(\.mailboxState) == [.inbox, .archive])
    for message in messages {
      #expect(
        try await context.store.remoteUID(
          messageID: message.id,
          mailboxState: message.mailboxState
        ) == message.remoteUID
      )
    }
  }

  @Test
  func startupRemovesTransientArchivedBodies() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("FlitTransientTests-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Flit", isDirectory: true)
    let transient = support.appendingPathComponent("TransientBodies/1", isDirectory: true)
    try FileManager.default.createDirectory(at: transient, withIntermediateDirectories: true)
    let staleBody = transient.appendingPathComponent("stale.html")
    try Data("stale".utf8).write(to: staleBody)
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try MailStore(path: support.appendingPathComponent("flit.sqlite3").path)

    #expect(!FileManager.default.fileExists(atPath: staleBody.path))
  }

  @Test
  func archiveDeletesCachedBody() async throws {
    let context = try await makeStore()
    defer { context.cleanup() }

    let bodyURL = context.directory.appendingPathComponent("body.txt")
    try Data("Cached body".utf8).write(to: bodyURL)

    let messageID = try await context.store.addMessage(
      NewMessage(
        accountID: context.accountID,
        remoteID: "icloud-1",
        remoteUID: 9,
        uidValidity: 2,
        receivedAt: 1_700_000_000,
        sender: "Alex Rivera",
        recipients: "me@example.com",
        cc: "",
        internetMessageID: "",
        subject: "A cached message",
        preview: "Cached body",
        isRead: true,
        mailboxState: .inbox,
        bodyPath: bodyURL.path
      ))

    try await context.store.archive(messageID: messageID)

    #expect(!FileManager.default.fileExists(atPath: bodyURL.path))
    #expect(try await context.store.search("cached").first?.bodyPath == nil)
  }

  @Test
  func cachesSummaryUntilMessageLeavesTheInbox() async throws {
    let context = try await makeStore()
    defer { context.cleanup() }

    let messageID = try await context.store.addMessage(
      NewMessage(
        accountID: context.accountID,
        remoteID: "summarized-message",
        remoteUID: 10,
        uidValidity: 2,
        receivedAt: 1_700_000_000,
        sender: "Maya Chen",
        recipients: "me@example.com",
        cc: "",
        internetMessageID: "",
        subject: "A summarized message",
        preview: "Summary source",
        isRead: false,
        mailboxState: .inbox,
        bodyPath: nil
      ))

    #expect(try await context.store.saveSummary("One concise sentence.", for: messageID))
    #expect(try await context.store.summary(for: messageID) == "One concise sentence.")

    try await context.store.archive(messageID: messageID)

    #expect(try await context.store.summary(for: messageID) == nil)
  }

  @Test
  func inboxUsesStableNewestFirstPagination() async throws {
    let context = try await makeStore()
    defer { context.cleanup() }

    for index in 0..<5 {
      try await context.store.addMessage(
        NewMessage(
          accountID: context.accountID,
          remoteID: "message-\(index)",
          remoteUID: Int64(index),
          uidValidity: 1,
          receivedAt: Int64(100 + index),
          sender: "Sender \(index)",
          recipients: "me@example.com",
          cc: "",
          internetMessageID: "",
          subject: "Message \(index)",
          preview: "",
          isRead: false,
          mailboxState: .inbox,
          bodyPath: nil
        ))
    }

    let firstPage = try await context.store.fetchInbox(limit: 2)
    let secondPage = try await context.store.fetchInbox(after: firstPage.last?.cursor, limit: 2)

    #expect(firstPage.map(\.receivedAt) == [104, 103])
    #expect(secondPage.map(\.receivedAt) == [102, 101])
  }

  @Test
  func inboxSyncDoesNotUndoAPendingOptimisticArchive() async throws {
    let context = try await makeStore()
    defer { context.cleanup() }

    let remoteMessage = NewMessage(
      accountID: context.accountID,
      remoteID: "pending-archive",
      remoteUID: 203,
      uidValidity: 17,
      receivedAt: 1_700_000_000,
      sender: "Gmail Sender",
      recipients: "me@example.com",
      cc: "",
      internetMessageID: "",
      subject: "Keep archived",
      preview: "",
      isRead: false,
      mailboxState: .inbox,
      bodyPath: nil
    )
    let messageID = try await context.store.addMessage(remoteMessage)
    try await context.store.archive(messageID: messageID)

    try await context.store.applyInboxSync(
      SyncResult(
        messages: [remoteMessage],
        removedRemoteIDs: [],
        cursor: SyncCursor(uidValidity: 17, highestUID: 203, highestModSequence: nil)
      ),
      accountID: context.accountID
    )

    #expect(try await context.store.fetchInbox().isEmpty)
    #expect(try await context.store.search("archived").first?.mailboxState == .archive)
  }

  @Test
  func inboxSyncPersistsMessagesAndCursorAtomically() async throws {
    let context = try await makeStore()
    defer { context.cleanup() }

    let cursor = SyncCursor(uidValidity: 17, highestUID: 204, highestModSequence: "9901")
    try await context.store.applyInboxSync(
      SyncResult(
        messages: [
          NewMessage(
            accountID: context.accountID,
            remoteID: "gmail-message-id",
            remoteUID: 204,
            uidValidity: 17,
            receivedAt: 1_700_000_000,
            sender: "Gmail Sender",
            recipients: "me@example.com",
            cc: "",
            internetMessageID: "",
            subject: "Synced metadata",
            preview: "",
            isRead: false,
            mailboxState: .inbox,
            bodyPath: nil
          )
        ],
        removedRemoteIDs: [],
        cursor: cursor
      ),
      accountID: context.accountID
    )

    #expect(try await context.store.fetchInbox().map(\.remoteID) == ["gmail-message-id"])
    #expect(try await context.store.accounts().first?.syncCursor == cursor)
  }

  @Test
  func remoteReconciliationUpdatesFlagsAndRemovesMessagesMissingFromInbox() async throws {
    let context = try await makeStore(provider: "gmail")
    defer { context.cleanup() }

    let retainedID = try await context.store.addMessage(
      NewMessage(
        accountID: context.accountID, remoteID: "remote-retained", remoteUID: 41,
        uidValidity: 7, receivedAt: 1_700_000_001, sender: "Retained sender",
        recipients: "me@example.com", cc: "", internetMessageID: "",
        subject: "Retained message", preview: "", isRead: false,
        mailboxState: .inbox, bodyPath: nil
      ))
    let removedBody = context.directory.appendingPathComponent("removed-body.html")
    try Data("<p>Removed</p>".utf8).write(to: removedBody)
    let removedID = try await context.store.addMessage(
      NewMessage(
        accountID: context.accountID, remoteID: "remote-removed", remoteUID: 42,
        uidValidity: 7, receivedAt: 1_700_000_000, sender: "Removed sender",
        recipients: "me@example.com", cc: "", internetMessageID: "",
        subject: "Removed message", preview: "", isRead: false,
        mailboxState: .inbox, bodyPath: removedBody.path
      ))
    #expect(try await context.store.saveSummary("Delete this summary.", for: removedID))

    let localStates = try await context.store.inboxMessageStates(accountID: context.accountID)
    #expect(localStates.map(\.id) == [retainedID, removedID])

    try await context.store.applyInboxReconciliation(
      InboxReconciliationResult(
        messages: [
          RemoteInboxMessageState(
            remoteID: "remote-retained", remoteUID: 41, uidValidity: 7, isRead: true)
        ],
        removals: [
          RemoteInboxRemoval(remoteID: "remote-removed", destination: .archive)
        ]
      ),
      accountID: context.accountID
    )

    let inbox = try await context.store.fetchInbox()
    #expect(inbox.map(\.id) == [retainedID])
    #expect(inbox.first?.isRead == true)
    let removed = try #require(try await context.store.search("Removed").first)
    #expect(removed.mailboxState == .archive)
    #expect(removed.bodyPath == nil)
    #expect(try await context.store.summary(for: removedID) == nil)
    #expect(!FileManager.default.fileExists(atPath: removedBody.path))
  }

  @Test
  func discoversOlderInboxPagesWithoutMovingTheSyncCursor() async throws {
    let context = try await makeStore(provider: "gmail")
    defer { context.cleanup() }

    _ = try await context.store.addMessage(
      NewMessage(
        accountID: context.accountID, remoteID: "newer", remoteUID: 40,
        uidValidity: 7, receivedAt: 400, sender: "Newer", recipients: "me@example.com",
        cc: "", internetMessageID: "", subject: "Newer", preview: "", isRead: false,
        mailboxState: .inbox, bodyPath: nil
      ))
    try await context.store.applyInboxDiscovery(
      [
        NewMessage(
          accountID: context.accountID, remoteID: "older", remoteUID: 20,
          uidValidity: 7, receivedAt: 200, sender: "Older", recipients: "me@example.com",
          cc: "", internetMessageID: "", subject: "Older", preview: "", isRead: true,
          mailboxState: .inbox, bodyPath: nil
        )
      ],
      accountID: context.accountID
    )

    try await context.store.applyInboxDiscovery(
      [
        NewMessage(
          accountID: context.accountID, remoteID: "newer", remoteUID: 999,
          uidValidity: 99, receivedAt: 400, sender: "Newer", recipients: "me@example.com",
          cc: "", internetMessageID: "", subject: "Newer", preview: "", isRead: false,
          mailboxState: .archive, bodyPath: nil
        )
      ],
      accountID: context.accountID
    )

    #expect(try await context.store.oldestInboxRemoteUID(accountID: context.accountID) == 20)
    let currentState = try #require(
      try await context.store.inboxMessageStates(accountID: context.accountID)
        .first(where: { $0.remoteID == "newer" })
    )
    #expect(currentState.remoteUID == 40)
    #expect(currentState.uidValidity == 7)
    let firstPage = try await context.store.fetchInbox(limit: 1)
    let secondPage = try await context.store.fetchInbox(after: firstPage.last?.cursor, limit: 1)
    #expect(firstPage.map(\.remoteID) == ["newer"])
    #expect(secondPage.map(\.remoteID) == ["older"])
  }

  @Test
  func remoteUnreadStateDoesNotOverridePendingLocalRead() async throws {
    let context = try await makeStore(provider: "gmail")
    defer { context.cleanup() }

    let messageID = try await context.store.addMessage(
      NewMessage(
        accountID: context.accountID, remoteID: "pending-read", remoteUID: 51,
        uidValidity: 8, receivedAt: 1_700_000_000, sender: "Sender",
        recipients: "me@example.com", cc: "", internetMessageID: "",
        subject: "Pending read", preview: "", isRead: false,
        mailboxState: .inbox, bodyPath: nil
      ))
    try await context.store.markRead(messageID: messageID)

    try await context.store.applyInboxReconciliation(
      InboxReconciliationResult(
        messages: [
          RemoteInboxMessageState(
            remoteID: "pending-read", remoteUID: 51, uidValidity: 8, isRead: false)
        ],
        removals: []
      ),
      accountID: context.accountID
    )

    #expect(try await context.store.fetchInbox().first?.isRead == true)
    #expect(try await context.store.pendingOperations(accountID: context.accountID).count == 1)
  }

  @Test
  func bodyCachePruningKeepsOnlyTheMostRecentFiles() async throws {
    let context = try await makeStore()
    defer { context.cleanup() }

    var bodyURLs: [URL] = []
    for index in 0..<3 {
      let bodyURL = context.directory.appendingPathComponent("body-\(index).txt")
      try Data("Body \(index)".utf8).write(to: bodyURL)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index + 1))],
        ofItemAtPath: bodyURL.path
      )
      bodyURLs.append(bodyURL)
      try await context.store.addMessage(
        NewMessage(
          accountID: context.accountID,
          remoteID: "cached-\(index)",
          remoteUID: Int64(index + 1),
          uidValidity: 1,
          receivedAt: Int64(index + 1),
          sender: "Sender",
          recipients: "me@example.com",
          cc: "",
          internetMessageID: "",
          subject: "Cached \(index)",
          preview: "",
          isRead: true,
          mailboxState: .inbox,
          bodyPath: bodyURL.path
        ))
    }

    try await context.store.pruneBodyCache(maximumFiles: 2)

    #expect(!FileManager.default.fileExists(atPath: bodyURLs[0].path))
    #expect(FileManager.default.fileExists(atPath: bodyURLs[1].path))
    #expect(FileManager.default.fileExists(atPath: bodyURLs[2].path))
    #expect(try await context.store.fetchInbox().compactMap(\.bodyPath).count == 2)
  }

  @Test
  func deduplicatesRepeatedPendingOperations() async throws {
    let context = try await makeStore(provider: "gmail")
    defer { context.cleanup() }

    let messageID = try await context.store.addMessage(
      NewMessage(
        accountID: context.accountID,
        remoteID: "deduplicated-operation",
        remoteUID: 300,
        uidValidity: 22,
        receivedAt: 1_700_000_000,
        sender: "Sender",
        recipients: "me@example.com",
        cc: "",
        internetMessageID: "",
        subject: "Queued once",
        preview: "",
        isRead: false,
        mailboxState: .inbox,
        bodyPath: nil
      ))
    try await context.store.markRead(messageID: messageID)
    try await context.store.markRead(messageID: messageID)

    #expect(try await context.store.pendingOperations(accountID: context.accountID).count == 1)
  }

  @Test
  func exposesAndCompletesQueuedGmailOperations() async throws {
    let context = try await makeStore(provider: "gmail")
    defer { context.cleanup() }

    let messageID = try await context.store.addMessage(
      NewMessage(
        accountID: context.accountID,
        remoteID: "gmail-operation",
        remoteUID: 301,
        uidValidity: 22,
        receivedAt: 1_700_000_000,
        sender: "Sender",
        recipients: "me@example.com",
        cc: "",
        internetMessageID: "",
        subject: "Queued action",
        preview: "",
        isRead: false,
        mailboxState: .inbox,
        bodyPath: nil
      ))
    try await context.store.archive(messageID: messageID)

    let operation = try #require(try await context.store.pendingOperations(
      accountID: context.accountID
    ).first)
    #expect(operation.kind == .archive)
    #expect(operation.remoteUID == 301)
    #expect(operation.uidValidity == 22)
    #expect(!(try await context.store.cacheBody(at: "/tmp/body", messageID: messageID)))

    try await context.store.completePendingOperation(id: operation.id)
    #expect(try await context.store.pendingOperations(accountID: context.accountID).isEmpty)
  }

  @Test
  func ccMigrationRefreshesGmailMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FlitMigrationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let path = directory.appendingPathComponent("flit.sqlite3").path
    do {
      let legacy = try SQLiteDatabase(path: path)
      try legacy.execute(
        """
        CREATE TABLE accounts (
          id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE,
          provider TEXT NOT NULL, uid_validity INTEGER, highest_uid INTEGER,
          highest_modseq TEXT
        );
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY, account_id INTEGER NOT NULL,
          remote_id TEXT NOT NULL, remote_uid INTEGER, uid_validity INTEGER,
          received_at INTEGER NOT NULL, sender TEXT NOT NULL DEFAULT '',
          recipients TEXT NOT NULL DEFAULT '', subject TEXT NOT NULL DEFAULT '',
          preview TEXT NOT NULL DEFAULT '', flags INTEGER NOT NULL DEFAULT 0,
          mailbox_state INTEGER NOT NULL DEFAULT 0, body_path TEXT,
          UNIQUE(account_id, remote_id)
        );
        INSERT INTO accounts
          (name, email, provider, uid_validity, highest_uid, highest_modseq)
        VALUES ('Gmail', 'me@example.com', 'gmail', 7, 42, '9');
        """)
    }

    let store = try MailStore(path: path)
    let account = try #require(try await store.accounts(provider: "gmail").first)
    #expect(account.syncCursor == nil)

    _ = try await store.addMessage(
      NewMessage(
        accountID: account.id, remoteID: "gmail-1", remoteUID: 42, uidValidity: 7,
        receivedAt: 1_700_000_000, sender: "Maya", recipients: "me@example.com",
        cc: "team@example.com", internetMessageID: "<hello@example.com>",
        subject: "Hello", preview: "", isRead: false,
        mailboxState: .inbox, bodyPath: nil
      ))
    let migratedMessage = try await store.fetchInbox().first
    #expect(migratedMessage?.cc == "team@example.com")
    #expect(migratedMessage?.internetMessageID == "<hello@example.com>")
  }

  private func makeStore(provider: String = "test") async throws -> TestContext {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FlitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let store = try MailStore(path: directory.appendingPathComponent("flit.sqlite3").path)
    let accountID = try await store.addAccount(
      name: "Test account",
      email: "me@example.com",
      provider: provider
    )
    return TestContext(store: store, accountID: accountID, directory: directory)
  }
}

private struct TestContext {
  let store: MailStore
  let accountID: Int64
  let directory: URL

  func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }
}
