import XCTest

/// AeroSpace answers workspaces, windows and the focused window in three commands that know
/// nothing about each other. The join must give every window to the workspace that claims it,
/// mark exactly one as focused, and survive the two queries disagreeing - they are taken a moment
/// apart, so they will.
final class AerospaceMergeTests: XCTestCase {

  private func workspace(_ name: String) -> AerospaceWorkspace {
    AerospaceWorkspace(workspace: name)
  }

  private func window(_ id: Int, _ app: String, on workspace: String) -> AerospaceWindow {
    AerospaceWindow(windowId: id, appName: app, workspace: workspace)
  }

  // MARK: - The join

  func testEachWindowLandsOnTheWorkspaceItNames() {
    let merged = AerospaceMerge.merge(
      workspaces: [workspace("1"), workspace("2")],
      windows: [window(10, "Safari", on: "1"), window(20, "Xcode", on: "2"),
        window(11, "Notes", on: "1")],
      focusedWindowId: nil)

    XCTAssertEqual(merged.map { $0.workspace }, ["1", "2"], "workspace order is preserved")
    XCTAssertEqual(merged[0].windows.map { $0.windowId }, [10, 11])
    XCTAssertEqual(merged[1].windows.map { $0.windowId }, [20])
  }

  func testWindowsKeepTheOrderTheQueryReturnedThemIn() {
    // AeroSpace's own ordering is what the opened-apps row reads left to right.
    let merged = AerospaceMerge.merge(
      workspaces: [workspace("1")],
      windows: [window(30, "C", on: "1"), window(10, "A", on: "1"), window(20, "B", on: "1")],
      focusedWindowId: nil)

    XCTAssertEqual(merged[0].windows.map { $0.appName }, ["C", "A", "B"])
  }

  func testAWorkspaceWithNoWindowsGetsAnEmptyListRatherThanTheWholeSet() {
    let merged = AerospaceMerge.merge(
      workspaces: [workspace("1"), workspace("empty")],
      windows: [window(10, "Safari", on: "1")],
      focusedWindowId: nil)

    XCTAssertEqual(merged[1].windows, [])
  }

  func testNoWorkspacesProducesNoWorkspaces() {
    let merged = AerospaceMerge.merge(
      workspaces: [], windows: [window(10, "Safari", on: "1")], focusedWindowId: 10)

    XCTAssertEqual(merged, [])
  }

  // MARK: - Focus

  func testExactlyTheFocusedWindowIsMarked() {
    let merged = AerospaceMerge.merge(
      workspaces: [workspace("1"), workspace("2")],
      windows: [window(10, "Safari", on: "1"), window(20, "Xcode", on: "2")],
      focusedWindowId: 20)

    XCTAssertEqual(merged.flatMap { $0.windows }.filter { $0.isFocused }.map { $0.windowId }, [20])
  }

  func testNothingIsFocusedWhenNothingIsFocused() {
    // The focused-window query is allowed to fail - an empty desktop has no focused window - and
    // then no window may match. An `Int` compared against a nil `Int?` is false for every window,
    // which is what makes that true.
    let merged = AerospaceMerge.merge(
      workspaces: [workspace("1")],
      windows: [window(10, "Safari", on: "1"), window(0, "Finder", on: "1")],
      focusedWindowId: nil)

    XCTAssertTrue(merged[0].windows.allSatisfy { !$0.isFocused })
  }

  func testAFocusedIdThatMatchesNoWindowMarksNothing() {
    // The focused-window query and the all-windows query are separate calls, so the focused
    // window can close in between.
    let merged = AerospaceMerge.merge(
      workspaces: [workspace("1")], windows: [window(10, "Safari", on: "1")],
      focusedWindowId: 999)

    XCTAssertTrue(merged[0].windows.allSatisfy { !$0.isFocused })
  }

  func testAStaleFocusFlagOnAnIncomingWindowIsOverwritten() {
    // `isFocused` defaults to false but is part of the decoded type, so a window arriving with it
    // set must not stay focused once a different window has focus.
    var stale = window(10, "Safari", on: "1")
    stale.isFocused = true

    let merged = AerospaceMerge.merge(
      workspaces: [workspace("1")], windows: [stale, window(20, "Xcode", on: "1")],
      focusedWindowId: 20)

    XCTAssertFalse(merged[0].windows[0].isFocused, "focus must be assigned, not inherited")
    XCTAssertTrue(merged[0].windows[1].isFocused)
  }

  // MARK: - The two queries disagreeing

  func testAWindowOnAnUnknownWorkspaceIsDroppedRatherThanMisfiled() {
    // `list-windows --all` can name a workspace that `list-workspaces` no longer reports, because
    // it was destroyed between the two calls. Putting that window anywhere would show it on the
    // wrong desktop.
    let merged = AerospaceMerge.merge(
      workspaces: [workspace("1")],
      windows: [window(10, "Safari", on: "1"), window(99, "Ghost", on: "destroyed")],
      focusedWindowId: nil)

    XCTAssertEqual(merged.flatMap { $0.windows }.map { $0.windowId }, [10])
  }

  func testTheMergedStateAnswersTheQuestionsTheWidgetsAsk() {
    let merged = AerospaceMerge.merge(
      workspaces: [workspace("1"), workspace("2")],
      windows: [window(10, "Safari", on: "1"), window(11, "Safari", on: "1"),
        window(20, "Xcode", on: "2")],
      focusedWindowId: 11)
    let state = AerospaceState(workspaces: merged, monitors: [])

    XCTAssertEqual(state.focusedWindow?.windowId, 11)
    XCTAssertEqual(state.allWindows.count, 3)
    XCTAssertEqual(state.uniqueApps(forWorkspace: "1").map { $0.appName }, ["Safari"])
  }
}
