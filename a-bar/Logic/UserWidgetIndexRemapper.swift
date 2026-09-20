import Foundation

/// Keeping placed custom widgets pointing at the script they were placed for.
///
/// A `WidgetInstance` refers to a custom widget by its *position* in `userWidgets`, so deleting
/// or reordering that list silently repoints every instance after the change. The failure is
/// invisible: the bar keeps rendering, but a widget now runs somebody else's script.
enum UserWidgetIndexRemapper {

  // MARK: - One section

  /// Drop instances of the deleted widget and shift the ones that pointed past it.
  static func removing(_ removedIndex: Int, from widgets: [WidgetInstance]) -> [WidgetInstance] {
    widgets.compactMap { widget in
      guard widget.identifier == .userWidget, let index = widget.userWidgetIndex else {
        return widget
      }
      if index == removedIndex { return nil }
      guard index > removedIndex else { return widget }

      var updated = widget
      updated.userWidgetIndex = index - 1
      return updated
    }
  }

  /// Repoint instances after the custom widget list has been reordered.
  static func remapping(
    _ oldToNew: [Int: Int], in widgets: [WidgetInstance]
  ) -> [WidgetInstance] {
    widgets.map { widget in
      guard widget.identifier == .userWidget,
        let oldIndex = widget.userWidgetIndex,
        let newIndex = oldToNew[oldIndex]
      else {
        return widget
      }
      var updated = widget
      updated.userWidgetIndex = newIndex
      return updated
    }
  }

  // MARK: - Every bar on every display

  static func removing(_ removedIndex: Int, from layout: MultiDisplayLayout) -> MultiDisplayLayout {
    mapAllSections(of: layout) { removing(removedIndex, from: $0) }
  }

  static func remapping(
    _ oldToNew: [Int: Int], in layout: MultiDisplayLayout
  ) -> MultiDisplayLayout {
    mapAllSections(of: layout) { remapping(oldToNew, in: $0) }
  }

  /// Applies a section transform to every section of every bar, so a new bar or section cannot
  /// be forgotten by one of the two callers above.
  private static func mapAllSections(
    of layout: MultiDisplayLayout, _ transform: ([WidgetInstance]) -> [WidgetInstance]
  ) -> MultiDisplayLayout {
    var layout = layout

    for displayIndex in layout.displays.indices {
      for position in BarPosition.allCases {
        var bar: SingleBarLayout?
        switch position {
        case .top: bar = layout.displays[displayIndex].topBar
        case .bottom: bar = layout.displays[displayIndex].bottomBar
        }
        guard var bar else { continue }

        bar.left = transform(bar.left)
        bar.center = transform(bar.center)
        bar.right = transform(bar.right)

        switch position {
        case .top: layout.displays[displayIndex].topBar = bar
        case .bottom: layout.displays[displayIndex].bottomBar = bar
        }
      }
    }

    return layout
  }
}
