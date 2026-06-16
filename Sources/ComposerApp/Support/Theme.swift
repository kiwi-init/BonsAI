import SwiftUI
import AppKit

// MARK: - Design tokens

/// One source of truth for everything spatial, material, and temporal.
/// The app is a single translucent card, so the token set is deliberately small.
enum Theme {
  enum Radius {
    static let panel: CGFloat = 20
    static let actionBar: CGFloat = 10
    static let menu: CGFloat = 10
    static let row: CGFloat = 7
  }

  enum Material {
    static let hud: NSVisualEffectView.Material = .hudWindow      // canvas backdrop
    static let popover: NSVisualEffectView.Material = .popover    // selection action bar
    static let menu: NSVisualEffectView.Material = .menu          // @-mention list
  }

  enum Size {
    static let widthFraction: CGFloat = 0.52
    static let heightFraction: CGFloat = 0.62
    static let minWidth: CGFloat = 560, maxWidth: CGFloat = 820
    static let minHeight: CGFloat = 420, maxHeight: CGFloat = 680
    static let opticalLift: CGFloat = 0.06   // nudge the panel up 6% of its height

    static let actionBarHeight: CGFloat = 34
    static let actionBarItemHeight: CGFloat = 28
    static let menuWidth: CGFloat = 300
    static let menuRowHeight: CGFloat = 32
    static let menuMaxVisibleRows: CGFloat = 6
  }

  enum Inset {
    static let horizontal: CGFloat = 60
    static let titleTop: CGFloat = 16
    static let editorTop: CGFloat = 22
    static let countBottom: CGFloat = 14
    static let textContainer = NSSize(width: 4, height: 8)
  }

  enum Typography {
    static let body = NSFont.systemFont(ofSize: 17, weight: .regular)
    static let bodyLineSpacing: CGFloat = 7
    static let title = SwiftUI.Font.system(size: 12, weight: .regular)
    static let count = SwiftUI.Font.system(size: 11, weight: .regular)
    static let menuName = SwiftUI.Font.system(size: 13, weight: .regular)
    static let menuDesc = SwiftUI.Font.system(size: 11, weight: .regular)
    static let actionLabel = SwiftUI.Font.system(size: 12, weight: .medium)
    static let actionIcon = SwiftUI.Font.system(size: 12, weight: .medium)
  }

  /// All text is driven from semantic colors so alpha resolves correctly on vibrancy.
  enum Palette {
    static let body = Color(nsColor: .labelColor)
    static let title = Color(nsColor: .tertiaryLabelColor)
    static let count = Color(nsColor: .quaternaryLabelColor)
    static let placeholder = Color(nsColor: .placeholderTextColor)
    static let menuDesc = Color(nsColor: .secondaryLabelColor)
    static let accentFill = Color.accentColor.opacity(0.20)

    static func scrim(_ scheme: ColorScheme) -> Color {
      scheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.07)
    }
    static func hairline(_ scheme: ColorScheme) -> Color {
      scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
  }

  enum Shadow {
    static let panel = (color: Color.black.opacity(0.28), radius: 30.0, y: 12.0)
    static let bar = (color: Color.black.opacity(0.25), radius: 14.0, y: 6.0)
    static let menu = (color: Color.black.opacity(0.25), radius: 16.0, y: 8.0)
  }

  enum Motion {
    static let accessory = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let dismissDuration = 0.16
    static let selectionDebounce: TimeInterval = 0.10
  }
}

// MARK: - Vibrancy

/// Native `NSVisualEffectView` so the panel picks up real desktop translucency.
struct VisualEffectBackground: NSViewRepresentable {
  var material: NSVisualEffectView.Material = .underWindowBackground
  var blending: NSVisualEffectView.BlendingMode = .behindWindow
  var emphasized: Bool = false
  var state: NSVisualEffectView.State = .followsWindowActiveState
  var forceDark: Bool = false

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    apply(to: view)
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) { apply(to: view) }

  private func apply(to view: NSVisualEffectView) {
    view.material = material
    view.blendingMode = blending
    view.state = state
    view.isEmphasized = emphasized
    view.appearance = forceDark ? NSAppearance(named: .darkAqua) : nil
  }
}

// MARK: - Panel backdrop

/// The frosted, rounded, scrimmed card the whole canvas sits on.
struct ComposerPanelBackground: View {
  @Environment(\.colorScheme) private var scheme
  var radius: CGFloat = Theme.Radius.panel

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    ZStack {
      VisualEffectBackground(
        material: Theme.Material.hud,
        blending: .behindWindow,
        state: .active,
        forceDark: true
      )
      Theme.Palette.scrim(scheme)
    }
    .clipShape(shape)
    .overlay(shape.strokeBorder(Theme.Palette.hairline(scheme), lineWidth: 1))
    .ignoresSafeArea()
  }
}
