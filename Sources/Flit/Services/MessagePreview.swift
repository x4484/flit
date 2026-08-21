import Foundation

enum MessagePreview {
  static let maximumLength = 180

  static func make(from readableBody: String, limit: Int = maximumLength) -> String {
    guard limit > 0 else { return "" }
    let normalized = readableBody
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > limit else { return normalized }
    guard limit > 1 else { return "…" }
    return String(normalized.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
  }
}
