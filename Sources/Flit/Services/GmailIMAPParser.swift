import Foundation

struct IMAPMailboxState: Sendable, Equatable {
  let messageCount: Int
  let uidValidity: Int64
  let highestModSequence: String?
}

enum GmailIMAPParserError: Error, LocalizedError {
  case missingMailboxState
  case malformedMessage

  var errorDescription: String? {
    switch self {
    case .missingMailboxState:
      return "Gmail did not provide the inbox synchronization state."
    case .malformedMessage:
      return "Gmail returned malformed message metadata."
    }
  }
}

enum GmailIMAPParser {
  static func mailboxState(from result: IMAPCommandResult) throws -> IMAPMailboxState {
    var messageCount: Int?
    var uidValidity: Int64?
    var highestModSequence: String?

    for response in result.responses {
      if let value = firstCapture(#"^\*\s+(\d+)\s+EXISTS\b"#, in: response.line) {
        messageCount = Int(value)
      }
      if let value = firstCapture(#"\bUIDVALIDITY\s+(\d+)\b"#, in: response.line) {
        uidValidity = Int64(value)
      }
      if let value = firstCapture(#"\bHIGHESTMODSEQ\s+(\d+)\b"#, in: response.line) {
        highestModSequence = value
      }
    }

    guard let messageCount, let uidValidity else {
      throw GmailIMAPParserError.missingMailboxState
    }
    return IMAPMailboxState(
      messageCount: messageCount,
      uidValidity: uidValidity,
      highestModSequence: highestModSequence
    )
  }

  static func searchedUIDs(from result: IMAPCommandResult, greaterThan minimum: Int64) -> [Int64] {
    result.responses
      .filter { $0.line.uppercased().hasPrefix("* SEARCH") }
      .flatMap { response in
        response.line.split(separator: " ").dropFirst(2).compactMap { Int64($0) }
      }
      .filter { $0 > minimum }
      .sorted()
  }

  static func gmailMessageID(from response: IMAPResponse) -> String? {
    firstCapture(#"\bX-GM-MSGID\s+(\d+)\b"#, in: response.line)
  }

  static func message(
    from response: IMAPResponse,
    accountID: Int64,
    uidValidity: Int64
  ) throws -> NewMessage? {
    guard response.line.uppercased().contains(" FETCH ") else { return nil }
    guard let uidText = firstCapture(#"\bUID\s+(\d+)\b"#, in: response.line),
      let uid = Int64(uidText),
      let literal = response.literal
    else {
      throw GmailIMAPParserError.malformedMessage
    }

    let gmailMessageID = gmailMessageID(from: response)
    let remoteID = gmailMessageID ?? "\(uidValidity):\(uid)"
    let flags = firstCapture(#"\bFLAGS\s+\(([^)]*)\)"#, in: response.line) ?? ""
    let internalDate = firstCapture(#"\bINTERNALDATE\s+\"([^\"]+)\""#, in: response.line)
    let headers = parseHeaders(literal)

    let to = decodedHeader(headers["to"] ?? "")
    let cc = decodedHeader(headers["cc"] ?? "")

    return NewMessage(
      accountID: accountID,
      remoteID: remoteID,
      remoteUID: uid,
      uidValidity: uidValidity,
      receivedAt: receivedTimestamp(internalDate),
      sender: decodedHeader(headers["from"] ?? ""),
      recipients: to,
      cc: cc,
      internetMessageID: headers["message-id"]?.trimmingCharacters(in: .whitespaces) ?? "",
      subject: decodedHeader(headers["subject"] ?? ""),
      preview: "",
      isRead: flags.uppercased().contains("\\SEEN"),
      mailboxState: .inbox,
      bodyPath: nil
    )
  }

  private static func parseHeaders(_ data: Data) -> [String: String] {
    let source = String(decoding: data, as: UTF8.self)
    var headers: [String: String] = [:]
    var currentName: String?

    for line in source.components(separatedBy: "\r\n") {
      if line.isEmpty { break }
      if line.first?.isWhitespace == true, let currentName {
        headers[currentName, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
        continue
      }
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = String(line[..<colon]).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if let existing = headers[name], !existing.isEmpty {
        headers[name] = existing + ", " + value
      } else {
        headers[name] = value
      }
      currentName = name
    }
    return headers
  }

  private static func receivedTimestamp(_ internalDate: String?) -> Int64 {
    guard let internalDate else { return Int64(Date().timeIntervalSince1970) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
    return Int64(
      (formatter.date(from: internalDate) ?? Date()).timeIntervalSince1970
    )
  }

  private static func decodedHeader(_ value: String) -> String {
    let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]+)\?="#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
    var result = value
    let range = NSRange(result.startIndex..<result.endIndex, in: result)

    for match in expression.matches(in: result, range: range).reversed() {
      guard let matchRange = Range(match.range(at: 0), in: result),
        let charsetRange = Range(match.range(at: 1), in: result),
        let encodingRange = Range(match.range(at: 2), in: result),
        let payloadRange = Range(match.range(at: 3), in: result)
      else { continue }

      let charset = String(result[charsetRange]).lowercased()
      let encoding = String(result[encodingRange]).lowercased()
      let payload = String(result[payloadRange])
      let data =
        encoding == "b"
        ? Data(base64Encoded: payload)
        : decodeQuotedPrintableWord(payload)
      guard let data, let decoded = String(data: data, encoding: stringEncoding(charset)) else {
        continue
      }
      result.replaceSubrange(matchRange, with: decoded)
    }

    return result.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
  }

  private static func decodeQuotedPrintableWord(_ payload: String) -> Data? {
    let bytes = Array(payload.utf8)
    var decoded: [UInt8] = []
    decoded.reserveCapacity(bytes.count)
    var index = 0

    while index < bytes.count {
      if bytes[index] == 95 {
        decoded.append(32)
        index += 1
      } else if bytes[index] == 61, index + 2 < bytes.count,
        let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
      {
        decoded.append(high * 16 + low)
        index += 3
      } else {
        decoded.append(bytes[index])
        index += 1
      }
    }
    return Data(decoded)
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: return byte - 48
    case 65...70: return byte - 55
    case 97...102: return byte - 87
    default: return nil
    }
  }

  private static func stringEncoding(_ charset: String) -> String.Encoding {
    switch charset {
    case "iso-8859-1", "latin1": return .isoLatin1
    case "windows-1252": return .windowsCP1252
    case "us-ascii", "ascii": return .ascii
    default: return .utf8
    }
  }

  private static func firstCapture(_ pattern: String, in value: String) -> String? {
    guard let expression = try? NSRegularExpression(
      pattern: pattern, options: [.caseInsensitive])
    else { return nil }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = expression.firstMatch(in: value, range: range), match.numberOfRanges > 1,
      let captureRange = Range(match.range(at: 1), in: value)
    else { return nil }
    return String(value[captureRange])
  }
}
