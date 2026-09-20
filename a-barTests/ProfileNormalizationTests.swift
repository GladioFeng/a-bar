import XCTest

/// Invariants the rest of the app assumes about profiles, enforced on every load whatever
/// the source, rather than in `ProfileManager.init` where only one path reached them.
final class ProfileNormalizationTests: XCTestCase {

  private func profile(_ name: String, id: UUID = UUID(), isDefault: Bool = false) -> LayoutProfile
  {
    LayoutProfile(id: id, name: name, multiDisplayLayout: .defaultLayout, isDefault: isDefault)
  }

  func testEmptyProfileListGetsADefaultProfile() {
    var settings = ABarSettings()
    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.profiles.count, 1)
    XCTAssertTrue(settings.profiles[0].isDefault)
    XCTAssertEqual(settings.activeProfileId, settings.profiles[0].id.uuidString)
  }

  func testDuplicateIdsAreMadeUnique() {
    let shared = UUID()
    var settings = ABarSettings()
    settings.profiles = [
      profile("Work", id: shared, isDefault: true),
      profile("Home", id: shared),
    ]

    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.profiles.count, 2)
    XCTAssertNotEqual(settings.profiles[0].id, settings.profiles[1].id)
    XCTAssertEqual(settings.profiles.map { $0.name }, ["Work", "Home"])
  }

  func testDuplicateNamesAreDisambiguated() {
    // `set profile "…"` matches by name, so duplicates make the AppleScript API ambiguous.
    var settings = ABarSettings()
    settings.profiles = [profile("Work", isDefault: true), profile("work"), profile("Work")]

    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.profiles.map { $0.name }, ["Work", "work 2", "Work 3"])
  }

  func testBlankNamesGetAName() {
    var settings = ABarSettings()
    settings.profiles = [profile("   ", isDefault: true)]

    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.profiles[0].name, "Profile")
  }

  func testExactlyOneProfileIsMarkedDefault() {
    var settings = ABarSettings()
    settings.profiles = [
      profile("Work", isDefault: true),
      profile("Home", isDefault: true),
    ]

    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.profiles.filter { $0.isDefault }.count, 1)
    XCTAssertTrue(settings.profiles[0].isDefault)
  }

  func testProfilesWithoutADefaultGetOneWithoutGrowingTheList() {
    // The old code inserted a brand new "Default" profile here, quietly duplicating a layout.
    var settings = ABarSettings()
    settings.profiles = [profile("Work"), profile("Home")]

    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.profiles.count, 2)
    XCTAssertTrue(settings.profiles[0].isDefault)
  }

  func testDanglingActiveProfileIdFallsBackToTheDefault() {
    var settings = ABarSettings()
    settings.profiles = [profile("Work"), profile("Home", isDefault: true)]
    settings.activeProfileId = UUID().uuidString

    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.activeProfileId, settings.profiles[1].id.uuidString)
  }

  func testUnparseableActiveProfileIdFallsBack() {
    var settings = ABarSettings()
    settings.profiles = [profile("Work", isDefault: true)]
    settings.activeProfileId = "not-a-uuid"

    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.activeProfileId, settings.profiles[0].id.uuidString)
  }

  func testAResolvableActiveProfileIdIsLeftAlone() {
    var settings = ABarSettings()
    settings.profiles = [profile("Work", isDefault: true), profile("Home")]
    settings.activeProfileId = settings.profiles[1].id.uuidString

    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.activeProfileId, settings.profiles[1].id.uuidString)
  }

  func testAProfileWithAnUnknownWidgetKeepsTheRestOfItsLayout() {
    var config = SettingsFixtures.json(SettingsFixtures.settings())
    SettingsFixtures.set(
      42, at: "profiles.0.multiDisplayLayout.displays.0.topBar.center.0.identifier", in: &config)

    let (settings, _) = decodeSettings(config)

    XCTAssertEqual(settings.profiles.count, 1, "the profile itself is not lost")
    let bar = settings.profiles[0].multiDisplayLayout.displays[0].topBar
    XCTAssertEqual(bar?.center, [])
    XCTAssertEqual(bar?.left.map { $0.identifier }, [.spaces])
    XCTAssertEqual(bar?.right.count, 3)
  }
}
