import AppKit
import WebKit

@MainActor
final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate, NSMenuItemValidation, WKNavigationDelegate
{
  private let store: MailStore
  private let gmailSyncService: GmailSyncService
  private let openRouterKeyStore = OpenRouterAPIKeyStore()
  private let summaryService = OpenRouterSummaryService()
  private var messages: [MessageSummary] = []
  private var threadMessages: [MessageSummary] = []
  private var activeMessageID: Int64?
  private var selectedThreadRemoteID: String?
  private var isUpdatingThreadSelection = false
  private var searchTask: Task<Void, Never>?
  private var remoteSearchTask: Task<Void, Never>?
  private var threadLoadTask: Task<Void, Never>?
  private var bodyLoadTask: Task<Void, Never>?
  private var summaryTask: Task<Void, Never>?
  private var composeWindowController: ComposeWindowController?
  private var settingsWindowController: SettingsWindowController?
  private var cachedBodyURLs: [Int64: URL] = [:]
  private var transientBodyURLs: [Int64: URL] = [:]
  private var suppressNextReadMark = false
  private var currentQuery = ""
  private var inboxCount = 0
  private var displayedBodyText = ""
  private var cachedOpenRouterAPIKey: String?
  private var didLoadOpenRouterAPIKey = false
  private var isLoadingMoreMessages = false
  private var hasMoreInboxMessages = true

  private let tableView = NSTableView()
  private let threadTableView = NSTableView()
  private var threadSplitItem: NSSplitViewItem?
  private let threadHeadingLabel = NSTextField(labelWithString: "Thread")
  private let searchField = NSSearchField()
  private let inboxCountLabel = NSTextField(labelWithString: "0")
  private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
  private let settingsButton = NSButton(title: "Settings", target: nil, action: nil)
  private let fromLabel = NSTextField(labelWithString: "")
  private let toLabel = NSTextField(labelWithString: "")
  private let ccLabel = NSTextField(labelWithString: "")
  private let subjectLabel = NSTextField(labelWithString: "")
  private let metadataLabel = NSTextField(labelWithString: "")
  private let bodyView = NSTextView()
  private let summaryLabel = NSTextField(wrappingLabelWithString: "")
  private let bodyScrollView = NSScrollView(
    frame: NSRect(x: 0, y: 0, width: 734, height: 480)
  )
  private lazy var bodyWebView: WKWebView = {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.allowsAirPlayForMediaPlayback = false

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.underPageBackgroundColor = .textBackgroundColor
    webView.setAccessibilityLabel("HTML message body")
    return webView
  }()
  private let replyButton = NSButton(title: "Reply", target: nil, action: nil)
  private let replyAllButton = NSButton(title: "Reply All", target: nil, action: nil)
  private let forwardButton = NSButton(title: "Forward", target: nil, action: nil)
  private let archiveButton = NSButton(title: "Archive", target: nil, action: nil)
  private let trashButton = NSButton(title: "Trash", target: nil, action: nil)

  private lazy var rowDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()

  private lazy var quotedDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  init(store: MailStore) {
    self.store = store
    self.gmailSyncService = GmailSyncService(store: store)

    let splitController = NSSplitViewController()
    let window = NSWindow(contentViewController: splitController)
    window.title = "Flit"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.backgroundColor = .windowBackgroundColor
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.setContentSize(NSSize(width: 1_300, height: 680))
    window.minSize = NSSize(width: 980, height: 480)
    window.setFrameAutosaveName("FlitMainWindow")

    super.init(window: window)

    splitController.addSplitViewItem(
      NSSplitViewItem(contentListWithViewController: makeInboxController()))
    splitController.addSplitViewItem(NSSplitViewItem(viewController: makePreviewController()))
    let summaryItem = NSSplitViewItem(viewController: makeSummaryController())
    summaryItem.minimumThickness = 220
    summaryItem.maximumThickness = 320
    splitController.addSplitViewItem(summaryItem)
    splitController.splitView.dividerStyle = .thin
    splitController.splitView.setPosition(340, ofDividerAt: 0)
    splitController.splitView.setPosition(1_020, ofDividerAt: 1)

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
    tableView === threadTableView ? threadMessages.count : messages.count
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    if tableView === threadTableView {
      guard threadMessages.indices.contains(row) else { return nil }
      let cell =
        (tableView.makeView(withIdentifier: ThreadMessageCellView.identifier, owner: self)
          as? ThreadMessageCellView)
        ?? ThreadMessageCellView()
      let message = threadMessages[row]
      cell.configure(
        with: message,
        dateText: rowDateFormatter.string(from: message.receivedDate),
        position: row + 1,
        count: threadMessages.count
      )
      return cell
    }

    guard messages.indices.contains(row) else { return nil }
    let cell =
      (tableView.makeView(withIdentifier: MessageCellView.identifier, owner: self)
        as? MessageCellView)
      ?? MessageCellView()
    let message = messages[row]
    cell.configure(with: message, dateText: rowDateFormatter.string(from: message.receivedDate))
    if row >= messages.count - 12 {
      loadMoreInboxMessagesIfNeeded()
    }
    return cell
  }

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    MessageRowView()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard let changedTable = notification.object as? NSTableView else { return }
    if changedTable === threadTableView {
      guard !isUpdatingThreadSelection,
        threadMessages.indices.contains(threadTableView.selectedRow)
      else { return }
      activeMessageID = threadMessages[threadTableView.selectedRow].id
      renderSelection()
      markSelectedReadIfNeeded()
      return
    }

    guard changedTable === tableView, messages.indices.contains(tableView.selectedRow) else {
      activeMessageID = nil
      selectedThreadRemoteID = nil
      threadMessages = []
      updateThreadNavigator()
      renderSelection()
      return
    }
    let message = messages[tableView.selectedRow]
    activeMessageID = message.id
    selectedThreadRemoteID = message.threadRemoteID.isEmpty ? nil : message.threadRemoteID
    threadMessages = [message]
    updateThreadNavigator()
    renderSelection()
    loadThread(for: message)
    if suppressNextReadMark {
      suppressNextReadMark = false
    } else {
      markSelectedReadIfNeeded()
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    searchTask?.cancel()
    remoteSearchTask?.cancel()
    let query = searchField.stringValue
    searchTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
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

  @objc func replySelected() {
    presentComposer(.reply)
  }

  @objc func replyAllSelected() {
    presentComposer(.replyAll)
  }

  @objc func forwardSelected() {
    presentComposer(.forward)
  }

  @objc func focusSearch() {
    window?.makeFirstResponder(searchField)
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    let messageActions: Set<Selector> = [
      #selector(archiveSelected),
      #selector(trashSelected),
      #selector(replySelected),
      #selector(replyAllSelected),
      #selector(forwardSelected),
    ]
    guard let action = menuItem.action, messageActions.contains(action) else { return true }
    guard window?.isKeyWindow == true, window?.attachedSheet == nil else { return false }

    guard let message = selectedMessage else { return false }
    if action == #selector(archiveSelected) || action == #selector(trashSelected) {
      guard message.mailboxState == .inbox else { return false }
    }
    if action == #selector(trashSelected),
      let textView = window?.firstResponder as? NSTextView,
      textView.isEditable
    {
      return false
    }
    if action == #selector(replySelected) || action == #selector(replyAllSelected)
      || action == #selector(forwardSelected)
    {
      return message.accountProvider == "gmail"
    }
    return true
  }

  @objc func refreshInbox() {
    synchronizeGmail(showErrors: true)
  }

  @objc func openSettings() {
    if let settingsWindowController, settingsWindowController.window?.isVisible == true {
      settingsWindowController.showWindow(nil)
      settingsWindowController.window?.makeKeyAndOrderFront(nil)
      return
    }

    settingsButton.isEnabled = false
    Task { [weak self, store] in
      do {
        let accounts = try await store.accounts()
        guard let self else { return }
        let apiKey = try self.loadOpenRouterAPIKey()
        let controller = SettingsWindowController(
          accounts: accounts,
          hasOpenRouterAPIKey: apiKey != nil
        ) { [weak self] updatedKey in
          guard let self else { return }
          self.cachedOpenRouterAPIKey = updatedKey
          self.didLoadOpenRouterAPIKey = true
          self.renderSelection()
        }
        self.settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      } catch {
        self?.showError(error)
      }
      self?.settingsButton.isEnabled = true
    }
  }

  @objc func addGmailAccount() {
    guard let window else { return }

    let emailField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    emailField.placeholderString = "name@gmail.com"
    emailField.setAccessibilityLabel("Gmail address")

    let alert = NSAlert()
    alert.messageText = "Add Gmail account"
    alert.informativeText =
      "Enter the Gmail address you want to connect. Google sign-in will open in your browser."
    alert.accessoryView = emailField
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")

    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.connectGmail(email: emailField.stringValue)
    }
  }

  func reloadAfterSeed() {
    loadMessages(query: searchField.stringValue)
  }

  func syncConnectedAccounts() {
    synchronizeGmail(showErrors: false)
  }

  private func connectGmail(email: String) {
    Task { [weak self, store] in
      guard let self else { return }
      do {
        let configuration = try GoogleOAuthConfigurationLoader.load()
        let oauth = GoogleOAuthService(configuration: configuration)
        let session = try await oauth.authorize(email: email)
        _ = try await store.addAccount(
          name: "Gmail",
          email: session.email,
          provider: "gmail"
        )
        let synchronizedCount = try await self.gmailSyncService.syncAllAccounts()
        self.loadMessages(query: self.searchField.stringValue)
        let messageLabel = synchronizedCount == 1 ? "message" : "messages"
        self.showMessage(
          title: "Gmail connected",
          message: "Flit securely connected \(session.email) and synced \(synchronizedCount) \(messageLabel)."
        )
      } catch {
        self.showError(error)
      }
    }
  }

  private func synchronizeGmail(showErrors: Bool) {
    refreshButton.isEnabled = false
    Task { [weak self, gmailSyncService] in
      do {
        _ = try await gmailSyncService.syncAllAccounts()
        guard let self else { return }
        self.loadMessages(query: self.searchField.stringValue)
      } catch {
        if showErrors {
          self?.showError(error)
        }
      }
      self?.refreshButton.isEnabled = true
    }
  }

  private func makeInboxController() -> NSViewController {
    let titleLabel = NSTextField(labelWithString: "Inbox")
    titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

    inboxCountLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    inboxCountLabel.textColor = .tertiaryLabelColor
    updateInboxCount(0)

    configureActionButton(
      refreshButton,
      symbolName: "arrow.clockwise",
      toolTip: "Refresh inbox",
      accessibilityLabel: "Refresh inbox",
      action: #selector(refreshInbox)
    )

    configureActionButton(
      settingsButton,
      symbolName: "gearshape",
      toolTip: "Settings",
      accessibilityLabel: "Settings",
      action: #selector(openSettings)
    )

    let titleRow = NSStackView(
      views: [titleLabel, inboxCountLabel, NSView(), refreshButton, settingsButton])
    titleRow.orientation = .horizontal
    titleRow.alignment = .centerY
    titleRow.spacing = 8
    titleRow.translatesAutoresizingMaskIntoConstraints = false

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
    container.addSubview(titleRow)
    container.addSubview(searchField)
    container.addSubview(scrollView)

    NSLayoutConstraint.activate([
      titleRow.topAnchor.constraint(
        equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
      titleRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      titleRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
      searchField.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 6),
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
    for addressLabel in [fromLabel, toLabel, ccLabel] {
      addressLabel.font = .systemFont(ofSize: 13)
      addressLabel.textColor = .secondaryLabelColor
      addressLabel.lineBreakMode = .byTruncatingTail
      addressLabel.maximumNumberOfLines = 1
      addressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    subjectLabel.font = .systemFont(ofSize: 28, weight: .semibold)
    subjectLabel.maximumNumberOfLines = 2
    subjectLabel.lineBreakMode = .byWordWrapping
    subjectLabel.cell?.wraps = true
    subjectLabel.cell?.truncatesLastVisibleLine = true
    subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    metadataLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    metadataLabel.textColor = .tertiaryLabelColor

    configureActionButton(
      replyButton,
      symbolName: "arrowshape.turn.up.left",
      toolTip: "Reply",
      accessibilityLabel: "Reply",
      action: #selector(replySelected)
    )
    configureActionButton(
      replyAllButton,
      symbolName: "arrowshape.turn.up.left.2",
      toolTip: "Reply all",
      accessibilityLabel: "Reply all",
      action: #selector(replyAllSelected)
    )
    configureActionButton(
      forwardButton,
      symbolName: "arrowshape.turn.up.right",
      toolTip: "Forward",
      accessibilityLabel: "Forward",
      action: #selector(forwardSelected)
    )

    configureActionButton(
      archiveButton,
      symbolName: "archivebox",
      toolTip: "Archive selected message (Command-D)",
      accessibilityLabel: "Archive selected message",
      action: #selector(archiveSelected)
    )
    configureActionButton(
      trashButton,
      symbolName: "trash",
      toolTip: "Move selected message to Trash",
      accessibilityLabel: "Move selected message to Trash",
      action: #selector(trashSelected)
    )

    let correspondenceActions = NSStackView(
      views: [replyButton, replyAllButton, forwardButton])
    correspondenceActions.orientation = .horizontal
    correspondenceActions.spacing = 2

    let mailboxActions = NSStackView(views: [archiveButton, trashButton])
    mailboxActions.orientation = .horizontal
    mailboxActions.spacing = 2

    let actions = NSStackView(views: [correspondenceActions, mailboxActions])
    actions.orientation = .horizontal
    actions.spacing = 10

    let metadataRow = NSStackView(views: [metadataLabel, NSView(), actions])
    metadataRow.orientation = .horizontal
    metadataRow.alignment = .centerY
    metadataRow.distribution = .fill
    metadataRow.spacing = 12

    let header = NSStackView(views: [fromLabel, toLabel, ccLabel, subjectLabel, metadataRow])
    header.orientation = .vertical
    header.alignment = .leading
    header.spacing = 3
    header.setCustomSpacing(10, after: ccLabel)
    header.setCustomSpacing(10, after: subjectLabel)
    header.translatesAutoresizingMaskIntoConstraints = false

    bodyView.isEditable = false
    bodyView.isSelectable = true
    bodyView.isRichText = true
    bodyView.importsGraphics = false
    bodyView.drawsBackground = false
    bodyView.backgroundColor = .clear
    bodyView.textColor = .labelColor
    bodyView.font = .systemFont(ofSize: 16)
    bodyView.textContainerInset = NSSize(width: 0, height: 16)
    bodyView.textContainer?.lineFragmentPadding = 0
    bodyView.textContainer?.widthTracksTextView = true
    bodyView.setAccessibilityLabel("Message body")

    bodyScrollView.hasVerticalScroller = true
    bodyScrollView.autohidesScrollers = true
    bodyScrollView.drawsBackground = false
    bodyScrollView.translatesAutoresizingMaskIntoConstraints = false

    bodyView.frame = bodyScrollView.contentView.bounds
    bodyView.minSize = NSSize(width: 0, height: bodyScrollView.contentSize.height)
    bodyView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    bodyView.isVerticallyResizable = true
    bodyView.isHorizontallyResizable = false
    bodyView.autoresizingMask = [.width]
    bodyView.textContainer?.containerSize = NSSize(
      width: bodyScrollView.contentSize.width,
      height: CGFloat.greatestFiniteMagnitude
    )
    bodyScrollView.documentView = bodyView

    let viewController = NSViewController()
    let container = ReaderSurfaceView()
    let contentColumn = NSView()
    contentColumn.translatesAutoresizingMaskIntoConstraints = false
    viewController.view = container
    container.addSubview(contentColumn)
    contentColumn.addSubview(header)
    contentColumn.addSubview(bodyScrollView)
    contentColumn.addSubview(bodyWebView)

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

      bodyWebView.topAnchor.constraint(equalTo: bodyScrollView.topAnchor),
      bodyWebView.leadingAnchor.constraint(equalTo: bodyScrollView.leadingAnchor),
      bodyWebView.trailingAnchor.constraint(equalTo: bodyScrollView.trailingAnchor),
      bodyWebView.bottomAnchor.constraint(equalTo: bodyScrollView.bottomAnchor),
    ])

    renderSelection()
    return viewController
  }

  private func makeSummaryController() -> NSViewController {
    let splitController = NSSplitViewController()
    splitController.splitView.isVertical = false
    splitController.splitView.dividerStyle = .thin
    splitController.splitView.autosaveName = "FlitSummaryThreadSplit"

    let summaryController = NSViewController()
    let summaryContainer = SidebarSurfaceView()
    summaryController.view = summaryContainer

    let heading = NSTextField(labelWithString: "Summary")
    heading.font = .systemFont(ofSize: 16, weight: .semibold)
    heading.translatesAutoresizingMaskIntoConstraints = false

    summaryLabel.font = .systemFont(ofSize: 15, weight: .regular)
    summaryLabel.textColor = .labelColor
    summaryLabel.isSelectable = true
    summaryLabel.maximumNumberOfLines = 0
    summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    summaryLabel.setAccessibilityLabel("Email summary")
    summaryLabel.translatesAutoresizingMaskIntoConstraints = false

    summaryContainer.addSubview(heading)
    summaryContainer.addSubview(summaryLabel)
    NSLayoutConstraint.activate([
      heading.topAnchor.constraint(
        equalTo: summaryContainer.safeAreaLayoutGuide.topAnchor, constant: 24),
      heading.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor, constant: 20),
      heading.trailingAnchor.constraint(
        lessThanOrEqualTo: summaryContainer.trailingAnchor, constant: -20),
      summaryLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
      summaryLabel.leadingAnchor.constraint(equalTo: summaryContainer.leadingAnchor, constant: 20),
      summaryLabel.trailingAnchor.constraint(equalTo: summaryContainer.trailingAnchor, constant: -20),
      summaryLabel.bottomAnchor.constraint(
        lessThanOrEqualTo: summaryContainer.bottomAnchor, constant: -20),
    ])

    let threadController = NSViewController()
    let threadContainer = SidebarSurfaceView()
    threadController.view = threadContainer
    threadHeadingLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    threadHeadingLabel.translatesAutoresizingMaskIntoConstraints = false

    threadTableView.headerView = nil
    threadTableView.backgroundColor = .clear
    threadTableView.rowHeight = 58
    threadTableView.intercellSpacing = NSSize(width: 0, height: 2)
    threadTableView.selectionHighlightStyle = .regular
    threadTableView.usesAlternatingRowBackgroundColors = false
    threadTableView.delegate = self
    threadTableView.dataSource = self
    threadTableView.setAccessibilityLabel("Messages in thread")
    let threadColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ThreadMessage"))
    threadColumn.resizingMask = .autoresizingMask
    threadTableView.addTableColumn(threadColumn)

    let threadScrollView = NSScrollView()
    threadScrollView.documentView = threadTableView
    threadScrollView.hasVerticalScroller = true
    threadScrollView.autohidesScrollers = true
    threadScrollView.drawsBackground = false
    threadScrollView.translatesAutoresizingMaskIntoConstraints = false

    threadContainer.addSubview(threadHeadingLabel)
    threadContainer.addSubview(threadScrollView)
    NSLayoutConstraint.activate([
      threadHeadingLabel.topAnchor.constraint(equalTo: threadContainer.topAnchor, constant: 16),
      threadHeadingLabel.leadingAnchor.constraint(equalTo: threadContainer.leadingAnchor, constant: 20),
      threadHeadingLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: threadContainer.trailingAnchor, constant: -20),
      threadScrollView.topAnchor.constraint(equalTo: threadHeadingLabel.bottomAnchor, constant: 10),
      threadScrollView.leadingAnchor.constraint(equalTo: threadContainer.leadingAnchor),
      threadScrollView.trailingAnchor.constraint(equalTo: threadContainer.trailingAnchor),
      threadScrollView.bottomAnchor.constraint(equalTo: threadContainer.bottomAnchor),
    ])

    let summaryItem = NSSplitViewItem(viewController: summaryController)
    summaryItem.minimumThickness = 140
    summaryItem.preferredThicknessFraction = 0.38
    splitController.addSplitViewItem(summaryItem)
    let threadItem = NSSplitViewItem(viewController: threadController)
    threadItem.minimumThickness = 180
    threadItem.isCollapsed = true
    splitController.addSplitViewItem(threadItem)
    threadSplitItem = threadItem

    setSummaryText("Open an email to see its summary.")
    return splitController
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
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalizedQuery.isEmpty {
      hasMoreInboxMessages = true
    }

    Task { [weak self, store] in
      do {
        let loaded =
          normalizedQuery.isEmpty
          ? try await store.fetchInbox(limit: 200)
          : try await store.search(normalizedQuery, limit: 200)
        let inboxCount = try await store.inboxCount()
        guard let self, self.currentQuery == query else { return }
        self.messages = loaded
        self.updateInboxCount(inboxCount)
        self.tableView.reloadData()
        if !loaded.isEmpty {
          let selectionWillChange = self.tableView.selectedRow != 0
          self.suppressNextReadMark = selectionWillChange
          self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
          if !selectionWillChange {
            let message = loaded[0]
            self.activeMessageID = message.id
            self.selectedThreadRemoteID = message.threadRemoteID.isEmpty
              ? nil : message.threadRemoteID
            self.threadMessages = [message]
            self.updateThreadNavigator()
            self.renderSelection()
            self.loadThread(for: message)
          }
        } else {
          self.activeMessageID = nil
          self.selectedThreadRemoteID = nil
          self.threadMessages = []
          self.updateThreadNavigator()
          self.renderSelection()
        }

        if !normalizedQuery.isEmpty {
          self.searchRemoteInbox(query: normalizedQuery)
        }
      } catch {
        self?.showError(error)
      }
    }
  }

  private func loadMoreInboxMessagesIfNeeded() {
    guard currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      hasMoreInboxMessages,
      !isLoadingMoreMessages,
      let cursor = messages.last?.cursor
    else { return }

    isLoadingMoreMessages = true
    Task { [weak self, store, gmailSyncService] in
      guard let self else { return }
      defer { self.isLoadingMoreMessages = false }
      do {
        var loaded = try await store.fetchInbox(after: cursor, limit: 100)
        if loaded.isEmpty {
          let discovered = try await gmailSyncService.fetchOlderInboxPage(limit: 100)
          if discovered > 0 {
            loaded = try await store.fetchInbox(after: cursor, limit: 100)
          }
        }
        guard self.currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          return
        }
        if loaded.isEmpty {
          self.hasMoreInboxMessages = false
          return
        }

        let existingIDs = Set(self.messages.map(\.id))
        let newMessages = loaded.filter { !existingIDs.contains($0.id) }
        guard !newMessages.isEmpty else {
          self.hasMoreInboxMessages = false
          return
        }
        self.messages.append(contentsOf: newMessages)
        self.updateInboxCount(try await store.inboxCount())
        self.tableView.reloadData()
      } catch {
        self.hasMoreInboxMessages = true
      }
    }
  }

  private func searchRemoteInbox(query: String) {
    remoteSearchTask?.cancel()
    remoteSearchTask = Task { [weak self, store, gmailSyncService] in
      do {
        _ = try await gmailSyncService.searchInbox(query: query, limit: 100)
        guard !Task.isCancelled, let self,
          self.currentQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
        else { return }

        let loaded = try await store.search(query, limit: 200)
        let selectedID = self.selectedMessageID
        self.messages = loaded
        self.updateInboxCount(try await store.inboxCount())
        self.tableView.reloadData()
        if let selectedID, let row = loaded.firstIndex(where: { $0.id == selectedID }) {
          if self.tableView.selectedRow != row {
            self.suppressNextReadMark = true
            self.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
          } else {
            self.renderSelection()
          }
        } else if !loaded.isEmpty {
          if self.tableView.selectedRow != 0 {
            self.suppressNextReadMark = true
            self.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
          } else {
            self.renderSelection()
          }
        } else {
          self.renderSelection()
        }
      } catch is CancellationError {
        return
      } catch {
        // Local search results remain available when remote search is offline.
      }
    }
  }

  private func loadThread(for message: MessageSummary) {
    threadLoadTask?.cancel()
    guard !message.threadRemoteID.isEmpty else { return }
    let expectedThreadID = message.threadRemoteID

    threadLoadTask = Task { [weak self, store, gmailSyncService] in
      do {
        let localMessages = try await store.threadMessages(
          accountID: message.accountID,
          remoteThreadID: expectedThreadID,
          limit: 50
        )
        guard !Task.isCancelled, let self, self.selectedThreadRemoteID == expectedThreadID else {
          return
        }
        if !localMessages.isEmpty {
          self.threadMessages = localMessages
          self.updateThreadNavigator()
        }
        guard message.accountProvider == "gmail" else { return }

        let hydratedMessages = try await gmailSyncService.hydrateThread(for: message, limit: 50)
        guard !Task.isCancelled, self.selectedThreadRemoteID == expectedThreadID else { return }
        self.threadMessages = hydratedMessages
        self.updateThreadNavigator()
        if let activeMessageID = self.activeMessageID,
          self.cachedBodyURLs[activeMessageID] == nil,
          self.threadMessages.first(where: { $0.id == activeMessageID })?.mailboxState == .archive
        {
          self.renderSelection()
        }
      } catch is CancellationError {
        return
      } catch {
        // Locally known thread members remain selectable while Gmail is offline.
      }
    }
  }

  private func updateThreadNavigator() {
    let showsThread = threadMessages.count > 1
    threadHeadingLabel.stringValue = "Thread · \(threadMessages.count)"
    threadHeadingLabel.setAccessibilityLabel(
      "Thread with \(threadMessages.count) \(threadMessages.count == 1 ? "message" : "messages")"
    )
    threadSplitItem?.isCollapsed = !showsThread

    isUpdatingThreadSelection = true
    threadTableView.reloadData()
    if let activeMessageID,
      let row = threadMessages.firstIndex(where: { $0.id == activeMessageID })
    {
      threadTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      threadTableView.scrollRowToVisible(row)
    } else {
      threadTableView.deselectAll(nil)
    }
    isUpdatingThreadSelection = false
  }

  private func updateInboxCount(_ count: Int) {
    inboxCount = count
    inboxCountLabel.stringValue = count.formatted()
    let noun = count == 1 ? "message" : "messages"
    inboxCountLabel.setAccessibilityLabel("\(count) \(noun) in Inbox")
  }

  private func performMove(_ destination: MailboxState) {
    guard let message = selectedMessage, message.mailboxState == .inbox else { return }

    let sidebarRow = messages.firstIndex(where: { $0.id == message.id })
    updateInboxCount(max(0, inboxCount - 1))
    archiveButton.isEnabled = false
    trashButton.isEnabled = false
    if let sidebarRow {
      messages.remove(at: sidebarRow)
      tableView.removeRows(at: IndexSet(integer: sidebarRow), withAnimation: [])
      if tableView.selectedRow == -1, !messages.isEmpty {
        let nextRow = min(sidebarRow, messages.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
      }
    }

    Task { [weak self, store] in
      do {
        switch destination {
        case .archive: try await store.archive(messageID: message.id)
        case .trash: try await store.moveToTrash(messageID: message.id)
        case .inbox: break
        }
        guard let self else { return }
        self.cachedBodyURLs.removeValue(forKey: message.id)
        if let transientURL = self.transientBodyURLs.removeValue(forKey: message.id) {
          try? FileManager.default.removeItem(at: transientURL)
        }
        _ = try? await self.gmailSyncService.flushPendingOperations()
        if self.selectedThreadRemoteID == message.threadRemoteID,
          !message.threadRemoteID.isEmpty
        {
          if let hydratedMessages = try? await self.gmailSyncService.hydrateThread(
            for: message,
            limit: 50
          ) {
            self.threadMessages = hydratedMessages
          } else {
            self.threadMessages = try await store.threadMessages(
              accountID: message.accountID,
              remoteThreadID: message.threadRemoteID,
              limit: 50
            )
          }
          self.updateThreadNavigator()
          self.renderSelection()
        }
      } catch {
        guard let self else { return }
        if let sidebarRow {
          self.messages.insert(message, at: min(sidebarRow, self.messages.count))
        }
        self.updateInboxCount(self.inboxCount + 1)
        self.tableView.reloadData()
        self.showError(error)
      }
    }
  }

  private func markSelectedReadIfNeeded() {
    guard let message = selectedMessage,
      message.mailboxState == .inbox,
      !message.isRead
    else { return }
    let messageID = message.id
    if let sidebarRow = messages.firstIndex(where: { $0.id == messageID }) {
      messages[sidebarRow].isRead = true
      tableView.reloadData(
        forRowIndexes: IndexSet(integer: sidebarRow),
        columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
      )
    }
    if let threadRow = threadMessages.firstIndex(where: { $0.id == messageID }) {
      threadMessages[threadRow].isRead = true
      threadTableView.reloadData(
        forRowIndexes: IndexSet(integer: threadRow),
        columnIndexes: IndexSet(integersIn: 0..<threadTableView.numberOfColumns)
      )
    }
    Task { [store, gmailSyncService] in
      try? await store.markRead(messageID: messageID)
      _ = try? await gmailSyncService.flushPendingOperations()
    }
  }

  private func renderSelection() {
    bodyLoadTask?.cancel()
    summaryTask?.cancel()
    let selectedID = activeMessageID
    cleanupTransientBodyCache(keeping: selectedID)
    guard let message = selectedMessage else {
      fromLabel.stringValue = ""
      toLabel.stringValue = ""
      ccLabel.stringValue = ""
      subjectLabel.stringValue = currentQuery.isEmpty ? "Inbox is clear" : "No results"
      metadataLabel.stringValue = ""
      setBodyText(
        currentQuery.isEmpty
          ? "New messages will appear here."
          : "Try a different search."
      )
      setSummaryText("Open an email to see its summary.")
      replyButton.isEnabled = false
      replyAllButton.isEnabled = false
      forwardButton.isEnabled = false
      archiveButton.isEnabled = false
      trashButton.isEnabled = false
      return
    }

    setAddressLine(fromLabel, title: "From", value: message.sender)
    setAddressLine(toLabel, title: "To", value: message.recipients)
    setAddressLine(ccLabel, title: "Cc", value: message.cc)
    subjectLabel.stringValue = message.subject.isEmpty ? "(No subject)" : message.subject
    metadataLabel.stringValue =
      "\(message.accountName) · \(rowDateFormatter.string(from: message.receivedDate))"
    loadCachedSummary(for: message)
    if let cachedURL = cachedBodyURLs[message.id] ?? message.bodyPath.map({ URL(fileURLWithPath: $0) }) {
      setBodyText("Loading message…")
      loadBodyText(from: cachedURL, for: message.id)
    } else if message.accountProvider == "gmail" && message.mailboxState != .trash {
      setBodyText("Loading message…")
      fetchBody(for: message)
    } else {
      let body = message.preview.isEmpty ? "Message body isn’t available." : message.preview
      setBodyText(body)
      if message.mailboxState == .inbox, !message.preview.isEmpty {
        startSummary(for: message, readableBody: message.preview)
      }
    }
    let canSend = message.accountProvider == "gmail"
    replyButton.isEnabled = canSend
    replyAllButton.isEnabled = canSend
    forwardButton.isEnabled = canSend
    archiveButton.isEnabled = message.mailboxState == .inbox
    trashButton.isEnabled = message.mailboxState == .inbox
  }

  private func presentComposer(_ mode: ComposeMode) {
    guard let message = selectedMessage, let window, window.attachedSheet == nil else {
      return
    }
    guard message.accountProvider == "gmail" else { return }

    let displayedBody = displayedBodyText
    let unavailableBodyStates: Set<String> = [
      "Loading message…",
      "Unable to load this message.",
      "Message body isn’t available.",
      "This message has no readable text.",
    ]
    let originalBody = unavailableBodyStates.contains(displayedBody)
      ? message.preview
      : displayedBody
    let draft = ReplyDraftBuilder.draft(
      mode: mode,
      message: message,
      originalBody: originalBody,
      dateText: quotedDateFormatter.string(from: message.receivedDate)
    )
    let composerTitle: String
    switch mode {
    case .reply: composerTitle = "Reply"
    case .replyAll: composerTitle = "Reply All"
    case .forward: composerTitle = "Forward"
    }

    let composer = ComposeWindowController(title: composerTitle, draft: draft) { draft in
      let to = EmailAddressParser.addresses(in: draft.to)
      let toInput = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
      let cc = EmailAddressParser.addresses(in: draft.cc)
      let ccInput = draft.cc.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (toInput.isEmpty || !to.isEmpty), (ccInput.isEmpty || !cc.isEmpty) else {
        throw OutgoingMessageError.invalidRecipient
      }

      let toSet = Set(to)
      let uniqueCC = cc.filter { !toSet.contains($0) }
      let configuration = try GoogleOAuthConfigurationLoader.load()
      let oauth = GoogleOAuthService(configuration: configuration)
      let smtp = GmailSMTPService(oauth: oauth)
      try await smtp.send(
        OutgoingMessage(
          sender: draft.sender,
          recipients: to,
          ccRecipients: uniqueCC,
          subject: draft.subject,
          plainTextBody: draft.body,
          inReplyTo: draft.inReplyTo
        ))
    }
    guard let composeWindow = composer.window else { return }
    composeWindowController = composer
    window.beginSheet(composeWindow) { [weak self] response in
      self?.composeWindowController = nil
      if response == .OK {
        self?.showMessage(title: "Message sent", message: "Your message was sent with Gmail.")
      }
    }
    composer.focusInitialField()
  }

  private func setAddressLine(_ label: NSTextField, title: String, value: String) {
    let displayedValue = value.isEmpty ? "—" : value
    let text = NSMutableAttributedString(
      string: "\(title): ",
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
      ])
    text.append(
      NSAttributedString(
        string: displayedValue,
        attributes: [
          .font: NSFont.systemFont(ofSize: 13, weight: .regular),
          .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    label.attributedStringValue = text
    label.toolTip = value.isEmpty ? nil : value
    label.setAccessibilityLabel(value.isEmpty ? "\(title): none" : "\(title): \(value)")
  }

  private func cleanupTransientBodyCache(keeping messageID: Int64?) {
    let staleMessageIDs = transientBodyURLs.keys.filter { $0 != messageID }
    for staleMessageID in staleMessageIDs {
      if let url = transientBodyURLs.removeValue(forKey: staleMessageID) {
        try? FileManager.default.removeItem(at: url)
      }
      cachedBodyURLs.removeValue(forKey: staleMessageID)
    }
  }

  private func fetchBody(for message: MessageSummary) {
    bodyLoadTask = Task { [weak self, gmailSyncService] in
      do {
        let url = try await gmailSyncService.fetchBody(for: message)
        guard !Task.isCancelled, let self else { return }
        self.cachedBodyURLs[message.id] = url
        if message.mailboxState != .inbox {
          self.transientBodyURLs[message.id] = url
        }
        self.loadBodyText(from: url, for: message.id)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, let self,
          self.selectedMessageID == message.id
        else { return }
        self.setBodyText("Unable to load this message.")
      }
    }
  }

  private func loadBodyText(from url: URL, for messageID: Int64) {
    bodyLoadTask = Task { [weak self] in
      do {
        let data = try await Task.detached(priority: .userInitiated) {
          try Data(contentsOf: url)
        }.value
        guard !Task.isCancelled, let self, self.selectedMessageID == messageID else { return }
        let readableBody: String
        if url.pathExtension.lowercased() == "html" {
          let html = String(decoding: data, as: UTF8.self)
          readableBody = MIMETextExtractor.readableHTMLText(html)
          self.setBodyHTML(html)
        } else {
          let text = String(decoding: data, as: UTF8.self)
          readableBody = MIMETextExtractor.readableText(text)
          self.setBodyText(text.isEmpty ? "This message has no readable text." : text)
        }
        if let message = self.threadMessages.first(where: { $0.id == messageID })
          ?? self.messages.first(where: { $0.id == messageID }),
          message.mailboxState == .inbox,
          !readableBody.isEmpty
        {
          self.startSummary(for: message, readableBody: readableBody)
        }
      } catch {
        guard !Task.isCancelled, let self, self.selectedMessageID == messageID else { return }
        self.setBodyText("Unable to load this message.")
      }
    }
  }

  private func loadCachedSummary(for message: MessageSummary) {
    guard message.mailboxState == .inbox else {
      setSummaryText("Summaries are available for Inbox messages.")
      return
    }
    setSummaryText("Loading summary…")
    summaryTask = Task { [weak self, store] in
      do {
        let cachedSummary = try await store.summary(for: message.id)
        guard !Task.isCancelled, let self, self.selectedMessageID == message.id else { return }
        if let cachedSummary, !cachedSummary.isEmpty {
          self.setSummaryText(cachedSummary)
          return
        }
        if try self.loadOpenRouterAPIKey() == nil {
          self.setSummaryText("Add an OpenRouter API key in Settings to summarize emails.")
        } else {
          self.setSummaryText("Summarizing…")
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, let self, self.selectedMessageID == message.id else { return }
        self.setSummaryText("Unable to load the saved summary.")
      }
    }
  }

  private func startSummary(for message: MessageSummary, readableBody: String) {
    summaryTask?.cancel()
    summaryTask = Task { [weak self, store, summaryService] in
      do {
        if let cachedSummary = try await store.summary(for: message.id), !cachedSummary.isEmpty {
          guard !Task.isCancelled, let self, self.selectedMessageID == message.id else { return }
          self.setSummaryText(cachedSummary)
          return
        }

        guard let self else { return }
        guard let apiKey = try self.loadOpenRouterAPIKey() else {
          if self.selectedMessageID == message.id {
            self.setSummaryText("Add an OpenRouter API key in Settings to summarize emails.")
          }
          return
        }
        if self.selectedMessageID == message.id {
          self.setSummaryText("Summarizing…")
        }

        let summary = try await summaryService.summarize(
          sender: message.sender,
          subject: message.subject,
          readableBody: readableBody,
          apiKey: apiKey
        )
        let saved = try await store.saveSummary(summary, for: message.id)
        guard saved, !Task.isCancelled, self.selectedMessageID == message.id else { return }
        self.setSummaryText(summary, announce: true)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, let self, self.selectedMessageID == message.id else { return }
        self.setSummaryText(
          "Unable to summarize this email. Check your OpenRouter API key and connection, then reopen it."
        )
      }
    }
  }

  private func loadOpenRouterAPIKey() throws -> String? {
    if !didLoadOpenRouterAPIKey {
      cachedOpenRouterAPIKey = try openRouterKeyStore.apiKey()
      didLoadOpenRouterAPIKey = true
    }
    return cachedOpenRouterAPIKey
  }

  private func setSummaryText(_ text: String, announce: Bool = false) {
    summaryLabel.stringValue = text
    summaryLabel.setAccessibilityLabel("Email summary: \(text)")
    if announce {
      NSAccessibility.post(element: summaryLabel, notification: .valueChanged)
    }
  }

  private var selectedMessage: MessageSummary? {
    guard let activeMessageID else { return nil }
    return threadMessages.first(where: { $0.id == activeMessageID })
      ?? messages.first(where: { $0.id == activeMessageID })
  }

  private var selectedMessageID: Int64? {
    activeMessageID
  }

  private func setBodyText(_ text: String) {
    bodyWebView.stopLoading()
    bodyWebView.isHidden = true
    bodyScrollView.isHidden = false
    let readableText = MIMETextExtractor.readableText(text)
    displayedBodyText = readableText
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 3
    paragraphStyle.paragraphSpacing = 0
    paragraphStyle.lineBreakMode = .byWordWrapping

    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 15, weight: .regular),
      .foregroundColor: NSColor.labelColor,
      .paragraphStyle: paragraphStyle,
    ]
    bodyView.textStorage?.setAttributedString(
      NSAttributedString(string: readableText, attributes: attributes)
    )
    bodyView.scrollToBeginningOfDocument(nil)
  }

  private func setBodyHTML(_ html: String) {
    displayedBodyText = MIMETextExtractor.readableHTMLText(html)
    bodyView.textStorage?.setAttributedString(NSAttributedString(string: ""))
    bodyScrollView.isHidden = true
    bodyWebView.isHidden = false
    bodyWebView.loadHTMLString(EmailHTMLDocument.prepare(html), baseURL: nil)
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard navigationAction.navigationType == .linkActivated,
      let url = navigationAction.request.url
    else {
      decisionHandler(.allow)
      return
    }

    if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
      NSWorkspace.shared.open(url)
    }
    decisionHandler(.cancel)
  }

  private func showMessage(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Done")
    alert.beginSheetModal(for: window ?? NSWindow())
  }

  private func showError(_ error: Error) {
    let alert = NSAlert(error: error)
    alert.beginSheetModal(for: window ?? NSWindow())
  }
}
