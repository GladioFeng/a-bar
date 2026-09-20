import Combine
import XCTest

/// Profiles are the one part of settings that persists the moment it changes, rather than
/// waiting for an explicit Save. That makes `ProfileManager` the writer for its slice of the
/// config file, and every mutation here has to leave three things agreeing: the in-memory
/// list, what landed on disk, and the layout the bar is actually drawing.
final class ProfileManagerTests: XCTestCase {
    private var directory: URL!
    private var settings: SettingsManager!
    private var layout: LayoutManager!
    private var center: NotificationCenter!
    private var manager: ProfileManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("abar-profiles-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A notification center of its own: `.profileDidChange` is global, and the real
        // `LayoutManager.shared` is listening on the default one.
        center = NotificationCenter()
        layout = LayoutManager(initialLayout: .defaultLayout, notificationCenter: center)
        try reload(with: SettingsFixtures.settings())
    }

    override func tearDownWithError() throws {
        settings?.flush()
        try? FileManager.default.removeItem(at: directory)
        manager = nil; settings = nil; layout = nil; center = nil
    }

    /// Rebuild the manager against the config on disk, as a relaunch would.
    private func reload(with seed: ABarSettings? = nil) throws {
        settings?.flush()
        let config = directory.appendingPathComponent("config.json")
        if let seed { try SettingsCodec.encode(seed).write(to: config) }
        settings = SettingsManager(store: SettingsStore(fileURL: config))
        manager = ProfileManager(
            settingsManager: settings,
            notificationCenter: center,
            layoutManager: { [layout] in layout! })
    }

    private func persisted(line: UInt = #line) throws -> ABarSettings {
        settings.flush()
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard case .ok(let stored, _) = SettingsCodec.decode(data) else {
            XCTFail("the config on disk did not parse", line: line)
            return ABarSettings()
        }
        return stored
    }

    private var active: LayoutProfile { manager.activeProfile! }

    // MARK: - Loading

    func testProfilesComeUpFromTheStoredSettings() {
        XCTAssertEqual(manager.profileNames, ["Work"])
        XCTAssertEqual(manager.activeProfile?.name, "Work")
    }

    func testAConfigWithNoProfilesFallsBackToTheDefaultOne() throws {
        var seed = ABarSettings()
        seed.profiles = []
        try reload(with: seed)

        XCTAssertEqual(manager.profileNames, ["Default"])
        XCTAssertNotNil(manager.activeProfile, "there is always an active profile")
    }

    func testAnActiveIdThatNoProfileClaimsFallsBackToTheFirst() throws {
        var seed = SettingsFixtures.settings()
        seed.activeProfileId = UUID().uuidString
        try reload(with: seed)

        XCTAssertEqual(manager.activeProfileId, manager.profiles[0].id,
                       "a dangling active id must not leave the bar with no profile")
    }

    func testAMalformedActiveIdIsIgnored() throws {
        var seed = SettingsFixtures.settings()
        seed.activeProfileId = "not-a-uuid"
        try reload(with: seed)

        XCTAssertEqual(manager.activeProfileId, manager.profiles[0].id)
    }

    // MARK: - Switching

    func testSwitchingAppliesTheLayoutToTheBarAndPersistsTheChoice() throws {
        var other = MultiDisplayLayout.defaultLayout
        other.setConfiguration(
            DisplayConfiguration(displayIndex: 3, name: "Side", topBar: SingleBarLayout()),
            forDisplay: 3)
        let created = manager.createProfile(name: "Second", layout: other)

        XCTAssertTrue(manager.switchToProfile(id: created.id))
        XCTAssertEqual(manager.activeProfileId, created.id)
        XCTAssertEqual(layout.multiDisplayLayout, other, "the bar follows the active profile")
        XCTAssertEqual(try persisted().activeProfileId, created.id.uuidString)
    }

    func testSwitchingPostsTheProfileSoListenersCanFollow() {
        let created = manager.createProfile(name: "Second")
        var received: LayoutProfile?
        let token = center.addObserver(forName: .profileDidChange, object: nil, queue: nil) {
            received = $0.object as? LayoutProfile
        }
        defer { center.removeObserver(token) }

        _ = manager.switchToProfile(id: created.id)

        XCTAssertEqual(received?.id, created.id)
    }

    func testSwitchingToTheProfileAlreadyActiveIsASuccessfulNoOp() {
        var posts = 0
        let token = center.addObserver(forName: .profileDidChange, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { center.removeObserver(token) }

        XCTAssertTrue(manager.switchToProfile(id: manager.activeProfileId))
        XCTAssertEqual(posts, 0, "nothing changed, so nothing should be announced")
    }

    func testSwitchingToAnUnknownProfileFails() {
        XCTAssertFalse(manager.switchToProfile(id: UUID()))
    }

    func testSwitchingByNameIgnoresCase() {
        _ = manager.createProfile(name: "Second")

        XCTAssertTrue(manager.switchToProfile(named: "sEcOnD"))
        XCTAssertEqual(active.name, "Second")
    }

    func testSwitchingByAnUnknownNameFails() {
        XCTAssertFalse(manager.switchToProfile(named: "nope"))
    }

    // MARK: - Create, rename, duplicate

    func testCreatingAProfileAppendsItAndWritesItToDisk() throws {
        let created = manager.createProfile(name: "Second")

        XCTAssertEqual(manager.profileNames, ["Work", "Second"])
        XCTAssertFalse(created.isDefault, "a new profile never claims the default slot")
        XCTAssertEqual(try persisted().profiles.map(\.name), ["Work", "Second"])
    }

    func testCreatingWithoutALayoutUsesTheDefaultOne() {
        // `defaultLayout` mints fresh widget ids on every call, so compare its shape, not it.
        let created = manager.createProfile(name: "Second").multiDisplayLayout
        let expected = MultiDisplayLayout.defaultLayout

        XCTAssertEqual(created.displays.map(\.displayIndex), expected.displays.map(\.displayIndex))
        XCTAssertEqual(
            created.displays.first?.topBar?.left.map(\.identifier),
            expected.displays.first?.topBar?.left.map(\.identifier))
    }

    func testCreatingDoesNotStealTheActiveProfile() {
        let before = manager.activeProfileId
        _ = manager.createProfile(name: "Second")

        XCTAssertEqual(manager.activeProfileId, before)
    }

    func testRenamingKeepsTheIdAndPersists() throws {
        let id = manager.activeProfileId

        XCTAssertTrue(manager.renameProfile(id: id, newName: "Renamed"))
        XCTAssertEqual(manager.profile(withId: id)?.name, "Renamed")
        XCTAssertEqual(try persisted().profiles.first?.name, "Renamed")
    }

    func testRenamingAnUnknownProfileFails() {
        XCTAssertFalse(manager.renameProfile(id: UUID(), newName: "x"))
    }

    func testDuplicatingCopiesTheLayoutUnderANewIdentity() {
        let original = active
        let copy = manager.duplicateProfile(id: original.id)

        XCTAssertEqual(copy?.name, "Work Copy")
        XCTAssertNotEqual(copy?.id, original.id)
        XCTAssertEqual(copy?.multiDisplayLayout, original.multiDisplayLayout)
    }

    func testDuplicatingCanBeGivenAName() {
        XCTAssertEqual(manager.duplicateProfile(id: active.id, newName: "Mine")?.name, "Mine")
    }

    func testDuplicatingAnUnknownProfileReturnsNothing() {
        XCTAssertNil(manager.duplicateProfile(id: UUID()))
    }

    // MARK: - Updating a layout

    func testUpdatingTheActiveProfilesLayoutRedrawsTheBar() {
        var changed = MultiDisplayLayout.defaultLayout
        changed.setConfiguration(
            DisplayConfiguration(displayIndex: 2, name: "New", topBar: SingleBarLayout()),
            forDisplay: 2)

        manager.updateProfileLayout(id: manager.activeProfileId, layout: changed)

        XCTAssertEqual(layout.multiDisplayLayout, changed)
    }

    func testUpdatingAnInactiveProfileLeavesTheBarAlone() {
        let other = manager.createProfile(name: "Second")
        let before = layout.multiDisplayLayout
        var changed = MultiDisplayLayout.defaultLayout
        changed.setConfiguration(
            DisplayConfiguration(displayIndex: 4, name: "Hidden", topBar: SingleBarLayout()),
            forDisplay: 4)

        manager.updateProfileLayout(id: other.id, layout: changed)

        XCTAssertEqual(layout.multiDisplayLayout, before, "editing a profile you are not on")
        XCTAssertEqual(manager.profile(withId: other.id)?.multiDisplayLayout, changed)
    }

    func testUpdatingAnUnknownProfileDoesNothing() {
        let before = manager.profiles
        manager.updateProfileLayout(id: UUID(), layout: .defaultLayout)

        XCTAssertEqual(manager.profiles, before)
    }

    // MARK: - Deleting

    func testDeletingRemovesTheProfileAndPersists() throws {
        let doomed = manager.createProfile(name: "Second")

        XCTAssertTrue(manager.deleteProfile(id: doomed.id))
        XCTAssertEqual(manager.profileNames, ["Work"])
        XCTAssertEqual(try persisted().profiles.map(\.name), ["Work"])
    }

    func testTheDefaultProfileCannotBeDeleted() throws {
        var seed = ABarSettings()
        seed.profiles = []
        try reload(with: seed)

        XCTAssertFalse(manager.deleteProfile(id: manager.profiles[0].id))
        XCTAssertEqual(manager.profileNames, ["Default"], "the last resort has to survive")
    }

    func testDeletingAnUnknownProfileFails() {
        XCTAssertFalse(manager.deleteProfile(id: UUID()))
    }

    func testDeletingTheActiveProfileFallsBackToTheDefaultOne() throws {
        var seed = ABarSettings()
        seed.profiles = []
        try reload(with: seed)
        let fallback = manager.profiles[0].id
        let extra = manager.createProfile(name: "Second")
        _ = manager.switchToProfile(id: extra.id)

        XCTAssertTrue(manager.deleteProfile(id: extra.id))
        XCTAssertEqual(manager.activeProfileId, fallback,
                       "deleting what you are standing on has to land somewhere")
    }

    func testDeletingTheActiveProfileWithNoDefaultLandsOnWhateverRemains() {
        // The fixture's only profile is not marked default, so nothing claims the fallback slot.
        let extra = manager.createProfile(name: "Second")
        let survivor = manager.profiles[0].id
        _ = manager.switchToProfile(id: extra.id)

        XCTAssertTrue(manager.deleteProfile(id: extra.id))
        XCTAssertEqual(manager.activeProfileId, survivor)
    }

    // MARK: - Round trip

    func testEverythingWrittenSurvivesARelaunch() throws {
        let created = manager.createProfile(name: "Second")
        _ = manager.switchToProfile(id: created.id)
        _ = manager.renameProfile(id: created.id, newName: "Second Renamed")

        try reload()

        XCTAssertEqual(manager.profileNames, ["Work", "Second Renamed"])
        XCTAssertEqual(manager.activeProfile?.name, "Second Renamed")
    }
}
