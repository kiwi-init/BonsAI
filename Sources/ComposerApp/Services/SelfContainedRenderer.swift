import AppKit

/// Expands the note's `@mentions` into a self-contained block of text ready to
/// paste into a coding harness. The note body stays first; resolved context is
/// appended as labelled sections.
enum SelfContainedRenderer {
  private static let skillMentions: Set<String> = [
    "@build-macos-apps", "@build-ios-apps", "@frontend-design",
  ]

  static func render(_ plain: String) -> String {
    let mentions = detected(in: plain)
    var sections: [String] = []
    let body = plain.trimmed
    if !body.isEmpty { sections.append(body) }

    let skills = mentions.filter { skillMentions.contains($0) }.sorted()
    if !skills.isEmpty {
      sections.append("## Skills To Use\n" + skills.map { "- \($0.dropFirst())" }.joined(separator: "\n"))
    }
    if mentions.contains("@context7") {
      sections.append("""
      ## Context7
      Use Context7 to fetch current, version-accurate library and framework documentation for anything referenced above.
      """)
    }
    if mentions.contains("@github") {
      sections.append("""
      ## GitHub
      Fetch and summarize the referenced GitHub issue or PR (URL above): state, body, key comments, constraints, and acceptance criteria.
      """)
    }
    if mentions.contains("@clipboard"),
       let clip = NSPasteboard.general.string(forType: .string)?.trimmed, !clip.isEmpty {
      sections.append("## Clipboard\n\(clip)")
    }

    return sections.joined(separator: "\n\n") + "\n"
  }

  private static func detected(in text: String) -> Set<String> {
    var found: Set<String> = []
    for item in MentionCatalog.all where text.contains(item.id) {
      found.insert(item.id)
    }
    return found
  }
}
