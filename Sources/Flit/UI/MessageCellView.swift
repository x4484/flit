import AppKit

private final class UnreadIndicatorView: NSView {
  var isUnread = false {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard isUnread else { return }
    NSColor.controlAccentColor.setFill()
    NSBezierPath(ovalIn: bounds).fill()
  }
}

final class MessageCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("MessageCell")

  private let unreadIndicator = UnreadIndicatorView()
  private let senderLabel = NSTextField(labelWithString: "")
  private let metadataLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.identifier

    senderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    senderLabel.alignment = .left
    senderLabel.lineBreakMode = .byTruncatingTail
    senderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    metadataLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    metadataLabel.textColor = .tertiaryLabelColor
    metadataLabel.alignment = .left
    metadataLabel.lineBreakMode = .byTruncatingTail
    metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    unreadIndicator.translatesAutoresizingMaskIntoConstraints = false
    unreadIndicator.setAccessibilityElement(false)

    let stack = NSStackView(views: [senderLabel, metadataLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(unreadIndicator)
    addSubview(stack)

    NSLayoutConstraint.activate([
      unreadIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      unreadIndicator.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
      unreadIndicator.widthAnchor.constraint(equalToConstant: 6),
      unreadIndicator.heightAnchor.constraint(equalToConstant: 6),
      stack.leadingAnchor.constraint(equalTo: unreadIndicator.trailingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with message: MessageSummary, dateText: String) {
    let accountName = Self.accountName(for: message)
    unreadIndicator.isUnread = !message.isRead
    senderLabel.stringValue = message.sender
    senderLabel.font = .systemFont(ofSize: 13, weight: message.isRead ? .regular : .semibold)
    metadataLabel.stringValue = "\(accountName) | \(dateText)"

    senderLabel.toolTip = message.sender
    metadataLabel.toolTip = "\(accountName) | \(dateText)"
    let readState = message.isRead ? "Read" : "Unread"
    setAccessibilityLabel("\(readState), \(message.sender), \(accountName), \(dateText)")
  }

  private static func accountName(for message: MessageSummary) -> String {
    guard let atSign = message.accountEmail.lastIndex(of: "@") else {
      return message.accountName
    }
    let domain = message.accountEmail[message.accountEmail.index(after: atSign)...]
    return domain.isEmpty ? message.accountName : domain.lowercased()
  }
}
