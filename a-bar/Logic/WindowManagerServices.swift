import Foundation

/// Which window-manager service feeds the bar.
enum WindowManagerServices {

  /// The service to start, and the one that has to be stopped to make room for it.
  struct Transition: Equatable {
    let start: WindowManager
    /// The service that was running and must be stopped first, or `nil` at launch when
    /// nothing was running yet.
    let stop: WindowManager?
  }

  /// What to do about a chosen window manager, given the one already running.
  ///
  /// Only one window manager drives the bar at a time, so switching has to stop the other:
  /// both services shell out on a timer, and one left running for a window manager the user no
  /// longer uses keeps paying that cost.
  ///
  /// But the choice arrives on *every* settings change, not only when it changed - the same
  /// shape of bug as the login item, and with the same fix. Restarting on each save meant
  /// `AerospaceService.start()` re-registering its six `NSWorkspace` observers without ever
  /// dropping the previous set, so every settings save permanently added another round of
  /// `aerospace list-windows` to every app switch for the rest of the session.
  static func transition(to windowManager: WindowManager, from running: WindowManager?)
    -> Transition?
  {
    guard running != windowManager else { return nil }
    return Transition(start: windowManager, stop: running)
  }
}
