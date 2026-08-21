import Foundation

enum ComposeMode: Sendable {
  case reply
  case replyAll
  case forward
}

struct ComposeDraft: Sendable, Equatable {
  let sender: String
  var to: String
  var cc: String
  var subject: String
  var body: String
  let quotedDisplayText: String?
  let quotedPlainText: String?
  let inReplyTo: String?
}

enum EmailAddressParser {
  private static let pattern = #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+"#

  static func addresses(in source: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }

    let range = NSRange(source.startIndex..., in: source)
    var seen: Set<String> = []
    return expression.matches(in: source, range: range).compactMap { match in
      guard let range = Range(match.range, in: source) else { return nil }
      let address = String(source[range]).lowercased()
      return seen.insert(address).inserted ? address : nil
    }
  }
}

enum ReplyDraftBuilder {
  static func draft(
    mode: ComposeMode,
    message: MessageSummary,
    originalBody: String,
    dateText: String
  ) -> ComposeDraft {
    let senderAddresses = EmailAddressParser.addresses(in: message.sender)
    let ownAddress = message.accountEmail.lowercased()
    let originalRecipients = EmailAddressParser.addresses(
      in: message.recipients + ", " + message.cc
    )
    let replyTo = senderAddresses.first.map { [$0] } ?? []

    let to: [String]
    let cc: [String]
    let subject: String
    let quotedDisplayText: String
    let quotedPlainText: String

    switch mode {
    case .reply:
      to = replyTo
      cc = []
      subject = prefixedSubject(message.subject, prefix: "Re:")
      quotedDisplayText = replyDisplayText(
        sender: message.sender, dateText: dateText, originalBody: originalBody)
      quotedPlainText = replyPlainText(
        sender: message.sender, dateText: dateText, originalBody: originalBody)
    case .replyAll:
      to = replyTo
      let excluded = Set(replyTo.map { $0.lowercased() } + [ownAddress])
      cc = originalRecipients.filter { !excluded.contains($0.lowercased()) }
      subject = prefixedSubject(message.subject, prefix: "Re:")
      quotedDisplayText = replyDisplayText(
        sender: message.sender, dateText: dateText, originalBody: originalBody)
      quotedPlainText = replyPlainText(
        sender: message.sender, dateText: dateText, originalBody: originalBody)
    case .forward:
      to = []
      cc = []
      subject = prefixedSubject(message.subject, prefix: "Fwd:")
      quotedDisplayText = forwardedBody(
        message: message, dateText: dateText, originalBody: originalBody, decorated: false)
      quotedPlainText = forwardedBody(
        message: message, dateText: dateText, originalBody: originalBody, decorated: true)
    }

    return ComposeDraft(
      sender: message.accountEmail,
      to: to.joined(separator: ", "),
      cc: cc.joined(separator: ", "),
      subject: subject,
      body: "",
      quotedDisplayText: quotedDisplayText,
      quotedPlainText: quotedPlainText,
      inReplyTo: mode == .forward || message.internetMessageID.isEmpty
        ? nil
        : message.internetMessageID
    )
  }

  private static func prefixedSubject(_ subject: String, prefix: String) -> String {
    let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return prefix }
    if trimmed.lowercased().hasPrefix(prefix.lowercased()) { return trimmed }
    return "\(prefix) \(trimmed)"
  }

  private static func replyDisplayText(
    sender: String,
    dateText: String,
    originalBody: String
  ) -> String {
    "On \(dateText), \(sender) wrote:\n"
      + originalBody.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func replyPlainText(
    sender: String,
    dateText: String,
    originalBody: String
  ) -> String {
    "On \(dateText), \(sender) wrote:\n\(quote(originalBody))"
  }

  private static func forwardedBody(
    message: MessageSummary,
    dateText: String,
    originalBody: String,
    decorated: Bool
  ) -> String {
    var headers = [
      "From: \(message.sender)",
      "Date: \(dateText)",
      "Subject: \(message.subject)",
      "To: \(message.recipients)",
    ]
    if !message.cc.isEmpty { headers.append("Cc: \(message.cc)") }
    let heading = decorated ? "---------- Forwarded message ----------" : "Forwarded message"
    return heading + "\n"
      + headers.joined(separator: "\n")
      + "\n\n"
      + originalBody
  }

  private static func quote(_ body: String) -> String {
    let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return ">" }
    return normalized.components(separatedBy: .newlines)
      .map { $0.isEmpty ? ">" : "> \($0)" }
      .joined(separator: "\n")
  }
}
