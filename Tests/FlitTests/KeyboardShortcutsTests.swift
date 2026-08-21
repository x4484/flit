import AppKit
import Testing

@testable import Flit

struct KeyboardShortcutsTests {
  @Test
  func settingsDisplaysTheConfiguredMessageShortcuts() {
    #expect(AppKeyboardShortcuts.archiveKeyEquivalent == "d")
    #expect(AppKeyboardShortcuts.trashKeyEquivalent == "\u{8}")
    #expect(AppKeyboardShortcuts.replyKeyEquivalent == "r")
    #expect(AppKeyboardShortcuts.forwardKeyEquivalent == "f")
    #expect(
      AppKeyboardShortcuts.displayed.map(\.action) == [
        "Archive", "Move to Trash", "Reply", "Forward", "Send message",
      ])
  }

  @Test @MainActor
  func settingsContainsAccountsAndKeyboardTabs() throws {
    let account = MailAccount(
      id: 1,
      name: "Gmail",
      email: "me@example.com",
      provider: "gmail",
      syncCursor: nil
    )
    let controller = SettingsWindowController(accounts: [account])
    let tabs = try #require(controller.window?.contentViewController as? NSTabViewController)

    #expect(tabs.tabViewItems.map(\.label) == ["Accounts", "AI Summaries", "Keyboard Shortcuts"])
  }
}
