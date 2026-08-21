import AppKit

@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  private let store: MailStore
  private var messages: [MessageSummary] = []
  private var searchTask: Task<Void, Never>?

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
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.setContentSize(NSSize(width: 1_020, height: 680))
    window.minSize = NSSize(width: 760, height: 480)
    window.setFrameAutosaveName("FlitMainWindow")

    super.init(window: window)

    splitController.addSplitViewItem(
      NSSplitViewItem(contentListWithViewController: makeInboxController()))
    splitController.addSplitViewItem(NSSplitViewItem(viewController: makePreviewController()))
    splitController.splitView.setPosition(370, ofDividerAt: 0)

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
    searchField.placeholderString = "Search inbox and archive"
    searchField.delegate = self
    searchField.setAccessibilityLabel("Search inbox and archive")
    searchField.translatesAutoresizingMaskIntoConstraints = false

    tableView.headerView = nil
    tableView.rowHeight = 56
    tableView.intercellSpacing = NSSize(width: 0, height: 0)
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
    let container = NSView()
    viewController.view = container
    container.addSubview(searchField)
    container.addSubview(scrollView)

    NSLayoutConstraint.activate([
      searchField.topAnchor.constraint(
        equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 10),
      searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
      searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
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

    subjectLabel.font = .systemFont(ofSize: 24, weight: .semibold)
    subjectLabel.maximumNumberOfLines = 2
    subjectLabel.lineBreakMode = .byTruncatingTail

    metadataLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    metadataLabel.textColor = .tertiaryLabelColor

    archiveButton.target = self
    archiveButton.action = #selector(archiveSelected)
    archiveButton.keyEquivalent = "e"
    archiveButton.keyEquivalentModifierMask = [.command]
    archiveButton.toolTip = "Archive selected message (Command-E)"
    archiveButton.setAccessibilityLabel("Archive selected message")

    trashButton.target = self
    trashButton.action = #selector(trashSelected)
    trashButton.toolTip = "Move selected message to Trash"
    trashButton.setAccessibilityLabel("Move selected message to Trash")

    let actions = NSStackView(views: [archiveButton, trashButton])
    actions.orientation = .horizontal
    actions.spacing = 8

    let header = NSStackView(views: [senderLabel, subjectLabel, metadataLabel, actions])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 8
    header.translatesAutoresizingMaskIntoConstraints = false

    bodyView.isEditable = false
    bodyView.isRichText = false
    bodyView.drawsBackground = false
    bodyView.font = .systemFont(ofSize: 15)
    bodyView.textContainerInset = NSSize(width: 0, height: 12)
    bodyView.setAccessibilityLabel("Message body")

    let bodyScrollView = NSScrollView()
    bodyScrollView.documentView = bodyView
    bodyScrollView.hasVerticalScroller = true
    bodyScrollView.autohidesScrollers = true
    bodyScrollView.drawsBackground = false
    bodyScrollView.translatesAutoresizingMaskIntoConstraints = false

    let viewController = NSViewController()
    let container = NSView()
    viewController.view = container
    container.addSubview(header)
    container.addSubview(bodyScrollView)

    NSLayoutConstraint.activate([
      header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 28),
      header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
      header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -28),
      bodyScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
      bodyScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
      bodyScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
      bodyScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
    ])

    renderSelection()
    return viewController
  }

  private func loadMessages(query: String = "") {
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
      subjectLabel.stringValue = "Inbox zero"
      metadataLabel.stringValue = ""
      bodyView.string = "There are no messages to triage."
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
