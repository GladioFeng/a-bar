import XCTest

/// AeroSpace's CLI has shipped the same field as a JSON boolean and as a quoted string across
/// versions. Every shape it has emitted must still decode, and a field it stops sending must
/// cost that field only - never the whole query.
final class AerospaceDecodingTests: XCTestCase {

  private func workspace(_ json: String) throws -> AerospaceWorkspace {
    try JSONDecoder().decode(AerospaceWorkspace.self, from: Data(json.utf8))
  }

  private func window(_ json: String) throws -> AerospaceWindow {
    try JSONDecoder().decode(AerospaceWindow.self, from: Data(json.utf8))
  }

  // MARK: - Booleans arrive in two shapes

  func testFocusAndVisibilityDecodeFromRealBooleans() throws {
    let parsed = try workspace(
      #"{"workspace":"1","workspace-is-focused":true,"workspace-is-visible":true,"monitor-id":1,"monitor-name":"Built-in"}"#)

    XCTAssertTrue(parsed.isFocused)
    XCTAssertTrue(parsed.isVisible)
  }

  func testFocusAndVisibilityDecodeFromQuotedStrings() throws {
    // Some AeroSpace versions emit "true"/"false" as strings; a strict decode drops the bar.
    let parsed = try workspace(
      #"{"workspace":"1","workspace-is-focused":"true","workspace-is-visible":"false","monitor-id":1,"monitor-name":"Built-in"}"#)

    XCTAssertTrue(parsed.isFocused, "the string form means the same thing")
    XCTAssertFalse(parsed.isVisible)
  }

  func testAStringBooleanIsReadCaseInsensitively() throws {
    let parsed = try workspace(
      #"{"workspace":"1","workspace-is-focused":"TRUE","monitor-id":1}"#)

    XCTAssertTrue(parsed.isFocused)
  }

  func testAMissingFocusFieldMeansNotFocusedRatherThanAFailedQuery() throws {
    let parsed = try workspace(#"{"workspace":"2","monitor-id":1}"#)

    XCTAssertFalse(parsed.isFocused, "absent is not focused")
    XCTAssertFalse(parsed.isVisible)
    XCTAssertEqual(parsed.workspace, "2", "the rest of the workspace still decodes")
  }

  func testAnUnrecognisedFocusValueFallsBackRatherThanThrowing() throws {
    let parsed = try workspace(
      #"{"workspace":"1","workspace-is-focused":7,"monitor-id":1}"#)

    XCTAssertFalse(parsed.isFocused)
  }

  // MARK: - The wire format is kebab-case

  func testWorkspaceFieldsReadTheHyphenatedKeys() throws {
    let parsed = try workspace(
      #"{"workspace":"main","workspace-is-focused":true,"monitor-id":3,"monitor-name":"DELL"}"#)

    XCTAssertEqual(parsed.monitorId, 3)
    XCTAssertEqual(parsed.monitorName, "DELL")
    XCTAssertEqual(parsed.displayLabel, "main", "the label is the workspace name")
  }

  func testAMissingMonitorNameBecomesEmptyRatherThanFailing() throws {
    let parsed = try workspace(#"{"workspace":"1","monitor-id":1}"#)

    XCTAssertEqual(parsed.monitorName, "")
  }

  func testWindowFieldsReadTheHyphenatedKeys() throws {
    let parsed = try window(
      #"{"window-id":42,"app-name":"Safari","window-title":"Docs","workspace":"1","monitor-id":2}"#)

    XCTAssertEqual(parsed.windowId, 42)
    XCTAssertEqual(parsed.appName, "Safari")
    XCTAssertEqual(parsed.windowTitle, "Docs")
    XCTAssertEqual(parsed.monitorId, 2)
  }

  func testAWindowWithoutATitleStillDecodes() throws {
    // A window with no title is common; losing it would empty the process widget.
    let parsed = try window(#"{"window-id":1,"app-name":"Finder"}"#)

    XCTAssertEqual(parsed.windowTitle, "")
    XCTAssertEqual(parsed.workspace, "")
    XCTAssertEqual(parsed.monitorId, 1, "the monitor defaults rather than failing")
  }

  func testAWindowWithoutAnAppNameIsRejected() throws {
    // There is nothing useful to render without one, so this is the one field worth failing on.
    XCTAssertThrowsError(try window(#"{"window-id":1}"#))
  }

  // MARK: - Reading the assembled state

  private func state() -> AerospaceState {
    let safari = AerospaceWindow(windowId: 1, appName: "Safari", workspace: "1")
    let notes = AerospaceWindow(windowId: 2, appName: "Notes", workspace: "1", isFocused: true)
    let safariAgain = AerospaceWindow(windowId: 3, appName: "Safari", workspace: "1")
    let mail = AerospaceWindow(windowId: 4, appName: "Mail", workspace: "2")

    return AerospaceState(
      workspaces: [
        AerospaceWorkspace(
          workspace: "1", isFocused: true, monitorId: 1,
          windows: [safari, notes, safariAgain]),
        AerospaceWorkspace(workspace: "2", monitorId: 2, windows: [mail]),
      ],
      monitors: [
        AerospaceMonitor(monitorId: 1, monitorName: "Built-in"),
        AerospaceMonitor(monitorId: 2, monitorName: "DELL"),
      ])
  }

  func testWorkspacesAreFilteredByMonitor() {
    XCTAssertEqual(state().workspaces(forMonitor: 2).map { $0.workspace }, ["2"])
    XCTAssertEqual(state().workspaces(forMonitor: 9), [], "an unknown monitor has no workspaces")
  }

  func testAScreenNameResolvesToItsMonitorId() {
    XCTAssertEqual(state().monitorId(forScreenName: "DELL"), 2)
    XCTAssertNil(
      state().monitorId(forScreenName: "Unplugged"), "a screen AeroSpace cannot see has no id")
  }

  func testTheFocusedWorkspaceAndWindowAreFound() {
    XCTAssertEqual(state().focusedWorkspace?.workspace, "1")
    XCTAssertEqual(state().focusedWindow?.appName, "Notes")
  }

  func testWindowsAreListedPerWorkspace() {
    XCTAssertEqual(state().windows(forWorkspace: "2").map { $0.appName }, ["Mail"])
    XCTAssertEqual(state().windows(forWorkspace: "none"), [], "an unknown workspace is empty")
    XCTAssertEqual(state().allWindows.count, 4)
  }

  func testRepeatedAppsAreShownOnceInTheOrderTheyFirstAppear() {
    // The process widget draws one icon per app; two Safari windows must not draw two icons.
    let apps = state().uniqueApps(forWorkspace: "1")

    XCTAssertEqual(apps.map { $0.appName }, ["Safari", "Notes"], "first occurrence wins")
    XCTAssertEqual(apps.first?.windowId, 1, "and it keeps that window's identity")
  }
}
