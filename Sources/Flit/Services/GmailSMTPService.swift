import Foundation

enum OutgoingMessageError: Error, LocalizedError {
  case invalidSender
  case missingRecipient
  case invalidRecipient

  var errorDescription: String? {
    switch self {
    case .invalidSender:
      return "The sending Gmail account is invalid."
    case .missingRecipient:
      return "Add at least one recipient."
    case .invalidRecipient:
      return "Use valid email addresses in the To and Cc fields."
    }
  }
}

actor GmailSMTPService {
  private let oauth: GoogleOAuthService

  init(oauth: GoogleOAuthService) {
    self.oauth = oauth
  }

  func send(_ message: OutgoingMessage) async throws {
    guard EmailAddressParser.addresses(in: message.sender) == [message.sender.lowercased()] else {
      throw OutgoingMessageError.invalidSender
    }
    let recipients = message.recipients + message.ccRecipients
    guard !recipients.isEmpty else { throw OutgoingMessageError.missingRecipient }
    guard recipients.allSatisfy({ EmailAddressParser.addresses(in: $0) == [$0.lowercased()] }) else {
      throw OutgoingMessageError.invalidRecipient
    }

    let session = try await oauth.refreshAccessToken(email: message.sender)
    let transport = try SMTPTransport(host: "smtp.gmail.com", port: 465)
    do {
      try await transport.connect()
      _ = try await transport.execute("EHLO localhost", expecting: 250)
      let authentication = GmailXOAUTH2.initialClientResponse(
        email: message.sender,
        accessToken: session.accessToken
      )
      _ = try await transport.execute("AUTH XOAUTH2 \(authentication)", expecting: 235)
      _ = try await transport.execute("MAIL FROM:<\(message.sender)>", expecting: 250)
      for recipient in recipients {
        _ = try await transport.execute("RCPT TO:<\(recipient)>", expecting: 250)
      }
      try await transport.sendMessage(RFC5322MessageBuilder.build(message))
      _ = try? await transport.execute("QUIT", expecting: 221)
      transport.close()
    } catch {
      transport.close()
      throw error
    }
  }
}

enum RFC5322MessageBuilder {
  static func build(_ message: OutgoingMessage, now: Date = Date()) -> Data {
    let sender = sanitizedHeader(message.sender)
    let recipients = message.recipients.map(sanitizedHeader).joined(separator: ", ")
    let ccRecipients = message.ccRecipients.map(sanitizedHeader).joined(separator: ", ")
    let subject = encodedSubject(sanitizedHeader(message.subject))
    let domain = sender.split(separator: "@", maxSplits: 1).last.map(String.init) ?? "localhost"

    var headers = [
      "Date: \(dateString(now))",
      "Message-ID: <\(UUID().uuidString.lowercased())@\(domain)>",
      "From: \(sender)",
      "To: \(recipients)",
    ]
    if !ccRecipients.isEmpty { headers.append("Cc: \(ccRecipients)") }
    if let inReplyTo = message.inReplyTo.map(sanitizedHeader), !inReplyTo.isEmpty {
      headers.append("In-Reply-To: \(inReplyTo)")
      headers.append("References: \(inReplyTo)")
    }
    headers.append(contentsOf: [
      "Subject: \(subject)",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Transfer-Encoding: base64",
    ])

    let body = Data(message.plainTextBody.utf8).base64EncodedString()
    let foldedBody = stride(from: 0, to: body.count, by: 76).map { offset -> String in
      let start = body.index(body.startIndex, offsetBy: offset)
      let end = body.index(start, offsetBy: min(76, body.count - offset))
      return String(body[start..<end])
    }.joined(separator: "\r\n")

    return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + foldedBody).utf8)
  }

  private static func sanitizedHeader(_ value: String) -> String {
    value.replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
  }

  private static func encodedSubject(_ subject: String) -> String {
    guard !subject.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) else {
      return subject
    }
    return "=?UTF-8?B?\(Data(subject.utf8).base64EncodedString())?="
  }

  private static func dateString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
    return formatter.string(from: date)
  }
}
