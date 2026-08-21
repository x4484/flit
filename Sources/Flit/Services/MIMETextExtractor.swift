import Foundation

enum PreferredMIMEBody: Sendable, Equatable {
  case plainText(String)
  case html(String)
}

enum MIMETextExtractor {
  private static let maximumOutputCharacters = 100_000

  static func preferredBody(headerData: Data, bodyData: Data) -> PreferredMIMEBody {
    let headers = parseHeaders(headerData)
    if let html = extractHTML(headers: headers, body: bodyData), !html.isEmpty {
      return .html(renderableHTML(html))
    }
    return .plainText(plainText(headerData: headerData, bodyData: bodyData))
  }

  static func plainText(headerData: Data, bodyData: Data) -> String {
    let headers = parseHeaders(headerData)
    let text = extract(headers: headers, body: bodyData)
      .replacingOccurrences(of: "<html-fallback>", with: "")
      .replacingOccurrences(of: "\u{0}", with: "")
    return String(readableText(text).prefix(maximumOutputCharacters))
  }

  static func readableText(_ source: String) -> String {
    var text = source.replacingOccurrences(of: "\r\n", with: "\n")
    text = text.replacingOccurrences(
      of: #"<(?:https?://|mailto:)[^>\n]+>"#,
      with: "",
      options: [.regularExpression, .caseInsensitive]
    )
    let lines = text.components(separatedBy: "\n").map {
      $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression)
    }
    text = lines.joined(separator: "\n")
    text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func readableHTMLText(_ source: String) -> String {
    readableText(stripHTML(source))
  }

  static func renderableHTML(_ source: String) -> String {
    var html = source.replacingOccurrences(of: "\u{0000}", with: "")
    let blockedElements = ["script", "iframe", "object", "embed", "applet"]
    for element in blockedElements {
      html = html.replacingOccurrences(
        of: "(?is)<\(element)\\b[^>]*>.*?</\(element)\\s*>",
        with: "",
        options: .regularExpression
      )
      html = html.replacingOccurrences(
        of: "(?is)<\(element)\\b[^>]*/?\\s*>",
        with: "",
        options: .regularExpression
      )
    }
    html = html.replacingOccurrences(
      of: #"(?is)<meta\b[^>]*http-equiv\s*=\s*(?:\"refresh\"|'refresh'|refresh)[^>]*>"#,
      with: "",
      options: .regularExpression
    )
    html = html.replacingOccurrences(
      of: #"(?i)\s+on[a-z]+\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
      with: "",
      options: .regularExpression
    )
    html = html.replacingOccurrences(
      of: #"(?i)(href|src)\s*=\s*([\"'])\s*javascript:[^\"']*\2"#,
      with: "$1=$2#$2",
      options: .regularExpression
    )
    return String(html.prefix(1_000_000))
  }

  static func sanitizedHTML(_ source: String) -> String {
    var html = source
    let hiddenStylePatterns = [
      #"(?is)<([a-z][a-z0-9:-]*)\b[^>]*style\s*=\s*\"[^\"]*(?:display\s*:\s*none|visibility\s*:\s*hidden|mso-hide\s*:\s*all|max-height\s*:\s*0(?:px)?)[^\"]*\"[^>]*>.*?</\1\s*>"#,
      #"(?is)<([a-z][a-z0-9:-]*)\b[^>]*style\s*=\s*'[^']*(?:display\s*:\s*none|visibility\s*:\s*hidden|mso-hide\s*:\s*all|max-height\s*:\s*0(?:px)?)[^']*'[^>]*>.*?</\1\s*>"#,
    ]
    for pattern in hiddenStylePatterns {
      html = html.replacingOccurrences(
        of: pattern,
        with: "",
        options: .regularExpression
      )
    }

    let blockedElements = ["script", "style", "head", "iframe", "object", "embed", "svg", "form", "video", "audio"]
    for element in blockedElements {
      html = html.replacingOccurrences(
        of: "(?is)<\(element)\\b[^>]*>.*?</\(element)\\s*>",
        with: "",
        options: .regularExpression
      )
    }
    html = html.replacingOccurrences(
      of: #"(?is)<!--.*?-->"#,
      with: "",
      options: .regularExpression
    )
    html = replaceImageTagsWithAltText(in: html)
    html = html.replacingOccurrences(
      of: #"(?is)<(?:link|meta|input|source)\b[^>]*>"#,
      with: "",
      options: .regularExpression
    )
    html = html.replacingOccurrences(
      of: #"(?i)\s+(?:src|srcset|background|on[a-z]+)\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s>]+)"#,
      with: "",
      options: .regularExpression
    )
    html = html.replacingOccurrences(
      of: #"(?i)url\s*\([^)]*\)"#,
      with: "",
      options: .regularExpression
    )
    html = sanitizeInlineStyles(in: html)
    return String(html.prefix(200_000))
  }

  private static func replaceImageTagsWithAltText(in source: String) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: #"(?is)<img\b[^>]*>"#)
    else { return source }
    var html = source
    let matches = expression.matches(
      in: html,
      range: NSRange(html.startIndex..<html.endIndex, in: html)
    )
    for match in matches.reversed() {
      guard let range = Range(match.range, in: html) else { continue }
      let tag = String(html[range])
      let rawAlt = attribute("alt", in: tag)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let alt = rawAlt.replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
      let width = Int(attribute("width", in: tag) ?? "") ?? 0
      let replacement: String
      if !alt.isEmpty, width == 0 || width >= 40 {
        let escaped = alt.replacingOccurrences(of: "&", with: "&amp;")
          .replacingOccurrences(of: "<", with: "&lt;")
          .replacingOccurrences(of: ">", with: "&gt;")
        replacement = "<span data-flit-image-alt=\"true\">\(escaped)</span>"
      } else {
        replacement = ""
      }
      html.replaceSubrange(range, with: replacement)
    }
    return html
  }

  private static func sanitizeInlineStyles(in source: String) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: #"(?i)\s+style\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#)
    else { return source }
    var html = source
    let matches = expression.matches(
      in: html,
      range: NSRange(html.startIndex..<html.endIndex, in: html)
    )
    for match in matches.reversed() {
      guard let fullRange = Range(match.range(at: 0), in: html) else { continue }
      var rawStyle = ""
      for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
        if let range = Range(match.range(at: index), in: html) {
          rawStyle = String(html[range])
          break
        }
      }
      let safeStyle = safeCSSDeclarations(rawStyle)
      let replacement = safeStyle.isEmpty ? "" : " style=\"\(safeStyle)\""
      html.replaceSubrange(fullRange, with: replacement)
    }
    return html
  }

  private static func safeCSSDeclarations(_ source: String) -> String {
    source.split(separator: ";").compactMap { declaration -> String? in
      guard let colon = declaration.firstIndex(of: ":") else { return nil }
      let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      let value = declaration[declaration.index(after: colon)...]
        .replacingOccurrences(of: "!important", with: "", options: .caseInsensitive)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty,
        !value.localizedCaseInsensitiveContains("url"),
        !value.localizedCaseInsensitiveContains("expression"),
        isSafeCSSValue(value, for: property)
      else { return nil }
      return "\(property):\(value)"
    }.joined(separator: ";")
  }

  private static func isSafeCSSValue(_ value: String, for property: String) -> Bool {
    let colorPattern = #"(?i)^(?:#[0-9a-f]{3,8}|rgba?\([0-9.,% ]+\)|transparent|black|white)$"#
    let lengthPattern = #"^-?(?:\d+(?:\.\d+)?)(?:px|em|rem|%)?$"#
    let lengthsPattern = #"^-?(?:\d+(?:\.\d+)?)(?:px|em|rem|%)?(?:\s+-?(?:\d+(?:\.\d+)?)(?:px|em|rem|%)?){0,3}$"#
    let matches: (String) -> Bool = { pattern in
      value.range(of: pattern, options: .regularExpression) != nil
    }

    switch property {
    case "color", "background", "background-color":
      return matches(colorPattern)
    case "font-size", "letter-spacing", "width", "max-width", "min-width",
      "margin-top", "margin-right", "margin-bottom", "margin-left",
      "padding-top", "padding-right", "padding-bottom", "padding-left":
      return matches(lengthPattern)
    case "margin", "padding":
      return matches(lengthsPattern)
    case "font-weight":
      return value == "normal" || value == "bold"
        || Int(value).map { (100...900).contains($0) } == true
    case "line-height":
      return matches(lengthPattern)
    case "text-align":
      return ["left", "center", "right", "justify"].contains(value.lowercased())
    case "text-transform":
      return ["none", "uppercase", "lowercase", "capitalize"].contains(value.lowercased())
    case "vertical-align":
      return ["top", "middle", "bottom", "baseline"].contains(value.lowercased())
    default:
      return false
    }
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let pattern = "(?i)\\b\(escaped)\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^\\s>]+))"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let matchRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    guard let match = expression.firstMatch(in: tag, range: matchRange) else { return nil }
    for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
      if let range = Range(match.range(at: index), in: tag) {
        return String(tag[range])
      }
    }
    return nil
  }

  private static func extractHTML(headers: [String: String], body: Data) -> String? {
    let contentType = headers["content-type"] ?? "text/plain; charset=utf-8"
    let mediaType = contentType.split(separator: ";", maxSplits: 1)
      .first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "text/plain"
    let disposition = headers["content-disposition"]?.lowercased() ?? ""
    if disposition.hasPrefix("attachment") { return nil }

    if mediaType.hasPrefix("multipart/"), let boundary = parameter("boundary", in: contentType) {
      for part in multipartParts(body, boundary: boundary) {
        if let html = extractHTML(headers: parseHeaders(part.headers), body: part.body), !html.isEmpty {
          return html
        }
      }
      return nil
    }

    guard mediaType == "text/html" else { return nil }
    let decoded = decodeTransferEncoding(
      body,
      encoding: headers["content-transfer-encoding"]?.lowercased() ?? ""
    )
    let charset = parameter("charset", in: contentType)?.lowercased() ?? "utf-8"
    return String(data: decoded, encoding: stringEncoding(charset))
      ?? String(decoding: decoded, as: UTF8.self)
  }

  private static func extract(headers: [String: String], body: Data) -> String {
    let contentType = headers["content-type"] ?? "text/plain; charset=utf-8"
    let mediaType = contentType.split(separator: ";", maxSplits: 1)
      .first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "text/plain"
    let disposition = headers["content-disposition"]?.lowercased() ?? ""
    if disposition.hasPrefix("attachment") { return "" }

    if mediaType.hasPrefix("multipart/"), let boundary = parameter("boundary", in: contentType) {
      let parts = multipartParts(body, boundary: boundary)
      let extracted = parts.map { part in
        extract(headers: parseHeaders(part.headers), body: part.body)
      }
      if let plain = extracted.first(where: { !$0.isEmpty && !$0.hasPrefix("<html-fallback>") }) {
        return plain
      }
      return extracted.first(where: { !$0.isEmpty })?
        .replacingOccurrences(of: "<html-fallback>", with: "") ?? ""
    }

    guard mediaType == "text/plain" || mediaType == "text/html" else { return "" }
    let decoded = decodeTransferEncoding(
      body,
      encoding: headers["content-transfer-encoding"]?.lowercased() ?? ""
    )
    let charset = parameter("charset", in: contentType)?.lowercased() ?? "utf-8"
    let text = String(data: decoded, encoding: stringEncoding(charset))
      ?? String(decoding: decoded, as: UTF8.self)

    if mediaType == "text/html" {
      return "<html-fallback>" + stripHTML(text)
    }
    return text
  }

  private static func parseHeaders(_ data: Data) -> [String: String] {
    let source = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "\r\n", with: "\n")
    var headers: [String: String] = [:]
    var currentName: String?

    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.isEmpty { break }
      if line.first?.isWhitespace == true, let currentName {
        headers[currentName, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
        continue
      }
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
      currentName = name
    }
    return headers
  }

  private static func multipartParts(_ data: Data, boundary: String) -> [MIMEPart] {
    let source = String(decoding: data, as: UTF8.self)
    let marker = "--\(boundary)"
    return source.components(separatedBy: marker).dropFirst().compactMap { rawPart in
      if rawPart.hasPrefix("--") { return nil }
      var part = rawPart.replacingOccurrences(of: "\r\n", with: "\n")
      if part.hasPrefix("\n") { part.removeFirst() }
      guard let separator = part.range(of: "\n\n") else { return nil }
      let headerText = String(part[..<separator.lowerBound])
      var bodyText = String(part[separator.upperBound...])
      while bodyText.hasSuffix("\n") { bodyText.removeLast() }
      return MIMEPart(headers: Data(headerText.utf8), body: Data(bodyText.utf8))
    }
  }

  private static func decodeTransferEncoding(_ data: Data, encoding: String) -> Data {
    switch encoding {
    case "base64":
      let compact = String(decoding: data, as: UTF8.self)
        .filter { !$0.isWhitespace }
      return Data(base64Encoded: compact) ?? data
    case "quoted-printable":
      return decodeQuotedPrintable(data)
    default:
      return data
    }
  }

  private static func decodeQuotedPrintable(_ data: Data) -> Data {
    let bytes = Array(data)
    var decoded: [UInt8] = []
    decoded.reserveCapacity(bytes.count)
    var index = 0

    while index < bytes.count {
      if bytes[index] == 61 {
        if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
          index += 3
          continue
        }
        if index + 1 < bytes.count, bytes[index + 1] == 10 {
          index += 2
          continue
        }
        if index + 2 < bytes.count,
          let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2])
        {
          decoded.append(high * 16 + low)
          index += 3
          continue
        }
      }
      decoded.append(bytes[index])
      index += 1
    }
    return Data(decoded)
  }

  private static func parameter(_ name: String, in header: String) -> String? {
    let escapedName = NSRegularExpression.escapedPattern(for: name)
    let pattern = "(?:^|;)\\s*\(escapedName)\\s*=\\s*(?:\\\"([^\\\"]+)\\\"|([^;\\s]+))"
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return nil }
    let range = NSRange(header.startIndex..<header.endIndex, in: header)
    guard let match = expression.firstMatch(in: header, range: range) else { return nil }
    for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
      if let capture = Range(match.range(at: index), in: header) {
        return String(header[capture])
      }
    }
    return nil
  }

  private static func stripHTML(_ html: String) -> String {
    var text = html.replacingOccurrences(
      of: #"(?is)<(script|style)[^>]*>.*?</\1>"#,
      with: " ",
      options: .regularExpression
    )
    text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"(?i)</p\s*>"#, with: "\n\n", options: .regularExpression)
    text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    let entities = [
      "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
      "&#39;": "'",
    ]
    for (entity, replacement) in entities {
      text = text.replacingOccurrences(of: entity, with: replacement)
    }
    text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func stringEncoding(_ charset: String) -> String.Encoding {
    switch charset {
    case "iso-8859-1", "latin1": return .isoLatin1
    case "windows-1252": return .windowsCP1252
    case "us-ascii", "ascii": return .ascii
    default: return .utf8
    }
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: return byte - 48
    case 65...70: return byte - 55
    case 97...102: return byte - 87
    default: return nil
    }
  }
}

private struct MIMEPart {
  let headers: Data
  let body: Data
}
