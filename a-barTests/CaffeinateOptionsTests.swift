import XCTest

/// The caffeinate option is free text in the config file. Whatever is in there, the flags handed
/// to `caffeinate` must hold something awake - launching it with no flags at all holds nothing,
/// and the user would see the widget lit while the Mac slept anyway.
final class CaffeinateOptionsTests: XCTestCase {

  // MARK: - The names the settings UI offers

  func testEachNamedOptionMapsToItsFlag() {
    XCTAssertEqual(CaffeinateOptions.arguments(for: "systemsleep"), ["-s"])
    XCTAssertEqual(CaffeinateOptions.arguments(for: "displaysleep"), ["-d"])
    XCTAssertEqual(CaffeinateOptions.arguments(for: "idlesleep"), ["-i"])
    XCTAssertEqual(CaffeinateOptions.arguments(for: "user"), ["-u"])
    XCTAssertEqual(CaffeinateOptions.arguments(for: "displayidle"), ["-di"])
    XCTAssertEqual(CaffeinateOptions.arguments(for: "all"), ["-dimu"])
  }

  func testANameIsReadWhateverItsCaseOrSurroundingSpace() {
    XCTAssertEqual(CaffeinateOptions.arguments(for: "  DisplaySleep \n"), ["-d"])
    XCTAssertEqual(CaffeinateOptions.arguments(for: "ALL"), ["-dimu"])
  }

  // MARK: - Anything else in the file

  func testAnEmptyOrBlankOptionFallsBackToTheDefault() {
    XCTAssertEqual(CaffeinateOptions.arguments(for: ""), ["-di"])
    XCTAssertEqual(CaffeinateOptions.arguments(for: "   "), ["-di"])
  }

  func testARawFlagIsPassedThrough() {
    // Someone reading the caffeinate man page and typing the flag directly gets what they asked
    // for, including combinations the settings UI never offers.
    XCTAssertEqual(CaffeinateOptions.arguments(for: "-w 500"), ["-w 500"])
    XCTAssertEqual(CaffeinateOptions.arguments(for: "  -m  "), ["-m"])
  }

  func testATypoFallsBackToTheDefaultRatherThanToNothing() {
    // The failure that matters: an empty argument list launches caffeinate holding nothing awake,
    // so the bar shows the widget active while the Mac sleeps regardless.
    for typo in ["displaysleeep", "sleep", "yes", "true"] {
      XCTAssertEqual(
        CaffeinateOptions.arguments(for: typo), ["-di"],
        "\(typo) must not produce an empty argument list")
    }
  }

  func testNoOptionEverProducesAnEmptyArgumentList() {
    for option in ["", " ", "-", "--", "nonsense", "ALL", "user", "\n\t"] {
      XCTAssertFalse(
        CaffeinateOptions.arguments(for: option).isEmpty,
        "\(option.debugDescription) produced no flags")
    }
  }
}
