import Foundation

enum MailboxState: Int32, Sendable {
  case inbox = 0
  case archive = 1
  case trash = 2
}

enum PendingOperationKind: Int32, Sendable {
  case archive = 0
  case trash = 1
  case markRead = 2
  case send = 3
}

struct PageCursor: Sendable, Equatable {
  let receivedAt: Int64
  let id: Int64
}

struct MessageSummary: Sendable, Equatable, Identifiable {
  let id: Int64
  let accountID: Int64
  let accountName: String
  let accountEmail: String
  let remoteID: String
  let remoteUID: Int64?
  let receivedAt: Int64
  let sender: String
  let recipients: String
  let subject: String
  let preview: String
  let isRead: Bool
  let mailboxState: MailboxState
  let bodyPath: String?

  var cursor: PageCursor {
    PageCursor(receivedAt: receivedAt, id: id)
  }

  var receivedDate: Date {
    Date(timeIntervalSince1970: TimeInterval(receivedAt))
  }
}

struct NewMessage: Sendable {
  let accountID: Int64
  let remoteID: String
  let remoteUID: Int64?
  let uidValidity: Int64?
  let receivedAt: Int64
  let sender: String
  let recipients: String
  let subject: String
  let preview: String
  let isRead: Bool
  let mailboxState: MailboxState
  let bodyPath: String?
}
