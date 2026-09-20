import Foundation

/// Moving widgets within and between the sections of a bar.
///
/// Dropping is the one place in the settings UI where a widget can be duplicated or lost by an
/// arithmetic slip, because the index the drop reports is measured against the list *before*
/// the dragged widget is taken out of it.
enum WidgetReorder {

  /// Move a widget already in this list to a new position.
  ///
  /// `insertAt` is a gap index in the list as the user sees it, so when the widget is moving
  /// down, removing it first shifts every later gap one to the left and the target has to be
  /// compensated. Moving up needs no compensation, because the gaps before the widget do not
  /// move. Getting this wrong puts the widget one slot past where it was dropped.
  static func moving(_ widgets: [WidgetInstance], id: UUID, to insertAt: Int) -> [WidgetInstance] {
    guard let currentIndex = widgets.firstIndex(where: { $0.id == id }) else { return widgets }

    var result = widgets
    let moved = result.remove(at: currentIndex)
    let compensated = insertAt > currentIndex ? insertAt - 1 : insertAt
    result.insert(moved, at: min(max(0, compensated), result.count))
    return result
  }

  /// Add a widget that is not in this list yet - from the palette, or from another section.
  ///
  /// Deliberately without the compensation above: nothing is being removed from this list, so
  /// its gaps are exactly where the drop said they were.
  static func inserting(
    _ widget: WidgetInstance, into widgets: [WidgetInstance], at insertAt: Int
  ) -> [WidgetInstance] {
    var result = widgets
    result.insert(widget, at: min(max(0, insertAt), result.count))
    return result
  }
}
