import Foundation
import SwiftUI

/// Live GitHub Actions run status for one repo + branch, mirrored onto the board. Shells the `gh`
/// CLI (which brings its own auth — no stored token), so "not signed in" is the unauthorized state.
/// One card = one repo/branch; it shows the latest run of each recent workflow as a row, with the
/// card border tinted to the overall state. See docs/widgets.md.
enum GitHubActionsWidget: BoardWidget {
  static let id = "github.actions"
  static let name = "GitHub Actions"
  static let summary = "Live run status for a repo and branch"
  static let symbol = "checkmark.seal"
  static let category = WidgetCategory.devCI
  // Uses the `gh` CLI's own auth, not a stored secret — so no requiredConnector. The unauthorized
  // state routes to `gh auth login`, not Settings. Token-based widgets set this to a connector id.
  static let requiredConnector: String? = nil
  static let refresh = RefreshPolicy.manual
  static let configVersion = 1

  // MARK: Types

  struct Config: Codable, Equatable, Sendable {
    var repo: String            // "owner/name"
    var branch: String?         // nil = all branches
  }

  struct Run: Codable, Equatable, Sendable {
    var workflow: String
    var number: Int
    var status: String          // queued | in_progress | completed
    var conclusion: String?     // success | failure | cancelled | skipped | …
    var url: String
    var startedAt: Date
  }

  struct Snapshot: Codable, Equatable, Sendable {
    var runs: [Run]
  }

  typealias Raw = String        // the `gh run list --json …` output

  // MARK: Config

  static func defaultConfig() -> Config { Config(repo: "", branch: nil) }

  static func validate(_ config: Config) -> [ConfigIssue] {
    var issues: [ConfigIssue] = []
    if !isValidRepo(config.repo) {
      issues.append(ConfigIssue(field: "repo", message: "Use owner/name (letters, digits, dot, dash)."))
    }
    if let branch = config.branch, !branch.isEmpty, !isValidBranch(branch) {
      issues.append(ConfigIssue(field: "branch", message: "Not a valid branch name."))
    }
    return issues
  }

  // MARK: Fetch + parse

  static func fetch(_ config: Config, _ transport: WidgetTransport) async throws -> Raw {
    // Defense in depth: reject bad input before it becomes argv, even though argv can't shell-inject.
    guard isValidRepo(config.repo) else { throw WidgetError.badConfig }
    if let b = config.branch, !b.isEmpty, !isValidBranch(b) { throw WidgetError.badConfig }

    // `gh` brings its own auth; a nonzero `auth status` means "sign in", surfaced as unauthorized.
    if (try? await transport.shell(["gh", "auth", "status"])) == nil { throw WidgetError.unauthorized }

    var argv = ["gh", "run", "list", "--repo", config.repo, "--limit", "12",
                "--json", "workflowName,number,status,conclusion,url,createdAt,headBranch"]
    if let branch = config.branch, !branch.isEmpty { argv += ["--branch", branch] }
    do {
      return try await transport.shell(argv)
    } catch let error as WidgetError {
      throw error
    } catch {
      throw WidgetError.network
    }
  }

  static func parse(_ raw: Raw) throws -> Snapshot {
    struct GHRun: Decodable {
      let workflowName: String; let number: Int; let status: String
      let conclusion: String?; let url: String; let createdAt: Date
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = raw.data(using: .utf8) else { throw WidgetError.badResponse }
    let ghRuns: [GHRun]
    do { ghRuns = try decoder.decode([GHRun].self, from: data) }
    catch { throw WidgetError.badResponse }

    // Collapse to the latest run per workflow, newest first, cap at what the card shows.
    var latest: [String: GHRun] = [:]
    for run in ghRuns where (latest[run.workflowName]?.number ?? -1) < run.number {
      latest[run.workflowName] = run
    }
    let runs = latest.values
      .sorted { $0.createdAt > $1.createdAt }
      .prefix(4)
      .map { Run(workflow: $0.workflowName, number: $0.number, status: $0.status,
                 conclusion: $0.conclusion, url: $0.url, startedAt: $0.createdAt) }
    return Snapshot(runs: Array(runs))
  }

  static func agentSummary(_ config: Config, _ snapshot: Snapshot?) -> String {
    let where_ = config.repo + (config.branch.map { "@\($0)" } ?? "")
    guard let runs = snapshot?.runs, !runs.isEmpty else { return "GitHub Actions — \(where_): no runs" }
    let failing = runs.filter { $0.conclusion == "failure" }
    let running = runs.filter { $0.status == "in_progress" }
    var parts = ["\(runs.count) workflows"]
    if !failing.isEmpty { parts.append("\(failing.count) failing (\(failing.map { "\($0.workflow) #\($0.number)" }.joined(separator: ", ")))") }
    if !running.isEmpty { parts.append("\(running.count) running") }
    if failing.isEmpty && running.isEmpty { parts.append("all passing") }
    return "GitHub Actions — \(where_): " + parts.joined(separator: ", ")
  }

  // MARK: Views

  static func configForm(_ config: Binding<Config>) -> some View {
    GitHubActionsConfigForm(config: config)
  }

  static func card(_ config: Config, _ snapshot: Snapshot?, _ phase: WidgetPhase) -> some View {
    GitHubActionsCard(config: config, snapshot: snapshot, phase: phase)
  }

  // MARK: Validation helpers

  static func isValidRepo(_ repo: String) -> Bool {
    repo.range(of: #"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
  }
  static func isValidBranch(_ branch: String) -> Bool {
    // Conservative ref-safe subset; rejects spaces, control chars, and shell metacharacters.
    branch.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil
      && !branch.hasPrefix("-")
  }
}
