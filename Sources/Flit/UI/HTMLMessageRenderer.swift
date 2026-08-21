import AppKit
import Foundation

/// Converts sanitized email HTML into native attributed text without WebKit or remote resources.
enum HTMLMessageRenderer {
  static func render(_ data: Data) throws -> NSAttributedString {
    let source = MIMETextExtractor.sanitizedHTML(String(decoding: data, as: UTF8.self))
    let output = NSMutableAttributedString()
    var styles = [HTMLTextStyle.root]
    var tables: [HTMLTableContext] = []
    var cursor = source.startIndex

    while cursor < source.endIndex {
      guard let opening = source[cursor...].firstIndex(of: "<") else {
        appendText(String(source[cursor...]), style: styles.last ?? .root, to: output)
        break
      }
      if opening > cursor {
        appendText(String(source[cursor..<opening]), style: styles.last ?? .root, to: output)
      }
      guard let closing = source[opening...].firstIndex(of: ">") else {
        appendText(String(source[opening...]), style: styles.last ?? .root, to: output)
        break
      }

      let rawTag = String(source[source.index(after: opening)..<closing])
      processTag(rawTag, styles: &styles, tables: &tables, output: output)
      cursor = source.index(after: closing)
    }

    trimWhitespace(in: output)
    return output
  }

  private static func processTag(
    _ rawTag: String,
    styles: inout [HTMLTextStyle],
    tables: inout [HTMLTableContext],
    output: NSMutableAttributedString
  ) {
    let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("!") else { return }
    let isClosing = trimmed.hasPrefix("/")
    let tagContent = isClosing ? String(trimmed.dropFirst()) : trimmed
    let tag = tagContent.split(whereSeparator: { $0.isWhitespace || $0 == "/" })
      .first?.lowercased() ?? ""
    guard !tag.isEmpty else { return }

    if isClosing {
      if ["td", "th"].contains(tag) {
        appendBreaks(1, style: styles.last ?? .root, to: output)
      }
      if let index = styles.lastIndex(where: { $0.tag == tag }) {
        styles.removeSubrange(index..<styles.endIndex)
      }
      if tag == "table" { _ = tables.popLast() }

      let inherited = styles.last ?? .root
      if ["p", "section", "article", "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) {
        appendBreaks(2, style: inherited, to: output)
      } else if ["div", "li"].contains(tag) {
        appendBreaks(1, style: inherited, to: output)
      }
      return
    }

    let inherited = styles.last ?? .root
    if tag == "br" {
      appendBreaks(1, style: inherited, to: output)
      return
    }
    if ["p", "section", "article", "header", "footer", "h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) {
      appendBreaks(2, style: inherited, to: output)
    } else if ["div", "li"].contains(tag) {
      appendBreaks(1, style: inherited, to: output)
      if tag == "li" { appendRaw("• ", style: inherited, to: output) }
    }

    guard !["br", "hr", "meta", "link", "img", "input", "source"].contains(tag) else {
      if tag == "hr" { appendBreaks(2, style: inherited, to: output) }
      return
    }

    if tag == "table" {
      tables.append(HTMLTableContext())
    } else if tag == "tr" {
      tables.last?.beginRow()
    }

    var style = inherited
    style.tag = tag
    switch tag {
    case "strong", "b": style.isBold = true
    case "em", "i": style.isItalic = true
    case "u": style.isUnderlined = true
    case "code", "pre": style.isMonospaced = true; style.preservesWhitespace = true
    case "blockquote": style.isQuote = true
    case "h1": style.headingLevel = 1; style.isBold = true
    case "h2": style.headingLevel = 2; style.isBold = true
    case "h3": style.headingLevel = 3; style.isBold = true
    case "h4", "h5", "h6": style.headingLevel = 4; style.isBold = true
    case "a": style.link = linkURL(in: tagContent)
    default: break
    }
    applyPresentationAttributes(from: tagContent, to: &style)

    if ["td", "th"].contains(tag), let table = tables.last {
      let columnSpan = max(1, Int(attribute("colspan", in: tagContent) ?? "1") ?? 1)
      let rowSpan = max(1, Int(attribute("rowspan", in: tagContent) ?? "1") ?? 1)
      let block = table.nextCell(columnSpan: columnSpan, rowSpan: rowSpan)
      configure(block: block, from: style)
      style.textBlocks.append(block)
    }
    styles.append(style)
  }

  private static func applyPresentationAttributes(
    from tagContent: String,
    to style: inout HTMLTextStyle
  ) {
    if let alignment = attribute("align", in: tagContent) {
      style.alignment = textAlignment(alignment)
    }
    if attribute("data-flit-image-alt", in: tagContent) != nil {
      style.isBold = true
    }

    guard let inlineStyle = attribute("style", in: tagContent) else { return }
    let declarations = Dictionary(uniqueKeysWithValues: inlineStyle.split(separator: ";").compactMap {
      declaration -> (String, String)? in
      guard let colon = declaration.firstIndex(of: ":") else { return nil }
      let property = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      let value = declaration[declaration.index(after: colon)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (property, value)
    })

    if let value = declarations["color"], let color = cssColor(value) {
      style.foregroundColor = color
    }
    if let value = declarations["background-color"] ?? declarations["background"],
      let color = cssColor(value)
    {
      style.backgroundColor = color
    }
    if let value = declarations["font-size"], let size = cssLength(value) {
      style.fontSize = size
    }
    if let value = declarations["font-weight"] {
      style.isBold = value.lowercased() == "bold" || (Int(value) ?? 0) >= 600
    }
    if let value = declarations["text-align"] {
      style.alignment = textAlignment(value)
    }
    style.textTransform = declarations["text-transform"]?.lowercased()
    style.paragraphSpacingBefore = cssLength(declarations["margin-top"] ?? "") ?? 0
    style.paragraphSpacing = cssLength(declarations["margin-bottom"] ?? "") ?? 0
    style.padding = cssInsets(
      shorthand: declarations["padding"],
      top: declarations["padding-top"],
      right: declarations["padding-right"],
      bottom: declarations["padding-bottom"],
      left: declarations["padding-left"]
    )
    if let width = declarations["width"] {
      if width.hasSuffix("%"), let value = Double(width.dropLast()) {
        style.contentWidthPercentage = CGFloat(min(100, max(1, value)))
      } else if let value = cssLength(width) {
        style.contentWidth = value
      }
    }
  }

  private static func configure(block: NSTextTableBlock, from style: HTMLTextStyle) {
    block.backgroundColor = style.backgroundColor
    if let percentage = style.contentWidthPercentage {
      block.setContentWidth(percentage, type: .percentageValueType)
    } else if let width = style.contentWidth {
      block.setContentWidth(width, type: .absoluteValueType)
    }
    let padding = style.padding
    let edges: [(NSRectEdge, CGFloat)] = [
      (.minX, padding.left), (.maxX, padding.right),
      (.minY, padding.top), (.maxY, padding.bottom),
    ]
    for (edge, width) in edges where width > 0 {
      block.setWidth(width, type: .absoluteValueType, for: .padding, edge: edge)
    }
  }

  private static func attribute(_ name: String, in tag: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let pattern = "(?i)\\b\(escaped)\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^\\s>]+))"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    guard let match = expression.firstMatch(in: tag, range: range) else { return nil }
    for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
      if let capture = Range(match.range(at: index), in: tag) {
        return decodeEntities(String(tag[capture]))
      }
    }
    return nil
  }

  private static func textAlignment(_ value: String) -> NSTextAlignment {
    switch value.lowercased() {
    case "center": return .center
    case "right": return .right
    case "justify": return .justified
    default: return .left
    }
  }

  private static func cssLength(_ source: String) -> CGFloat? {
    let value = source.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "px", with: "")
      .replacingOccurrences(of: "rem", with: "")
      .replacingOccurrences(of: "em", with: "")
    guard !value.hasSuffix("%"), let number = Double(value) else { return nil }
    return CGFloat(min(64, max(0, number)))
  }

  private static func cssInsets(
    shorthand: String?,
    top: String?,
    right: String?,
    bottom: String?,
    left: String?
  ) -> NSEdgeInsets {
    let values = (shorthand ?? "").split(whereSeparator: { $0.isWhitespace })
      .compactMap { cssLength(String($0)) }
    var result = NSEdgeInsets()
    switch values.count {
    case 1:
      result = NSEdgeInsets(top: values[0], left: values[0], bottom: values[0], right: values[0])
    case 2:
      result = NSEdgeInsets(top: values[0], left: values[1], bottom: values[0], right: values[1])
    case 3:
      result = NSEdgeInsets(top: values[0], left: values[1], bottom: values[2], right: values[1])
    case 4:
      result = NSEdgeInsets(top: values[0], left: values[3], bottom: values[2], right: values[1])
    default:
      break
    }
    if let value = top.flatMap(cssLength) { result.top = value }
    if let value = right.flatMap(cssLength) { result.right = value }
    if let value = bottom.flatMap(cssLength) { result.bottom = value }
    if let value = left.flatMap(cssLength) { result.left = value }
    return result
  }

  private static func cssColor(_ source: String) -> NSColor? {
    let value = source.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if value == "transparent" { return .clear }
    if value == "black" { return .black }
    if value == "white" { return .white }
    if value.hasPrefix("#") {
      let hex = String(value.dropFirst())
      let expanded = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
      guard expanded.count == 6, let number = UInt64(expanded, radix: 16) else { return nil }
      return NSColor(
        srgbRed: CGFloat((number >> 16) & 0xff) / 255,
        green: CGFloat((number >> 8) & 0xff) / 255,
        blue: CGFloat(number & 0xff) / 255,
        alpha: 1
      )
    }
    guard value.hasPrefix("rgb"),
      let opening = value.firstIndex(of: "("), let closing = value.lastIndex(of: ")")
    else { return nil }
    let components = value[value.index(after: opening)..<closing].split(separator: ",")
      .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    guard components.count >= 3 else { return nil }
    let alpha = components.count > 3 ? min(1, max(0, components[3])) : 1
    return NSColor(
      srgbRed: CGFloat(min(255, max(0, components[0]))) / 255,
      green: CGFloat(min(255, max(0, components[1]))) / 255,
      blue: CGFloat(min(255, max(0, components[2]))) / 255,
      alpha: CGFloat(alpha)
    )
  }

  private static func appendText(
    _ rawText: String,
    style: HTMLTextStyle,
    to output: NSMutableAttributedString
  ) {
    var text = decodeEntities(rawText)
    if !style.preservesWhitespace {
      text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      if output.string.last?.isWhitespace == true {
        text = text.drop(while: { $0.isWhitespace }).description
      }
    }
    switch style.textTransform {
    case "uppercase": text = text.uppercased()
    case "lowercase": text = text.lowercased()
    case "capitalize": text = text.capitalized
    default: break
    }
    guard !text.isEmpty else { return }
    appendRaw(text, style: style, to: output)
  }

  private static func appendRaw(
    _ text: String,
    style: HTMLTextStyle,
    to output: NSMutableAttributedString
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3
    paragraph.paragraphSpacing = style.paragraphSpacing
    paragraph.paragraphSpacingBefore = style.paragraphSpacingBefore
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.alignment = style.alignment
    paragraph.textBlocks = style.textBlocks
    if style.isQuote {
      paragraph.headIndent = 18
      paragraph.firstLineHeadIndent = 18
    }

    let attributes: [NSAttributedString.Key: Any] = {
      var values: [NSAttributedString.Key: Any] = [
        .font: font(for: style),
        .foregroundColor: style.link == nil
          ? (style.foregroundColor ?? NSColor.labelColor)
          : NSColor.linkColor,
        .paragraphStyle: paragraph,
      ]
      if let backgroundColor = style.backgroundColor, style.textBlocks.isEmpty {
        values[.backgroundColor] = backgroundColor
      }
      if let link = style.link { values[.link] = link }
      if style.isUnderlined || style.link != nil {
        values[.underlineStyle] = NSUnderlineStyle.single.rawValue
      }
      return values
    }()
    output.append(NSAttributedString(string: text, attributes: attributes))
  }

  private static func font(for style: HTMLTextStyle) -> NSFont {
    let size: CGFloat
    if let explicitSize = style.fontSize {
      size = min(38, max(11, explicitSize))
    } else {
      switch style.headingLevel {
      case 1: size = 23
      case 2: size = 20
      case 3: size = 18
      case 4: size = 16
      default: size = 15
      }
    }
    if style.isMonospaced {
      return .monospacedSystemFont(ofSize: size - 1, weight: style.isBold ? .semibold : .regular)
    }
    let weight: NSFont.Weight = style.isBold ? .semibold : .regular
    var descriptor = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
    if style.isItalic { descriptor = descriptor.withSymbolicTraits([.italic]) }
    return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
  }

  private static func linkURL(in tag: String) -> URL? {
    let pattern = #"(?i)\bhref\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s>]+))"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    guard let match = expression.firstMatch(in: tag, range: range) else { return nil }
    for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
      guard let capture = Range(match.range(at: index), in: tag),
        let url = URL(string: decodeEntities(String(tag[capture]))),
        let scheme = url.scheme?.lowercased(),
        ["http", "https", "mailto"].contains(scheme)
      else { continue }
      return url
    }
    return nil
  }

  private static func appendBreaks(
    _ count: Int,
    style: HTMLTextStyle,
    to output: NSMutableAttributedString
  ) {
    var trailing = 0
    for character in output.string.reversed() {
      guard character == "\n" else { break }
      trailing += 1
    }
    guard trailing < count else { return }
    appendRaw(
      String(repeating: "\n", count: count - trailing),
      style: style,
      to: output
    )
  }

  private static func decodeEntities(_ source: String) -> String {
    var text = source
    let entities = [
      "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
      "&apos;": "'", "&#39;": "'", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”",
      "&ldquo;": "“", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&bull;": "•",
      "&zwnj;": "", "&zwj;": "", "&shy;": "", "&ZeroWidthSpace;": "",
    ]
    for (entity, replacement) in entities {
      text = text.replacingOccurrences(of: entity, with: replacement)
    }

    guard let expression = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) else {
      return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in expression.matches(in: text, range: range).reversed() {
      guard let matchRange = Range(match.range(at: 0), in: text),
        let valueRange = Range(match.range(at: 1), in: text)
      else { continue }
      let value = String(text[valueRange])
      let number = value.lowercased().hasPrefix("x")
        ? UInt32(value.dropFirst(), radix: 16)
        : UInt32(value, radix: 10)
      guard let number, let scalar = UnicodeScalar(number) else { continue }
      text.replaceSubrange(matchRange, with: String(scalar))
    }
    for invisible in ["\u{00AD}", "\u{034F}", "\u{180E}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"] {
      text = text.replacingOccurrences(of: invisible, with: "")
    }
    return text
  }

  private static func trimWhitespace(in text: NSMutableAttributedString) {
    while text.length > 0, text.string.first?.isWhitespace == true {
      text.deleteCharacters(in: NSRange(location: 0, length: 1))
    }
    while text.length > 0, text.string.last?.isWhitespace == true {
      text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
    }
  }
}

private struct HTMLTextStyle {
  var tag = "root"
  var isBold = false
  var isItalic = false
  var isUnderlined = false
  var isMonospaced = false
  var preservesWhitespace = false
  var isQuote = false
  var headingLevel: Int?
  var fontSize: CGFloat?
  var foregroundColor: NSColor?
  var backgroundColor: NSColor?
  var alignment: NSTextAlignment = .left
  var textTransform: String?
  var paragraphSpacingBefore: CGFloat = 0
  var paragraphSpacing: CGFloat = 0
  var padding = NSEdgeInsets()
  var contentWidth: CGFloat?
  var contentWidthPercentage: CGFloat?
  var textBlocks: [NSTextBlock] = []
  var link: URL?

  static let root = HTMLTextStyle()
}

private final class HTMLTableContext {
  let table: NSTextTable
  private var row = -1
  private var column = 0

  init() {
    table = NSTextTable()
    table.numberOfColumns = 1
    table.layoutAlgorithm = .automaticLayoutAlgorithm
    table.collapsesBorders = true
    table.setContentWidth(100, type: .percentageValueType)
  }

  func beginRow() {
    row += 1
    column = 0
  }

  func nextCell(columnSpan: Int, rowSpan: Int) -> NSTextTableBlock {
    if row < 0 { beginRow() }
    table.numberOfColumns = max(table.numberOfColumns, column + columnSpan)
    let block = NSTextTableBlock(
      table: table,
      startingRow: row,
      rowSpan: rowSpan,
      startingColumn: column,
      columnSpan: columnSpan
    )
    column += columnSpan
    return block
  }
}
