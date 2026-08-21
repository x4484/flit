import Foundation

struct SyncCursor: Sendable, Equatable {
  let uidValidity: Int64?
  let highestUID: Int64?
  let highestModSequence: String?
}

struct SyncResult: Sendable {
  let messages: [NewMessage]
  let removedRemoteIDs: [String]
  let cursor: SyncCursor
}

extension SyncResult {
  static func empty(cursor: SyncCursor) -> SyncResult {
    SyncResult(messages: [], removedRemoteIDs: [], cursor: cursor)
  }
}

struct OutgoingMessage: Sendable, Equatable {
  let sender: String
  let recipients: [String]
  let ccRecipients: [String]
  let subject: String
  let plainTextBody: String
  let inReplyTo: String?
}

protocol MailProvider: Sendable {
  func syncInbox(from cursor: SyncCursor?) async throws -> SyncResult
  func fetchPlainTextBody(remoteID: String) async throws -> URL
  func markRead(remoteID: String) async throws
  func archive(remoteID: String) async throws
  func moveToTrash(remoteID: String) async throws
  func send(_ message: OutgoingMessage) async throws
}
