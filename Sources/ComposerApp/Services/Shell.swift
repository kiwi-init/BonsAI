import Foundation

/// Runs a CLI off the main thread with the PATH a GUI app needs (a Finder-launched app
/// inherits a minimal PATH, so `gh`, `claude`, etc. wouldn't otherwise resolve).
enum Shell {
  struct Result { let stdout: String; let stderr: String; let status: Int32 }

  /// One-shot thread-safe flag: the timeout killer (on a global queue) and the awaiting task must
  /// agree on whether the command was killed.
  private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func fire() { lock.lock(); value = true; lock.unlock() }
    var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
  }

  /// Run `/usr/bin/env <args…>` and capture output. Throws only if the process can't launch.
  /// `directory` sets the working directory; pass it for user-authored commands, since a
  /// Finder-launched GUI app inherits `/` as its cwd (so a bare `pwd`/`ls`/`git` would otherwise
  /// run against the filesystem root). `timeout` (seconds) kills a command that overstays it and
  /// returns status 124 — so a hung `$(…)` at copy time can't freeze the app.
  static func run(_ args: [String], directory: String? = nil, timeout: TimeInterval? = nil) async throws -> Result {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let outPipe = Pipe(), errPipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = args
      process.environment = augmentedEnvironment()
      if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
      process.standardOutput = outPipe
      process.standardError = errPipe
      try process.run()

      // A command that overstays `timeout` is terminated, so a hung tool can't block the copy.
      let timedOut = TimeoutFlag()
      var killer: DispatchWorkItem?
      if let timeout {
        let work = DispatchWorkItem {
          if process.isRunning { timedOut.fire(); process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
        killer = work
      }

      // Drain both pipes concurrently. Reading stdout to EOF and only then reading stderr can
      // deadlock if a child fills stderr before it closes stdout (common with verbose CLI errors).
      async let outData = outPipe.fileHandleForReading.readToEnd()
      async let errData = errPipe.fileHandleForReading.readToEnd()
      process.waitUntilExit()
      killer?.cancel()
      let (stdoutData, stderrData) = try await (outData, errData)
      let stdout = String(data: stdoutData ?? Data(), encoding: .utf8) ?? ""
      var stderr = String(data: stderrData ?? Data(), encoding: .utf8) ?? ""
      if timedOut.fired {
        let limit = timeout.map { "\(Int($0))s" } ?? "the time limit"
        stderr = (stderr.isEmpty ? "" : stderr + "\n") + "Command timed out after \(limit)."
        return Result(stdout: stdout, stderr: stderr, status: 124)   // 124 = the `timeout(1)` convention
      }
      return Result(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }.value
  }

  /// A GUI app launched from Finder has a minimal PATH; add the usual CLI locations.
  static func augmentedEnvironment() -> [String: String] {
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
