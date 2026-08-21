import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  private let store: MailStore
  private var messages: [MessageSummary] = []
  private var searchTask: Task<Void, Never>?
  private var currentQuery = ""

  private let tableView = NSTableView()
  private let searchField = NSSearchField()
  private let senderLabel = NSTextField(labelWithString: "")
  private let subjectLabel = NSTextField(labelWithString: "")
  private let metadataLabel = NSTextField(labelWithString: "")
  private let bodyView = NSTextView()
  private let archiveButton = NSButton(title: "Archive", target: nil, action: nil)
  private let trashButton = NSButton(title: "Trash", target: nil, action: nil)

  private lazy var rowDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    return formatter
  }()

  init(store: MailStore) {
    self.store = store

    let splitController = NSSplitViewController()
    let window = NSWindow(contentViewController: splitController)
    window.title = "Flit"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.backgroundColor = .windowBackgroundColor
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.setContentSize(NSSize(width: 1_020, height: 680))
    window.minSize = NSSize(width: 760, height: 480)
    window.setFrameAutosaveName("FlitMainWindow")

    super.init(window: window)

    splitController.addSplitViewItem(
      NSSplitViewItem(contentListWithViewController: makeInboxController()))
    splitController.addSplitViewItem(NSSplitViewItem(viewController: makePreviewController()))
    splitController.splitView.dividerStyle = .thin
    splitController.splitView.setPosition(340, ofDividerAt: 0)

    loadMessages()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    window?.makeKeyAndOrderFront(sender)
    window?.makeFirstResponder(tableView)
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    messages.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard messages.indices.contains(row) else { return nil }
    let cell =
      (tableView.makeView(withIdentifier: MessageCellView.identifier, owner: self)
        as? MessageCellView)
      ?? MessageCellView()
    let message = messages[row]
    cell.configure(with: message, dateText: rowDateFormatter.string(from: message.receivedDate))
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    MessageRowView()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    renderSelection()
    markSelectedReadIfNeeded()
  }

  func controlTextDidChange(_ notification: Notification) {
    searchTask?.cancel()
    let query = searchField.stringValue
    searchTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 50_000_000)
      guard !Task.isCancelled else { return }
      self?.loadMessages(query: query)
    }
  }

  @objc func archiveSelected() {
    performMove(.archive)
  }

  @objc func trashSelected() {
    performMove(.trash)
  }

  @objc func focusSearch() {
    window?.makeFirstResponder(searchField)
  }

  @objc func refreshInbox() {
    loadMessages(query: searchField.stringValue)
  }

  func reloadAfterSeed() {
    loadMessages(query: searchField.stringValue)
  }

  private func makeInboxController() -> NSViewController {
    let titleLabel = NSTextField(labelWithString: "Inbox")
    titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
    titleLabel.translatesAutoresizingMaskIntoConstraints = false

    searchField.placeholderString = "Search"
    searchField.delegate = self
    searchField.controlSize = .large
    searchField.setAccessibilityLabel("Search inbox and archive")
    searchField.translatesAutoresizingMaskIntoConstraints = false

    tableView.headerView = nil
    tableView.backgroundColor = .clear
    tableView.rowHeight = 60
    tableView.intercellSpacing = NSSize(width: 0, height: 2)
    tableView.selectionHighlightStyle = .regular
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.delegate = self
    tableView.dataSource = self
    tableView.setAccessibilityLabel("Unified inbox")

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Message"))
    column.resizingMask = .autoresizingMask
    tableView.addTableColumn(column)

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false

    let viewController = NSViewController()
    let container = SidebarSurfaceView()
    viewController.view = container
    container.addSubview(titleLabel)
    container.addSubview(searchField)
    container.addSubview(scrollView)

    NSLayoutConstraint.activate([
      titleLabel.topAnchor.constraint(
        equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 14),
      titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: container.trailingAnchor, constant: -16),
      searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
      searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
      searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
      scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return viewController
  }

  private func makePreviewController() -> NSViewController {
    senderLabel.font = .systemFont(ofSize: 13, weight: .medium)
    senderLabel.textColor = .secondaryLabelColor
    senderLabel.lineBreakMode = .byTruncatingTail

    subjectLabel.font = .systemFont(ofSize: 28, weight: .semibold)
    subjectLabel.maximumNumberOfLines = 2
    subjectLabel.lineBreakMode = .byTruncatingTail
    subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    metadataLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    metadataLabel.textColor = .tertiaryLabelColor

    configureActionButton(
      archiveButton,
      symbolName: "archivebox",
      toolTip: "Archive selected message (Command-E)",
      accessibilityLabel: "Archive selected message",
      action: #selector(archiveSelected)
    )
    archiveButton.keyEquivalent = "e"
    archiveButton.keyEquivalentModifierMask = [.command]

    configureActionButton(
      trashButton,
      symbolName: "trash",
      toolTip: "Move selected message to Trash",
      accessibilityLabel: "Move selected message to Trash",
      action: #selector(trashSelected)
    )

    let actions = NSStackView(views: [archiveButton, trashButton])
    actions.orientation = .horizontal
    actions.spacing = 4

    let metadataRow = NSStackView(views: [metadataLabel, NSView(), actions])
    metadataRow.orientation = .horizontal
    metadataRow.alignment = .centerY
    metadataRow.distribution = .fill
    metadataRow.spacing = 12

    let header = NSStackView(views: [senderLabel, subjectLabel, metadataRow])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 10
    header.translatesAutoresizingMaskIntoConstraints = false

    bodyView.isEditable = false
    bodyView.isRichText = false
    bodyView.drawsBackground = false
    bodyView.font = .systemFont(ofSize: 16)
    bodyView.textContainerInset = NSSize(width: 0, height: 16)
    bodyView.textContainer?.lineFragmentPadding = 0
    bodyView.textContainer?.widthTracksTextView = true
    bodyView.setAccessibilityLabel("Message body")

    let bodyScrollView = NSScrollView()
    bodyScrollView.documentView = bodyView
    bodyScrollView.hasVerticalScroller = true
    bodyScrollView.autohidesScrollers = true
    bodyScrollView.drawsBackground = false
    bodyScrollView.translatesAutoresizingMaskIntoConstraints = false

    let viewController = NSViewController()
    let container = NSView()
    let contentColumn = NSView()
    contentColumn.translatesAutoresizingMaskIntoConstraints = false
    viewController.view = container
    container.addSubview(contentColumn)
    contentColumn.addSubview(header)
    contentColumn.addSubview(bodyScrollView)

    let preferredContentWidth = contentColumn.widthAnchor.constraint(
      equalTo: container.widthAnchor,
      constant: -56
    )
    preferredContentWidth.priority = .defaultHigh

    NSLayoutConstraint.activate([
      contentColumn.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
      contentColumn.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      contentColumn.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      contentColumn.leadingAnchor.constraint(
        greaterThanOrEqualTo: container.leadingAnchor, constant: 28),
      contentColumn.trailingAnchor.constraint(
        lessThanOrEqualTo: container.trailingAnchor, constant: -28),
      contentColumn.widthAnchor.constraint(lessThanOrEqualToConstant: 734),
      preferredContentWidth,

      header.topAnchor.constraint(equalTo: contentColumn.topAnchor, constant: 40),
      header.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
      metadataRow.widthAnchor.constraint(equalTo: header.widthAnchor),

      bodyScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
      bodyScrollView.leadingAnchor.constraint(equalTo: contentColumn.leadingAnchor),
      bodyScrollView.trailingAnchor.constraint(equalTo: contentColumn.trailingAnchor),
      bodyScrollView.bottomAnchor.constraint(equalTo: contentColumn.bottomAnchor, constant: -20),
    ])

    renderSelection()
    return viewController
  }

  private func configureActionButton(
    _ button: NSButton,
    symbolName: String,
    toolTip: String,
    accessibilityLabel: String,
    action: Selector
  ) {
    button.target = self
    button.action = action
    button.title = ""
    button.image = NSImage(
      systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.bezelStyle = .inline
    button.isBordered = false
    button.contentTintColor = .secondaryLabelColor
    button.toolTip = toolTip
    button.setAccessibilityLabel(accessibilityLabel)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 36),
      button.heightAnchor.constraint(equalToConstant: 36),
    ])
  }

  private func loadMessages(query: String = "") {
    currentQuery = query
    Task { [weak self, store] in
      do {
        let loaded =
          query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? try await store.fetchInbox(limit: 200)
          : try await store.search(query, limit: 200)
        guard let self else { return }
        self.messages = loaded
        self.tableView.reloadData()
        if !loaded.isEmpty {
          self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
          self.renderSelection()
        }
      } catch {
        self?.showError(error)
      }
    }
  }

  private func performMove(_ destination: MailboxState) {
    let selectedRow = tableView.selectedRow
    guard messages.indices.contains(selectedRow) else { return }

    let message = messages.remove(at: selectedRow)
    tableView.removeRows(at: IndexSet(integer: selectedRow), withAnimation: [])

    if !messages.isEmpty {
      let nextRow = min(selectedRow, messages.count - 1)
      tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
    } else {
      renderSelection()
    }

    Task { [weak self, store] in
      do {
        switch destination {
        case .archive: try await store.archive(messageID: message.id)
        case .trash: try await store.moveToTrash(messageID: message.id)
        case .inbox: break
        }
      } catch {
        guard let self else { return }
        self.messages.insert(message, at: min(selectedRow, self.messages.count))
        self.tableView.reloadData()
        self.showError(error)
      }
    }
  }

  private func markSelectedReadIfNeeded() {
    let selectedRow = tableView.selectedRow
    guard messages.indices.contains(selectedRow), !messages[selectedRow].isRead else { return }
    let messageID = messages[selectedRow].id
    Task { [store] in
      try? await store.markRead(messageID: messageID)
    }
  }

  private func renderSelection() {
    let selectedRow = tableView.selectedRow
    guard messages.indices.contains(selectedRow) else {
      senderLabel.stringValue = ""
      subjectLabel.stringValue = currentQuery.isEmpty ? "Inbox is clear" : "No results"
      metadataLabel.stringValue = ""
      bodyView.string =
        currentQuery.isEmpty
        ? "New messages will appear here."
        : "Try a different search."
      archiveButton.isEnabled = false
      trashButton.isEnabled = false
      return
    }

    let message = messages[selectedRow]
    senderLabel.stringValue = "\(message.sender)  →  \(message.recipients)"
    subjectLabel.stringValue = message.subject.isEmpty ? "(No subject)" : message.subject
    metadataLabel.stringValue =
      "\(message.accountName) · \(rowDateFormatter.string(from: message.receivedDate))"
    bodyView.string =
      message.preview.isEmpty
      ? "Body not cached. Provider sync is the next milestone." : message.preview
    archiveButton.isEnabled = true
    trashButton.isEnabled = true
  }

  private func showError(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.beginSheetModal(for: window ?? NSWindow())
  }
}
