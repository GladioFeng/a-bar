import XCTest

/// A graph widget samples forever, so its history is a fixed-size window. It must drop the
/// oldest sample rather than grow, and must never hand the renderer a ceiling of zero.
final class GraphHistoryTests: XCTestCase {

  // MARK: - The window never grows

  func testSamplesAccumulateUntilTheWindowIsFull() {
    var history = GraphHistory(maxLength: 3)

    history.add(1)
    history.add(2)

    XCTAssertEqual(history.values, [1, 2])
  }

  func testTheOldestSampleIsEvictedOnceTheWindowIsFull() {
    var history = GraphHistory(maxLength: 3)

    for value in [1.0, 2.0, 3.0, 4.0] { history.add(value) }

    XCTAssertEqual(history.values, [2, 3, 4], "the front is dropped, not the back")
    XCTAssertEqual(history.dataPoints.count, 3, "the window does not grow")
  }

  func testTheWindowHoldsAtItsLimitAcrossManySamples() {
    // The widget runs for hours; an off-by-one here is a slow leak rather than a crash.
    var history = GraphHistory(maxLength: 50)

    for value in 1...500 { history.add(Double(value)) }

    XCTAssertEqual(history.dataPoints.count, 50)
    XCTAssertEqual(history.values.first, 451)
    XCTAssertEqual(history.values.last, 500, "the newest sample is always kept")
  }

  func testAWindowOfOneKeepsOnlyTheLatestSample() {
    var history = GraphHistory(maxLength: 1)

    history.add(10)
    history.add(20)

    XCTAssertEqual(history.values, [20])
  }

  func testClearingEmptiesTheWindow() {
    var history = GraphHistory(maxLength: 5)
    history.add(1)

    history.clear()

    XCTAssertEqual(history.values, [])
  }

  // MARK: - The ceiling the renderer scales against

  func testAnEmptyHistoryReportsAUsableCeiling() {
    // `maxValue` is the divisor the graph scales by; zero would make every point NaN.
    XCTAssertEqual(GraphHistory().maxValue, 100, "an empty graph still needs a scale")
  }

  func testTheCeilingIsTheLargestSampleInTheWindow() {
    var history = GraphHistory(maxLength: 5)

    for value in [12.0, 87.0, 3.0] { history.add(value) }

    XCTAssertEqual(history.maxValue, 87)
  }

  func testTheCeilingFollowsTheWindowRatherThanAllTimeHistory() {
    // A spike that has scrolled off the window must stop compressing the graph.
    var history = GraphHistory(maxLength: 2)

    history.add(1000)
    history.add(10)
    history.add(20)

    XCTAssertEqual(history.maxValue, 20, "the spike scrolled out of the window")
  }

  func testSamplesOfZeroStillCountAsSamples() {
    var history = GraphHistory(maxLength: 3)

    history.add(0)

    XCTAssertEqual(history.values, [0])
    XCTAssertEqual(history.maxValue, 0, "an idle graph reports its real ceiling, not the default")
  }
}
