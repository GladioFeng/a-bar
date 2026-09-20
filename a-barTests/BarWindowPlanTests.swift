import XCTest

/// Every attached display that was configured gets the bars it asked for, an unconfigured one
/// gets none, and a display that is no longer plugged in gets none either.
final class BarWindowPlanTests: XCTestCase {

  // MARK: - Fixtures

  private enum Fixture {
    static func bar(_ identifiers: WidgetIdentifier...) -> SingleBarLayout {
      SingleBarLayout(left: identifiers.map { WidgetInstance(identifier: $0) })
    }

    static func display(
      _ index: Int, top: SingleBarLayout? = nil, bottom: SingleBarLayout? = nil
    ) -> DisplayConfiguration {
      DisplayConfiguration(displayIndex: index, topBar: top, bottomBar: bottom)
    }

    /// One display, top bar only - the shipped default.
    static let singleTopBar = MultiDisplayLayout(displays: [display(0, top: bar(.time))])
  }

  private func plan(
    screens: Int, _ layout: MultiDisplayLayout, barEnabled: Bool = true
  ) -> [BarWindowKey] {
    BarWindowPlan.windows(screenCount: screens, layout: layout, barEnabled: barEnabled)
  }

  // MARK: - What a display asks for

  func testAConfiguredDisplayGetsTheBarsItAskedFor() {
    let layout = MultiDisplayLayout(displays: [
      Fixture.display(0, top: Fixture.bar(.time), bottom: Fixture.bar(.cpu))
    ])

    XCTAssertEqual(
      plan(screens: 1, layout),
      [
        BarWindowKey(displayIndex: 0, position: .top),
        BarWindowKey(displayIndex: 0, position: .bottom),
      ],
      "both edges were configured, so both should open, top first")
  }

  func testADisplayWithOnlyABottomBarGetsNoTopBar() {
    let layout = MultiDisplayLayout(displays: [Fixture.display(0, bottom: Fixture.bar(.time))])

    XCTAssertEqual(plan(screens: 1, layout), [BarWindowKey(displayIndex: 0, position: .bottom)])
  }

  func testAnUnconfiguredDisplayGetsNothing() {
    // Plugging in a second monitor must not put an unasked-for bar on it.
    XCTAssertEqual(
      plan(screens: 2, Fixture.singleTopBar),
      [BarWindowKey(displayIndex: 0, position: .top)],
      "only display 0 is configured")
  }

  func testAConfiguredDisplayWithBothBarsRemovedGetsNothing() {
    let layout = MultiDisplayLayout(displays: [Fixture.display(0)])

    XCTAssertEqual(plan(screens: 1, layout), [])
  }

  // MARK: - Displays that come and go

  func testADisplayThatIsNoLongerAttachedGetsNoBar() {
    // The layout outlives the hardware: a laptop undocked from a second monitor still has a
    // configuration for display 1, and a window created for a screen that is not there cannot
    // be seen or closed.
    let layout = MultiDisplayLayout(displays: [
      Fixture.display(0, top: Fixture.bar(.time)),
      Fixture.display(1, top: Fixture.bar(.time)),
    ])

    XCTAssertEqual(plan(screens: 1, layout), [BarWindowKey(displayIndex: 0, position: .top)])
  }

  func testEveryAttachedAndConfiguredDisplayIsPlannedInIndexOrder() {
    let layout = MultiDisplayLayout(displays: [
      Fixture.display(2, bottom: Fixture.bar(.time)),
      Fixture.display(0, top: Fixture.bar(.time)),
      Fixture.display(1, top: Fixture.bar(.time), bottom: Fixture.bar(.cpu)),
    ])

    XCTAssertEqual(
      plan(screens: 3, layout),
      [
        BarWindowKey(displayIndex: 0, position: .top),
        BarWindowKey(displayIndex: 1, position: .top),
        BarWindowKey(displayIndex: 1, position: .bottom),
        BarWindowKey(displayIndex: 2, position: .bottom),
      ],
      "the plan is ordered by screen, not by the order displays were configured in")
  }

  func testEveryPlannedDisplayIndexIsAnAttachedScreen() {
    // The caller subscripts NSScreen.screens with these, so an index past the end would trap.
    let layout = MultiDisplayLayout(displays: (0..<6).map {
      Fixture.display($0, top: Fixture.bar(.time), bottom: Fixture.bar(.cpu))
    })

    for screens in 0...4 {
      let indices = plan(screens: screens, layout).map(\.displayIndex)
      XCTAssertTrue(
        indices.allSatisfy { (0..<screens).contains($0) },
        "planned \(indices) for \(screens) screen(s)")
    }
  }

  func testNoScreensMeansNoBars() {
    XCTAssertEqual(plan(screens: 0, Fixture.singleTopBar), [])
  }

  func testANegativeScreenCountIsSurvived() {
    // NSScreen.screens cannot be negative, but max(0,) is cheaper than finding out.
    XCTAssertEqual(plan(screens: -1, Fixture.singleTopBar), [])
  }

  func testTheSameBarIsNeverPlannedTwice() {
    let layout = MultiDisplayLayout(displays: [
      Fixture.display(0, top: Fixture.bar(.time)),
      Fixture.display(0, top: Fixture.bar(.cpu)),
    ])

    // The windows are held in a dictionary keyed by this, so a duplicate would silently close
    // and replace the bar it collided with.
    let keys = plan(screens: 2, layout)
    XCTAssertEqual(keys.count, Set(keys).count, "planned \(keys)")
  }

  // MARK: - The bar switched off

  func testSwitchingTheBarOffPlansNoWindows() {
    XCTAssertEqual(plan(screens: 2, Fixture.singleTopBar, barEnabled: false), [])
  }

  // MARK: - Which samplers have to run

  func testOnlyWidgetsOnAnAttachedDisplayCount() {
    // Hidden widgets must not poll or initialize blocking hardware APIs, so a widget that is
    // only on a disconnected display's bar must not start its service.
    let layout = MultiDisplayLayout(displays: [
      Fixture.display(0, top: Fixture.bar(.time)),
      Fixture.display(1, top: Fixture.bar(.bluetooth)),
    ])

    XCTAssertEqual(
      BarWindowPlan.visibleWidgets(screenCount: 1, layout: layout, barEnabled: true),
      [.time],
      "bluetooth lives on a display that is not attached")
  }

  func testSwitchingTheBarOffLeavesNothingToSample() {
    let layout = MultiDisplayLayout(displays: [
      Fixture.display(0, top: Fixture.bar(.time, .wifi), bottom: Fixture.bar(.cpu))
    ])

    XCTAssertEqual(
      BarWindowPlan.visibleWidgets(screenCount: 1, layout: layout, barEnabled: true),
      [.time, .wifi, .cpu])
    XCTAssertTrue(
      BarWindowPlan.visibleWidgets(screenCount: 1, layout: layout, barEnabled: false).isEmpty,
      "no bar means no widget is on screen, whatever the layout says")
  }

  func testADisabledWidgetIsNotSampled() {
    let layout = MultiDisplayLayout(displays: [
      Fixture.display(
        0,
        top: SingleBarLayout(left: [
          WidgetInstance(identifier: .time),
          WidgetInstance(identifier: .wifi, enabled: false),
        ]))
    ])

    XCTAssertEqual(
      BarWindowPlan.visibleWidgets(screenCount: 1, layout: layout, barEnabled: true), [.time])
  }
}
