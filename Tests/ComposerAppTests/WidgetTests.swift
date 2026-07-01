import XCTest
@testable import ComposerApp

/// A canned transport so `fetch` is exercised without the network or the `gh` CLI. `parse` is the
/// pure part that fixtures cover directly.
private struct StubTransport: WidgetTransport {
  var authSucceeds = true
  var runListJSON = "[]"
  func shell(_ argv: [String]) async throws -> String {
    if argv.contains("auth") {
      if authSucceeds { return "Logged in" } else { throw WidgetError.unauthorized }
    }
    return runListJSON
  }
  func get(_ url: URL, headers: [String: String]) async throws -> Data { Data() }
}

private let fixture = """
[
  {"workflowName":"CI","number":482,"status":"completed","conclusion":"success","url":"u1","createdAt":"2026-06-30T10:00:00Z","headBranch":"main"},
  {"workflowName":"CI","number":480,"status":"completed","conclusion":"failure","url":"u2","createdAt":"2026-06-30T09:00:00Z","headBranch":"main"},
  {"workflowName":"Deploy","number":91,"status":"in_progress","conclusion":null,"url":"u3","createdAt":"2026-06-30T10:05:00Z","headBranch":"main"}
]
"""

final class GitHubActionsWidgetTests: XCTestCase {

  // MARK: parse (the pure, high-value test)

  func testParseCollapsesToLatestRunPerWorkflowNewestFirst() throws {
    let snapshot = try GitHubActionsWidget.parse(fixture)
    XCTAssertEqual(snapshot.runs.count, 2, "two workflows (CI collapsed to its latest run)")
    XCTAssertEqual(snapshot.runs[0].workflow, "Deploy", "newest createdAt first")
    XCTAssertEqual(snapshot.runs[0].status, "in_progress")
    let ci = try XCTUnwrap(snapshot.runs.first { $0.workflow == "CI" })
    XCTAssertEqual(ci.number, 482, "kept the higher run number, not #480")
    XCTAssertEqual(ci.conclusion, "success")
  }

  func testParseRejectsGarbageAsBadResponse() {
    XCTAssertThrowsError(try GitHubActionsWidget.parse("not json")) { error in
      XCTAssertEqual(error as? WidgetError, .badResponse)
    }
  }

  // MARK: fetch (transport stubbed)

  func testFetchThrowsUnauthorizedWhenGhNotSignedIn() async {
    let transport = StubTransport(authSucceeds: false)
    do {
      _ = try await GitHubActionsWidget.fetch(.init(repo: "owner/name", branch: nil), transport)
      XCTFail("expected unauthorized")
    } catch { XCTAssertEqual(error as? WidgetError, .unauthorized) }
  }

  func testFetchRejectsBadConfigBeforeTouchingTransport() async {
    let transport = StubTransport(authSucceeds: true, runListJSON: fixture)
    do {
      _ = try await GitHubActionsWidget.fetch(.init(repo: "a/b; rm -rf ~", branch: nil), transport)
      XCTFail("expected badConfig")
    } catch { XCTAssertEqual(error as? WidgetError, .badConfig) }
  }

  func testFetchThenParseHappyPath() async throws {
    let transport = StubTransport(authSucceeds: true, runListJSON: fixture)
    let raw = try await GitHubActionsWidget.fetch(.init(repo: "owner/name", branch: "main"), transport)
    let snapshot = try GitHubActionsWidget.parse(raw)
    XCTAssertEqual(snapshot.runs.count, 2)
  }

  // MARK: validate (security — injection & malformed input rejected)

  func testValidateAcceptsGoodConfigs() {
    XCTAssertTrue(GitHubActionsWidget.validate(.init(repo: "ojowwalker77/BonsAI", branch: nil)).isEmpty)
    XCTAssertTrue(GitHubActionsWidget.validate(.init(repo: "a.b_c/d-e.f", branch: "release/1.3.0")).isEmpty)
  }

  func testValidateRejectsInjectionAndMalformed() {
    let bad: [GitHubActionsWidget.Config] = [
      .init(repo: "a/b; rm -rf ~", branch: nil),
      .init(repo: "noslash", branch: nil),
      .init(repo: "owner/name", branch: "bad branch"),
      .init(repo: "owner/name", branch: "--dangerous"),
      .init(repo: "owner/name", branch: "a;b"),
    ]
    for config in bad {
      XCTAssertFalse(GitHubActionsWidget.validate(config).isEmpty, "should reject \(config)")
    }
  }

  // MARK: forward-compat (an old/partial config blob must still decode)

  func testConfigDecodesFromOlderAndNewerBlobs() throws {
    let old = Data(#"{"repo":"owner/name"}"#.utf8)          // pre-branch-field board
    let cfg = try JSONDecoder().decode(GitHubActionsWidget.Config.self, from: old)
    XCTAssertEqual(cfg.repo, "owner/name")
    XCTAssertNil(cfg.branch)

    let future = Data(#"{"repo":"o/r","branch":"main","unknownFutureField":true}"#.utf8)
    XCTAssertNoThrow(try JSONDecoder().decode(GitHubActionsWidget.Config.self, from: future),
                     "unknown fields from a newer build must be ignored, not fatal")
  }

  // MARK: agent projection

  func testAgentSummaryNamesFailures() {
    let runs = [
      GitHubActionsWidget.Run(workflow: "Release", number: 13, status: "completed", conclusion: "failure", url: "u", startedAt: Date()),
      GitHubActionsWidget.Run(workflow: "CI", number: 486, status: "completed", conclusion: "success", url: "u", startedAt: Date()),
    ]
    let summary = GitHubActionsWidget.agentSummary(.init(repo: "o/r", branch: "main"), .init(runs: runs))
    XCTAssertTrue(summary.contains("failing"))
    XCTAssertTrue(summary.contains("Release #13"))
  }
}

final class WidgetRegistryTests: XCTestCase {
  func testRegistryInvariants() {
    let ids = WidgetRegistry.all.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "widget ids are unique")
    for widget in WidgetRegistry.all {
      XCTAssertFalse(widget.id.isEmpty)
      XCTAssertFalse(widget.name.isEmpty)
      XCTAssertFalse(widget.symbol.isEmpty)
      if let connector = widget.requiredConnector {
        XCTAssertTrue(connector.hasPrefix("@"), "requiredConnector must be a connector id (\(connector))")
      }
    }
  }

  func testLookupByID() {
    XCTAssertNotNil(WidgetRegistry.widget(id: "github.actions"))
    XCTAssertNil(WidgetRegistry.widget(id: "nope"))
  }
}
