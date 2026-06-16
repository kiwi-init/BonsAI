import AppKit

// MARK: - Mention catalog

/// One entry in the `@` autocomplete. `id` is the raw token that gets serialized
/// back into the self-contained text (e.g. "@context7").
struct MentionItem: Identifiable, Hashable {
  let id: String        // raw token + serialized form, e.g. "@context7"
  let title: String     // lowercase match key, e.g. "context7"
  let label: String     // pretty chip label, e.g. "Context7"
  let subtitle: String  // "Live library docs"
  let symbol: String    // SF Symbol
}

enum MentionCatalog {
  static let all: [MentionItem] = [
    .init(id: "@context7", title: "context7", label: "Context7", subtitle: "Live library docs", symbol: "books.vertical"),
    .init(id: "@github", title: "github", label: "GitHub", subtitle: "Issue or PR URL", symbol: "chevron.left.forwardslash.chevron.right"),
    .init(id: "@build-macos-apps", title: "build-macos-apps", label: "build-macos-apps", subtitle: "Native macOS skill", symbol: "macwindow"),
    .init(id: "@build-ios-apps", title: "build-ios-apps", label: "build-ios-apps", subtitle: "SwiftUI iOS skill", symbol: "iphone"),
    .init(id: "@frontend-design", title: "frontend-design", label: "frontend-design", subtitle: "Polished web UI skill", symbol: "paintbrush"),
    .init(id: "@clipboard", title: "clipboard", label: "Clipboard", subtitle: "Paste current clipboard", symbol: "doc.on.clipboard"),
  ]

  static func filtered(_ query: String) -> [MentionItem] {
    guard !query.isEmpty else { return all }
    let q = query.lowercased()
    let prefix = all.filter { $0.title.lowercased().hasPrefix(q) }
    let contains = all.filter { !$0.title.lowercased().hasPrefix(q) && $0.title.lowercased().contains(q) }
    return prefix + contains
  }
}

// MARK: - Token attribute

extension NSAttributedString.Key {
  static let mentionToken = NSAttributedString.Key("composer.mentionToken")
  /// Tags an inline image-attachment run with the on-disk PNG path for serialization.
  static let imageAttachmentPath = NSAttributedString.Key("composer.imageAttachmentPath")
}

enum MentionToken {
  /// A styled, single-run token carrying its raw id so it round-trips to plain text.
  static func attributed(for item: MentionItem, font: NSFont) -> NSAttributedString {
    NSAttributedString(string: item.label, attributes: [
      .mentionToken: item.id,
      .font: font,
      .foregroundColor: NSColor.controlAccentColor,
      .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.14),
    ])
  }
}

extension NSAttributedString {
  /// Self-contained plain text:
  /// - mention chips/tokens collapse to their raw id ("@github"), once per chip;
  /// - inline image attachments collapse to "[image: <file>]";
  /// - everything else is literal text.
  ///
  /// A chip is multiple style runs (icon attachment + thin space + colored name) that
  /// share one `.mentionToken` value, so we walk by `longestEffectiveRange` per key to
  /// emit each chip exactly once.
  var composerPlainText: String {
    var out = ""
    let ns = string as NSString
    var index = 0
    while index < length {
      var range = NSRange()
      let remaining = NSRange(location: index, length: length - index)

      if let id = attribute(.mentionToken, at: index, longestEffectiveRange: &range, in: remaining) as? String {
        out += id
        index = range.location + range.length
      } else if let path = attribute(.imageAttachmentPath, at: index, longestEffectiveRange: &range, in: remaining) as? String {
        out += "[image: \((path as NSString).lastPathComponent)]"
        index = range.location + range.length
      } else {
        out += ns.substring(with: NSRange(location: index, length: 1))
        index += 1
      }
    }
    return out
  }
}
