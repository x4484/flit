import Foundation

enum MailboxState: Int32, Sendable {
  case inbox = 0
  case archive = 1
  case trash = 2
}

enum PendingOperationKind: Int32, Sendable, Equatable {
  case archive = 0
  case trash = 1
  case markRead = 2
  case send = 3
}

struct PageCursor: Sendable, Equatable {
  let receivedAt: Int64
  let id: Int64
}

struct MailAccount: Sendable, Equatable, Identifiable {
  let id: Int64
  let name: String
  let email: String
  let provider: String
  let syncCursor: SyncCursor?
}

struct MessageSummary: Sendable, Equatable, Identifiable {
  let id: Int64
  let accountID: Int64
  let accountName: String
  let accountEmail: String
  let accountProvider: String
  let remoteID: String
  let threadRemoteID: String
  let remoteUID: Int64?
  let receivedAt: Int64
  let sender: String
  let recipients: String
  let cc: String
  let internetMessageID: String
  let subject: String
  var preview: String
  var isRead: Bool
  let mailboxState: MailboxState
  let bodyPath: String?

  init(
    id: Int64,
    accountID: Int64,
    accountName: String,
    accountEmail: String,
    accountProvider: String,
    remoteID: String,
    threadRemoteID: String = "",
    remoteUID: Int64?,
    receivedAt: Int64,
    sender: String,
    recipients: String,
    cc: String,
    internetMessageID: String,
    subject: String,
    preview: String,
    isRead: Bool,
    mailboxState: MailboxState,
    bodyPath: String?
  ) {
    self.id = id
    self.accountID = accountID
    self.accountName = accountName
    self.accountEmail = accountEmail
    self.accountProvider = accountProvider
    self.remoteID = remoteID
    self.threadRemoteID = threadRemoteID
    self.remoteUID = remoteUID
    self.receivedAt = receivedAt
    self.sender = sender
    self.recipients = recipients
    self.cc = cc
    self.internetMessageID = internetMessageID
    self.subject = subject
    self.preview = preview
    self.isRead = isRead
    self.mailboxState = mailboxState
    self.bodyPath = bodyPath
  }

  var cursor: PageCursor {
    PageCursor(receivedAt: receivedAt, id: id)
  }

  var receivedDate: Date {
    Date(timeIntervalSince1970: TimeInterval(receivedAt))
  }
}

struct PendingMailOperation: Sendable, Equatable, Identifiable {
  let id: Int64
  let messageID: Int64
  let accountID: Int64
  let accountEmail: String
  let remoteID: String
  let remoteUID: Int64
  let uidValidity: Int64?
  let kind: PendingOperationKind
  let attempts: Int
}

struct NewMessage: Sendable, Equatable {
  let accountID: Int64
  let remoteID: String
  let threadRemoteID: String
  let remoteUID: Int64?
  let uidValidity: Int64?
  let receivedAt: Int64
  let sender: String
  let recipients: String
  let cc: String
  let internetMessageID: String
  let subject: String
  let preview: String
  let isRead: Bool
  let mailboxState: MailboxState
  let bodyPath: String?

  init(
    accountID: Int64,
    remoteID: String,
    threadRemoteID: String = "",
    remoteUID: Int64?,
    uidValidity: Int64?,
    receivedAt: Int64,
    sender: String,
    recipients: String,
    cc: String,
    internetMessageID: String,
    subject: String,
    preview: String,
    isRead: Bool,
    mailboxState: MailboxState,
    bodyPath: String?
  ) {
    self.accountID = accountID
    self.remoteID = remoteID
    self.threadRemoteID = threadRemoteID
    self.remoteUID = remoteUID
    self.uidValidity = uidValidity
    self.receivedAt = receivedAt
    self.sender = sender
    self.recipients = recipients
    self.cc = cc
    self.internetMessageID = internetMessageID
    self.subject = subject
    self.preview = preview
    self.isRead = isRead
    self.mailboxState = mailboxState
    self.bodyPath = bodyPath
  }
}
