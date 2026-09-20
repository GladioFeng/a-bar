import XCTest

/// A placed custom widget points at its script by position in the list, so deleting or
/// reordering that list repoints every instance after the change. Nothing about the bar looks
/// wrong when this goes wrong - the widget just quietly runs somebody else's script.
final class UserWidgetIndexRemapperTests: XCTestCase {

  private func custom(_ index: Int) -> WidgetInstance {
    WidgetInstance(identifier: .userWidget, userWidgetIndex: index)
  }

  private func indices(_ widgets: [WidgetInstance]) -> [Int?] {
    widgets.map { $0.userWidgetIndex }
  }

  // MARK: - Deleting a custom widget

  func testInstancesOfTheDeletedWidgetAreRemoved() {
    let result = UserWidgetIndexRemapper.removing(1, from: [custom(0), custom(1), custom(2)])

    XCTAssertEqual(indices(result), [0, 1], "the deleted widget's instance is gone")
  }

  func testInstancesPointingPastTheDeletedOneShiftDown() {
    // This is the whole point: index 2 becomes index 1 because the list got shorter.
    let result = UserWidgetIndexRemapper.removing(0, from: [custom(1), custom(2)])

    XCTAssertEqual(indices(result), [0, 1])
  }

  func testInstancesPointingBeforeTheDeletedOneAreUntouched() {
    let result = UserWidgetIndexRemapper.removing(2, from: [custom(0), custom(1)])

    XCTAssertEqual(indices(result), [0, 1])
  }

  func testDeletingTheLastWidgetTouchesNothingElse() {
    let result = UserWidgetIndexRemapper.removing(5, from: [custom(0), custom(1)])

    XCTAssertEqual(indices(result), [0, 1])
  }

  func testEveryInstanceOfTheDeletedWidgetGoesNotJustTheFirst() {
    // The same custom widget can be placed in several bars.
    let result = UserWidgetIndexRemapper.removing(1, from: [custom(1), custom(0), custom(1)])

    XCTAssertEqual(indices(result), [0])
  }

  func testBuiltInWidgetsAreNeverTouched() {
    let widgets = [WidgetInstance(identifier: .cpu), custom(1), WidgetInstance(identifier: .time)]

    let result = UserWidgetIndexRemapper.removing(1, from: widgets)

    XCTAssertEqual(result.map { $0.identifier }, [.cpu, .time], "only the custom one went")
  }

  func testACustomWidgetWithNoIndexIsLeftAlone() {
    // A malformed config can carry one; dropping it would lose a widget the user placed.
    let orphan = WidgetInstance(identifier: .userWidget, userWidgetIndex: nil)

    let result = UserWidgetIndexRemapper.removing(0, from: [orphan])

    XCTAssertEqual(result.count, 1)
  }

  // MARK: - Reordering the custom widget list

  func testInstancesFollowTheirWidgetToItsNewPosition() {
    let result = UserWidgetIndexRemapper.remapping([0: 2, 1: 0, 2: 1], in: [custom(0), custom(1)])

    XCTAssertEqual(indices(result), [2, 0])
  }

  func testAnIndexAbsentFromTheMapIsLeftAlone() {
    let result = UserWidgetIndexRemapper.remapping([0: 1], in: [custom(0), custom(5)])

    XCTAssertEqual(indices(result), [1, 5])
  }

  func testRemappingNeverAddsOrDropsAWidget() {
    let widgets = [custom(0), WidgetInstance(identifier: .cpu), custom(1)]

    let result = UserWidgetIndexRemapper.remapping([0: 1, 1: 0], in: widgets)

    XCTAssertEqual(result.count, 3)
    XCTAssertEqual(indices(result), [1, nil, 0])
  }

  // MARK: - Across every bar of every display

  private func layout() -> MultiDisplayLayout {
    MultiDisplayLayout(displays: [
      DisplayConfiguration(
        displayIndex: 0, name: "Main",
        topBar: SingleBarLayout(left: [custom(0)], center: [custom(1)], right: [custom(2)]),
        bottomBar: SingleBarLayout(left: [custom(2)])),
      DisplayConfiguration(
        displayIndex: 1, name: "External",
        topBar: SingleBarLayout(right: [custom(1), WidgetInstance(identifier: .cpu)])),
    ])
  }

  func testEverySectionOfEveryBarOnEveryDisplayIsRemapped() {
    // A section missed here is a widget left pointing at the wrong script, on a display the
    // user may not even be looking at.
    let result = UserWidgetIndexRemapper.removing(1, from: layout())

    let top = result.displays[0].topBar
    XCTAssertEqual(indices(top?.left ?? []), [0], "left")
    XCTAssertEqual(top?.center ?? [], [], "center - the deleted widget's instance")
    XCTAssertEqual(indices(top?.right ?? []), [1], "right, shifted down")
    XCTAssertEqual(indices(result.displays[0].bottomBar?.left ?? []), [1], "the bottom bar too")
    XCTAssertEqual(indices(result.displays[1].topBar?.right ?? []), [nil], "the second display too")
  }

  func testTheBuiltInWidgetOnTheSecondDisplaySurvives() {
    let result = UserWidgetIndexRemapper.removing(1, from: layout())

    XCTAssertEqual(result.displays[1].topBar?.right.map { $0.identifier }, [.cpu])
  }

  func testABarThatIsSwitchedOffStaysSwitchedOff() {
    let result = UserWidgetIndexRemapper.removing(0, from: layout())

    XCTAssertNil(result.displays[1].bottomBar, "an absent bar is not conjured into existence")
  }

  func testRemappingReachesEverySectionToo() {
    let result = UserWidgetIndexRemapper.remapping([0: 5, 1: 6, 2: 7], in: layout())

    XCTAssertEqual(indices(result.displays[0].topBar?.left ?? []), [5])
    XCTAssertEqual(indices(result.displays[0].topBar?.center ?? []), [6])
    XCTAssertEqual(indices(result.displays[0].topBar?.right ?? []), [7])
    XCTAssertEqual(indices(result.displays[0].bottomBar?.left ?? []), [7])
    XCTAssertEqual(indices(result.displays[1].topBar?.right ?? []), [6, nil])
  }

  func testAnEmptyLayoutIsHandled() {
    XCTAssertEqual(UserWidgetIndexRemapper.removing(0, from: MultiDisplayLayout()).displays, [])
  }
}
