import XCTest

/// Exactly one window-manager service polls at a time, it is started once, and it is stopped
/// when - and only when - the user switches away from it.
final class WindowManagerServicesTests: XCTestCase {

  // MARK: - Starting up

  func testTheFirstStartHasNothingToStop() {
    let transition = WindowManagerServices.transition(to: .aerospace, from: nil)

    XCTAssertEqual(transition, .init(start: .aerospace, stop: nil))
  }

  // MARK: - Switching

  func testSwitchingToAerospaceStopsYabai() {
    let transition = WindowManagerServices.transition(to: .aerospace, from: .yabai)

    XCTAssertEqual(transition, .init(start: .aerospace, stop: .yabai))
  }

  func testSwitchingToYabaiStopsAerospace() {
    let transition = WindowManagerServices.transition(to: .yabai, from: .aerospace)

    XCTAssertEqual(transition, .init(start: .yabai, stop: .aerospace))
  }

  func testTheServiceStartedIsAlwaysTheOneTheUserChose() {
    for windowManager in WindowManager.allCases {
      for running in WindowManager.allCases where running != windowManager {
        let transition = WindowManagerServices.transition(to: windowManager, from: running)

        XCTAssertEqual(transition?.start, windowManager, "for \(windowManager.displayName)")
        XCTAssertEqual(
          transition?.stop, running,
          "the service left running is the one that was running, not the one not chosen")
      }
    }
  }

  func testTheWindowManagerBeingSwitchedAwayFromIsNeverLeftRunning() {
    // Both services shell out on a timer. One left polling for a window manager the user no
    // longer uses keeps paying that cost and keeps publishing spaces nothing shows.
    for windowManager in WindowManager.allCases {
      for running in WindowManager.allCases {
        let transition = WindowManagerServices.transition(to: windowManager, from: running)

        XCTAssertFalse(
          running != windowManager && transition?.stop == nil,
          "\(running.displayName) would keep running under \(windowManager.displayName)")
      }
    }
  }

  // MARK: - An unrelated settings change

  func testSavingAnUnrelatedSettingDoesNotRestartTheService() {
    // Every settings change arrives here, not just a change of window manager. Restarting on
    // each one meant AerospaceService.start() re-registering its six NSWorkspace observers
    // without dropping the previous set, so every save added another round of
    // `aerospace list-windows` to every app switch for the rest of the session.
    for windowManager in WindowManager.allCases {
      XCTAssertNil(
        WindowManagerServices.transition(to: windowManager, from: windowManager),
        "\(windowManager.displayName) is already running; there is nothing to do")
    }
  }

  func testAServiceIsNotStartedTwiceOverASequenceOfSaves() {
    var running: WindowManager?
    var started: [WindowManager] = []
    var stopped: [WindowManager] = []

    // Launch, three unrelated saves, a switch, three more saves.
    for chosen: WindowManager in [.aerospace, .aerospace, .aerospace, .aerospace, .yabai, .yabai, .yabai, .yabai] {
      guard let transition = WindowManagerServices.transition(to: chosen, from: running) else {
        continue
      }
      if let stop = transition.stop { stopped.append(stop) }
      started.append(transition.start)
      running = transition.start
    }

    XCTAssertEqual(started, [.aerospace, .yabai], "each service should be started exactly once")
    XCTAssertEqual(stopped, [.aerospace], "and stopped only when it was switched away from")
  }
}
