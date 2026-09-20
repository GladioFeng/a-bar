import XCTest

/// A layout is the user's arrangement of their bar. Reading it must never invent a widget,
/// lose one, or disturb a display the user was not editing.
final class WidgetTypesTests: XCTestCase {

  // MARK: - Every widget a user can place must be presentable

  func testEveryWidgetHasADisplayNameAndASymbol() {
    // `allCases` drives both the settings palette and the layout builder, so a widget added
    // without a name or a symbol renders as a blank row the user cannot identify.
    for identifier in WidgetIdentifier.allCases {
      XCTAssertFalse(
        identifier.displayName.trimmingCharacters(in: .whitespaces).isEmpty,
        "\(identifier.rawValue) has no display name")
      XCTAssertFalse(
        identifier.symbolName.trimmingCharacters(in: .whitespaces).isEmpty,
        "\(identifier.rawValue) has no symbol")
    }
  }

  func testDisplayNamesAreUnique() {
    // The palette lists widgets by name; two widgets sharing one are indistinguishable there.
    let names = WidgetIdentifier.allCases.map { $0.displayName }
    XCTAssertEqual(Set(names).count, names.count, "two widgets share a display name")
  }

  func testEveryWidgetBelongsToExactlyOneCategory() {
    // The palette is built by concatenating the categories, so a widget in none of them is
    // unreachable and a widget in two is offered twice.
    let categorised = WidgetCategory.allCases.flatMap { $0.widgets }

    XCTAssertEqual(
      Set(categorised), Set(WidgetIdentifier.allCases), "a widget is missing from the palette")
    XCTAssertEqual(categorised.count, WidgetIdentifier.allCases.count, "a widget is listed twice")
  }

  // MARK: - A disabled widget is hidden, not deleted

  func testOnlyEnabledWidgetsAreHandedToTheBar() {
    let layout = SingleBarLayout(
      left: [
        WidgetInstance(identifier: .cpu),
        WidgetInstance(identifier: .memory, enabled: false),
        WidgetInstance(identifier: .battery),
      ])

    XCTAssertEqual(
      layout.widgets(for: .left).map { $0.identifier }, [.cpu, .battery],
      "the disabled widget is not rendered")
    XCTAssertEqual(layout.left.count, 3, "but it is still in the layout, ready to be re-enabled")
  }

  func testAnEmptySectionYieldsNoWidgets() {
    let layout = SingleBarLayout(left: [WidgetInstance(identifier: .cpu)])

    XCTAssertEqual(layout.widgets(for: .center), [])
    XCTAssertEqual(layout.widgets(for: .right), [])
    XCTAssertFalse(layout.isEmpty, "a bar with one widget is not empty")
  }

  func testABarIsEmptyOnlyWhenEverySectionIs() {
    XCTAssertTrue(SingleBarLayout().isEmpty)
    XCTAssertFalse(
      SingleBarLayout(center: [WidgetInstance(identifier: .time)]).isEmpty,
      "a widget in any section makes the bar non-empty")
  }

  // MARK: - Editing one display must not disturb another

  func testConfigurationIsFoundByDisplayIndexNotByPosition() {
    // The displays array is not ordered by index - a display removed and re-added lands last.
    let layout = MultiDisplayLayout(displays: [
      DisplayConfiguration(displayIndex: 2, name: "External"),
      DisplayConfiguration(displayIndex: 0, name: "Built-in"),
    ])

    XCTAssertEqual(layout.configuration(forDisplay: 0)?.name, "Built-in")
    XCTAssertEqual(layout.configuration(forDisplay: 2)?.name, "External")
    XCTAssertNil(layout.configuration(forDisplay: 1), "an unconfigured display has no layout")
  }

  func testSettingAConfigurationReplacesTheMatchingDisplayRatherThanAppending() {
    var layout = MultiDisplayLayout(displays: [
      DisplayConfiguration(displayIndex: 0, name: "Built-in"),
      DisplayConfiguration(displayIndex: 1, name: "External"),
    ])

    layout.setConfiguration(
      DisplayConfiguration(displayIndex: 0, name: "Renamed"), forDisplay: 0)

    XCTAssertEqual(layout.displays.count, 2, "the display is replaced, not duplicated")
    XCTAssertEqual(layout.configuration(forDisplay: 0)?.name, "Renamed")
    XCTAssertEqual(layout.configuration(forDisplay: 1)?.name, "External", "the sibling survives")
  }

  func testSettingAConfigurationForAnUnknownDisplayAddsIt() {
    var layout = MultiDisplayLayout()

    layout.setConfiguration(DisplayConfiguration(displayIndex: 3, name: "New"), forDisplay: 3)

    XCTAssertEqual(layout.displays.count, 1)
    XCTAssertEqual(layout.configuration(forDisplay: 3)?.name, "New")
  }

  func testRemovingADisplayLeavesTheOthersAlone() {
    var layout = MultiDisplayLayout(displays: [
      DisplayConfiguration(displayIndex: 0, name: "Built-in"),
      DisplayConfiguration(displayIndex: 1, name: "External"),
    ])

    layout.removeConfiguration(forDisplay: 1)

    XCTAssertEqual(layout.displays.map { $0.name }, ["Built-in"])
    XCTAssertNil(layout.configuration(forDisplay: 1))
  }

  func testRemovingADisplayThatWasNeverConfiguredChangesNothing() {
    var layout = MultiDisplayLayout.defaultLayout
    let before = layout

    layout.removeConfiguration(forDisplay: 7)

    XCTAssertEqual(layout, before, "the user's layout is left alone")
  }

  func testBarLayoutIsReturnedPerPositionAndIsNilWhenThatBarIsOff() {
    let layout = MultiDisplayLayout(displays: [
      DisplayConfiguration(displayIndex: 0, name: "Main", topBar: .defaultTopBar, bottomBar: nil)
    ])

    XCTAssertNotNil(layout.barLayout(forDisplay: 0, position: .top))
    XCTAssertNil(
      layout.barLayout(forDisplay: 0, position: .bottom), "the bottom bar is switched off")
    XCTAssertNil(
      layout.barLayout(forDisplay: 1, position: .top), "an unconfigured display has no bars")
  }

  func testADisplayHasBarsOnlyWhenOneIsConfigured() {
    XCTAssertFalse(DisplayConfiguration(displayIndex: 0).hasBars)
    XCTAssertTrue(
      DisplayConfiguration(displayIndex: 0, bottomBar: SingleBarLayout()).hasBars,
      "an empty bar is still a bar the user asked for")
  }

  // MARK: - A custom widget cannot be configured to hammer the machine

  func testRefreshAndCycleIntervalsAreClampedToAOneSecondFloor() {
    // The clamp lives in the initializer, so it is invisible at the call site and applies to
    // decoded configs too - a hand-edited `.a-barrc` cannot ask for a zero-second loop.
    let widget = UserWidgetDefinition(refreshInterval: 0, cycleDuration: -5)

    XCTAssertEqual(widget.refreshInterval, 1, "a zero refresh would spin the CPU")
    XCTAssertEqual(widget.cycleDuration, 1)
  }

  func testIntervalsAboveTheFloorAreLeftAlone() {
    let widget = UserWidgetDefinition(refreshInterval: 30, cycleDuration: 4)

    XCTAssertEqual(widget.refreshInterval, 30)
    XCTAssertEqual(widget.cycleDuration, 4)
  }

  func testTheInitializerFloorDoesNotProtectAHandEditedConfigOnItsOwn() {
    // Synthesized `Codable` assigns the stored properties directly, so it never runs the
    // initializer that clamps. This is why `SettingsCodec.normalizeUserWidgets` exists and must
    // not be deleted as redundant - it is the only thing standing between a hand-edited
    // `.a-barrc` and a zero-second loop.
    var decoded = UserWidgetDefinition()
    decoded.refreshInterval = 0
    decoded.cycleDuration = 0

    XCTAssertEqual(decoded.refreshInterval, 0, "assignment bypasses the initializer's floor")

    var settings = ABarSettings()
    settings.userWidgets = [decoded]
    SettingsCodec.normalize(&settings)

    XCTAssertEqual(settings.userWidgets[0].refreshInterval, 1, "normalizing restores the floor")
    XCTAssertEqual(settings.userWidgets[0].cycleDuration, 1)
  }

  // MARK: - Transfer rates

  func testNetworkRatesAreLabelledPerSecond() {
    let stats = NetworkStats(download: 0, upload: 1024 * 1024)

    XCTAssertTrue(stats.formattedDownload.hasSuffix("/s"), "a rate without a unit is a number")
    XCTAssertTrue(stats.formattedUpload.hasSuffix("/s"))
    XCTAssertTrue(stats.formattedUpload.contains("MB"), "1 MiB should read in megabytes")
  }
  func testSamplingDemandMatchesConnectedEnabledWidgetsAcrossBothBars() {
    let layout = MultiDisplayLayout(displays: [
      DisplayConfiguration(displayIndex: 0,
        topBar: SingleBarLayout(left: [WidgetInstance(identifier: .cpu), WidgetInstance(identifier: .gpu, enabled: false)]),
        bottomBar: SingleBarLayout(right: [WidgetInstance(identifier: .cpu), WidgetInstance(identifier: .sound)])),
      DisplayConfiguration(displayIndex: 1,
        topBar: SingleBarLayout(left: [WidgetInstance(identifier: .bluetooth)]))
    ])
    XCTAssertEqual(layout.enabledWidgets(displayCount: 1), [.cpu, .sound])
    XCTAssertEqual(layout.enabledWidgets(displayCount: 2), [.cpu, .sound, .bluetooth])
    XCTAssertTrue(layout.enabledWidgets(displayCount: 0).isEmpty)
  }

}
