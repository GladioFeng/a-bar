import SwiftUI
import XCTest

/// Every number and name the bar puts on screen passes through one of these. They are pure
/// string work with no failure mode louder than a wrong label, so the boundaries are pinned.
final class FormattingTests: XCTestCase {

  private func components(_ color: Color) -> [CGFloat] {
    NSColor(color).cgColor.components ?? []
  }

  // MARK: - Transfer rates change unit at 1024, not 1000

  func testRatesBelowAKilobyteAreWholeBytes() {
    XCTAssertEqual((0.0).formattedTransferRate(), "0B/s")
    XCTAssertEqual((512.0).formattedTransferRate(), "512B/s")
    XCTAssertEqual((1023.0).formattedTransferRate(), "1023B/s")
  }

  func testTheUnitChangesAtEachPowerOfTwoBoundary() {
    XCTAssertEqual((1024.0).formattedTransferRate(), "1.0K/s")
    XCTAssertEqual((1024.0 * 1024).formattedTransferRate(), "1.0M/s")
    XCTAssertEqual((1024.0 * 1024 * 1024).formattedTransferRate(), "1.0G/s")
  }

  func testJustUnderABoundaryStaysInTheSmallerUnit() {
    // Rounding to one decimal makes this read "1024.0K/s" rather than "1.0M/s" for one byte's
    // worth of traffic. Pinned as-is: it is the smaller unit, which is what the branch asked for.
    XCTAssertEqual((1024.0 * 1024 - 1).formattedTransferRate(), "1024.0K/s")
  }

  func testUnitsCanBeSpacedForTheWiderWidgets() {
    XCTAssertEqual((1024.0).formattedTransferRate(spacedUnits: true), "1.0 K/s")
    XCTAssertEqual((100.0).formattedTransferRate(spacedUnits: true), "100 B/s")
  }

  func testAVeryLargeRateStaysInGigabytes() {
    XCTAssertTrue((1024.0 * 1024 * 1024 * 50).formattedTransferRate().hasSuffix("G/s"))
  }

  // MARK: - Truncation is by character count

  func testAStringShorterThanTheLimitIsUntouched() {
    XCTAssertEqual("Safari".truncated(to: 10), "Safari")
  }

  func testAStringExactlyAtTheLimitIsUntouched() {
    // The comparison is `>`, so the limit is inclusive - a 6-character name at 6 keeps its tail.
    XCTAssertEqual("Safari".truncated(to: 6), "Safari")
  }

  func testALongerStringIsCutAndMarked() {
    XCTAssertEqual("Safari".truncated(to: 4), "Safa…")
  }

  func testTheTrailingMarkerCanBeReplaced() {
    XCTAssertEqual("Safari".truncated(to: 4, trailing: "..."), "Safa...")
  }

  func testTruncationCountsCharactersNotBytes() {
    // An emoji is one character; cutting by bytes would split it into replacement characters.
    XCTAssertEqual("🎵🎵🎵".truncated(to: 2), "🎵🎵…")
  }

  // MARK: - Exclusion patterns match anywhere in the string

  func testAPatternMatchesAsASubstringNotAsAWholeString() {
    // This is the contract users are actually typing against. "afa" hides Safari, and a pattern
    // meant to hide one app can hide another that merely contains it. Anchor with ^...$ to
    // match the whole name.
    XCTAssertTrue("Safari".matches(pattern: "afa"), "the pattern is not anchored")
    XCTAssertTrue("Safari".matches(pattern: "^Safari$"), "anchoring is how you get exact")
    XCTAssertFalse("Safari".matches(pattern: "^afa$"))
  }

  func testRegexSyntaxIsHonoured() {
    XCTAssertTrue("Safari".matches(pattern: "S.f.ri"))
    XCTAssertTrue("Google Chrome".matches(pattern: "Chrome|Firefox"))
    XCTAssertFalse("Notes".matches(pattern: "Chrome|Firefox"))
  }

  func testMatchingIsCaseSensitive() {
    XCTAssertFalse("Safari".matches(pattern: "safari"), "a lowercase pattern misses the app")
  }

  func testAnInvalidPatternSimplyDoesNotMatch() {
    // A half-typed pattern in Settings must not throw while the user is still typing it.
    XCTAssertFalse("Safari".matches(pattern: "[unclosed"))
  }

  // MARK: - Progress through the day

  func testMiddayIsHalfwayThroughTheDay() {
    var components = DateComponents()
    components.year = 2026
    components.month = 6
    components.day = 15
    components.hour = 12
    let noon = Calendar.current.date(from: components)!

    XCTAssertEqual(noon.dayProgress, 0.5, accuracy: 0.001)
  }

  func testMidnightIsTheStartOfTheDay() {
    var components = DateComponents()
    components.year = 2026
    components.month = 6
    components.day = 15
    let midnight = Calendar.current.date(from: components)!

    XCTAssertEqual(midnight.dayProgress, 0, accuracy: 0.001)
  }

  func testProgressStaysWithinTheDay() {
    var components = DateComponents()
    components.year = 2026
    components.month = 6
    components.day = 15
    components.hour = 23
    components.minute = 59
    let lateEvening = Calendar.current.date(from: components)!

    XCTAssertLessThan(lateEvening.dayProgress, 1)
    XCTAssertGreaterThan(lateEvening.dayProgress, 0.99)
  }

  // MARK: - CSS colours a user types into a custom widget

  func testNamedColoursAreRecognised() {
    XCTAssertNotNil(Color(cssString: "red"))
    XCTAssertNotNil(Color(cssString: "grey"), "the British spelling is accepted")
    XCTAssertNotNil(Color(cssString: "gray"))
    XCTAssertNotNil(Color(cssString: "  RED  "), "surrounding space and case do not matter")
  }

  func testSixDigitHexIsRead() {
    let color = Color(cssString: "#FF8800")

    XCTAssertNotNil(color)
    XCTAssertEqual(components(color!)[0], 1, accuracy: 0.01)
    XCTAssertEqual(components(color!)[1], 0.533, accuracy: 0.01)
  }

  func testThreeDigitHexIsExpanded() {
    let color = Color(cssString: "#abc")

    XCTAssertEqual(components(color!)[0], 0.667, accuracy: 0.01)
    XCTAssertEqual(components(color!)[2], 0.8, accuracy: 0.01)
  }

  func testEightDigitHexIsReadAsRGBAWithAlphaLast() {
    // CSS order, deliberately unlike `Color(hex:)` in Theme.swift, which reads 8 digits as ARGB.
    // The two serve different inputs - a user's CSS string here, a stored theme value there -
    // and changing either would silently re-colour existing configs. See ThemeColorTests.
    let color = Color(cssString: "#FF000080")

    XCTAssertEqual(components(color!)[0], 1, accuracy: 0.01, "red comes first")
    XCTAssertEqual(components(color!)[3], 0.502, accuracy: 0.01, "alpha comes last")
  }

  func testFunctionalRGBIsRead() {
    let color = Color(cssString: "rgb(255, 136, 0)")

    XCTAssertEqual(components(color!)[0], 1, accuracy: 0.01)
    XCTAssertEqual(components(color!)[1], 0.533, accuracy: 0.01)
  }

  func testFunctionalRGBAKeepsItsAlpha() {
    let color = Color(cssString: "rgba(255, 0, 0, 0.5)")

    XCTAssertEqual(components(color!)[3], 0.5, accuracy: 0.01)
  }

  func testSpacingInsideTheFunctionIsTolerated() {
    XCTAssertNotNil(Color(cssString: "rgb(255,0,0)"))
    XCTAssertNotNil(Color(cssString: "rgb(  255 ,  0 , 0  )"))
  }

  func testAnUnreadableColourIsRefusedRatherThanGuessed() {
    // Returning nil lets the caller fall back to the theme, which is why this initializer is
    // failable and `Color(hex:)` is not.
    XCTAssertNil(Color(cssString: "nonsense"))
    XCTAssertNil(Color(cssString: "#12345"))
    XCTAssertNil(Color(cssString: "#zzzzzz"))
    XCTAssertNil(Color(cssString: "rgb(255, 0)"))
    XCTAssertNil(Color(cssString: ""))
  }
}
