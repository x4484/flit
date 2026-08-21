import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var mainWindowController: MainWindowController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    configureMainMenu()

    do {
      let store = try MailStore(path: databasePath())
      let windowController = MainWindowController(store: store)
      mainWindowController = windowController
      windowController.showWindow(nil)
      NSApp.activate(ignoringOtherApps: true)

      if ProcessInfo.processInfo.environment["FLIT_SEED_DEMO"] == "1" {
        Task {
          try? await store.seedDemoDataIfEmpty()
          windowController.reloadAfterSeed()
        }
      }
    } catch {
      NSAlert(error: error).runModal()
      NSApp.terminate(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  private func databasePath() -> String {
    if let override = ProcessInfo.processInfo.environment["FLIT_DATABASE_PATH"] {
      return override
    }

    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    return
      applicationSupport
      .appendingPathComponent("Flit", isDirectory: true)
      .appendingPathComponent("flit.sqlite3")
      .path
  }

  private func configureMainMenu() {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About Flit", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Flit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(
      withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenu.addItem(.separator())
    editMenu.addItem(
      withTitle: "Find", action: #selector(MainWindowController.focusSearch), keyEquivalent: "f")
    editMenuItem.submenu = editMenu

    let accountsMenuItem = NSMenuItem()
    mainMenu.addItem(accountsMenuItem)
    let accountsMenu = NSMenu(title: "Accounts")
    accountsMenu.addItem(
      withTitle: "Add Gmail Account…",
      action: #selector(MainWindowController.addGmailAccount),
      keyEquivalent: ""
    )
    accountsMenuItem.submenu = accountsMenu

    let messageMenuItem = NSMenuItem()
    mainMenu.addItem(messageMenuItem)
    let messageMenu = NSMenu(title: "Message")
    messageMenu.addItem(
      withTitle: "Archive", action: #selector(MainWindowController.archiveSelected),
      keyEquivalent: "e")
    let trash = NSMenuItem(
      title: "Move to Trash", action: #selector(MainWindowController.trashSelected),
      keyEquivalent: "\u{8}")
    trash.keyEquivalentModifierMask = [.command]
    messageMenu.addItem(trash)
    messageMenu.addItem(
      withTitle: "Refresh Inbox", action: #selector(MainWindowController.refreshInbox),
      keyEquivalent: "r")
    messageMenuItem.submenu = messageMenu

    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenuMenuSetup(windowMenu)
    windowMenuItem.submenu = windowMenu
    NSApp.windowsMenu = windowMenu

    NSApp.mainMenu = mainMenu
  }

  private func windowMenuMenuSetup(_ menu: NSMenu) {
    menu.addItem(
      withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: "")
  }
}
