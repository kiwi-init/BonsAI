import SwiftUI

struct SettingsView: View {
  private let shortcuts: [(String, String)] = [
    ("Summon / hide Composer", "⌃⌥Space"),
    ("Refine selection", "select text → Claude / Codex"),
    ("Insert a connector", "type @"),
    ("Copy self-contained text", "⇧⌘C"),
    ("Dismiss", "Esc"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Composer").font(.system(size: 15, weight: .semibold))
        Text("A menu-bar scratchpad for drafting prompts.")
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 9) {
        Text("SHORTCUTS").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
        ForEach(shortcuts, id: \.0) { item in
          HStack {
            Text(item.0).font(.system(size: 12))
            Spacer(minLength: 16)
            Text(item.1)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 7).padding(.vertical, 2)
              .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
          }
        }
      }
      .padding(14)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))

      Text("Connectors: type @ for context7, github, skills, and clipboard. They expand into self-contained context when you copy.")
        .font(.system(size: 11)).foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(22)
    .frame(width: 400)
  }
}
