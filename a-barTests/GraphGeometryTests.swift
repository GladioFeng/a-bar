import XCTest

/// A graph with no range, one sample, or a sample above its own ceiling must still produce
/// points that can be drawn. Each of those used to be answered by accident rather than on purpose.
final class GraphGeometryTests: XCTestCase {

  private let size = CGSize(width: 100, height: 50)

  // MARK: - Laying samples out

  func testSamplesAreSpreadAcrossTheFullWidth() {
    let points = GraphGeometry.points(values: [0, 50, 100], maxValue: 100, size: size)

    XCTAssertEqual(points.count, 3)
    XCTAssertEqual(points[0].x, 0, accuracy: 0.01, "the first sample sits on the left edge")
    XCTAssertEqual(points[1].x, 50, accuracy: 0.01)
    XCTAssertEqual(points[2].x, 100, accuracy: 0.01, "the last sits on the right edge")
  }

  func testValueIsMeasuredUpwardsFromTheBottom() {
    // Screen coordinates run downwards, so a full-scale sample is at y = 0.
    let points = GraphGeometry.points(values: [0, 50, 100], maxValue: 100, size: size)

    XCTAssertEqual(points[0].y, 50, accuracy: 0.01, "zero sits on the bottom edge")
    XCTAssertEqual(points[1].y, 25, accuracy: 0.01)
    XCTAssertEqual(points[2].y, 0, accuracy: 0.01, "full scale reaches the top")
  }

  func testAnEmptySeriesDrawsNothing() {
    XCTAssertEqual(GraphGeometry.points(values: [], maxValue: 100, size: size), [])
  }

  func testASingleSampleProducesOnePoint() {
    let points = GraphGeometry.points(values: [50], maxValue: 100, size: size)

    XCTAssertEqual(points.count, 1)
    XCTAssertEqual(points[0].x, 0, accuracy: 0.01)
    XCTAssertEqual(points[0].y, 25, accuracy: 0.01)
  }

  // MARK: - The cases that used to be undefined

  func testAnIdleGraphDrawsAFlatLineRatherThanNothing() {
    // `GraphHistory.maxValue` reports 0 for an all-zero window. Dividing by it produced NaN,
    // and a path of NaN points draws nothing at all - the graph silently disappeared.
    let points = GraphGeometry.points(values: [0, 0, 0], maxValue: 0, size: size)

    XCTAssertEqual(points.count, 3)
    for point in points {
      XCTAssertFalse(point.y.isNaN, "a NaN point draws nothing")
      XCTAssertEqual(point.y, 50, accuracy: 0.01, "an idle graph sits on the floor")
    }
  }

  func testANegativeCeilingIsTreatedAsNoCeiling() {
    let points = GraphGeometry.points(values: [1], maxValue: -5, size: size)

    XCTAssertFalse(points[0].y.isNaN)
  }

  func testASampleAboveTheCeilingIsClampedToTheTop() {
    // The CPU and GPU graphs pass a fixed ceiling of 100, so a transient reading above it is a
    // real case. It used to be drawn above the frame and left to `.clipped()` to hide.
    let points = GraphGeometry.points(values: [150], maxValue: 100, size: size)

    XCTAssertEqual(points[0].y, 0, accuracy: 0.01, "it sits on the top edge, not above it")
    XCTAssertGreaterThanOrEqual(points[0].y, 0)
  }

  func testANegativeSampleIsClampedToTheFloor() {
    let points = GraphGeometry.points(values: [-10], maxValue: 100, size: size)

    XCTAssertEqual(points[0].y, 50, accuracy: 0.01)
  }

  func testEveryPointStaysInsideTheFrame() {
    // The property all of the above add up to.
    let values = [-50.0, 0, 1, 99, 100, 250]

    for ceiling in [0.0, 1, 100] {
      let points = GraphGeometry.points(values: values, maxValue: ceiling, size: size)

      for point in points {
        XCTAssertTrue((0...size.height).contains(point.y), "y \(point.y) at ceiling \(ceiling)")
        XCTAssertTrue((0...size.width).contains(point.x), "x \(point.x)")
      }
    }
  }

  func testAZeroSizedGraphDoesNotTrap() {
    let points = GraphGeometry.points(values: [1, 2], maxValue: 2, size: .zero)

    XCTAssertEqual(points.count, 2)
    for point in points {
      XCTAssertFalse(point.x.isNaN)
      XCTAssertFalse(point.y.isNaN)
    }
  }

  // MARK: - The pie

  func testThePieFitsInsideItsFrame() {
    XCTAssertEqual(GraphGeometry.pieRadius(in: CGSize(width: 20, height: 20)), 9, accuracy: 0.01)
    XCTAssertEqual(
      GraphGeometry.pieRadius(in: CGSize(width: 40, height: 20)), 9, accuracy: 0.01,
      "the shorter side decides")
  }

  func testATinyPieHasNoNegativeRadius() {
    // A radius below zero is not a smaller circle, it is an invalid path.
    XCTAssertEqual(GraphGeometry.pieRadius(in: CGSize(width: 1, height: 1)), 0, accuracy: 0.01)
    XCTAssertEqual(GraphGeometry.pieRadius(in: .zero), 0, accuracy: 0.01)
  }

  func testTheArcStartsAtTheTopAndSweepsClockwise() {
    XCTAssertEqual(GraphGeometry.pieEndAngleDegrees(usedPercentage: 0), -90, accuracy: 0.01)
    XCTAssertEqual(GraphGeometry.pieEndAngleDegrees(usedPercentage: 25), 0, accuracy: 0.01)
    XCTAssertEqual(GraphGeometry.pieEndAngleDegrees(usedPercentage: 50), 90, accuracy: 0.01)
    XCTAssertEqual(GraphGeometry.pieEndAngleDegrees(usedPercentage: 100), 270, accuracy: 0.01)
  }

  func testAPercentageOutsideTheScaleCannotOverdrawTheCircle() {
    XCTAssertEqual(GraphGeometry.pieEndAngleDegrees(usedPercentage: 150), 270, accuracy: 0.01)
    XCTAssertEqual(GraphGeometry.pieEndAngleDegrees(usedPercentage: -20), -90, accuracy: 0.01)
  }
}
