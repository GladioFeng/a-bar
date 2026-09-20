import XCTest

/// A user's widget script is arbitrary code. It must be able to fail, write to stderr, or hang
/// forever without taking the bar with it - so every one of those paths comes back as a result.
///
/// These run real processes against `/bin/zsh`, which is what production does. They are the one
/// file in the suite that spends wall-clock time, so timeouts are kept short.
final class ShellExecutorTests: XCTestCase {

  // MARK: - The environment child processes inherit

  func testHomebrewPathsArePrependedSoWidgetsCanFindTheirTools() {
    // yabai, aerospace and gh live in /opt/homebrew/bin, which a GUI app does not inherit.
    let path = ShellExecutor.shellEnvironment()["PATH"]

    XCTAssertNotNil(path)
    XCTAssertTrue(
      path!.hasPrefix("/usr/local/bin:/opt/homebrew/bin"),
      "the prefix must come first, or a system binary shadows the brew one")
  }

  func testTheInheritedPathIsKeptRatherThanReplaced() {
    let inherited = ProcessInfo.processInfo.environment["PATH"]
    let path = ShellExecutor.shellEnvironment()["PATH"]

    if let inherited, !inherited.isEmpty {
      XCTAssertTrue(path!.hasSuffix(inherited), "the user's own PATH still follows")
    }
  }

  func testTheRestOfTheEnvironmentIsPassedThrough() {
    let environment = ShellExecutor.shellEnvironment()

    XCTAssertEqual(environment["HOME"], ProcessInfo.processInfo.environment["HOME"])
  }

  // MARK: - Running a command

  func testStandardOutputComesBack() async throws {
    let output = try await ShellExecutor.run("echo hello")

    XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
  }

  func testTheCommandRunsThroughAShellSoItsSyntaxWorks() async throws {
    // The command is passed to `zsh -c`, so pipes and substitutions are expected to work.
    let output = try await ShellExecutor.run("echo one two | tr ' ' '-'")

    XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "one-two")
  }

  func testRunFoldsStandardErrorIntoItsOutput() async throws {
    // `run` gives both streams the same pipe, so callers see stderr inline. `runWidget` is the
    // one that keeps them apart.
    let output = try await ShellExecutor.run("echo oops 1>&2")

    XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "oops")
  }

  func testSynchronousRunReturnsTheSameOutput() {
    let output = ShellExecutor.runSync("echo hello")

    XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
  }

  func testAFailingSynchronousCommandReturnsEmptyRatherThanThrowing() {
    XCTAssertEqual(ShellExecutor.runSync("exit 1"), "")
  }

  // MARK: - A widget script that fails must still report

  func testASuccessfulScriptReportsSuccess() async {
    let result = await ShellExecutor.runWidget("echo hi")

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hi")
    XCTAssertEqual(result.stderr, "", "a clean run says nothing on stderr")
  }

  func testTheExitCodeIsReportedRatherThanThrown() async {
    let result = await ShellExecutor.runWidget("exit 3")

    XCTAssertFalse(result.succeeded)
    XCTAssertEqual(result.exitCode, 3, "the script's own code reaches the widget")
  }

  func testTheTwoStreamsAreKeptApart() async {
    // The widget shows stdout in the bar and stderr as an error; mixing them prints the error
    // into the bar.
    let result = await ShellExecutor.runWidget("echo out; echo err 1>&2")

    XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
    XCTAssertEqual(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
  }

  func testAMissingCommandIsReportedOnStandardError() async {
    let result = await ShellExecutor.runWidget("this-command-does-not-exist")

    XCTAssertFalse(result.succeeded)
    XCTAssertFalse(result.stderr.isEmpty, "the user needs to be told what went wrong")
  }

  func testOutputIsReturnedWholeRatherThanTruncatedAtAPipeBuffer() async {
    // regression: the pipes were read only after `waitUntilExit()`. A pipe holds ~64KB, so a
    // script writing more blocked on write while we blocked on wait. The watchdog broke the
    // deadlock after the full timeout and the output came back cut to exactly 65529 bytes -
    // which also put every script beyond UserWidget's 512KB guard out of reach.
    let started = Date()

    let result = await ShellExecutor.runWidget("for i in $(seq 1 20000); do echo line$i; done")

    XCTAssertLessThan(
      Date().timeIntervalSince(started), 5, "a chatty script must not wait out its timeout")
    XCTAssertTrue(result.succeeded)
    XCTAssertGreaterThan(result.stdout.utf8.count, 65529, "more than one pipe buffer came back")
    XCTAssertEqual(result.stdout.split(separator: "\n").count, 20000, "nothing was dropped")
  }

  func testBothStreamsCanOverflowTheirBuffersAtOnce() async {
    // stdout and stderr have separate buffers; draining only one still deadlocks on the other.
    let result = await ShellExecutor.runWidget(
      "for i in $(seq 1 12000); do echo out$i; echo err$i 1>&2; done")

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.stdout.split(separator: "\n").count, 12000)
    XCTAssertEqual(result.stderr.split(separator: "\n").count, 12000)
  }

  func testALargeOutputSurvivesTheSynchronousPathToo() {
    let output = ShellExecutor.runSync("for i in $(seq 1 20000); do echo line$i; done")

    XCTAssertEqual(output.split(separator: "\n").count, 20000)
  }

  // MARK: - A script that hangs must be killed, not waited on

  func testAHangingCommandIsTerminatedAtItsDeadline() async {
    let started = Date()

    let result = await ShellExecutor.runWidget("sleep 30", timeout: 1)

    let elapsed = Date().timeIntervalSince(started)
    XCTAssertLessThan(elapsed, 10, "the watchdog fired instead of waiting out the sleep")
    XCTAssertFalse(result.succeeded, "a killed script did not succeed")
  }

  func testAHangingCommandDoesNotStopTheNextOneFromRunning() async throws {
    _ = await ShellExecutor.runWidget("sleep 30", timeout: 1)

    let output = try await ShellExecutor.run("echo still here")

    XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "still here")
  }

  func testACommandThatFinishesInsideItsDeadlineIsNotKilled() async {
    let result = await ShellExecutor.runWidget("echo quick", timeout: 5)

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "quick")
  }

  // MARK: - The result type

  func testOnlyAZeroExitCodeCountsAsSuccess() {
    XCTAssertTrue(ShellExecutor.WidgetRunResult(stdout: "", stderr: "", exitCode: 0).succeeded)
    XCTAssertFalse(ShellExecutor.WidgetRunResult(stdout: "", stderr: "", exitCode: 1).succeeded)
    XCTAssertFalse(
      ShellExecutor.WidgetRunResult(stdout: "", stderr: "", exitCode: -1).succeeded,
      "-1 is the code used when the process could not be started at all")
  }
}
