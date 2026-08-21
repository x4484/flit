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
  func reconciliationFindsMessagesRemovedFromTheRemoteInbox() {
    let local = [
      LocalInboxMessageState(
        id: 1, remoteID: "1001", remoteUID: 71, uidValidity: 9, isRead: false),
      LocalInboxMessageState(
        id: 2, remoteID: "1002", remoteUID: 72, uidValidity: 9, isRead: false),
    ]
    let remote = [
      RemoteInboxMessageState(
        remoteID: "1002", remoteUID: 72, uidValidity: 9, isRead: true)
    ]

    let result = GmailIMAPProvider.reconciliation(
      localMessages: local,
      remoteStates: remote
    )

    #expect(result.messages == remote)
    #expect(
      result.removals == [
        RemoteInboxRemoval(remoteID: "1001", destination: .archive)
      ])
  }

  @Test
  func classifiesRemoteMovesAndPermanentDeletions() {
    let removals = GmailIMAPProvider.classifiedRemovals(
      missingRemoteIDs: ["1003", "1002", "1001"],
      trashRemoteIDs: ["1002"],
      allMailRemoteIDs: ["1001"]
    )

    #expect(
      removals == [
        RemoteInboxRemoval(remoteID: "1001", destination: .archive),
        RemoteInboxRemoval(remoteID: "1002", destination: .trash),
        RemoteInboxRemoval(remoteID: "1003", destination: .delete),
      ])
  }

  @Test
  func computesABoundedOlderSequenceWindow() {
    #expect(
      GmailIMAPProvider.olderSequenceNumbers(beforeSequence: 51, limit: 25)
        == Array(26...50).map(Int64.init)
    )
    #expect(GmailIMAPProvider.olderSequenceNumbers(beforeSequence: 1, limit: 25).isEmpty)
  }

  @Test
  func safelyQuotesGmailRawSearches() {
    let command = GmailIMAPProvider.inboxSearchCommand(
      query: "from:\"Maya\"\nUID STORE 1 +FLAGS (\\Deleted)"
    )

    #expect(
      command
        == "UID SEARCH X-GM-RAW \"from:\\\"Maya\\\" UID STORE 1 +FLAGS (\\\\Deleted)\""
    )
    #expect(command?.contains("\n") == false)
    #expect(GmailIMAPProvider.inboxSearchCommand(query: "   ") == nil)
  }

  @Test
  func trashMovesTheMessageIntoGmailTrash() {
    #expect(
      GmailIMAPProvider.mailboxMoveCommand(kind: .trash, remoteUID: 76)
        == "UID MOVE 76 \"[Gmail]/Trash\""
    )
  }
}
