import Foundation

/// Which colour a widget uses to warn about its own data.
///
/// Each of these is a ladder of thresholds, and a ladder tested in the wrong order has rungs
/// nothing can reach - which is a warning that never fires.
enum WidgetPalette {

  /// The battery's fill colour.
  ///
  /// `nil` means "leave it the widget's own foreground", which follows the widget's settings
  /// rather than the theme, so it is not a role this type can name.
  static func batteryFill(percentage: Int, isCharging: Bool) -> ThemeColorRole? {
    if isCharging { return .green }
    if percentage < criticalBatteryPercentage { return .red }
    if percentage < lowBatteryPercentage { return .orange }
    return nil
  }

  static let criticalBatteryPercentage = 20
  static let lowBatteryPercentage = 50

  /// How full a disk is, as a fraction.
  static func storageBar(fullness: Double) -> ThemeColorRole {
    if fullness > 0.9 { return .red }
    if fullness > 0.75 { return .yellow }
    return .green
  }

  /// Memory pressure, as a percentage.
  static func memoryPressure(_ usage: Double) -> ThemeColorRole {
    if usage > 80 { return .red }
    if usage > 60 { return .yellow }
    return .green
  }
}
