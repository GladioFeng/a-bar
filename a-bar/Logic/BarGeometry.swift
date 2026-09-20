import CoreGraphics
import Foundation

/// Where the bar sits on a screen.
enum BarGeometry {

  /// The bar's frame, inset from the edges of its screen.
  ///
  /// The width used to be `screenFrame.width - inset * 2` with nothing stopping it going
  /// negative, which an inset past half the screen width would do - and a window with a negative
  /// width cannot be seen, so it cannot be fixed from the bar itself either.
  static func barFrame(
    screenFrame: CGRect, height: CGFloat, inset: CGFloat, position: BarPosition
  ) -> CGRect {
    let inset = max(0, inset)
    let height = max(0, height)

    let y: CGFloat
    switch position {
    case .top: y = screenFrame.maxY - height - inset
    case .bottom: y = screenFrame.minY + inset
    }

    return CGRect(
      x: screenFrame.minX + inset,
      y: y,
      width: max(0, screenFrame.width - (inset * 2)),
      height: height)
  }
}
