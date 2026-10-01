import XCTest

/// `update` is the single write path. Anything that goes through it has to survive both a
/// restart and a later Save from the Preferences window.
final class SettingsManagerTests: XCTestCase {

  private var directory: URL!
  private var fileURL: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: SettingsStore!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("a-bar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appendingPathComponent(".a-barrc")

    suiteName = "a-bar.tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    store = SettingsStore(fileURL: fileURL, userDefaults: defaults, writeDelay: 0)
  }

  override func tearDownWithError() throws {
    // Land any debounced write before the directory it targets disappears.
    store.flush()
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }

  /// A second store over the same file, standing in for the next launch.
  private func reopen() -> SettingsStore {
    SettingsStore(fileURL: fileURL, userDefaults: defaults, writeDelay: 0)
  }

  func testUpdatePersistsImmediately() {
    let manager = SettingsManager(store: store)

    manager.update { $0.global.barEnabled = false }
    manager.flush()

    XCTAssertFalse(manager.settings.global.barEnabled)
    XCTAssertFalse(
      reopen().load().settings.global.barEnabled, "survives a restart")
  }

  func testFirstEditCanBeSavedImmediatelyAndSurvivesRebase() {
    let manager = SettingsManager(store: store)
    manager.draftSettings.global.barHeight = 43
    XCTAssertTrue(manager.hasUnsavedChanges)
    XCTAssertTrue(manager.canSave)
    manager.rebaseDraftIfClean()
    XCTAssertEqual(manager.draftSettings.global.barHeight, 43)
    manager.saveSettings()
    manager.flush()
    XCTAssertFalse(manager.hasUnsavedChanges)
    XCTAssertEqual(manager.saveState, .idle)
    XCTAssertEqual(reopen().load().settings.global.barHeight, 43)
  }

  func testFailedSaveKeepsAppliedSettingsAndRetryIncludesNewEdits() throws {
    let manager = SettingsManager(store: store)
    // A directory at the destination reliably rejects atomic file writes, even as root.
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    manager.draftSettings.global.barHeight = 43
    manager.saveSettings()
    manager.flush()
    XCTAssertEqual(manager.settings.global.barHeight, 43)
    XCTAssertFalse(manager.hasUnsavedChanges)
    XCTAssertTrue(manager.saveState.isFailure)
    XCTAssertTrue(manager.canSave)

    try FileManager.default.removeItem(at: fileURL)
    manager.draftSettings.global.barHeight = 44
    manager.saveSettings()
    manager.flush()
    XCTAssertEqual(manager.saveState, .idle)
    XCTAssertFalse(manager.canSave)
    XCTAssertEqual(reopen().load().settings.global.barHeight, 44)
  }

  func testAutomaticSaveFailureIsVisibleAndDiscardDoesNotHideIt() throws {
    let manager = SettingsManager(store: store)
    try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)
    manager.update { $0.global.barEnabled = false }
    manager.flush()
    manager.discardChanges()
    XCTAssertTrue(manager.saveState.isFailure)
    XCTAssertTrue(manager.canSave)
    XCTAssertFalse(manager.settings.global.barEnabled)
  }

  func testSaveCompletionDoesNotClearNewDraftEdits() {
    let manager = SettingsManager(store: store)
    manager.draftSettings.global.barHeight = 43
    manager.saveSettings()
    XCTAssertEqual(manager.saveState, .saving)
    manager.draftSettings.global.barHeight = 44
    manager.flush()
    XCTAssertEqual(manager.saveState, .idle)
    XCTAssertTrue(manager.hasUnsavedChanges)
    XCTAssertEqual(manager.draftSettings.global.barHeight, 44)
    XCTAssertEqual(reopen().load().settings.global.barHeight, 43)
  }

  func testUpdateKeepsTheDraftInStepSoSaveCannotRevertIt() {
    // The menu bar toggle and the AppleScript commands write through `update` while the
    // Preferences window holds its own copy. That copy used to be stale, so the next Save
    // silently put the old value back.
    let manager = SettingsManager(store: store)

    manager.update { $0.global.barEnabled = false }
    manager.saveSettings()

    XCTAssertFalse(manager.settings.global.barEnabled)
    XCTAssertFalse(manager.draftSettings.global.barEnabled)
  }

  func testUpdateDoesNotDiscardAnEditInProgress() {
    let manager = SettingsManager(store: store)

    manager.draftSettings.global.fontName = "Menlo"  // an edit being made in Preferences
    manager.update { $0.global.barEnabled = false }  // something toggled elsewhere

    XCTAssertEqual(manager.draftSettings.global.fontName, "Menlo")
    XCTAssertFalse(manager.draftSettings.global.barEnabled)
  }

  func testUpdateNormalizesWhatItIsGiven() {
    let manager = SettingsManager(store: store)

    manager.update { $0.global.barHeight = 5000 }

    XCTAssertEqual(manager.settings.global.barHeight, 100)
  }

  func testLoadingADegradedConfigDoesNotOverwriteIt() throws {
    let corrupt = Data("{ nope".utf8)
    try corrupt.write(to: fileURL)

    let manager = SettingsManager(store: store)
    XCTAssertTrue(manager.isDegraded)

    manager.update { $0.global.barEnabled = false }
    manager.flush()

    XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    XCTAssertNotNil(manager.loadSummary)
  }

  func testDraftLayoutStartsOnTheActiveProfile() {
    var settings = SettingsFixtures.settings()
    let other = LayoutProfile(name: "Other", multiDisplayLayout: MultiDisplayLayout(), isDefault: false)
    settings.profiles.append(other)
    settings.activeProfileId = other.id.uuidString
    try? SettingsCodec.encode(settings).write(to: fileURL)

    let manager = SettingsManager(store: store)

    XCTAssertEqual(manager.draftLayout, other.multiDisplayLayout)
    XCTAssertFalse(manager.hasUnsavedChanges)
  }

  func testLoadingALayoutForEditingIsNotAnEdit() {
    // Merely selecting a profile to edit used to mark the layout dirty, because the flag
    // that cleared it raced a debounced publisher.
    let manager = SettingsManager(store: store)

    manager.loadLayoutForEditing(MultiDisplayLayout(displays: [
      DisplayConfiguration(displayIndex: 0, name: "Other", topBar: SingleBarLayout())
    ]))

    XCTAssertFalse(manager.hasUnsavedChanges)
  }
}
