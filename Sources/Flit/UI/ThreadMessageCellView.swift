import AppKit

private final class ThreadUnreadIndicatorView: NSView {
  var isUnread = false {
    didSet { needsDisplay = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    guard isUnread else { return }
    NSColor.controlAccentColor.setFill()
    NSBezierPath(ovalIn: bounds).fill()
  }
}

final class ThreadMessageCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("ThreadMessageCell")

  private let unreadIndicator = ThreadUnreadIndicatorView()
  private let senderLabel = NSTextField(labelWithString: "")
  private let dateLabel = NSTextField(labelWithString: "")
  private let previewLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.identifier

    senderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    senderLabel.lineBreakMode = .byTruncatingTail
    senderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    dateLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    dateLabel.textColor = .tertiaryLabelColor
    dateLabel.alignment = .right

    previewLabel.font = .systemFont(ofSize: 11, weight: .regular)
    previewLabel.textColor = .secondaryLabelColor
    previewLabel.lineBreakMode = .byTruncatingTail
    previewLabel.maximumNumberOfLines = 1
    previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    unreadIndicator.translatesAutoresizingMaskIntoConstraints = false
    unreadIndicator.setAccessibilityElement(false)

    let heading = NSStackView(views: [senderLabel, NSView(), dateLabel])
    heading.orientation = .horizontal
    heading.alignment = .centerY
    heading.spacing = 6

    let text = NSStackView(views: [heading, previewLabel])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 4
    text.translatesAutoresizingMaskIntoConstraints = false

    addSubview(unreadIndicator)
    addSubview(text)
    NSLayoutConstraint.activate([
      unreadIndicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      unreadIndicator.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
      unreadIndicator.widthAnchor.constraint(equalToConstant: 6),
      unreadIndicator.heightAnchor.constraint(equalToConstant: 6),
      text.leadingAnchor.constraint(equalTo: unreadIndicator.trailingAnchor, constant: 8),
      text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      text.centerYAnchor.constraint(equalTo: centerYAnchor),
      heading.widthAnchor.constraint(equalTo: text.widthAnchor),
      previewLabel.widthAnchor.constraint(equalTo: text.widthAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    with message: MessageSummary,
    dateText: String,
    position: Int,
    count: Int
  ) {
    unreadIndicator.isUnread = !message.isRead
    senderLabel.stringValue = message.sender.isEmpty ? "Unknown sender" : message.sender
    senderLabel.font = .systemFont(ofSize: 12, weight: message.isRead ? .regular : .semibold)
    dateLabel.stringValue = dateText
    previewLabel.stringValue = message.preview.isEmpty
      ? "To: \(message.recipients.isEmpty ? "—" : message.recipients)"
      : message.preview

    senderLabel.toolTip = message.sender
    previewLabel.toolTip = previewLabel.stringValue
    let readState = message.isRead ? "Read" : "Unread"
    setAccessibilityLabel(
      "\(readState), \(senderLabel.stringValue), \(dateText), message \(position) of \(count)"
    )
  }
}
