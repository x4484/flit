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
        subject: "Quarterly planning",
        preview: "Notes for the planning session",
        isRead: false,
        mailboxState: .inbox,
        bodyPath: nil
      ))

    #expect(try await context.store.fetchInbox().count == 1)

    try await context.store.archive(messageID: messageID)

    #expect(try await context.store.fetchInbox().isEmpty)
    let results = try await context.store.search("quarterly")
    #expect(results.map(\.id) == [messageID])
    #expect(results.first?.mailboxState == .archive)
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

  private func makeStore() async throws -> TestContext {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("FlitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let store = try MailStore(path: directory.appendingPathComponent("flit.sqlite3").path)
    let accountID = try await store.addAccount(
      name: "Test account",
      email: "me@example.com",
      provider: "test"
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
