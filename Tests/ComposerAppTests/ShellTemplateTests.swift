import XCTest
@testable import ComposerApp

final class ShellTemplateTests: XCTestCase {
  private func ok(_ stdout: String) -> Shell.Result {
    Shell.Result(stdout: stdout, stderr: "", status: 0)
  }

  // MARK: Queries

  func testDefinedNamesFindsParenthesizedAssignmentsAnywhere() {
    // Mid-sentence and own-line both count; the parens bound the value.
    let board = "in file=(@index.ts) solve this\n\nregion = (us-central1)"
    XCTAssertEqual(ShellTemplate.definedNames(in: board), ["file", "region"])
  }

  func testCommandsListsEveryCommandSubstitution() {
    let board = "logs=($(gcloud tail))\nrunning $(whoami) in $(pwd)"
    XCTAssertEqual(ShellTemplate.commands(in: board), ["gcloud tail", "whoami", "pwd"])
  }

  func testReferenceOnlyStylesDefinedNames() {
    let text = "pay $5 to $region, home is $HOME"
    let kinds = ShellTemplate.expressions(in: text, definedNames: ["region"]).map(\.kind)
    XCTAssertEqual(kinds, [.reference(name: "region")])   // $5 and $HOME are left alone
  }

  func testStyleSpansCoverCommandDefinitionNameAndReference() {
    let kinds = ShellTemplate.expressions(in: "file=(x) $(pwd) $file", definedNames: ["file"]).map(\.kind)
    XCTAssertEqual(kinds, [.definition(name: "file"), .command("pwd"), .reference(name: "file")])
  }

  // MARK: Expansion

  func testInlineDefinitionBindsAndIsConsumed() async {
    // The exact shape that failed before: definition inside a sentence.
    let board = "in file=(@index.ts) solve gasdadsfa\n\nwhat is $file ?"
    let (out, failures) = await ShellTemplate.expand(board) { _ in self.ok("unused") }
    XCTAssertEqual(out, "in solve gasdadsfa\n\nwhat is @index.ts ?")
    XCTAssertTrue(failures.isEmpty, "\(failures)")
  }

  func testCommandSubstitutionInlinesStdout() async {
    let (out, failures) = await ShellTemplate.expand("running as $(whoami) in $(pwd)") { command in
      command == "whoami" ? self.ok("jow\n") : self.ok("/Users/jow\n")
    }
    XCTAssertEqual(out, "running as jow in /Users/jow")
    XCTAssertTrue(failures.isEmpty, "\(failures)")
  }

  func testVariableBoundToCommandRunsOnceAndReusesBoardWide() async {
    var calls = 0
    let board = "who=($(whoami))\n\n$who committed; ping $who again"
    let (out, _) = await ShellTemplate.expand(board) { command in
      if command == "whoami" { calls += 1; return self.ok("jow") }
      return self.ok("")
    }
    XCTAssertEqual(out, "jow committed; ping jow again")
    XCTAssertEqual(calls, 1, "the command behind a variable should run once, not per reference")
  }

  func testDefinitionValueCanReferenceAnEarlierVariable() async {
    let board = "base=(/srv) path=($base/logs)\n\ntail $path"
    let (out, _) = await ShellTemplate.expand(board) { _ in self.ok("") }
    XCTAssertEqual(out, "tail /srv/logs")
  }

  func testValueWithSpacesIsKeptWholeByParens() async {
    let board = "msg=(deploy now) — $msg"
    let (out, _) = await ShellTemplate.expand(board) { _ in self.ok("") }
    XCTAssertEqual(out, "— deploy now")
  }

  func testUndefinedDollarTokensAreLeftLiteral() async {
    let (out, failures) = await ShellTemplate.expand("cost is $5 and home is $HOME") { _ in self.ok("x") }
    XCTAssertEqual(out, "cost is $5 and home is $HOME")
    XCTAssertTrue(failures.isEmpty)
  }

  func testFailedCommandIsLeftLiteralAndReported() async {
    let (out, failures) = await ShellTemplate.expand("before $(boom) after") { _ in
      Shell.Result(stdout: "", stderr: "kaboom", status: 3)
    }
    XCTAssertEqual(out, "before $(boom) after")
    XCTAssertEqual(failures.count, 1)
    XCTAssertTrue(failures[0].contains("boom"))
    XCTAssertTrue(failures[0].contains("kaboom"))
  }

  func testUnbalancedDefinitionIsNotTreatedAsOne() {
    // No closing paren → not a definition (and not a crash).
    XCTAssertTrue(ShellTemplate.definedNames(in: "x=(@unclosed and more text").isEmpty)
  }

  func testVariablesResolveEvenWhenCommandsAreDisabled() async {
    // Toggle off: `$(…)` stays literal, but pure variable aliasing still works (no shell run).
    var ran = false
    let board = "cwd $(pwd); file=(@index.ts) about $file"
    let (out, _) = await ShellTemplate.expand(board, runCommands: false) { _ in
      ran = true; return self.ok("SHOULD-NOT-RUN")
    }
    XCTAssertFalse(ran, "commands must not run when disabled")
    XCTAssertEqual(out, "cwd $(pwd); about @index.ts")
  }

  func testIdenticalCommandsRunOnce() async {
    var calls = 0
    let (out, _) = await ShellTemplate.expand("a $(pwd) and again $(pwd)") { command in
      if command == "pwd" { calls += 1 }
      return self.ok("/x")
    }
    XCTAssertEqual(out, "a /x and again /x")
    XCTAssertEqual(calls, 1, "an identical command should run once per copy")
  }

  func testFailedCommandReportedOnceEvenIfRepeated() async {
    var failureCount = 0
    let (_, failures) = await ShellTemplate.expand("$(boom) then $(boom)") { _ in
      failureCount += 1
      return Shell.Result(stdout: "", stderr: "no", status: 1)
    }
    XCTAssertEqual(failureCount, 1, "a repeated failing command runs once")
    XCTAssertEqual(failures.count, 1, "and is reported once")
  }

  func testTextWithNoTokensIsUnchanged() async {
    let text = "just prose with an @github mention and a [link](url)"
    XCTAssertTrue(ShellTemplate.commands(in: text).isEmpty)
    let (out, failures) = await ShellTemplate.expand(text) { _ in self.ok("x") }
    XCTAssertEqual(out, text)
    XCTAssertTrue(failures.isEmpty)
  }
}
