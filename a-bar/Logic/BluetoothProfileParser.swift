import Foundation

/// Reading battery levels out of `system_profiler SPBluetoothDataType -json`.
///
/// IOBluetooth does not expose battery at all, so this output is the only source. It is also the
/// most variable thing the app parses: the shape of a battery value changes with the macOS
/// version and the user's locale, and the device list is keyed by display name rather than by
/// address.
///
/// The shell call stays in `BluetoothService`; only the walk over what it returns lives here,
/// because that file imports IOBluetooth and nothing importing IOBluetooth can be compiled into
/// the test bundle.
enum BluetoothProfileParser {

  /// Battery levels and device-kind hints, both keyed by normalized address.
  struct ParsedProfile: Equatable {
    var battery: [String: BluetoothBatteryLevels] = [:]
    var minorTypes: [String: String] = [:]
  }

  /// Parse `system_profiler`'s JSON. Returns nil only when the output is not the document this
  /// expects at all - a device it cannot read is skipped, never fatal, because one unfamiliar
  /// device must not cost the battery reading of every other.
  static func parse(_ data: Data) -> ParsedProfile? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = root["SPBluetoothDataType"] as? [[String: Any]],
      let first = entries.first
    else {
      return nil
    }

    var profile = ParsedProfile()

    // `device_connected` is absent entirely when nothing is connected, and each
    // element is a single-key dictionary keyed by the device's display name.
    for key in ["device_connected", "device_not_connected"] {
      guard let list = first[key] as? [[String: Any]] else { continue }
      for entry in list {
        guard let (_, value) = entry.first,
          let props = value as? [String: Any],
          let address = props["device_address"] as? String
        else { continue }
        let id = normalizedAddress(address)

        if let minorType = props["device_minorType"] as? String {
          profile.minorTypes[id] = minorType
        }

        var levels = BluetoothBatteryLevels()
        // Scan by prefix rather than hardcoding the four key names, so a
        // renamed or added suffix degrades to "unknown" instead of breaking.
        for (propKey, propValue) in props where propKey.hasPrefix("device_batteryLevel") {
          guard let percent = batteryPercent(propValue) else { continue }
          switch propKey.dropFirst("device_batteryLevel".count) {
          case "Left": levels.left = percent
          case "Right": levels.right = percent
          case "Case": levels.caseLevel = percent
          default: levels.main = percent
          }
        }
        if !levels.isEmpty {
          profile.battery[id] = levels
        }
      }
    }

    return profile
  }

  /// system_profiler reports battery as a localized percentage string - the
  /// observed value is "100\u{00A0}%", with a NON-BREAKING space (U+00A0), and
  /// the format varies by macOS version and locale. Keep only the digits rather
  /// than trimming a fixed character set: `trimmingCharacters(in: "% ")` leaves
  /// the U+00A0 in place, `Int(_:)` then returns nil, and battery silently
  /// never renders.
  static func batteryPercent(_ raw: Any?) -> Int? {
    if let value = raw as? Int { return value }
    if let value = raw as? Double { return Int(value.rounded()) }
    guard let text = raw as? String else { return nil }
    let digits = text.filter { $0.isNumber }
    return digits.isEmpty ? nil : Int(digits)
  }

  /// Merge key shared by IOBluetooth and system_profiler. IOBluetooth reports
  /// "ac-bf-71-09-96-af" while system_profiler reports "AC:BF:71:09:96:AF", so
  /// comparing them directly always fails and battery never appears.
  static func normalizedAddress(_ raw: String) -> String {
    raw.lowercased().filter { $0.isHexDigit }
  }
}
