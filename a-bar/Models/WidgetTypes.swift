import Foundation
import SwiftUI

/// Unique identifier for each widget type
enum WidgetIdentifier: String, Codable, CaseIterable, Identifiable {
  // Window manager widgets (yabai)
  case spaces = "spaces"
  case process = "process"

  // Window manager widgets (AeroSpace)
  case aerospaceSpaces = "aerospace-spaces"
  case aerospaceProcess = "aerospace-process"

  // Data widgets
  case battery = "battery"
  case weather = "weather"
  case time = "time"
  case date = "date-display"
  case wifi = "wifi"
  case bluetooth = "bluetooth"
  case sound = "sound"
  case mic = "mic"
  case keyboard = "keyboard"
  case github = "github"
  case hackerNews = "hacker-news"

  // Graph widgets
  case cpu = "cpu"
  case memory = "memory"
  case gpu = "gpu"
  case netstats = "netstats"
  case diskActivity = "disk-activity"
  case storage = "storage"

  // Custom widgets
  case userWidget = "user-widget"

  var id: String { rawValue }

  /// Human-readable display name
  var displayName: String {
    switch self {
    case .spaces: return "Spaces (yabai)"
    case .process: return "Process (yabai)"
    case .aerospaceSpaces: return "Spaces (AeroSpace)"
    case .aerospaceProcess: return "Process (AeroSpace)"
    case .battery: return "Battery"
    case .weather: return "Weather"
    case .time: return "Time"
    case .date: return "Date"
    case .wifi: return "Wi-Fi"
    case .bluetooth: return "Bluetooth"
    case .sound: return "Sound"
    case .mic: return "Microphone"
    case .keyboard: return "Keyboard"
    case .github: return "GitHub"
    case .hackerNews: return "Hacker News"
    case .cpu: return "CPU"
    case .memory: return "Memory"
    case .gpu: return "GPU"
    case .netstats: return "Network Stats"
    case .diskActivity: return "Disk Activity"
    case .storage: return "Storage"
    case .userWidget: return "User Widget"
    }
  }

  /// System symbol name for the widget
  var symbolName: String {
    switch self {
    case .spaces: return "square.grid.2x2"
    case .process: return "app.fill"
    case .aerospaceSpaces: return "square.grid.2x2"
    case .aerospaceProcess: return "app.fill"
    case .battery: return "battery.100"
    case .weather: return "cloud.sun"
    case .time: return "clock"
    case .date: return "calendar"
    case .wifi: return "wifi"
    case .bluetooth: return "antenna.radiowaves.left.and.right"
    case .sound: return "speaker.wave.2"
    case .mic: return "mic"
    case .keyboard: return "keyboard"
    case .github: return "bell"    
    case .hackerNews: return "newspaper"
    case .cpu: return "cpu"
    case .memory: return "memorychip"
    case .gpu: return "cpu"
    case .netstats: return "network"
    case .diskActivity: return "internaldrive"
    case .storage: return "externaldrive"
    case .userWidget: return "star"
    }
  }

  /// Widget category
  var category: WidgetCategory {
    switch self {
    case .spaces, .process:
      return .yabai
    case .aerospaceSpaces, .aerospaceProcess:
      return .aerospace
    case .cpu, .memory, .gpu, .netstats, .diskActivity, .storage:
      return .graph
    case .userWidget:
      return .custom
    default:
      return .data
    }
  }

}

/// Categories for grouping widgets
enum WidgetCategory: String, Codable, CaseIterable {
  case yabai = "Yabai"
  case aerospace = "AeroSpace"
  case data = "Data"
  case graph = "Graphs"
  case custom = "Custom"

  var widgets: [WidgetIdentifier] {
    WidgetIdentifier.allCases.filter { $0.category == self }
  }
}

/// Section of the bar
enum WidgetSection: String, Codable, CaseIterable {
  case left
  case center
  case right

  var displayName: String {
    switch self {
    case .left: return "Left"
    case .center: return "Center"
    case .right: return "Right"
    }
  }
}

/// Bar position on screen
enum BarPosition: String, Codable, CaseIterable {
  case top
  case bottom

  var displayName: String {
    switch self {
    case .top: return "Top"
    case .bottom: return "Bottom"
    }
  }
}

/// A single widget instance in a bar section
/// Widgets can appear multiple times across different bars
struct WidgetInstance: Codable, Identifiable, Equatable {
  let id: UUID
  var identifier: WidgetIdentifier
  var enabled: Bool
  var showIcon: Bool
  var userWidgetIndex: Int?  // For user widgets only

  init(
    id: UUID = UUID(),
    identifier: WidgetIdentifier,
    enabled: Bool = true,
    showIcon: Bool = true,
    userWidgetIndex: Int? = nil
  ) {
    self.id = id
    self.identifier = identifier
    self.enabled = enabled
    self.showIcon = showIcon
    self.userWidgetIndex = userWidgetIndex
  }
}

/// Layout configuration for a single bar (top or bottom)
struct SingleBarLayout: Codable, Equatable {
  var left: [WidgetInstance]
  var center: [WidgetInstance]
  var right: [WidgetInstance]

  init(
    left: [WidgetInstance] = [],
    center: [WidgetInstance] = [],
    right: [WidgetInstance] = []
  ) {
    self.left = left
    self.center = center
    self.right = right
  }

  /// Get widgets for a specific section
  func widgets(for section: WidgetSection) -> [WidgetInstance] {
    switch section {
    case .left: return left.filter { $0.enabled }
    case .center: return center.filter { $0.enabled }
    case .right: return right.filter { $0.enabled }
    }
  }

  /// Check if bar has any widgets
  var isEmpty: Bool {
    left.isEmpty && center.isEmpty && right.isEmpty
  }

  /// Default bar layout matching the original a-bar default
  static var defaultTopBar: SingleBarLayout {
    SingleBarLayout(
      left: [
        WidgetInstance(identifier: .spaces),
        WidgetInstance(identifier: .process),
      ],
      center: [],
      right: [
        WidgetInstance(identifier: .weather),
        WidgetInstance(identifier: .netstats),
        WidgetInstance(identifier: .cpu),
        WidgetInstance(identifier: .memory),
        WidgetInstance(identifier: .wifi),
        WidgetInstance(identifier: .bluetooth),
        WidgetInstance(identifier: .keyboard),
        WidgetInstance(identifier: .mic),
        WidgetInstance(identifier: .sound),
        WidgetInstance(identifier: .battery),
        WidgetInstance(identifier: .date),
        WidgetInstance(identifier: .time),
      ]
    )
  }
}

/// Configuration for a single display
struct DisplayConfiguration: Codable, Identifiable, Equatable {
  let id: UUID
  var displayIndex: Int
  var name: String  // User-friendly name (e.g., "Built-in Display", "External Monitor")
  var topBar: SingleBarLayout?
  var bottomBar: SingleBarLayout?

  init(
    id: UUID = UUID(),
    displayIndex: Int,
    name: String = "Display",
    topBar: SingleBarLayout? = nil,
    bottomBar: SingleBarLayout? = nil
  ) {
    self.id = id
    self.displayIndex = displayIndex
    self.name = name
    self.topBar = topBar
    self.bottomBar = bottomBar
  }

  /// Check if display has any bars configured
  var hasBars: Bool {
    topBar != nil || bottomBar != nil
  }
}

/// Complete layout configuration for all displays
struct MultiDisplayLayout: Codable, Equatable {
  var displays: [DisplayConfiguration]

  init(displays: [DisplayConfiguration] = []) {
    self.displays = displays
  }

  /// Get configuration for a specific display index
  func configuration(forDisplay index: Int) -> DisplayConfiguration? {
    displays.first { $0.displayIndex == index }
  }

  /// Get bar layout for a specific display and position
  func barLayout(forDisplay index: Int, position: BarPosition) -> SingleBarLayout? {
    guard let config = configuration(forDisplay: index) else { return nil }
    switch position {
    case .top: return config.topBar
    case .bottom: return config.bottomBar
    }
  }

  /// Match the widgets rendered on connected screens; one sampler serves all copies.
  func enabledWidgets(displayCount: Int) -> Set<WidgetIdentifier> {
    Set((0..<max(0, displayCount)).flatMap { index -> [WidgetIdentifier] in
      guard let display = configuration(forDisplay: index) else { return [] }
      return [display.topBar, display.bottomBar].compactMap { $0 }.flatMap { bar in
        (bar.left + bar.center + bar.right).filter { $0.enabled }.map { $0.identifier }
      }
    })
  }

  /// Update or add a display configuration
  mutating func setConfiguration(_ config: DisplayConfiguration, forDisplay index: Int) {
    if let existingIndex = displays.firstIndex(where: { $0.displayIndex == index }) {
      displays[existingIndex] = config
    } else {
      displays.append(config)
    }
  }

  /// Remove configuration for a display
  mutating func removeConfiguration(forDisplay index: Int) {
    displays.removeAll { $0.displayIndex == index }
  }

  /// Default layout: main display (index 0) with top bar only
  static var defaultLayout: MultiDisplayLayout {
    MultiDisplayLayout(displays: [
      DisplayConfiguration(
        displayIndex: 0,
        name: "Main Display",
        topBar: .defaultTopBar,
        bottomBar: nil
      )
    ])
  }
}

/// Definition for a custom user widget (xbar-compatible)
///
/// Scripts write to stdout using the xbar plugin format:
/// - Lines before `---` cycle in the bar
/// - Lines after `---` appear in a dropdown menu on click
/// - Parameters are specified via pipe: `text | color=red | href=...`
struct UserWidgetDefinition: Codable, Identifiable, Equatable {
  private static let minimumRefreshInterval: TimeInterval = 1
  private static let minimumCycleDuration: TimeInterval = 1

  let id: UUID
  var name: String
  var command: String
  var refreshInterval: TimeInterval  // in seconds
  var isActive: Bool
  var backgroundColor: String?  // CSS color or theme color name
  var hideWhenEmpty: Bool
  var cycleDuration: TimeInterval  // seconds between header line changes

  init(
    id: UUID = UUID(),
    name: String = "My Widget",
    command: String = "echo 'Hello'",
    refreshInterval: TimeInterval = 60,
    isActive: Bool = true,
    backgroundColor: String? = nil,
    hideWhenEmpty: Bool = false,
    cycleDuration: TimeInterval = 4
  ) {
    self.id = id
    self.name = name
    self.command = command
    self.refreshInterval = max(Self.minimumRefreshInterval, refreshInterval)
    self.isActive = isActive
    self.backgroundColor = backgroundColor
    self.hideWhenEmpty = hideWhenEmpty
    self.cycleDuration = max(Self.minimumCycleDuration, cycleDuration)
  }

}

/// A data point for graph widgets
struct GraphDataPoint: Identifiable, Equatable {
  let id = UUID()
  let timestamp: Date
  let value: Double

  init(value: Double, timestamp: Date = Date()) {
    self.timestamp = timestamp
    self.value = value
  }
}

/// Graph data history with configurable max length
struct GraphHistory: Equatable {
  var dataPoints: [GraphDataPoint] = []
  let maxLength: Int

  init(maxLength: Int = 50) {
    self.maxLength = maxLength
  }

  mutating func add(_ value: Double) {
    dataPoints.append(GraphDataPoint(value: value))
    if dataPoints.count > maxLength {
      dataPoints.removeFirst(dataPoints.count - maxLength)
    }
  }

  mutating func clear() {
    dataPoints.removeAll()
  }

  var values: [Double] {
    dataPoints.map { $0.value }
  }

  var maxValue: Double {
    dataPoints.map { $0.value }.max() ?? 100
  }
}

/// Network statistics data
struct NetworkStats: Equatable {
  var download: UInt64 = 0
  var upload: UInt64 = 0

  var formattedDownload: String {
    ByteCountFormatter.string(fromByteCount: Int64(download), countStyle: .binary) + "/s"
  }

  var formattedUpload: String {
    ByteCountFormatter.string(fromByteCount: Int64(upload), countStyle: .binary) + "/s"
  }
}
