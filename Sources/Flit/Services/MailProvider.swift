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

struct LocalInboxMessageState: Sendable, Equatable {
  let id: Int64
  let remoteID: String
  let remoteUID: Int64?
  let uidValidity: Int64?
  let isRead: Bool
}

struct RemoteInboxMessageState: Sendable, Equatable {
  let remoteID: String
  let remoteUID: Int64
  let uidValidity: Int64
  let isRead: Bool
}

enum RemoteRemovalDestination: Sendable, Equatable {
  case archive
  case trash
  case delete
}

struct RemoteInboxRemoval: Sendable, Equatable {
  let remoteID: String
  let destination: RemoteRemovalDestination
}

struct InboxReconciliationResult: Sendable, Equatable {
  let messages: [RemoteInboxMessageState]
  let removals: [RemoteInboxRemoval]
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
  func reconcileInbox(_ messages: [LocalInboxMessageState]) async throws
    -> InboxReconciliationResult
  func fetchOlderInbox(beforeRemoteUID: Int64, limit: Int) async throws -> [NewMessage]
  func searchInbox(query: String, limit: Int) async throws -> [NewMessage]
  func fetchPlainTextBody(remoteID: String) async throws -> URL
  func markRead(remoteID: String) async throws
  func archive(remoteID: String) async throws
  func moveToTrash(remoteID: String) async throws
  func send(_ message: OutgoingMessage) async throws
}
