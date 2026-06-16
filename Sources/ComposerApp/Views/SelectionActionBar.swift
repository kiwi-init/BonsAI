import SwiftUI

/// The floating capsule that appears above a text selection.
struct SelectionActionBar: View {
  var isWorking: Bool
  var onRefine: (HeadlessEngine) -> Void
  var onCopy: () -> Void

  @State private var shown = false

  var body: some View {
    HStack(spacing: 2) {
      if isWorking {
        HStack(spacing: 7) {
          ProgressView().controlSize(.small).scaleEffect(0.7)
          Text("Refining\u{2026}").font(Theme.Typography.actionLabel)
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.Size.actionBarItemHeight)
        .foregroundStyle(Theme.Palette.body)
      } else {
        action("Claude", icon: HeadlessEngine.claude.systemImage) { onRefine(.claude) }
        action("Codex", icon: HeadlessEngine.codex.systemImage) { onRefine(.codex) }
        Divider().frame(height: 16).opacity(0.35)
        iconAction(icon: "doc.on.doc", help: "Copy self-contained text", run: onCopy)
      }
    }
    .padding(.horizontal, 5)
    .frame(height: Theme.Size.actionBarHeight)
    .background(VisualEffectBackground(material: Theme.Material.popover, blending: .withinWindow, forceDark: true))
    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.actionBar, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.actionBar, style: .continuous)
        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
    )
    .shadow(color: Theme.Shadow.bar.color, radius: Theme.Shadow.bar.radius, y: Theme.Shadow.bar.y)
    .scaleEffect(shown ? 1 : 0.94, anchor: .bottom)
    .opacity(shown ? 1 : 0)
    .onAppear { withAnimation(Theme.Motion.accessory) { shown = true } }
  }

  @ViewBuilder
  private func action(_ title: String, icon: String, run: @escaping () -> Void) -> some View {
    Button(action: run) {
      HStack(spacing: 6) {
        Image(systemName: icon).font(Theme.Typography.actionIcon)
        Text(title).font(Theme.Typography.actionLabel)
      }
      .padding(.horizontal, 10)
      .frame(height: Theme.Size.actionBarItemHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(HoverButtonStyle())
    .foregroundStyle(Theme.Palette.body)
  }

  @ViewBuilder
  private func iconAction(icon: String, help: String, run: @escaping () -> Void) -> some View {
    Button(action: run) {
      Image(systemName: icon)
        .font(Theme.Typography.actionIcon)
        .frame(width: 30, height: Theme.Size.actionBarItemHeight)
        .contentShape(Rectangle())
    }
    .buttonStyle(HoverButtonStyle())
    .foregroundStyle(Theme.Palette.body)
    .help(help)
  }
}

/// A soft hover wash for the bar's buttons.
struct HoverButtonStyle: ButtonStyle {
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Color.white.opacity(hovering || configuration.isPressed ? 0.12 : 0))
      )
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
  }
}
