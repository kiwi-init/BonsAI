import Foundation

/// Apple Notes connector for the `@notes` chip. Notes.app ships no public framework, so this drives
/// it over Apple Events (JXA) through `osascript` — the same shell-out path the Browser and Finder
/// connectors use. Shelling out keeps it working under the release build's hardened runtime without
/// an apple-events entitlement (the Apple-Event sender is the Apple-signed `osascript` child, not the
/// app), and the first use trips the one-time Automation permission prompt for Notes.
///
/// Search matches note *titles* only — scanning every note's body would mean reading all their HTML,
/// which is slow on large accounts. Render re-reads the selected note's body at copy time and
/// flattens its HTML to plain text so the compiled prompt carries the note's content.
struct NotesService {
  private static let maxRows = 12
  private let textCap = 10_000

  func search(_ query: String) async throws -> [AppSearchResult] {
    let result = try await Shell.run(["osascript", "-l", "JavaScript", "-e", Self.searchScript(query: query)])
    guard result.status == 0 else { throw notesError(result) }
    let text = result.stdout.trimmed
    guard !text.isEmpty else { return [] }
    let rows = (try? JSONDecoder().decode([SearchRow].self, from: Data(text.utf8))) ?? []
    return rows
      .filter { !$0.id.isEmpty }
      .sorted { ($0.modified ?? "") > ($1.modified ?? "") }   // ISO-8601/UTC → lexicographic = chronological
      .prefix(Self.maxRows)
      .map { row in
        AppSearchResult(
          id: row.id,
          title: row.name.isEmpty ? "Untitled note" : row.name,
          subtitle: Self.subtitle(folder: row.folder, modified: row.modified),
          selection: .notes(NotesReference(id: row.id, title: row.name)))
      }
  }

  func render(_ reference: NotesReference) async throws -> String {
    let result = try await Shell.run(["osascript", "-l", "JavaScript", "-e", Self.renderScript(id: reference.id)])
    guard result.status == 0 else { throw notesError(result) }
    let fallbackTitle = reference.title.isEmpty ? "note" : reference.title
    let text = result.stdout.trimmed
    guard !text.isEmpty, let note = try? JSONDecoder().decode(RenderRow.self, from: Data(text.utf8)) else {
      return "## Apple Notes — \(fallbackTitle)\n_(could not read this note — it may have been deleted or moved.)_"
    }
    if note.error == "not-found" {
      return "## Apple Notes — \(fallbackTitle)\n_(this note is no longer available — it may have been deleted or renamed.)_"
    }

    let title = (note.name?.isEmpty == false) ? note.name! : fallbackTitle
    var lines = ["## Apple Notes — \(title)"]
    if let folder = note.folder, !folder.isEmpty { lines.append("Folder: \(folder)") }
    if let modified = note.modified, !modified.isEmpty { lines.append("Modified: \(String(modified.prefix(10)))") }
    lines.append("")
    let body = Self.htmlToPlainText(note.body ?? "").trimmed
    lines.append(body.isEmpty ? "_(this note has no text.)_" : truncate(body))
    return lines.joined(separator: "\n")
  }

  // MARK: - Decoding

  private struct SearchRow: Decodable { let id: String; let name: String; let folder: String?; let modified: String? }
  private struct RenderRow: Decodable { let name: String?; let body: String?; let folder: String?; let modified: String?; let error: String? }

  private static func subtitle(folder: String?, modified: String?) -> String {
    var bits = ["Apple Notes"]
    if let folder, !folder.isEmpty { bits.append(folder) }
    if let modified, !modified.isEmpty { bits.append(String(modified.prefix(10))) }
    return bits.joined(separator: " · ")
  }

  private func truncate(_ text: String) -> String {
    guard text.count > textCap else { return text }
    return String(text.prefix(textCap)) + "\n\n…(truncated)"
  }

  private func notesError(_ result: Shell.Result) -> AppSearchError {
    let text = result.diagnostic
    if text.contains("-1743") || text.localizedCaseInsensitiveContains("not authorized") {
      return .message("Allow BonsAI to control Notes in System Settings → Privacy & Security → Automation.")
    }
    if text.contains("-1728") {   // AppleScript "can't get" — the note/object no longer exists
      return .message("That note is no longer available in Apple Notes.")
    }
    if text.localizedCaseInsensitiveContains("execution error") {
      return .message(String(text.prefix(160)))
    }
    return .message(UserFacingError.commandFailure(command: "Reading Apple Notes", result: result))
  }

  // MARK: - JXA

  /// Bulk-reads every note's title/id/modification date in three Apple Events (far cheaper than
  /// per-note round trips), filters by title substring, then sorts + caps — and only *then* looks up
  /// each surviving note's folder name, so the folder round trips number in the handful, not the
  /// thousands. The folder travels into the result subtitle so a note sitting in "Recently Deleted"
  /// reads as such (the trash folder's name is localized, so there's no locale-proof way to exclude
  /// it — showing it is the honest option). User text is embedded as a JSON string literal — see
  /// `jsString` — so a note query can't break out of the script.
  private static func searchScript(query: String) -> String {
    """
    function run() {
      const query = \(jsString(query));
      const Notes = Application('Notes');
      const q = query.toLowerCase();
      let names = [], ids = [], mods = [];
      try { names = Notes.notes.name(); } catch (e) { names = []; }
      try { ids = Notes.notes.id(); } catch (e) { ids = []; }
      try { mods = Notes.notes.modificationDate(); } catch (e) { mods = []; }
      const hits = [];
      for (let i = 0; i < names.length; i++) {
        const name = names[i] || '';
        if (q === '' || name.toLowerCase().indexOf(q) !== -1) {
          let modified = '';
          try { if (mods[i]) { modified = mods[i].toISOString(); } } catch (e) {}
          hits.push({ i: i, id: String(ids[i] || ''), name: name, modified: modified });
        }
      }
      hits.sort(function(a, b) { return a.modified < b.modified ? 1 : (a.modified > b.modified ? -1 : 0); });
      const top = hits.slice(0, \(maxRows));
      let containers = [];
      try { containers = Notes.notes.container(); } catch (e) { containers = []; }
      const out = top.map(function(h) {
        let folder = '';
        try { if (containers[h.i]) { folder = containers[h.i].name() || ''; } } catch (e) {}
        return { id: h.id, name: h.name, folder: folder, modified: h.modified };
      });
      return JSON.stringify(out);
    }
    """
  }

  /// Fetches one note's title/body/folder by id, falling back to a linear id scan if `byId` can't
  /// resolve the specifier. The id is embedded as a JSON string literal (injection-safe).
  private static func renderScript(id: String) -> String {
    """
    function run() {
      const noteId = \(jsString(id));
      const Notes = Application('Notes');
      let note = null;
      try { note = Notes.notes.byId(noteId); note.name(); } catch (e) { note = null; }
      if (note === null) {
        try {
          const ids = Notes.notes.id();
          let idx = -1;
          for (let i = 0; i < ids.length; i++) { if (String(ids[i]) === noteId) { idx = i; break; } }
          if (idx !== -1) { note = Notes.notes[idx]; }
        } catch (e) { note = null; }
      }
      if (note === null) { return JSON.stringify({ error: 'not-found' }); }
      let name = '', body = '', folder = '', modified = '';
      try { name = note.name() || ''; } catch (e) {}
      try { body = note.body() || ''; } catch (e) {}
      try { folder = note.container().name() || ''; } catch (e) {}
      try { const d = note.modificationDate(); if (d) { modified = d.toISOString(); } } catch (e) {}
      return JSON.stringify({ name: name, body: body, folder: folder, modified: modified });
    }
    """
  }

  /// A JSON string literal is also a valid JS string literal, so encoding user text this way embeds
  /// it into the JXA source with no quote/newline able to escape the string (JSONEncoder escapes
  /// `"`, `\`, and control characters). Encoding a one-element array sidesteps top-level-fragment
  /// support: `["…"]` → drop the brackets → `"…"`.
  private static func jsString(_ value: String) -> String {
    guard let data = try? JSONEncoder().encode([value]),
          let json = String(data: data, encoding: .utf8), json.count >= 2 else { return "\"\"" }
    return String(json.dropFirst().dropLast())
  }

  // MARK: - HTML → text

  /// Flattens a Notes HTML body to readable plain text without WebKit (`NSAttributedString(html:)`
  /// forces main-thread work and is far heavier than this needs). Line-breaking and list tags become
  /// newlines/bullets, every other tag is dropped, and the common entities are decoded.
  static func htmlToPlainText(_ html: String) -> String {
    guard !html.isEmpty else { return "" }
    var s = html
    let newlineTags = ["<br>", "<br/>", "<br />", "</div>", "</p>", "</h1>", "</h2>", "</h3>",
                       "</h4>", "</h5>", "</h6>", "</ul>", "</ol>", "</tr>", "</blockquote>"]
    for tag in newlineTags {
      s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
    }
    s = s.replacingOccurrences(of: "<li>", with: "\n- ", options: .caseInsensitive)
    s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    s = decodeHTMLEntities(s)

    // Trim each line and collapse runs of blank lines to a single separator.
    var out: [String] = []
    var sawBlank = false
    for rawLine in s.components(separatedBy: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty {
        if !sawBlank, !out.isEmpty { out.append("") }
        sawBlank = true
      } else {
        out.append(line)
        sawBlank = false
      }
    }
    return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func decodeHTMLEntities(_ text: String) -> String {
    var s = text
    let named: [(String, String)] = [
      ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
      ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&hellip;", "…"),
      ("&mdash;", "—"), ("&ndash;", "–"),
      ("&rsquo;", "\u{2019}"), ("&lsquo;", "\u{2018}"),
      ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}"),
    ]
    for (entity, value) in named { s = s.replacingOccurrences(of: entity, with: value) }
    s = decodeNumericEntities(s)
    s = s.replacingOccurrences(of: "&amp;", with: "&")   // last: so "&amp;lt;" decodes to "&lt;", not "<"
    return s
  }

  private static func decodeNumericEntities(_ text: String) -> String {
    guard text.contains("&#"), let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else { return text }
    let ns = text as NSString
    var result = ""
    var cursor = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
      let isHex = ns.substring(with: match.range(at: 1)).lowercased() == "x"
      let digits = ns.substring(with: match.range(at: 2))
      if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
        result += String(scalar)
      } else {
        result += ns.substring(with: match.range)
      }
      cursor = match.range.location + match.range.length
    }
    result += ns.substring(from: cursor)
    return result
  }
}
