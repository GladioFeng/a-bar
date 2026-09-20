import XCTest

/// A threshold colour is a warning. A warning that cannot fire at the level it warns about is
/// worse than no warning at all, because the widget still looks like it is watching.
final class WidgetPaletteTests: XCTestCase {

  // MARK: - Battery

  func testACriticalBatteryIsRed() {
    // regression: the ladder tested `< 50 -> orange` before `< 20 -> red`, so the orange branch
    // claimed every low battery and red was unreachable at any percentage. The bar gave the same
    // warning at 45% as at 2%.
    XCTAssertEqual(WidgetPalette.batteryFill(percentage: 2, isCharging: false), .red)
    XCTAssertEqual(WidgetPalette.batteryFill(percentage: 19, isCharging: false), .red)
  }

  func testALowBatteryIsOrange() {
    XCTAssertEqual(WidgetPalette.batteryFill(percentage: 20, isCharging: false), .orange)
    XCTAssertEqual(WidgetPalette.batteryFill(percentage: 49, isCharging: false), .orange)
  }

  func testAHealthyBatteryUsesTheWidgetsOwnColour() {
    XCTAssertNil(WidgetPalette.batteryFill(percentage: 50, isCharging: false))
    XCTAssertNil(WidgetPalette.batteryFill(percentage: 100, isCharging: false))
  }

  func testChargingOutranksEveryLevel() {
    // A battery on the charger is not a problem, however empty it is.
    for percentage in [0, 5, 19, 20, 50, 100] {
      XCTAssertEqual(
        WidgetPalette.batteryFill(percentage: percentage, isCharging: true), .green,
        "charging at \(percentage)%")
    }
  }

  func testEveryBatteryLevelGetsAnAnswer() {
    for percentage in 0...100 {
      _ = WidgetPalette.batteryFill(percentage: percentage, isCharging: false)
    }
  }

  func testBothWarningColoursAreReachable() {
    // The property the ordering bug broke: every rung of the ladder must be reachable.
    let colours = (0...100).map { WidgetPalette.batteryFill(percentage: $0, isCharging: false) }

    XCTAssertTrue(colours.contains(.red), "red must be reachable")
    XCTAssertTrue(colours.contains(.orange), "orange must be reachable")
    XCTAssertTrue(colours.contains(nil), "and so must the untinted state")
  }

  func testAnImpossiblePercentageStillAnswers() {
    XCTAssertEqual(WidgetPalette.batteryFill(percentage: -5, isCharging: false), .red)
    XCTAssertNil(WidgetPalette.batteryFill(percentage: 150, isCharging: false))
  }

  // MARK: - Storage

  func testAFullDiskIsRed() {
    XCTAssertEqual(WidgetPalette.storageBar(fullness: 0.91), .red)
    XCTAssertEqual(WidgetPalette.storageBar(fullness: 1.0), .red)
  }

  func testAFillingDiskIsYellow() {
    XCTAssertEqual(WidgetPalette.storageBar(fullness: 0.76), .yellow)
    XCTAssertEqual(WidgetPalette.storageBar(fullness: 0.9), .yellow, "the boundary is exclusive")
  }

  func testARoomyDiskIsGreen() {
    XCTAssertEqual(WidgetPalette.storageBar(fullness: 0), .green)
    XCTAssertEqual(WidgetPalette.storageBar(fullness: 0.75), .green, "the boundary is exclusive")
  }

  // MARK: - Memory

  func testMemoryPressureLaddersUpwards() {
    XCTAssertEqual(WidgetPalette.memoryPressure(0), .green)
    XCTAssertEqual(WidgetPalette.memoryPressure(60), .green, "the boundary is exclusive")
    XCTAssertEqual(WidgetPalette.memoryPressure(61), .yellow)
    XCTAssertEqual(WidgetPalette.memoryPressure(80), .yellow, "the boundary is exclusive")
    XCTAssertEqual(WidgetPalette.memoryPressure(81), .red)
    XCTAssertEqual(WidgetPalette.memoryPressure(100), .red)
  }

  // MARK: - Roles resolve against a theme

  func testEveryRoleResolvesToAColour() {
    // A role with no slot behind it would render as whatever `Color` defaults to.
    let theme = ThemePreset.tokyoNight.theme

    for role in ThemeColorRole.allCases {
      XCTAssertNotNil(NSColor(role.color(in: theme)).cgColor.components, role.rawValue)
    }
  }

  func testARoleResolvesToTheThemeSlotItNames() {
    let theme = ThemePreset.tokyoNight.theme

    XCTAssertEqual(ThemeColorRole.red.color(in: theme).hexString, theme.red.hexString)
    XCTAssertEqual(ThemeColorRole.background.color(in: theme).hexString, theme.background.hexString)
  }
}
