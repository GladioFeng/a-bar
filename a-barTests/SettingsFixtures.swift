import Foundation
import XCTest

/// Shared fixtures. Tests corrupt exactly one value in a realistic config and assert that
/// everything else came through untouched - that is the property the whole codec exists for.
enum SettingsFixtures {

  /// A config with non-default values in every section, one profile with widgets in all
  /// three bar sections, and a custom widget.
  static func settings() -> ABarSettings {
    var settings = ABarSettings()

    settings.global.barHeight = 42
    settings.global.fontName = "Menlo"
    settings.global.barOpacity = 55
    settings.theme.appearance = .dark
    settings.theme.darkTheme = .tokyoNight
    settings.widgets.battery.refreshInterval = 12
    settings.widgets.battery.backgroundColor = .green
    settings.widgets.weather.customLocation = "Lyon"
    settings.userWidgets = [
      UserWidgetDefinition(name: "Disk", command: "df -h", refreshInterval: 30)
    ]

    let profile = LayoutProfile(
      name: "Work",
      multiDisplayLayout: MultiDisplayLayout(displays: [
        DisplayConfiguration(
          displayIndex: 0,
          name: "Main Display",
          topBar: SingleBarLayout(
            left: [WidgetInstance(identifier: .spaces)],
            center: [WidgetInstance(identifier: .time)],
            right: [
              WidgetInstance(identifier: .cpu),
              WidgetInstance(identifier: .battery),
              WidgetInstance(identifier: .wifi),
            ]
          )
        )
      ]),
      isDefault: true
    )

    settings.profiles = [profile]
    settings.activeProfileId = profile.id.uuidString
    return settings
  }

  static func json(_ settings: ABarSettings) -> [String: Any] {
    let data = try! SettingsCodec.encode(settings)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
  }

  static func json<T: Encodable>(encoding value: T) -> Any {
    try! JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }

  static func data(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
  }

  /// Set (or, with a nil value, remove) a value at a dotted path. A numeric component is an
  /// array index: `profiles.0.multiDisplayLayout.displays.0.topBar.right.1.identifier`.
  static func set(_ value: Any?, at path: String, in root: inout [String: Any]) {
    func apply(_ node: Any, _ components: ArraySlice<String>) -> Any {
      guard let head = components.first else { return value as Any }
      let rest = components.dropFirst()

      if let index = Int(head), var array = node as? [Any], array.indices.contains(index) {
        if rest.isEmpty {
          if let value = value { array[index] = value } else { array.remove(at: index) }
        } else {
          array[index] = apply(array[index], rest)
        }
        return array
      }

      var object = node as? [String: Any] ?? [:]
      if rest.isEmpty {
        if let value = value { object[head] = value } else { object.removeValue(forKey: head) }
      } else {
        object[head] = apply(object[head] ?? [String: Any](), rest)
      }
      return object
    }

    root = apply(root, path.split(separator: ".").map(String.init)[...]) as! [String: Any]
  }
}

extension XCTestCase {
  /// Decode through the codec, failing the test if the document was not loadable at all.
  func decodeSettings(
    _ object: [String: Any], file: StaticString = #filePath, line: UInt = #line
  ) -> (settings: ABarSettings, repairs: [SettingsCodec.Repair]) {
    switch SettingsCodec.decode(SettingsFixtures.data(object)) {
    case .ok(let settings, let repairs):
      return (settings, repairs)
    case .unreadable(let reason):
      XCTFail("expected a loadable document, got: \(reason)", file: file, line: line)
      return (ABarSettings(), [])
    }
  }
}
