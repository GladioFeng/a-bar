import Foundation

/// Identifies a bar window by the display it belongs to and the edge it sits against.
struct BarWindowKey: Hashable {
  let displayIndex: Int
  let position: BarPosition
}

/// Which bars exist, for the screens attached right now.
///
/// Displays come and go - a laptop lid closes, a dock is unplugged - while the layout the user
/// configured stays as it was. So the layout is a wish and the screen count is the constraint:
/// a display the user configured but is no longer attached gets no bar, and a display that is
/// attached but never configured gets none either.
enum BarWindowPlan {

  /// The bars to open, in creation order: each attached display in index order, top before
  /// bottom.
  static func windows(
    screenCount: Int, layout: MultiDisplayLayout, barEnabled: Bool
  ) -> [BarWindowKey] {
    guard barEnabled else { return [] }

    return (0..<max(0, screenCount)).flatMap { index -> [BarWindowKey] in
      guard let display = layout.configuration(forDisplay: index) else { return [] }
      return [
        display.topBar.map { _ in BarWindowKey(displayIndex: index, position: .top) },
        display.bottomBar.map { _ in BarWindowKey(displayIndex: index, position: .bottom) },
      ].compactMap { $0 }
    }
  }

  /// The widgets actually on screen, which is what decides whether a sampler runs at all.
  /// Hidden widgets must not poll or initialize blocking hardware APIs, and a bar switched off
  /// hides all of them however the layout is configured.
  static func visibleWidgets(
    screenCount: Int, layout: MultiDisplayLayout, barEnabled: Bool
  ) -> Set<WidgetIdentifier> {
    barEnabled ? layout.enabledWidgets(displayCount: screenCount) : []
  }
}
