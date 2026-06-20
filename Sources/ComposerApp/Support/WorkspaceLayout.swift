import SwiftUI

/// Transient geometry shared between the AppKit workspace controller and the SwiftUI board.
/// The board's window becomes narrower when a companion panel opens, but the top toolbar belongs
/// to the composed workspace, so its visual center must come from the controller that owns both.
@MainActor
final class WorkspaceLayout: ObservableObject {
  static let shared = WorkspaceLayout()

  @Published var toolbarCenterX: CGFloat = 0

  private init() {}
}
