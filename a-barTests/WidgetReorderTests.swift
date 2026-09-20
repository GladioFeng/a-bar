import XCTest

/// A drag must move a widget, never duplicate or lose one, wherever it is released. The index a
/// drop reports is measured against the list before the widget leaves it, so moving down needs a
/// compensation that moving up does not.
final class WidgetReorderTests: XCTestCase {

  private var widgets: [WidgetInstance] = []

  override func setUp() {
    super.setUp()
    widgets = [
      WidgetInstance(identifier: .cpu),
      WidgetInstance(identifier: .memory),
      WidgetInstance(identifier: .battery),
      WidgetInstance(identifier: .time),
    ]
  }

  private func names(_ list: [WidgetInstance]) -> [WidgetIdentifier] {
    list.map { $0.identifier }
  }

  // MARK: - Moving within one section

  func testMovingAWidgetLaterLandsItWhereItWasDropped() {
    // The compensation lives here: removing `cpu` first shifts gap 2 to gap 1.
    let result = WidgetReorder.moving(widgets, id: widgets[0].id, to: 2)

    XCTAssertEqual(names(result), [.memory, .cpu, .battery, .time])
  }

  func testMovingAWidgetEarlierNeedsNoCompensation() {
    let result = WidgetReorder.moving(widgets, id: widgets[2].id, to: 1)

    XCTAssertEqual(names(result), [.cpu, .battery, .memory, .time])
  }

  func testMovingToTheFront() {
    let result = WidgetReorder.moving(widgets, id: widgets[3].id, to: 0)

    XCTAssertEqual(names(result), [.time, .cpu, .memory, .battery])
  }

  func testMovingToTheEnd() {
    let result = WidgetReorder.moving(widgets, id: widgets[0].id, to: widgets.count)

    XCTAssertEqual(names(result), [.memory, .battery, .time, .cpu])
  }

  func testMovingAWidgetOntoItselfChangesNothing() {
    let unchanged = WidgetReorder.moving(widgets, id: widgets[1].id, to: 1)

    XCTAssertEqual(names(unchanged), names(widgets))
  }

  func testMovingAWidgetJustPastItselfChangesNothing() {
    // Dropping into the gap immediately after a widget is the same position it already holds.
    let unchanged = WidgetReorder.moving(widgets, id: widgets[1].id, to: 2)

    XCTAssertEqual(names(unchanged), names(widgets))
  }

  func testAMoveNeverChangesTheNumberOfWidgets() {
    for target in -2...(widgets.count + 2) {
      for widget in widgets {
        let result = WidgetReorder.moving(widgets, id: widget.id, to: target)

        XCTAssertEqual(result.count, widgets.count, "count changed moving to \(target)")
        XCTAssertEqual(
          Set(result.map { $0.id }), Set(widgets.map { $0.id }),
          "a widget was duplicated or lost moving to \(target)")
      }
    }
  }

  func testAnOutOfRangeTargetIsClampedRatherThanTrapping() {
    // The drop index comes from a gesture, so it is not guaranteed to be in range.
    XCTAssertEqual(names(WidgetReorder.moving(widgets, id: widgets[0].id, to: -5)).first, .cpu)
    XCTAssertEqual(names(WidgetReorder.moving(widgets, id: widgets[0].id, to: 99)).last, .cpu)
  }

  func testMovingAWidgetThatIsNotInThisListLeavesItAlone() {
    let result = WidgetReorder.moving(widgets, id: UUID(), to: 0)

    XCTAssertEqual(names(result), names(widgets))
  }

  func testMovingWithinASingleWidgetListIsANoOp() {
    let single = [WidgetInstance(identifier: .cpu)]

    XCTAssertEqual(names(WidgetReorder.moving(single, id: single[0].id, to: 1)), [.cpu])
  }

  // MARK: - Inserting from elsewhere

  func testInsertingPutsTheWidgetExactlyWhereItWasDropped() {
    // Deliberately uncompensated: nothing left this list, so its gaps did not move.
    let added = WidgetInstance(identifier: .wifi)
    let result = WidgetReorder.inserting(added, into: widgets, at: 2)

    XCTAssertEqual(names(result), [.cpu, .memory, .wifi, .battery, .time])
  }

  func testInsertingAtTheEnds() {
    let added = WidgetInstance(identifier: .wifi)

    XCTAssertEqual(names(WidgetReorder.inserting(added, into: widgets, at: 0)).first, .wifi)
    XCTAssertEqual(
      names(WidgetReorder.inserting(added, into: widgets, at: widgets.count)).last, .wifi)
  }

  func testInsertingIntoAnEmptySection() {
    let added = WidgetInstance(identifier: .wifi)

    XCTAssertEqual(names(WidgetReorder.inserting(added, into: [], at: 3)), [.wifi])
  }

  func testAnOutOfRangeInsertIsClampedRatherThanTrapping() {
    let added = WidgetInstance(identifier: .wifi)

    XCTAssertEqual(names(WidgetReorder.inserting(added, into: widgets, at: -5)).first, .wifi)
    XCTAssertEqual(names(WidgetReorder.inserting(added, into: widgets, at: 99)).last, .wifi)
  }

  func testInsertingAlwaysAddsExactlyOne() {
    for target in -2...(widgets.count + 2) {
      let result = WidgetReorder.inserting(
        WidgetInstance(identifier: .wifi), into: widgets, at: target)

      XCTAssertEqual(result.count, widgets.count + 1, "inserting at \(target)")
    }
  }

  // MARK: - A cross-section move is a remove plus an insert

  func testMovingBetweenSectionsKeepsTheWidgetIntact() {
    // The source section drops it, the destination inserts it - the widget's own identity and
    // settings have to survive the trip, or a disabled widget comes back enabled.
    var source = widgets
    let moved = WidgetInstance(identifier: .gpu, enabled: false, showIcon: false)
    source.append(moved)

    source.removeAll { $0.id == moved.id }
    let destination = WidgetReorder.inserting(moved, into: [], at: 0)

    XCTAssertFalse(source.contains { $0.id == moved.id }, "it left the source section")
    XCTAssertEqual(destination.first?.id, moved.id)
    XCTAssertFalse(destination.first?.enabled ?? true, "it is still disabled")
    XCTAssertFalse(destination.first?.showIcon ?? true, "and still icon-less")
  }
}
