import AppKit

private final class QuoteBarView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.separatorColor.setFill()
    bounds.fill()
  }
}

enum QuotedThreadRenderer {
  static func render(_ source: String) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let lines = source.components(separatedBy: .newlines)

    for (index, rawLine) in lines.enumerated() {
      let (depth, line) = unquoted(rawLine)
      let paragraph = NSMutableParagraphStyle()
      paragraph.firstLineHeadIndent = CGFloat(depth * 14)
      paragraph.headIndent = CGFloat(depth * 14)
      paragraph.lineSpacing = 2
      paragraph.paragraphSpacing = line.isEmpty ? 3 : 0
      paragraph.lineBreakMode = .byWordWrapping

      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(
          ofSize: index == 0 ? 13 : 13.5,
          weight: index == 0 ? .medium : .regular
        ),
        .foregroundColor: depth > 0
          ? NSColor.tertiaryLabelColor
          : NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph,
      ]
      result.append(NSAttributedString(string: line, attributes: attributes))
      if index < lines.count - 1 {
        result.append(NSAttributedString(string: "\n", attributes: attributes))
      }
    }
    return result
  }

  private static func unquoted(_ line: String) -> (depth: Int, line: String) {
    var remainder = line[...]
    var depth = 0

    while true {
      remainder = remainder.drop(while: { $0 == " " || $0 == "\t" })
      guard remainder.first == ">" else { break }
      depth += 1
      remainder = remainder.dropFirst()
      if remainder.first == " " { remainder = remainder.dropFirst() }
    }
    return (depth, String(remainder))
  }
}

@MainActor
final class ComposeWindowController: NSWindowController {
  typealias SendHandler = @Sendable (ComposeDraft) async throws -> Void

  private let draftSender: String
  private let quotedDisplayText: String?
  private let quotedPlainText: String?
  private let inReplyTo: String?
  private let sendHandler: SendHandler
  private let toField = NSTextField()
  private let ccField = NSTextField()
  private let subjectField = NSTextField()
  private let bodyView = NSTextView()
  private let sendButton = NSButton(title: "Send", target: nil, action: nil)
  private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
  private var sendTask: Task<Void, Never>?

  init(title: String, draft: ComposeDraft, sendHandler: @escaping SendHandler) {
    draftSender = draft.sender
    quotedDisplayText = draft.quotedDisplayText
    quotedPlainText = draft.quotedPlainText
    inReplyTo = draft.inReplyTo
    self.sendHandler = sendHandler

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.minSize = NSSize(width: 520, height: 400)
    super.init(window: window)

    toField.stringValue = draft.to
    ccField.stringValue = draft.cc
    subjectField.stringValue = draft.subject
    bodyView.string = draft.body
    configureView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func focusInitialField() {
    if toField.stringValue.isEmpty {
      window?.makeFirstResponder(toField)
    } else {
      window?.makeFirstResponder(bodyView)
      bodyView.setSelectedRange(NSRange(location: 0, length: 0))
    }
  }

  private func configureView() {
    guard let window else { return }
    let container = NSView()
    window.contentView = container

    let fromValue = NSTextField(labelWithString: draftSender)
    fromValue.textColor = .secondaryLabelColor
    fromValue.alignment = .left
    fromValue.lineBreakMode = .byTruncatingMiddle
    fromValue.setContentHuggingPriority(.defaultLow, for: .horizontal)
    fromValue.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    for field in [toField, ccField, subjectField] {
      field.font = .systemFont(ofSize: 13)
      field.cell?.isScrollable = true
      field.cell?.wraps = false
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    toField.setAccessibilityLabel("To")
    ccField.setAccessibilityLabel("Cc")
    subjectField.setAccessibilityLabel("Subject")

    let headerRows = [
      fieldRow("From:", value: fromValue),
      fieldRow("To:", value: toField),
      fieldRow("Cc:", value: ccField),
      fieldRow("Subject:", value: subjectField),
    ]
    let header = NSStackView(views: headerRows)
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 8
    header.translatesAutoresizingMaskIntoConstraints = false
    for row in headerRows {
      row.widthAnchor.constraint(equalTo: header.widthAnchor).isActive = true
    }

    configureTextView(bodyView, editable: true)
    bodyView.drawsBackground = false
    bodyView.textContainerInset = NSSize(width: 0, height: 4)
    bodyView.isAutomaticQuoteSubstitutionEnabled = true
    bodyView.isAutomaticDashSubstitutionEnabled = false
    bodyView.setAccessibilityLabel("Message")

    let bodyScroll = makeScrollView(documentView: bodyView, bordered: false)
    bodyScroll.drawsBackground = false
    bodyScroll.translatesAutoresizingMaskIntoConstraints = false

    cancelButton.target = self
    cancelButton.action = #selector(cancel)
    cancelButton.bezelStyle = .rounded

    sendButton.target = self
    sendButton.action = #selector(send)
    sendButton.bezelStyle = .rounded
    sendButton.keyEquivalent = "\r"
    sendButton.keyEquivalentModifierMask = [.command]
    sendButton.toolTip = "Send message (Command-Return)"

    let buttons = NSStackView(views: [cancelButton, sendButton])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    buttons.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(header)
    container.addSubview(bodyScroll)
    container.addSubview(buttons)

    var constraints = [
      header.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
      header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

      bodyScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
      bodyScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
      bodyScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

      buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
      buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
    ]

    if let quotedDisplayText, !quotedDisplayText.isEmpty {
      let quotedView = NSTextView()
      configureTextView(quotedView, editable: false)
      quotedView.drawsBackground = false
      quotedView.textContainerInset = NSSize(width: 0, height: 4)
      quotedView.textStorage?.setAttributedString(QuotedThreadRenderer.render(quotedDisplayText))
      quotedView.setAccessibilityLabel("Quoted message")

      let quoteScroll = makeScrollView(documentView: quotedView, bordered: false)
      quoteScroll.drawsBackground = false
      quoteScroll.translatesAutoresizingMaskIntoConstraints = false

      let quoteBar = QuoteBarView()
      quoteBar.translatesAutoresizingMaskIntoConstraints = false
      quoteBar.setAccessibilityElement(false)

      let quoteContainer = NSView()
      quoteContainer.translatesAutoresizingMaskIntoConstraints = false
      quoteContainer.addSubview(quoteBar)
      quoteContainer.addSubview(quoteScroll)
      container.addSubview(quoteContainer)

      constraints.append(contentsOf: [
        bodyScroll.heightAnchor.constraint(equalToConstant: 56),
        quoteContainer.topAnchor.constraint(equalTo: bodyScroll.bottomAnchor, constant: 14),
        quoteContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
        quoteContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        quoteContainer.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),

        quoteBar.leadingAnchor.constraint(equalTo: quoteContainer.leadingAnchor),
        quoteBar.topAnchor.constraint(equalTo: quoteContainer.topAnchor),
        quoteBar.bottomAnchor.constraint(equalTo: quoteContainer.bottomAnchor),
        quoteBar.widthAnchor.constraint(equalToConstant: 2),

        quoteScroll.leadingAnchor.constraint(equalTo: quoteBar.trailingAnchor, constant: 12),
        quoteScroll.trailingAnchor.constraint(equalTo: quoteContainer.trailingAnchor),
        quoteScroll.topAnchor.constraint(equalTo: quoteContainer.topAnchor),
        quoteScroll.bottomAnchor.constraint(equalTo: quoteContainer.bottomAnchor),
      ])
    } else {
      constraints.append(
        bodyScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16))
    }

    NSLayoutConstraint.activate(constraints)
  }

  private func fieldRow(_ title: String, value: NSView) -> NSStackView {
    let label = NSTextField(labelWithString: title)
    label.font = .systemFont(ofSize: 13, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.alignment = .left
    label.translatesAutoresizingMaskIntoConstraints = false
    label.widthAnchor.constraint(equalToConstant: 58).isActive = true

    let row = NSStackView(views: [label, value])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.distribution = .fill
    row.setContentHuggingPriority(.defaultLow, for: .horizontal)
    row.translatesAutoresizingMaskIntoConstraints = false
    return row
  }

  private func configureTextView(_ textView: NSTextView, editable: Bool) {
    textView.font = .systemFont(ofSize: 15)
    textView.textColor = .labelColor
    textView.isEditable = editable
    textView.isSelectable = true
    textView.isRichText = false
    textView.textContainerInset = NSSize(width: 8, height: 10)
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = true
  }

  private func makeScrollView(documentView: NSTextView, bordered: Bool) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = bordered ? .bezelBorder : .noBorder
    documentView.frame = scrollView.contentView.bounds
    scrollView.documentView = documentView
    return scrollView
  }

  @objc private func cancel() {
    sendTask?.cancel()
    guard let window, let parent = window.sheetParent else { return }
    parent.endSheet(window, returnCode: .cancel)
  }

  @objc private func send() {
    var composedBody = bodyView.string
    if let quotedPlainText, !quotedPlainText.isEmpty {
      composedBody += composedBody.isEmpty ? quotedPlainText : "\n\n" + quotedPlainText
    }

    let draft = ComposeDraft(
      sender: draftSender,
      to: toField.stringValue,
      cc: ccField.stringValue,
      subject: subjectField.stringValue,
      body: composedBody,
      quotedDisplayText: quotedDisplayText,
      quotedPlainText: quotedPlainText,
      inReplyTo: inReplyTo
    )
    let to = EmailAddressParser.addresses(in: draft.to)
    let cc = EmailAddressParser.addresses(in: draft.cc)
    guard !to.isEmpty || !cc.isEmpty else {
      showError(OutgoingMessageError.missingRecipient)
      return
    }

    setSending(true)
    sendTask = Task { [weak self, sendHandler] in
      do {
        try await sendHandler(draft)
        guard !Task.isCancelled, let self, let window = self.window,
          let parent = window.sheetParent
        else { return }
        parent.endSheet(window, returnCode: .OK)
      } catch is CancellationError {
        self?.setSending(false)
      } catch {
        self?.setSending(false)
        self?.showError(error)
      }
    }
  }

  private func setSending(_ isSending: Bool) {
    sendButton.isEnabled = !isSending
    cancelButton.isEnabled = !isSending
    toField.isEnabled = !isSending
    ccField.isEnabled = !isSending
    subjectField.isEnabled = !isSending
    bodyView.isEditable = !isSending
    sendButton.title = isSending ? "Sending…" : "Send"
  }

  private func showError(_ error: Error) {
    guard let window else { return }
    NSAlert(error: error).beginSheetModal(for: window)
  }
}
