import SwiftUI

/// The editing surface for a placed widget card: wraps the widget's own (chrome-less) config form
/// in the standard glass card, and commits the edited config back to the board when the user is
/// done (Enter / click Done / Escape). Generic — it renders any widget's form through the erased
/// registry entry, holding the config as opaque `Data` and letting the box bridge it to the typed
/// binding. Commit-on-done (not on every keystroke) so a repo half-typed doesn't trigger a fetch.
struct WidgetConfigEditor: View {
  let cardID: UUID
  let instance: WidgetInstance
  let board: BoardViewModel

  @State private var configData: Data

  init(cardID: UUID, instance: WidgetInstance, board: BoardViewModel) {
    self.cardID = cardID
    self.instance = instance
    self.board = board
    _configData = State(initialValue: instance.config)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let def = WidgetRegistry.widget(id: instance.typeID) {
        def.configForm($configData)
      } else {
        Text("Unknown widget").font(.callout).foregroundStyle(Color.white.opacity(0.7))
      }
      HStack {
        Spacer()
        Button("Done", action: commit)
          .buttonStyle(.plain)
          .font(.caption.weight(.semibold))
          .foregroundStyle(Color.accentColor)
      }
    }
    .padding(14)
    .frame(width: 260)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color(white: 0.11))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)))
    .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    .onExitCommand(perform: commit)
  }

  private func commit() {
    board.setWidgetConfig(cardID, configData)   // no-ops if unchanged; refreshes if changed
    board.endEditing(cardID)
  }
}
