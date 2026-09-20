import XCTest

/// When macOS refuses the change, the app must ask again next time rather than believe it
/// succeeded - and when macOS and the stored setting disagree at launch, macOS wins.
final class LaunchAtLoginReconcilerTests: XCTestCase {

  /// `SMAppService` throws for an app outside /Applications, among other reasons.
  private struct Refused: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
  }

  /// Records what the login-item backend was asked to do, and optionally refuses.
  private final class Backend {
    private(set) var asked: [Bool] = []
    var refuses = false

    func setEnabled(_ enabled: Bool) throws {
      asked.append(enabled)
      if refuses { throw Refused() }
    }
  }

  // MARK: - Asking only when it matters

  func testTheFirstRequestOfASessionIsAlwaysPassedOn() {
    let backend = Backend()

    // Nothing has been applied yet, so nothing is known - even a request matching what macOS
    // probably already has must go through.
    let outcome = LaunchAtLoginReconciler.apply(
      true, lastApplied: nil, setEnabled: backend.setEnabled)

    XCTAssertEqual(outcome, .applied(true))
    XCTAssertEqual(backend.asked, [true], "the login item should have been registered once")
  }

  func testAnUnrelatedSettingsSaveDoesNotTouchTheLoginItem() {
    let backend = Backend()

    // Every settings change arrives here, not just a change to this toggle. Reacting to all of
    // them is what used to unregister the login item the moment any other setting was saved.
    let outcome = LaunchAtLoginReconciler.apply(
      true, lastApplied: true, setEnabled: backend.setEnabled)

    XCTAssertEqual(outcome, .unchanged(true))
    XCTAssertEqual(backend.asked, [], "macOS should not have been asked anything")
  }

  func testTurningTheToggleOffIsPassedOn() {
    let backend = Backend()

    let outcome = LaunchAtLoginReconciler.apply(
      false, lastApplied: true, setEnabled: backend.setEnabled)

    XCTAssertEqual(outcome, .applied(false))
    XCTAssertEqual(backend.asked, [false])
  }

  // MARK: - A refusal is not a result

  func testARefusalIsRememberedAsNotKnowing() {
    let backend = Backend()
    backend.refuses = true

    let outcome = LaunchAtLoginReconciler.apply(
      true, lastApplied: false, setEnabled: backend.setEnabled)

    XCTAssertEqual(outcome, .failed(true, message: "Operation not permitted"))
    XCTAssertNil(
      outcome.lastApplied,
      "a refused change leaves the login item in an unknown state, not in the requested one")
  }

  func testTheSameValueIsTriedAgainAfterARefusal() {
    let backend = Backend()
    backend.refuses = true

    // The historical bug: the cache was set to the requested value before the call, so a
    // failure left the app believing a registration that never happened, and every later
    // request for the same value was skipped as redundant. Hence the reset to nil.
    let first = LaunchAtLoginReconciler.apply(
      true, lastApplied: false, setEnabled: backend.setEnabled)

    backend.refuses = false
    let second = LaunchAtLoginReconciler.apply(
      true, lastApplied: first.lastApplied, setEnabled: backend.setEnabled)

    XCTAssertEqual(second, .applied(true), "the second attempt must reach macOS")
    XCTAssertEqual(backend.asked, [true, true])
  }

  func testASucceededChangeIsRememberedSoItIsNotRepeated() {
    let backend = Backend()

    let first = LaunchAtLoginReconciler.apply(
      true, lastApplied: nil, setEnabled: backend.setEnabled)
    let second = LaunchAtLoginReconciler.apply(
      true, lastApplied: first.lastApplied, setEnabled: backend.setEnabled)

    XCTAssertEqual(second, .unchanged(true))
    XCTAssertEqual(backend.asked, [true], "the second request should have been skipped")
  }

  // MARK: - Adopting what macOS reports at launch

  func testAnAgreeingSettingIsLeftAlone() {
    let adoption = LaunchAtLoginReconciler.adopt(registered: true, stored: true)

    XCTAssertEqual(adoption, .init(lastApplied: true, settingToWrite: nil))
  }

  func testALoginItemRemovedInSystemSettingsTurnsTheStoredToggleOff() {
    // The user can remove the login item without the app hearing about it. Forcing the stored
    // value back on would re-register something they just removed.
    let adoption = LaunchAtLoginReconciler.adopt(registered: false, stored: true)

    XCTAssertEqual(adoption.lastApplied, false, "macOS is the truth, the setting is the guess")
    XCTAssertEqual(adoption.settingToWrite, false, "the toggle must stop showing as on")
  }

  func testALoginItemAddedOutsideTheAppTurnsTheStoredToggleOn() {
    let adoption = LaunchAtLoginReconciler.adopt(registered: true, stored: false)

    XCTAssertEqual(adoption, .init(lastApplied: true, settingToWrite: true))
  }

  func testAdoptingNeverLeavesTheSessionWithoutABaseline() {
    // Whatever it decides about the setting, adoption always produces a known value to compare
    // later requests against - otherwise the first settings save of the session re-applies.
    for registered in [true, false] {
      for stored in [true, false] {
        let adoption = LaunchAtLoginReconciler.adopt(registered: registered, stored: stored)
        XCTAssertEqual(adoption.lastApplied, registered)
      }
    }
  }
}
