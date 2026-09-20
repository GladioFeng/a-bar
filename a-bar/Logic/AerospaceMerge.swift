import Foundation

/// Joining AeroSpace's four separate queries into one state.
///
/// `aerospace` answers workspaces, windows and the focused window in three commands that know
/// nothing about each other, so the join - which window belongs to which workspace, and which one
/// has focus - happens here. It used to be a loop in the middle of `refreshAll`, between the
/// shell calls and the main-actor hop, where nothing could reach it.
enum AerospaceMerge {

  /// Give each workspace its windows, and mark the focused one.
  ///
  /// A window naming a workspace that is not in the list is dropped rather than collected
  /// anywhere: `--all` can list a window on a workspace that was destroyed between the two calls.
  static func merge(
    workspaces: [AerospaceWorkspace],
    windows: [AerospaceWindow],
    focusedWindowId: Int?
  ) -> [AerospaceWorkspace] {
    var byWorkspace: [String: [AerospaceWindow]] = [:]
    for window in windows {
      var window = window
      // Comparing `Int` to `Int?`: with nothing focused this is false for every window, which is
      // what an unfocused desktop should look like.
      window.isFocused = window.windowId == focusedWindowId
      byWorkspace[window.workspace, default: []].append(window)
    }

    return workspaces.map { workspace in
      var workspace = workspace
      workspace.windows = byWorkspace[workspace.workspace] ?? []
      return workspace
    }
  }
}
