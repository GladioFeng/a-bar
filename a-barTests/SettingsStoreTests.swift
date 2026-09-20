import XCTest

/// The store's job is to never lose a config: a file it cannot read is preserved, not
/// replaced by the defaults the app fell back to.
final class SettingsStoreTests: XCTestCase {

  private var directory: URL!
  private var fileURL: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("a-bar-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    fileURL = directory.appendingPathComponent(".a-barrc")

    suiteName = "a-bar.tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeStore() -> SettingsStore {
    SettingsStore(fileURL: fileURL, userDefaults: defaults, writeDelay: 0)
  }

  private func quarantineFiles(kind: String) throws -> [URL] {
    try FileManager.default
      .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".a-barrc.\(kind)-") }
  }

  private func writeConfig(barHeight: CGFloat) throws {
    var settings = SettingsFixtures.settings()
    settings.global.barHeight = barHeight
    try SettingsCodec.encode(settings).write(to: fileURL)
  }

  // MARK: - Loading

  func testLoadsDefaultsWhenNothingExists() {
    let result = makeStore().load()

    XCTAssertEqual(result.source, .defaults)
    XCTAssertFalse(result.isDegraded)
    XCTAssertEqual(result.settings.profiles.count, 1)
    XCTAssertNil(result.summary)
  }

  func testCleanLoadKeepsTheFileAsTheKnownGoodBackup() throws {
    try writeConfig(barHeight: 42)

    let result = makeStore().load()

    XCTAssertEqual(result.source, .file)
    XCTAssertEqual(result.settings.global.barHeight, 42)
    XCTAssertEqual(
      try Data(contentsOf: directory.appendingPathComponent(".a-barrc.bak")),
      try Data(contentsOf: fileURL))
  }

  func testRepairedFileIsQuarantinedBeforeAnythingIsWritten() throws {
    var config = SettingsFixtures.json(SettingsFixtures.settings())
    SettingsFixtures.set("not-a-theme", at: "theme.darkTheme", in: &config)
    try SettingsFixtures.data(config).write(to: fileURL)

    let result = makeStore().load()

    XCTAssertFalse(result.repairs.isEmpty)
    XCTAssertEqual(try quarantineFiles(kind: "repaired").count, 1)
    XCTAssertNotNil(result.summary)
  }

  // MARK: - A config we cannot read is never destroyed

  func testCorruptFileIsNeverOverwritten() throws {
    let corrupt = Data("{ \"global\": ".utf8)
    try corrupt.write(to: fileURL)

    let store = makeStore()
    let result = store.load()
    XCTAssertTrue(result.isDegraded)

    // Ordinary saves are refused while degraded.
    store.save(result.settings)
    store.flush()

    XCTAssertEqual(try Data(contentsOf: fileURL), corrupt, "the user's file is left alone")
    XCTAssertEqual(try quarantineFiles(kind: "corrupt").count, 1)
  }

  func testCorruptFileFallsBackToTheBackup() throws {
    try writeConfig(barHeight: 42)
    _ = makeStore().load()  // a clean load records the backup

    try Data("nonsense".utf8).write(to: fileURL)
    let result = makeStore().load()

    XCTAssertEqual(result.source, .backup)
    XCTAssertEqual(result.settings.global.barHeight, 42)
    XCTAssertTrue(result.isDegraded)
  }

  func testExplicitSaveClearsDegradedMode() throws {
    try Data("nonsense".utf8).write(to: fileURL)

    let store = makeStore()
    var settings = store.load().settings
    settings.global.barHeight = 51

    store.saveExplicitly(settings)
    store.flush()

    XCTAssertFalse(store.isDegraded)
    XCTAssertEqual(makeStore().load().settings.global.barHeight, 51)
  }

  func testQuarantineKeepsOnlyTheNewestFew() throws {
    for _ in 0..<5 {
      try Data("nonsense".utf8).write(to: fileURL)
      _ = makeStore().load()
    }

    XCTAssertEqual(try quarantineFiles(kind: "corrupt").count, 3)
  }

  // MARK: - Saving

  func testSaveRoundTripsThroughTheFile() throws {
    let store = makeStore()
    var settings = SettingsFixtures.settings()
    settings.global.barHeight = 44

    store.save(settings)
    store.flush()

    XCTAssertEqual(makeStore().load().settings.global.barHeight, 44)
  }

  func testSaveIsDebouncedIntoOneWrite() throws {
    let store = SettingsStore(fileURL: fileURL, userDefaults: defaults, writeDelay: 5)
    var settings = SettingsFixtures.settings()

    for height in 30...35 {
      settings.global.barHeight = CGFloat(height)
      store.save(settings)
    }
    store.flush()

    XCTAssertEqual(makeStore().load().settings.global.barHeight, 35, "only the last one lands")
  }

  // MARK: - Legacy UserDefaults

  func testLegacyUserDefaultsAreImportedOnce() throws {
    var legacy = SettingsFixtures.settings()
    legacy.global.barHeight = 44
    defaults.set(try SettingsCodec.encode(legacy), forKey: "abar-settings")

    let first = makeStore().load()
    XCTAssertEqual(first.source, .legacyUserDefaults)
    XCTAssertEqual(first.settings.global.barHeight, 44)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: fileURL.path), "the migration is made durable")

    let second = makeStore().load()
    XCTAssertEqual(second.source, .file, "the file wins from now on")
  }

  func testLegacyProfilesKeyIsFoldedIn() throws {
    var legacy = ABarSettings()
    legacy.global.barHeight = 44
    legacy.profiles = []
    defaults.set(try SettingsCodec.encode(legacy), forKey: "abar-settings")

    let profile = LayoutProfile(
      name: "Imported", multiDisplayLayout: .defaultLayout, isDefault: true)
    defaults.set(try JSONEncoder().encode([profile]), forKey: "abar-profiles")
    defaults.set(profile.id.uuidString, forKey: "abar-active-profile")

    let result = makeStore().load()

    XCTAssertEqual(result.settings.profiles.map { $0.name }, ["Imported"])
    XCTAssertEqual(result.settings.activeProfileId, profile.id.uuidString)
  }
}
