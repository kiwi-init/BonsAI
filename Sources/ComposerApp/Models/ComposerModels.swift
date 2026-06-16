import Foundation

/// The headless CLI used to refine selected text.
enum HeadlessEngine: String, Codable, CaseIterable, Identifiable {
  case claude
  case codex

  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var systemImage: String {
    switch self {
    case .claude: "sparkles"
    case .codex: "wand.and.stars"
    }
  }
}
