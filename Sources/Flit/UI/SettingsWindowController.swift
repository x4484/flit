import AppKit

struct KeyboardShortcutDescriptor: Sendable, Equatable {
  let action: String
  let keys: String
}

enum AppKeyboardShortcuts {
  static let archiveKeyEquivalent = "d"
  static let trashKeyEquivalent = "\u{8}"
  static let replyKeyEquivalent = "r"
  static let forwardKeyEquivalent = "f"

  static let displayed = [
    KeyboardShortcutDescriptor(action: "Archive", keys: "⌘D"),
    KeyboardShortcutDescriptor(action: "Move to Trash", keys: "⌫"),
    KeyboardShortcutDescriptor(action: "Reply", keys: "⌘R"),
    KeyboardShortcutDescriptor(action: "Forward", keys: "⌘F"),
    KeyboardShortcutDescriptor(action: "Send message", keys: "⌘↩"),
  ]
}

@MainActor
final class SettingsWindowController: NSWindowController {
  init(
    accounts: [MailAccount],
    hasOpenRouterAPIKey: Bool = false,
    onOpenRouterAPIKeyChange: @escaping (String?) -> Void = { _ in }
  ) {
    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar

    let accountsItem = NSTabViewItem(viewController: Self.accountsController(accounts: accounts))
    accountsItem.label = "Accounts"
    accountsItem.image = NSImage(
      systemSymbolName: "person.crop.circle",
      accessibilityDescription: "Accounts"
    )
    tabs.addTabViewItem(accountsItem)

    let summariesItem = NSTabViewItem(
      viewController: OpenRouterSettingsViewController(
        hasAPIKey: hasOpenRouterAPIKey,
        onAPIKeyChange: onOpenRouterAPIKeyChange
      ))
    summariesItem.label = "AI Summaries"
    summariesItem.image = NSImage(
      systemSymbolName: "sparkles",
      accessibilityDescription: "AI Summaries"
    )
    tabs.addTabViewItem(summariesItem)

    let shortcutsItem = NSTabViewItem(viewController: Self.shortcutsController())
    shortcutsItem.label = "Keyboard Shortcuts"
    shortcutsItem.image = NSImage(
      systemSymbolName: "keyboard",
      accessibilityDescription: "Keyboard Shortcuts"
    )
    tabs.addTabViewItem(shortcutsItem)

    let window = NSWindow(contentViewController: tabs)
    window.title = "Settings"
    window.styleMask = [.titled, .closable]
    window.setContentSize(NSSize(width: 520, height: 360))
    window.minSize = NSSize(width: 460, height: 320)
    window.isReleasedWhenClosed = false
    window.center()

    super.init(window: window)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func accountsController(accounts: [MailAccount]) -> NSViewController {
    let controller = NSViewController()
    controller.title = "Accounts"

    let container = NSView()
    controller.view = container

    let heading = NSTextField(labelWithString: "Accounts")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false

    if accounts.isEmpty {
      let empty = NSTextField(labelWithString: "No accounts connected")
      empty.textColor = .secondaryLabelColor
      stack.addArrangedSubview(empty)
    } else {
      for account in accounts {
        stack.addArrangedSubview(accountRow(account))
      }
    }

    let scrollView = NSScrollView()
    scrollView.documentView = stack
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(heading)
    container.addSubview(scrollView)
    heading.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
      heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

      scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
    ])

    return controller
  }

  private static func accountRow(_ account: MailAccount) -> NSView {
    let name = NSTextField(labelWithString: account.name)
    name.font = .systemFont(ofSize: 13, weight: .medium)

    let details = NSTextField(
      labelWithString: "\(account.email) · \(account.provider.capitalized)")
    details.font = .systemFont(ofSize: 12)
    details.textColor = .secondaryLabelColor
    details.lineBreakMode = .byTruncatingMiddle

    let labels = NSStackView(views: [name, details])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 3

    let icon = NSImageView()
    icon.image = NSImage(
      systemSymbolName: account.provider == "gmail" ? "envelope.fill" : "envelope",
      accessibilityDescription: nil
    )
    icon.contentTintColor = .secondaryLabelColor
    icon.translatesAutoresizingMaskIntoConstraints = false

    let row = NSStackView(views: [icon, labels])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    row.setAccessibilityLabel("\(account.name), \(account.email), \(account.provider)")

    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 24),
      icon.heightAnchor.constraint(equalToConstant: 24),
    ])
    return row
  }

  private static func shortcutsController() -> NSViewController {
    let controller = NSViewController()
    controller.title = "Keyboard Shortcuts"

    let container = NSView()
    controller.view = container

    let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    heading.translatesAutoresizingMaskIntoConstraints = false

    let note = NSTextField(labelWithString: "Shortcuts are fixed and cannot be changed.")
    note.font = .systemFont(ofSize: 12)
    note.textColor = .secondaryLabelColor
    note.translatesAutoresizingMaskIntoConstraints = false

    let rows = NSStackView()
    rows.orientation = .vertical
    rows.alignment = .width
    rows.spacing = 12
    rows.translatesAutoresizingMaskIntoConstraints = false
    for shortcut in AppKeyboardShortcuts.displayed {
      rows.addArrangedSubview(shortcutRow(shortcut))
    }

    container.addSubview(heading)
    container.addSubview(note)
    container.addSubview(rows)

    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
      heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      heading.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

      note.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
      note.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
      note.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

      rows.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 24),
      rows.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      rows.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
    ])

    return controller
  }

  private static func shortcutRow(_ shortcut: KeyboardShortcutDescriptor) -> NSView {
    let action = NSTextField(labelWithString: shortcut.action)
    action.font = .systemFont(ofSize: 13)

    let keys = NSTextField(labelWithString: shortcut.keys)
    keys.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
    keys.alignment = .right
    keys.setAccessibilityLabel("\(shortcut.action): \(shortcut.keys)")

    let spacer = NSView()
    let row = NSStackView(views: [action, spacer, keys])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fill
    return row
  }
}

@MainActor
private final class OpenRouterSettingsViewController: NSViewController {
  private let keyStore = OpenRouterAPIKeyStore()
  private let onAPIKeyChange: (String?) -> Void
  private let apiKeyField = NSSecureTextField()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let removeButton = NSButton(title: "Remove key", target: nil, action: nil)

  init(hasAPIKey: Bool, onAPIKeyChange: @escaping (String?) -> Void) {
    self.onAPIKeyChange = onAPIKeyChange
    super.init(nibName: nil, bundle: nil)
    title = "AI Summaries"
    configureView(hasAPIKey: hasAPIKey)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureView(hasAPIKey: Bool) {
    let container = NSView()
    view = container

    let heading = NSTextField(labelWithString: "AI summaries")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)

    let explanation = NSTextField(
      wrappingLabelWithString:
        "When you open an uncached email, Flit sends its sender, subject, and readable body to OpenRouter for a one-sentence summary."
    )
    explanation.font = .systemFont(ofSize: 12)
    explanation.textColor = .secondaryLabelColor

    let model = NSTextField(
      labelWithString: "Model: \(OpenRouterSummaryService.model)")
    model.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    model.textColor = .tertiaryLabelColor

    let apiKeyLabel = NSTextField(labelWithString: "OpenRouter API key")
    apiKeyLabel.font = .systemFont(ofSize: 13, weight: .medium)

    apiKeyField.placeholderString = "sk-or-v1-…"
    apiKeyField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    apiKeyField.setAccessibilityLabel("OpenRouter API key")
    apiKeyField.translatesAutoresizingMaskIntoConstraints = false

    let saveButton = NSButton(title: "Save key", target: self, action: #selector(saveAPIKey))
    saveButton.bezelStyle = .rounded
    saveButton.keyEquivalent = "\r"

    removeButton.target = self
    removeButton.action = #selector(removeAPIKey)
    removeButton.bezelStyle = .rounded
    removeButton.isEnabled = hasAPIKey

    let actions = NSStackView(views: [saveButton, removeButton])
    actions.orientation = .horizontal
    actions.alignment = .centerY
    actions.spacing = 10

    statusLabel.font = .systemFont(ofSize: 12)
    statusLabel.textColor = .secondaryLabelColor
    setStatus(hasAPIKey ? "API key saved in Keychain." : "No API key saved.")

    let stack = NSStackView(
      views: [heading, explanation, model, apiKeyLabel, apiKeyField, actions, statusLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.setCustomSpacing(18, after: model)
    stack.setCustomSpacing(12, after: apiKeyField)
    stack.translatesAutoresizingMaskIntoConstraints = false

    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
      apiKeyField.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
  }

  @objc private func saveAPIKey() {
    let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      setStatus("Enter an OpenRouter API key.", isError: true)
      view.window?.makeFirstResponder(apiKeyField)
      return
    }

    do {
      try keyStore.save(key)
      apiKeyField.stringValue = ""
      removeButton.isEnabled = true
      setStatus("API key saved in Keychain.")
      onAPIKeyChange(key)
    } catch {
      setStatus("Unable to save the API key. Try again.", isError: true)
    }
  }

  @objc private func removeAPIKey() {
    do {
      try keyStore.delete()
      apiKeyField.stringValue = ""
      removeButton.isEnabled = false
      setStatus("API key removed.")
      onAPIKeyChange(nil)
    } catch {
      setStatus("Unable to remove the API key. Try again.", isError: true)
    }
  }

  private func setStatus(_ text: String, isError: Bool = false) {
    statusLabel.stringValue = text
    statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    statusLabel.setAccessibilityLabel(text)
  }
}
