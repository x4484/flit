import AppKit

final class SidebarSurfaceView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
    dirtyRect.fill()
  }
}

final class MessageRowView: NSTableRowView {
  override func drawSelection(in dirtyRect: NSRect) {
    guard selectionHighlightStyle != .none else { return }

    let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let selectionColor =
      isDark
      ? NSColor.white.withAlphaComponent(0.09)
      : NSColor.black.withAlphaComponent(0.065)

    selectionColor.setFill()
    NSBezierPath(
      roundedRect: bounds.insetBy(dx: 8, dy: 4),
      xRadius: 8,
      yRadius: 8
    ).fill()
  }

  override var isEmphasized: Bool {
    get { false }
    set {}
  }
}
