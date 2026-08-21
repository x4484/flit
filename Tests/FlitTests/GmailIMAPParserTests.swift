import Foundation
import Testing

@testable import Flit

struct GmailIMAPParserTests {
  @Test
  func parsesMailboxSelectionTranscript() throws {
    let result = IMAPCommandResult(responses: [
      IMAPResponse(line: "* 248 EXISTS", literal: nil),
      IMAPResponse(line: "* OK [UIDVALIDITY 1779123456] UIDs valid", literal: nil),
      IMAPResponse(line: "* OK [HIGHESTMODSEQ 98211]", literal: nil),
      IMAPResponse(line: "A0002 OK [READ-ONLY] INBOX selected", literal: nil),
    ])

    let mailbox = try GmailIMAPParser.mailboxState(from: result)

    #expect(mailbox.messageCount == 248)
    #expect(mailbox.uidValidity == 1_779_123_456)
    #expect(mailbox.highestModSequence == "98211")
  }

  @Test
  func parsesFetchedGmailMetadataTranscript() throws {
    let headers = Data(
      """
      Message-ID: <project-99@example.com>\r
      From: =?UTF-8?Q?Maya_Chen?= <maya@example.com>\r
      To: me@example.com\r
      Cc: team@example.com\r
      Subject: =?UTF-8?Q?Project_=E2=9C=93?=\r
      Date: Thu, 20 Aug 2026 10:15:00 +0000\r
      \r
      """.utf8)
    let response = IMAPResponse(
      line:
        "* 42 FETCH (X-GM-MSGID 1888123412341234 UID 99 FLAGS (\\Seen) INTERNALDATE \"20-Aug-2026 10:15:00 +0000\" BODY[HEADER.FIELDS (MESSAGE-ID FROM TO CC SUBJECT DATE)] {\(headers.count)} )",
      literal: headers
    )

    let message = try #require(
      try GmailIMAPParser.message(from: response, accountID: 7, uidValidity: 123))

    #expect(message.accountID == 7)
    #expect(message.remoteID == "1888123412341234")
    #expect(message.remoteUID == 99)
    #expect(message.uidValidity == 123)
    #expect(message.sender == "Maya Chen <maya@example.com>")
    #expect(message.recipients == "me@example.com")
    #expect(message.cc == "team@example.com")
    #expect(message.internetMessageID == "<project-99@example.com>")
    #expect(message.subject == "Project ✓")
    #expect(message.isRead)
    #expect(message.preview.isEmpty)
  }

  @Test
  func parsesRemoteInboxFlagsWithoutFetchingHeaders() throws {
    let response = IMAPResponse(
      line: "* 17 FETCH (UID 301 X-GM-MSGID 1888123412345678 FLAGS (\\Seen \\Flagged))",
      literal: nil
    )

    let state = try #require(
      try GmailIMAPParser.remoteMessageState(from: response, uidValidity: 44)
    )

    #expect(state.remoteID == "1888123412345678")
    #expect(state.remoteUID == 301)
    #expect(state.uidValidity == 44)
    #expect(state.isRead)
  }

  @Test
  func searchTranscriptFiltersAlreadySynchronizedUIDs() {
    let result = IMAPCommandResult(responses: [
      IMAPResponse(line: "* SEARCH 98 99 101 103", literal: nil),
      IMAPResponse(line: "A0003 OK SEARCH completed", literal: nil),
    ])

    #expect(GmailIMAPParser.searchedUIDs(from: result, greaterThan: 99) == [101, 103])
  }

  @Test
  func rejectsFetchTranscriptWithoutUID() {
    let response = IMAPResponse(
      line: "* 42 FETCH (FLAGS () BODY[HEADER.FIELDS (FROM SUBJECT)] {16} )",
      literal: Data("Subject: Missing".utf8)
    )

    #expect(throws: GmailIMAPParserError.self) {
      try GmailIMAPParser.message(from: response, accountID: 1, uidValidity: 2)
    }
  }
}
