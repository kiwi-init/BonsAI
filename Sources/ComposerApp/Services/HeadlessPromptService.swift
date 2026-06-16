import Foundation

/// Runs `claude -p` / `codex exec` headlessly to refine a selection in-place,
/// always passing the whole note as context for better answers.
struct HeadlessPromptService {
  func refineSelection(whole: String, selection: String, engine: HeadlessEngine) async throws -> String {
    let prompt = """
    You are refining one part of a draft prompt that will be handed to a coding agent.
    Rewrite ONLY the SELECTED TEXT so it is clearer, more concrete, and more useful — \
    preserve the author's intent and voice, resolve ambiguity, and keep it tight. \
    Do not add commentary. Return ONLY the rewritten selection: no preamble, no quotes, no markdown fences.

    ===== FULL DRAFT (context — do not rewrite this) =====
    \(whole)

    ===== SELECTED TEXT TO REWRITE =====
    \(selection)
    """
    return try await run(prompt: prompt, engine: engine)
  }

  private func run(prompt: String, engine: HeadlessEngine) async throws -> String {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let outPipe = Pipe()
      let errPipe = Pipe()

      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      switch engine {
      case .claude:
        process.arguments = ["claude", "-p", prompt]
      case .codex:
        process.arguments = ["codex", "exec", "--ask-for-approval", "never", prompt]
      }
      process.environment = Self.augmentedEnvironment()
      process.standardOutput = outPipe
      process.standardError = errPipe

      do {
        try process.run()
      } catch {
        throw HeadlessPromptError.failed("Could not launch \(engine.title): \(error.localizedDescription)")
      }
      process.waitUntilExit()

      let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmed ?? ""
      let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmed ?? ""

      guard process.terminationStatus == 0 else {
        throw HeadlessPromptError.failed(err.isEmpty ? "\(engine.title) exited with \(process.terminationStatus)." : err)
      }
      guard !out.isEmpty else { throw HeadlessPromptError.failed("\(engine.title) returned no text.") }
      return out
    }.value
  }

  /// A GUI app launched from Finder has a minimal PATH; add the usual CLI locations
  /// so `claude` / `codex` resolve.
  private static func augmentedEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    let extras = [
      "/opt/homebrew/bin", "/usr/local/bin",
      "\(home)/.local/bin", "\(home)/.bun/bin",
      "\(home)/.npm-global/bin", "\(home)/.cargo/bin",
      "\(home)/.deno/bin", "/usr/bin", "/bin",
    ]
    let existing = env["PATH"].map { [$0] } ?? []
    env["PATH"] = (extras + existing).joined(separator: ":")
    return env
  }
}

enum HeadlessPromptError: LocalizedError {
  case failed(String)
  var errorDescription: String? {
    switch self {
    case .failed(let message): message
    }
  }
}
