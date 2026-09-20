import CoreGraphics
import Foundation

/// Turning a series of samples into something drawable.
///
/// The same loop used to be written twice in `GraphView` - once for the filled area and once for
/// the line - so the two could drift, and neither had an answer for a graph with no range, one
/// sample, or a sample above its own ceiling.
enum GraphGeometry {

  /// One point per sample, left to right, with the value measured up from the bottom.
  ///
  /// `maxValue` is the ceiling the graph scales against. An idle graph reports a ceiling of zero,
  /// which would divide every point into NaN and draw nothing at all, so it is floored. A sample
  /// above the ceiling is clamped rather than drawn off the top: the callers disagree about what
  /// the ceiling is - the CPU and GPU graphs pass a literal 100 while the network and disk graphs
  /// scale to the tallest sample - so an overshoot is a real case, not a rounding error.
  static func points(values: [Double], maxValue: Double, size: CGSize) -> [CGPoint] {
    guard !values.isEmpty else { return [] }

    let ceiling = maxValue > 0 ? maxValue : 1
    let stepX = size.width / CGFloat(max(1, values.count - 1))

    return values.enumerated().map { index, value in
      let fraction = min(max(value / ceiling, 0), 1)
      return CGPoint(
        x: CGFloat(index) * stepX,
        y: size.height - (CGFloat(fraction) * size.height))
    }
  }

  /// The radius of the pie, inset by a point so its stroke is not clipped.
  static func pieRadius(in size: CGSize) -> CGFloat {
    max(0, min(size.width, size.height) / 2 - 1)
  }

  /// Where the filled arc ends, starting from the top and going clockwise.
  static func pieEndAngleDegrees(usedPercentage: Double) -> Double {
    let fraction = min(max(usedPercentage, 0), 100) / 100
    return -90 + (fraction * 360)
  }
}
