import XCTest

/// The bar must land on the screen it belongs to, for every combination of edge, inset and
/// screen size a user can produce from Settings or by hand-editing the config.
final class BarGeometryTests: XCTestCase {

  private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

  // MARK: - Where the bar sits

  func testATopBarHangsFromTheTopEdge() {
    let frame = BarGeometry.barFrame(screenFrame: screen, height: 34, inset: 0, position: .top)

    XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.01)
    XCTAssertEqual(frame.height, 34, accuracy: 0.01)
  }

  func testABottomBarSitsOnTheBottomEdge() {
    let frame = BarGeometry.barFrame(screenFrame: screen, height: 34, inset: 0, position: .bottom)

    XCTAssertEqual(frame.minY, screen.minY, accuracy: 0.01)
  }

  func testTheInsetPullsTheBarInFromEveryEdgeItTouches() {
    let frame = BarGeometry.barFrame(screenFrame: screen, height: 34, inset: 10, position: .top)

    XCTAssertEqual(frame.minX, 10, accuracy: 0.01)
    XCTAssertEqual(frame.width, 1420, accuracy: 0.01, "inset from both sides")
    XCTAssertEqual(frame.maxY, screen.maxY - 10, accuracy: 0.01)
  }

  func testABottomBarIsInsetUpwards() {
    let frame = BarGeometry.barFrame(screenFrame: screen, height: 34, inset: 10, position: .bottom)

    XCTAssertEqual(frame.minY, 10, accuracy: 0.01)
  }

  // MARK: - A screen that does not start at the origin

  func testASecondDisplayIsPositionedInItsOwnCoordinates() {
    // Screens to the right of, or above, the main display have a non-zero origin - and one to
    // the left has a negative one.
    let external = CGRect(x: 1440, y: 200, width: 2560, height: 1440)

    let frame = BarGeometry.barFrame(screenFrame: external, height: 34, inset: 0, position: .top)

    XCTAssertEqual(frame.minX, 1440, accuracy: 0.01)
    XCTAssertEqual(frame.maxY, 1640, accuracy: 0.01)
  }

  func testADisplayLeftOfTheMainOneIsHandled() {
    let external = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

    let frame = BarGeometry.barFrame(screenFrame: external, height: 34, inset: 8, position: .bottom)

    XCTAssertEqual(frame.minX, -1912, accuracy: 0.01)
    XCTAssertEqual(frame.minY, 8, accuracy: 0.01)
  }

  // MARK: - Values a user can reach but should not be hurt by

  func testAnInsetPastHalfTheScreenCannotProduceANegativeWidth() {
    // regression: the width was `screenFrame.width - inset * 2` with nothing to stop it going
    // below zero. A window with a negative width cannot be seen - and so cannot be used to open
    // Settings and undo the change that hid it.
    let narrow = CGRect(x: 0, y: 0, width: 100, height: 900)

    let frame = BarGeometry.barFrame(screenFrame: narrow, height: 34, inset: 200, position: .top)

    XCTAssertGreaterThanOrEqual(frame.width, 0, "a negative width is an invisible window")
  }

  func testANegativeInsetIsTreatedAsNone() {
    let frame = BarGeometry.barFrame(screenFrame: screen, height: 34, inset: -20, position: .top)

    XCTAssertEqual(frame.minX, 0, accuracy: 0.01, "the bar does not hang off the screen")
    XCTAssertEqual(frame.width, 1440, accuracy: 0.01)
  }

  func testANegativeHeightIsTreatedAsNone() {
    let frame = BarGeometry.barFrame(screenFrame: screen, height: -10, inset: 0, position: .top)

    XCTAssertGreaterThanOrEqual(frame.height, 0)
  }

  func testTheBarNeverLeavesItsScreen() {
    // The property all of the above add up to, swept over the range Settings allows.
    for inset in stride(from: 0.0, through: 50, by: 5) {
      for height in stride(from: 10.0, through: 100, by: 10) {
        for position in BarPosition.allCases {
          let frame = BarGeometry.barFrame(
            screenFrame: screen, height: height, inset: inset, position: position)

          XCTAssertGreaterThanOrEqual(frame.minX, screen.minX, "inset \(inset)")
          XCTAssertLessThanOrEqual(frame.maxX, screen.maxX, "inset \(inset)")
          XCTAssertGreaterThanOrEqual(frame.minY, screen.minY, "height \(height)")
          XCTAssertLessThanOrEqual(frame.maxY, screen.maxY, "height \(height)")
        }
      }
    }
  }
}
