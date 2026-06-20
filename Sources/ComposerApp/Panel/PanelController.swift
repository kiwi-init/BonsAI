import AppKit
import SwiftUI

/// Owns the single reusable floating panel: summon/dismiss, animation,
/// center-on-mouse, focus, and click-away dismissal.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
  private var panel: FloatingPanel?
  private var dock: FloatingPanel?
  private var dockKind: ComposerDockKind?
  private var dockAgent: CanvasAgent?
  var isVisible: Bool { panel?.isVisible ?? false }

  override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleDismiss), name: .composerDismiss, object: nil)
    NotificationCenter.default.addObserver(
      forName: .composerPresentDock, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated {
        guard let rawKind = note.userInfo?["kind"] as? String,
              let kind = ComposerDockKind(rawValue: rawKind) else { return }
        self?.presentDock(kind, agent: note.object as? CanvasAgent)
      }
    }
    NotificationCenter.default.addObserver(
      forName: .composerDismissDock, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.dismissDock() } }
  }

  @objc private func handleDismiss() { hide() }

  func toggle() { isVisible ? hide() : show() }

  func show() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    positionWorkspace()

    panel.alphaValue = 0
    panel.contentView?.wantsLayer = true
    panel.contentView?.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)

    // Normal app: bring BonsAI forward and focus the board.
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    panel.orderFrontRegardless()
    if let dockKind, let dock {
      installDockContent(kind: dockKind, in: dock)
      dock.orderFrontRegardless()
      dock.makeKeyAndOrderFront(nil)
    } else {
      focusEditor(in: panel)
    }
    // The active card's editor only exists once SwiftUI mounts it, so ask the canvas to enter
    // editing — the caret is ready to type the instant the panel appears (no double-click).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      NotificationCenter.default.post(name: .composerEnterEditing, object: nil)
    }

    if reduceMotion {
      panel.alphaValue = 1
      panel.contentView?.layer?.transform = CATransform3DIdentity
    } else {
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.26
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().alphaValue = 1
        panel.contentView?.layer?.transform = CATransform3DIdentity
      }
    }
  }

  func hide() {
    guard let panel, panel.isVisible else { return }
    dock?.orderOut(nil)
    guard !reduceMotion else {
      panel.orderOut(nil)
      panel.contentView?.layer?.transform = CATransform3DIdentity
      NSApp.deactivate()
      return
    }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = Theme.Motion.dismissDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
      panel.animator().alphaValue = 0
      panel.contentView?.layer?.transform = CATransform3DMakeScale(0.97, 0.97, 1)
    }, completionHandler: {
      MainActor.assumeIsolated {
        panel.orderOut(nil)
        panel.contentView?.layer?.transform = CATransform3DIdentity
        NSApp.deactivate()
      }
    })
  }

  // MARK: Build

  private func makePanel() -> FloatingPanel {
    let initialFrame = initialPanelFrame()
    let panel = FloatingPanel(contentRect: initialFrame)
    panel.delegate = self
    installContent(ComposerCanvas(), in: panel)
    return panel
  }

  private func makeDockPanel() -> FloatingPanel {
    let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1))
    panel.isAuxiliaryPanel = true
    panel.delegate = self
    return panel
  }

  /// A hosted SwiftUI view must not be allowed to infer an AppKit window size. Both workspace
  /// panels are explicitly framed from the display's usable area below.
  private func installContent<Content: View>(_ root: Content, in panel: FloatingPanel) {
    let host = NSHostingView(rootView: root)
    host.translatesAutoresizingMaskIntoConstraints = false
    host.sizingOptions = []

    let container = NonMovableView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.clear.cgColor
    container.layer?.cornerRadius = Theme.Radius.panel
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = false
    container.addSubview(host)
    NSLayoutConstraint.activate([
      host.topAnchor.constraint(equalTo: container.topAnchor),
      host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    panel.contentView = container
  }

  private func presentDock(_ kind: ComposerDockKind, agent: CanvasAgent?) {
    if let agent { dockAgent = agent }
    guard kind != .agent || dockAgent != nil else { return }
    dockKind = kind
    let dock = self.dock ?? makeDockPanel()
    self.dock = dock
    positionWorkspace()
    installDockContent(kind: kind, in: dock)

    guard panel?.isVisible == true else { return }
    dock.orderFrontRegardless()
    dock.makeKeyAndOrderFront(nil)
  }

  private func installDockContent(kind: ComposerDockKind, in panel: FloatingPanel) {
    let width = panel.frame.width
    installContent(
      ComposerDockPanelContent(kind: kind, agent: dockAgent, width: width),
      in: panel
    )
  }

  private func dismissDock() {
    guard let kind = dockKind else { return }
    dock?.orderOut(nil)
    dockKind = nil
    positionWorkspace()
    NotificationCenter.default.post(
      name: .composerDockDismissed,
      object: nil,
      userInfo: ["kind": kind.rawValue]
    )
  }

  /// `show()` immediately repositions this panel on the display beneath the pointer. Starting it
  /// at the same screen-relative size prevents a one-frame fixed-size layout before that happens.
  private func initialPanelFrame() -> NSRect {
    guard let visible = NSScreen.main?.visibleFrame else {
      return NSRect(x: 0, y: 0, width: 1, height: 1)
    }
    return NSRect(
      x: visible.midX - visible.width * Theme.Size.screenFraction / 2,
      y: visible.midY - visible.height * Theme.Size.screenFraction / 2,
      width: visible.width * Theme.Size.screenFraction,
      height: visible.height * Theme.Size.screenFraction
    )
  }

  // MARK: Placement

  private func positionWorkspace() {
    guard let panel else { return }
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
      ?? NSScreen.main ?? NSScreen.screens.first
    guard let visible = screen?.visibleFrame else { panel.center(); return }
    let workspaceWidth = min((visible.width * Theme.Size.screenFraction).rounded(), visible.width)
    let workspaceHeight = min((visible.height * Theme.Size.screenFraction).rounded(), visible.height)
    let x = max(visible.minX, min((visible.midX - workspaceWidth / 2).rounded(), visible.maxX - workspaceWidth))
    let y = max(visible.minY, min((visible.midY - workspaceHeight / 2).rounded(), visible.maxY - workspaceHeight))
    // The top toolbar is visually centered on the entire composed workspace. Its SwiftUI host is
    // the left board window, so this remains a coordinate relative to that left edge.
    WorkspaceLayout.shared.toolbarCenterX = workspaceWidth / 2

    guard dockKind != nil else {
      panel.setFrame(NSRect(x: x, y: y, width: workspaceWidth, height: workspaceHeight), display: true)
      return
    }

    let dockWidth = Theme.Size.dockWidth(in: workspaceWidth)
    let gap = Theme.Size.dockMargin(in: workspaceWidth)
    let boardWidth = max(workspaceWidth - dockWidth - gap, 1)
    // The board's SwiftUI card begins below its floating toolbar and remains flush with the
    // workspace bottom. Its sibling dock keeps that same bottom edge and loses the same top slice.
    let cardTopInset = Theme.Size.toolbarGutter(in: workspaceHeight)
    let dockHeight = max(workspaceHeight - cardTopInset, 1)
    panel.setFrame(NSRect(x: x, y: y, width: boardWidth, height: workspaceHeight), display: true)
    dock?.setFrame(
      NSRect(
        x: x + boardWidth + gap,
        y: y,
        width: dockWidth,
        height: dockHeight
      ),
      display: true
    )
  }

  // MARK: Focus the text view so typing works the instant the panel appears.

  private func focusEditor(in panel: NSPanel) {
    guard let content = panel.contentView, let textView = firstTextView(in: content) else { return }
    panel.makeFirstResponder(textView)
  }

  private func firstTextView(in view: NSView) -> NSTextView? {
    if let textView = view as? NSTextView { return textView }
    for sub in view.subviews {
      if let found = firstTextView(in: sub) { return found }
    }
    return nil
  }

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }
}

/// Host container that never lets a click-drag move the window — the canvas owns all dragging.
private final class NonMovableView: NSView {
  override var mouseDownCanMoveWindow: Bool { false }
}
