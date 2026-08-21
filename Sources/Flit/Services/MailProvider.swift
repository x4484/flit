import Foundation

struct SyncCursor: Sendable {
  let uidValidity: Int64?
  let highestUID: Int64?
  let highestModSequence: String?
}

struct SyncResult: Sendable {
  let messages: [NewMessage]
  let removedRemoteIDs: [String]
  let cursor: SyncCursor
}

struct OutgoingMessage: Sendable {
  let sender: String
  let recipients: [String]
  let subject: String
  let plainTextBody: String
}

protocol MailProvider: Sendable {
  func syncInbox(from cursor: SyncCursor?) async throws -> SyncResult
  func fetchPlainTextBody(remoteID: String) async throws -> URL
  func markRead(remoteID: String) async throws
  func archive(remoteID: String) async throws
  func moveToTrash(remoteID: String) async throws
  func send(_ message: OutgoingMessage) async throws
}
