import SwiftUI

/// SwiftUI content for the workspace's real auxiliary window. The main board never hosts this
/// hierarchy, so Settings and the agent remain visually and behaviorally separate from the canvas.
struct ComposerDockPanelContent: View {
  let kind: ComposerDockKind
  let agent: CanvasAgent?
  let width: CGFloat

  var body: some View {
    Group {
      switch kind {
      case .agent:
        if let agent {
          AgentDock(agent: agent, width: width, onClose: dismiss)
        }
      case .settings:
        SettingsOverlay(width: width, onClose: dismiss)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func dismiss() {
    NotificationCenter.default.post(name: .composerDismissDock, object: nil)
  }
}
