import AppKit

/// Expands the note's `@mentions` into a self-contained block of text ready to paste into
/// a coding harness. The note body stays first; resolved context is appended as labelled
/// sections. Resolved app chips are fetched live and inlined; unresolved ones fall back
/// to connector-specific instructions.
enum SelfContainedRenderer {
  struct Result {
    let text: String
    /// Connector-specific failures, already phrased for display to the person who clicked Copy.
    let failures: [String]
  }

  /// `runShell` gates the copy-time shell expansion: `$(command)` substitution and `name=(value)`
  /// variables only run when the user has opted in (and confirmed the run); otherwise their literal
  /// source is kept and a single note explains how to enable it.
  ///
  /// App chips/skills/clipboard are scanned from the *expanded* body, so a `$file` that resolves to
  /// an `@finder` chip still gets its section — and a consumed, never-referenced definition doesn't.
  /// `commandDirectory` is the working directory for `$(…)` — the board's grounding folder when set,
  /// otherwise the user's home. `perCommandTimeout` caps each command so a hung one can't freeze the
  /// copy.
  static let perCommandTimeout: TimeInterval = 20

  static func render(_ plain: String, runShell: Bool = false, commandDirectory: String = NSHomeDirectory()) async -> Result {
    let clipboard = await MainActor.run { NSPasteboard.general.string(forType: .string)?.trimmed }

    var body = plain.trimmed
    var shellFailures: [String] = []
    let shellCommands = ShellTemplate.commands(in: plain)
    let hasVariables = !ShellTemplate.definedNames(in: plain).isEmpty
    // Variable substitution is pure text and always runs; only `$(…)` command execution is gated.
    if !shellCommands.isEmpty || hasVariables {
      let expansion = await ShellTemplate.expand(plain, runCommands: runShell) { command in
        try? await Shell.run(["bash", "-c", command], directory: commandDirectory, timeout: perCommandTimeout)
      }
      body = expansion.text.trimmed
      shellFailures = expansion.failures
      if !shellCommands.isEmpty, !runShell {
        let count = shellCommands.count
        shellFailures.append("Shell resolution is off — turn on “Resolve shell at copy time” in Settings ▸ Connectors to run \(count) command\(count == 1 ? "" : "s") at copy time.")
      }
    }

    var sections: [String] = []
    if !body.isEmpty { sections.append(body) }

    let skills = MentionCatalog.all
      .filter { $0.kind == .skill && body.contains($0.id) }
      .map(\.id).sorted()
    if !skills.isEmpty {
      sections.append("## Skills To Use\n" + skills.map { "- \($0.dropFirst())" }.joined(separator: "\n"))
    }

    let appSections = await appSections(for: AppToken.scan(body))
    sections.append(contentsOf: appSections.sections)

    if body.contains("@clipboard"), let clip = clipboard, !clip.isEmpty {
      sections.append("## Clipboard\n\(clip)")
    }

    return Result(text: sections.joined(separator: "\n\n") + "\n", failures: shellFailures + appSections.failures)
  }

  // MARK: App sections (fetched concurrently, emitted in note order)

  private static func appSections(for tokens: [(token: String, appID: String, selection: AppSelection?)]) async -> (sections: [String], failures: [String]) {
    guard !tokens.isEmpty else { return ([], []) }
    return await withTaskGroup(of: (Int, String?, String?).self) { group in
      for (index, entry) in tokens.enumerated() {
        group.addTask {
          guard let connector = AppConnectorRegistry.connector(for: entry.appID) else {
            return (index, nil, "\(entry.appID): Composer does not have a connector for this token.")
          }
          do {
            return (index, try await connector.render(selection: entry.selection), nil)
          } catch {
            let action = "Resolving \(entry.appID)"
            return (index, nil, "\(entry.appID): \(UserFacingError.message(for: error, while: action))")
          }
        }
      }
      var collected: [(Int, String?, String?)] = []
      for await result in group { collected.append(result) }
      let ordered = collected.sorted { $0.0 < $1.0 }
      return (
        ordered.compactMap(\.1).filter { !$0.isEmpty },
        ordered.compactMap(\.2)
      )
    }
  }
}
