import AppKit

final class MessageCellView: NSTableCellView {
  static let identifier = NSUserInterfaceItemIdentifier("MessageCell")

  private let senderLabel = NSTextField(labelWithString: "")
  private let subjectLabel = NSTextField(labelWithString: "")
  private let accountLabel = NSTextField(labelWithString: "")
  private let dateLabel = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = Self.identifier

    senderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    senderLabel.lineBreakMode = .byTruncatingTail
    senderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    subjectLabel.font = .systemFont(ofSize: 12, weight: .regular)
    subjectLabel.textColor = .secondaryLabelColor
    subjectLabel.lineBreakMode = .byTruncatingTail
    subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    accountLabel.font = .systemFont(ofSize: 11, weight: .medium)
    accountLabel.textColor = .tertiaryLabelColor
    accountLabel.lineBreakMode = .byTruncatingTail

    dateLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    dateLabel.textColor = .tertiaryLabelColor
    dateLabel.alignment = .right

    let topRow = NSStackView(views: [senderLabel, dateLabel])
    topRow.orientation = .horizontal
    topRow.spacing = 8
    topRow.distribution = .fill

    let bottomRow = NSStackView(views: [subjectLabel, accountLabel])
    bottomRow.orientation = .horizontal
    bottomRow.spacing = 8
    bottomRow.distribution = .fill

    let stack = NSStackView(views: [topRow, bottomRow])
    stack.orientation = .vertical
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(with message: MessageSummary, dateText: String) {
    senderLabel.stringValue = message.sender
    senderLabel.font = .systemFont(ofSize: 13, weight: message.isRead ? .regular : .semibold)
    subjectLabel.stringValue = message.subject.isEmpty ? "(No subject)" : message.subject
    accountLabel.stringValue = message.accountName
    dateLabel.stringValue = dateText

    senderLabel.toolTip = message.sender
    subjectLabel.toolTip = message.subject
    setAccessibilityLabel(
      "\(message.sender), \(message.subject), \(dateText), \(message.accountName)")
  }
}
