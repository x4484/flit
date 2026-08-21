import Foundation

enum BodyPrefetchPlanner {
  static let targetCount = 10
  static let maximumCachedBodies = 16

  static func candidates(
    from messages: [MessageSummary],
    excluding consumedMessageIDs: Set<Int64>
  ) -> [MessageSummary] {
    Array(
      messages.lazy
        .filter {
          $0.accountProvider == "gmail"
            && $0.mailboxState == .inbox
            && !consumedMessageIDs.contains($0.id)
        }
        .prefix(targetCount)
    )
  }
}
