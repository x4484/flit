import Testing

@testable import Flit

struct GmailOperationTests {
  @Test
  func archiveMovesTheMessageOutOfInboxAndIntoAllMail() {
    #expect(
      GmailIMAPProvider.mailboxMoveCommand(kind: .archive, remoteUID: 76)
        == "UID MOVE 76 \"[Gmail]/All Mail\""
    )
  }

  @Test
  func trashMovesTheMessageIntoGmailTrash() {
    #expect(
      GmailIMAPProvider.mailboxMoveCommand(kind: .trash, remoteUID: 76)
        == "UID MOVE 76 \"[Gmail]/Trash\""
    )
  }
}
