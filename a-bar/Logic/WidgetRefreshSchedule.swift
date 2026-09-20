import Foundation

/// Which system readings a widget needs, and how often.
///
/// Lifted out of `SystemInfoService`, where the same list of widgets was spelled out twice -
/// once to decide what a refresh collects, once to decide what a timer is scheduled for. Two
/// switch statements over the same enum drift: a widget added to one and not the other either
/// refreshes once and then never again, or ticks on a timer that collects nothing.
enum WidgetRefreshSchedule {

  /// One system reading. A widget maps to the readings it displays, not to a method name, so
  /// the caller stays free to collect them however it likes.
  enum Reading: String, CaseIterable, Equatable {
    case battery, caffeinate, cpu, memory, gpu
    case networkStats, diskStats, volume, mic, keyboard, storageVolumes
  }

  /// What one refresh of this widget has to collect.
  ///
  /// Widgets that read nothing from the system - the clock, the window-manager widgets, a
  /// custom script - collect nothing here and are driven from elsewhere.
  static func readings(for widget: WidgetIdentifier) -> [Reading] {
    switch widget {
    // The battery widget also draws the caffeinate cup, which is a separate reading.
    case .battery: return [.battery, .caffeinate]
    case .cpu: return [.cpu]
    case .memory: return [.memory]
    case .gpu: return [.gpu]
    case .netstats: return [.networkStats]
    case .diskActivity: return [.diskStats]
    case .sound: return [.volume]
    case .mic: return [.mic]
    case .keyboard: return [.keyboard]
    case .storage: return [.storageVolumes]
    default: return []
    }
  }

  /// Every reading a set of active widgets needs, each one collected once however many
  /// widgets asked for it.
  static func readings(for widgets: Set<WidgetIdentifier>) -> Set<Reading> {
    Set(widgets.flatMap(readings(for:)))
  }

  /// How often this widget wants refreshing, or nil if it is not on a timer here.
  static func interval(for widget: WidgetIdentifier, in settings: WidgetSettings) -> TimeInterval? {
    switch widget {
    case .battery: return settings.battery.refreshInterval
    case .cpu: return settings.cpu.refreshInterval
    case .memory: return settings.memory.refreshInterval
    case .gpu: return settings.gpu.refreshInterval
    case .netstats: return settings.netstats.refreshInterval
    case .diskActivity: return settings.diskActivity.refreshInterval
    case .sound: return settings.sound.refreshInterval
    case .mic: return settings.mic.refreshInterval
    case .keyboard: return settings.keyboard.refreshInterval
    case .storage: return settings.storage.refreshInterval
    default: return nil
    }
  }

  /// One timer per active widget that wants one, keyed by the widget's raw value.
  ///
  /// Sorted so the result is stable: the set of active widgets is unordered, and a caller
  /// rebuilding its timers should not see them come back in a different order each time.
  static func timers(
    for widgets: Set<WidgetIdentifier>,
    in settings: WidgetSettings
  ) -> [(id: String, widget: WidgetIdentifier, interval: TimeInterval)] {
    widgets
      .compactMap { widget in
        interval(for: widget, in: settings).map { (widget.rawValue, widget, $0) }
      }
      .sorted { $0.0 < $1.0 }
  }

  /// A widget drives a timer here only if it also has something to collect. The two lists
  /// were written separately and this is the invariant that keeps them in step.
  static var isConsistent: Bool {
    WidgetIdentifier.allCases.allSatisfy { widget in
      readings(for: widget).isEmpty == (interval(for: widget, in: WidgetSettings()) == nil)
    }
  }
}
