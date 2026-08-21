import Testing

@testable import Flit

struct BodyPrefetchPlannerTests {
  @Test
  func keepsTenEligibleMessagesAheadOfConsumedMail() {
    var messages = (1...14).map { message(id: Int64($0)) }
    messages.insert(message(id: 100, provider: "icloud"), at: 1)
    messages.insert(message(id: 101, mailboxState: .archive), at: 2)

    let candidates = BodyPrefetchPlanner.candidates(
      from: messages,
      excluding: [1, 3]
    )

    #expect(candidates.map(\.id) == [2, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    #expect(BodyPrefetchPlanner.targetCount == 10)
    #expect(BodyPrefetchPlanner.maximumCachedBodies > BodyPrefetchPlanner.targetCount)
  }

  private func message(
    id: Int64,
    provider: String = "gmail",
    mailboxState: MailboxState = .inbox
  ) -> MessageSummary {
    MessageSummary(
      id: id,
      accountID: 1,
      accountName: "Mail",
      accountEmail: "me@example.com",
      accountProvider: provider,
      remoteID: String(id),
      remoteUID: id,
      receivedAt: 1_800_000_000 - id,
      sender: "Sender",
      recipients: "me@example.com",
      cc: "",
      internetMessageID: "<\(id)@example.com>",
      subject: "Message \(id)",
      preview: "",
      isRead: false,
      mailboxState: mailboxState,
      bodyPath: nil
    )
  }
}
