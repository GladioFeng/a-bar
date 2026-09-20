import SwiftUI
import XCTest

/// Colour is the whole of a bar's legibility. The parsing, the blend and the contrast decision
/// have no visible failure mode short of an unreadable or invisible bar, so they are pinned here.
final class ThemeColorTests: XCTestCase {

  /// The bridged sRGB components, which is how every colour helper here reads a `Color`.
  private func components(_ color: Color) -> [CGFloat] {
    guard let components = NSColor(color).cgColor.components else {
      XCTFail("colour did not bridge to components")
      return [0, 0, 0, 0]
    }
    return components
  }

  private func assertComponents(
    _ color: Color, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let parts = components(color)
    XCTAssertEqual(parts[0], red, accuracy: 0.01, "red", file: file, line: line)
    XCTAssertEqual(parts[1], green, accuracy: 0.01, "green", file: file, line: line)
    XCTAssertEqual(parts[2], blue, accuracy: 0.01, "blue", file: file, line: line)
    XCTAssertEqual(parts[3], alpha, accuracy: 0.01, "alpha", file: file, line: line)
  }

  // MARK: - Parsing a hex colour

  func testSixDigitHexIsReadAsRGB() {
    assertComponents(Color(hex: "#FF8800"), red: 1, green: 0.533, blue: 0)
  }

  func testTheLeadingHashIsOptional() {
    assertComponents(Color(hex: "FF8800"), red: 1, green: 0.533, blue: 0)
  }

  func testThreeDigitHexIsExpandedByDoublingEachDigit() {
    assertComponents(Color(hex: "#ABC"), red: 0.667, green: 0.733, blue: 0.8)
  }

  func testEightDigitHexIsReadAsARGBWithAlphaFirst() {
    // Note this is ARGB, while `Color(cssString:)` in Extensions.swift reads #RRGGBBAA as RGBA.
    // The two are genuinely inconsistent; both are pinned so the difference is deliberate.
    assertComponents(Color(hex: "#80FF0000"), red: 1, green: 0, blue: 0, alpha: 0.502)
  }

  func testAThreeOrSixDigitStringThatIsNotHexBecomesBlack() {
    assertComponents(Color(hex: "#zzz"), red: 0, green: 0, blue: 0, alpha: 1)
  }

  func testAnUnreadableColourFallsBackToSomethingVisible() {
    // regression: `scanHexInt64` stops at the first non-hex character and still reports success,
    // so any 8-character typo fell into the ARGB branch, scanned as 0, and produced alpha 0.
    // The element disappeared from the bar rather than showing a colour the user could correct.
    assertComponents(Color(hex: "nonsense"), red: 0, green: 0, blue: 0, alpha: 1)
    assertComponents(Color(hex: "abcdefgh"), red: 0, green: 0, blue: 0, alpha: 1)
    assertComponents(Color(hex: "#zzzzzz"), red: 0, green: 0, blue: 0, alpha: 1)
  }

  func testAValidColourIsStillReadAfterThatCheck() {
    // The readability check must not reject the values that do work.
    assertComponents(Color(hex: "#1B222D"), red: 0.106, green: 0.133, blue: 0.176)
    assertComponents(Color(hex: "#80FF0000"), red: 1, green: 0, blue: 0, alpha: 0.502)
  }

  // MARK: - Writing a hex colour back out

  func testAColourSurvivesARoundTripWhenEachChannelDividesCleanly() {
    XCTAssertEqual(Color(hex: "#FF8800").hexString, "#FF8800")
    XCTAssertEqual(Color(hex: "#FFFFFF").hexString, "#FFFFFF")
    XCTAssertEqual(Color(hex: "#000000").hexString, "#000000")
  }

  func testAColourSurvivesARoundTripWhateverItsChannels() {
    // regression: `hexString` truncated with `Int()`, so 0x22 -> 33.999... -> 0x21. The default
    // theme's own background did not survive a round trip, and a value re-saved through the
    // picker walked steadily darker.
    XCTAssertEqual(Color(hex: "#1B222D").hexString, "#1B222D")
  }

  func testEveryChannelValueSurvivesARoundTrip() {
    // One step lost anywhere in the range is a theme that drifts; check the whole range.
    for value in 0...255 {
      let hex = String(format: "#%02X%02X%02X", value, value, value)
      XCTAssertEqual(Color(hex: hex).hexString, hex, "channel value \(value) did not survive")
    }
  }

  func testEveryPresetColourSurvivesARoundTrip() {
    // The picker reads a theme colour out and writes it back when the user edits a neighbour.
    for preset in ThemePreset.allCases {
      let theme = preset.theme
      XCTAssertEqual(
        Color(hex: theme.background.hexString).hexString, theme.background.hexString,
        "\(preset.rawValue) background drifts")
      XCTAssertEqual(
        Color(hex: theme.accent.hexString).hexString, theme.accent.hexString,
        "\(preset.rawValue) accent drifts")
    }
  }

  // MARK: - Relative luminance

  func testLuminanceSpansTheFullRange() {
    XCTAssertEqual(Color.white.luminance, 1, accuracy: 0.001)
    XCTAssertEqual(Color.black.luminance, 0, accuracy: 0.001)
  }

  func testLuminanceIsWeightedTowardsGreen() {
    // The WCAG weights are 0.2126/0.7152/0.0722; green must outweigh red and blue.
    XCTAssertGreaterThan(Color(hex: "#00FF00").luminance, Color(hex: "#FF0000").luminance)
    XCTAssertGreaterThan(Color(hex: "#FF0000").luminance, Color(hex: "#0000FF").luminance)
  }

  func testADarkThemeBackgroundReadsAsDark() {
    XCTAssertLessThan(Color(hex: "#1B222D").luminance, 0.5)
  }

  // MARK: - Blending against the bar

  func testFullOpacityKeepsTheElementColour() {
    let blended = Color(hex: "#FF0000").blendedWithBarBackground(Color(hex: "#000000"), opacity: 100)

    assertComponents(blended, red: 1, green: 0, blue: 0)
  }

  func testZeroOpacityShowsOnlyTheBarBehindIt() {
    let blended = Color(hex: "#FF0000").blendedWithBarBackground(Color(hex: "#FFFFFF"), opacity: 0)

    assertComponents(blended, red: 1, green: 1, blue: 1)
  }

  func testHalfOpacityLandsHalfwayBetweenTheTwo() {
    let blended = Color(hex: "#FFFFFF").blendedWithBarBackground(Color(hex: "#000000"), opacity: 50)

    assertComponents(blended, red: 0.5, green: 0.5, blue: 0.5)
  }

  func testOpacityOutsideTheSliderRangeIsClamped() {
    // The setting is a 0-100 slider, but the config file is hand-editable.
    let over = Color(hex: "#FF0000").blendedWithBarBackground(Color(hex: "#FFFFFF"), opacity: 900)
    let under = Color(hex: "#FF0000").blendedWithBarBackground(Color(hex: "#FFFFFF"), opacity: -50)

    assertComponents(over, red: 1, green: 0, blue: 0, alpha: 1)
    assertComponents(under, red: 1, green: 1, blue: 1, alpha: 1)
  }

  // MARK: - Choosing a readable foreground

  func testALightBackgroundGetsADarkForeground() {
    let theme = ThemePreset.nightShift.theme
    let foreground = Color(hex: "#FFFFFF").contrastingForeground(from: theme)

    XCTAssertEqual(components(foreground)[0], 0, accuracy: 0.01, "black text on a light element")
  }

  func testADarkBackgroundGetsALightForeground() {
    let theme = ThemePreset.nightShift.theme
    let foreground = Color(hex: "#101010").contrastingForeground(from: theme)

    XCTAssertEqual(components(foreground)[0], 1, accuracy: 0.01, "white text on a dark element")
  }

  func testAMostlyTransparentElementIsJudgedByWhatShowsThrough() {
    // At low opacity the element barely tints the bar, so the bar decides readability.
    let theme = ThemePreset.nightShift.theme
    let foreground = Color(hex: "#FFFFFF").contrastingForeground(
      from: theme, opacity: 10, barBackground: Color(hex: "#000000"))

    XCTAssertEqual(
      components(foreground)[0], 1, accuracy: 0.01,
      "a white element over a black bar still needs light text")
  }

  func testAMostlyOpaqueElementIsJudgedByItself() {
    let theme = ThemePreset.nightShift.theme
    let foreground = Color(hex: "#FFFFFF").contrastingForeground(
      from: theme, opacity: 95, barBackground: Color(hex: "#000000"))

    XCTAssertEqual(components(foreground)[0], 0, accuracy: 0.01, "the bar no longer shows through")
  }

  // MARK: - The preset table

  func testEveryPresetIsFiledUnderTheAppearanceItClaims() {
    // The Settings picker is built from `darkThemes`/`lightThemes`; a preset in the wrong list
    // is offered under the wrong appearance and applied when the opposite one is selected.
    for preset in ThemePreset.allCases {
      switch preset.kind {
      case .dark:
        XCTAssertTrue(
          ThemePreset.darkThemes.contains(preset), "\(preset.rawValue) is dark but not listed dark")
      case .light:
        XCTAssertTrue(
          ThemePreset.lightThemes.contains(preset),
          "\(preset.rawValue) is light but not listed light")
      }
    }
  }

  func testTheTwoListsPartitionEveryPreset() {
    let listed = ThemePreset.darkThemes + ThemePreset.lightThemes

    XCTAssertEqual(Set(listed), Set(ThemePreset.allCases), "a preset is unreachable in Settings")
    XCTAssertEqual(listed.count, ThemePreset.allCases.count, "a preset is offered in both lists")
  }

  func testEveryPresetBuildsAThemeThatAgreesWithItself() {
    for preset in ThemePreset.allCases {
      XCTAssertEqual(preset.theme.kind, preset.kind, "\(preset.rawValue) builds the wrong kind")
      XCTAssertEqual(
        preset.theme.name, preset.displayName, "\(preset.rawValue) builds a mismatched name")
      XCTAssertFalse(preset.displayName.isEmpty)
    }
  }

  // MARK: - Resolving the theme from settings

  func testAnExplicitAppearanceSelectsThatThemeWithoutConsultingTheSystem() {
    var settings = ThemeSettings()
    settings.appearance = .dark
    settings.darkTheme = .tokyoNight
    settings.lightTheme = .oneLight

    XCTAssertEqual(ThemeManager.currentTheme(for: settings).name, ThemePreset.tokyoNight.displayName)

    settings.appearance = .light
    XCTAssertEqual(ThemeManager.currentTheme(for: settings).name, ThemePreset.oneLight.displayName)
  }

  func testAnOverrideReplacesOnlyTheColourItNames() {
    var settings = ThemeSettings()
    settings.appearance = .dark
    settings.darkTheme = .tokyoNight
    settings.colorOverrides.red = "#00FF00"

    let theme = ThemeManager.currentTheme(for: settings)

    assertComponents(theme.red, red: 0, green: 1, blue: 0)
    XCTAssertEqual(
      components(theme.green), components(ThemePreset.tokyoNight.theme.green),
      "the siblings are untouched")
    XCTAssertEqual(theme.name, ThemePreset.tokyoNight.displayName, "and so is the name")
  }

  func testNoOverridesLeavesThePresetExactlyAsItIs() {
    var settings = ThemeSettings()
    settings.appearance = .dark
    settings.darkTheme = .gruvboxDark

    let theme = ThemeManager.currentTheme(for: settings)

    XCTAssertEqual(components(theme.background), components(ThemePreset.gruvboxDark.theme.background))
    XCTAssertEqual(components(theme.accent), components(ThemePreset.gruvboxDark.theme.accent))
  }
}
