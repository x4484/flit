import AppKit
import Foundation
import Testing

@testable import Flit

struct EmailCompositionTests {
  @Test
  func parsesAndDeduplicatesMailboxAddresses() {
    let addresses = EmailAddressParser.addresses(
      in: "Maya <MAYA@example.com>, team@example.com; maya@example.com")
    #expect(addresses == ["maya@example.com", "team@example.com"])
  }

  @Test
  func replyAllExcludesTheSendingAccountAndKeepsOtherRecipients() {
    let draft = ReplyDraftBuilder.draft(
      mode: .replyAll,
      message: message(),
      originalBody: "First line\n\nSecond line",
      dateText: "Aug 20, 2026 at 10:15 PM"
    )

    #expect(draft.sender == "me@example.com")
    #expect(draft.to == "maya@example.com")
    #expect(draft.cc == "team@example.com")
    #expect(draft.subject == "Re: Project update")
    #expect(draft.inReplyTo == "<original@example.com>")
    #expect(draft.body.isEmpty)
    #expect(draft.quotedDisplayText?.contains("First line\n\nSecond line") == true)
    #expect(draft.quotedPlainText?.contains("> First line\n>\n> Second line") == true)
  }

  @Test
  func forwardStartsWithEmptyRecipientsAndPreservesHeaders() {
    let draft = ReplyDraftBuilder.draft(
      mode: .forward,
      message: message(),
      originalBody: "Original body",
      dateText: "Aug 20, 2026 at 10:15 PM"
    )

    #expect(draft.to.isEmpty)
    #expect(draft.cc.isEmpty)
    #expect(draft.subject == "Fwd: Project update")
    #expect(draft.inReplyTo == nil)
    #expect(draft.quotedDisplayText?.contains("From: Maya <maya@example.com>") == true)
    #expect(draft.quotedDisplayText?.hasSuffix("Original body") == true)
    #expect(draft.quotedPlainText?.contains("---------- Forwarded message ----------") == true)
  }

  @Test
  func buildsSafeRFC5322PlainTextMessage() {
    let outgoing = OutgoingMessage(
      sender: "me@example.com",
      recipients: ["maya@example.com"],
      ccRecipients: ["team@example.com"],
      subject: "Hello ✓\r\nBcc: attacker@example.com",
      plainTextBody: "Hello Maya",
      inReplyTo: "<original@example.com>"
    )

    let data = RFC5322MessageBuilder.build(
      outgoing,
      now: Date(timeIntervalSince1970: 1_787_263_200)
    )
    let source = String(decoding: data, as: UTF8.self)

    #expect(source.contains("From: me@example.com\r\n"))
    #expect(source.contains("To: maya@example.com\r\n"))
    #expect(source.contains("Cc: team@example.com\r\n"))
    #expect(source.contains("In-Reply-To: <original@example.com>\r\n"))
    #expect(source.contains("References: <original@example.com>\r\n"))
    #expect(source.contains("Subject: =?UTF-8?B?"))
    #expect(!source.contains("\r\nBcc: attacker@example.com\r\n"))
    #expect(source.hasSuffix(Data("Hello Maya".utf8).base64EncodedString()))
  }

  @Test @MainActor
  func rendersQuoteMarkersAsNestedIndentation() {
    let rendered = QuotedThreadRenderer.render(
      "On Aug 20, Maya wrote:\n> First level\n>> Nested level")

    #expect(rendered.string == "On Aug 20, Maya wrote:\nFirst level\nNested level")
    let nestedLocation = (rendered.string as NSString).range(of: "Nested level").location
    let paragraph = rendered.attribute(
      .paragraphStyle,
      at: nestedLocation,
      effectiveRange: nil
    ) as? NSParagraphStyle
    #expect(paragraph?.headIndent == 28)
  }

  @Test
  func dotStuffsAndNormalizesSMTPData() {
    let normalized = SMTPTransport.normalizedForData(Data("one\n.two\r\nthree\r".utf8))
    #expect(String(decoding: normalized, as: UTF8.self) == "one\r\n..two\r\nthree")
  }

  private func message() -> MessageSummary {
    MessageSummary(
      id: 1,
      accountID: 2,
      accountName: "Gmail",
      accountEmail: "me@example.com",
      accountProvider: "gmail",
      remoteID: "123",
      remoteUID: 9,
      receivedAt: 1_787_263_200,
      sender: "Maya <maya@example.com>",
      recipients: "me@example.com, team@example.com",
      cc: "team@example.com",
      internetMessageID: "<original@example.com>",
      subject: "Project update",
      preview: "Original body",
      isRead: false,
      mailboxState: .inbox,
      bodyPath: nil
    )
  }
}
