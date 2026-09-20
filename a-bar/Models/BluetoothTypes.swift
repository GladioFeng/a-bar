import Foundation

/// The Bluetooth state the widgets read.
///
/// Lifted out of `BluetoothService`, which imports IOBluetooth. Only the classification of a
/// device's Class of Device needs those constants, and that stayed behind; everything here is
/// plain data, so the `system_profiler` parser that fills it can be tested.

/// Aggregate Bluetooth state published to the widgets.
struct BluetoothInfo: Equatable {
  /// A Bluetooth controller is present on this Mac.
  var hasController: Bool = false
  /// Controller radio is powered on.
  var isPoweredOn: Bool = false
  /// Paired devices, connected ones first, then alphabetically.
  var devices: [BluetoothPairedDevice] = []
  /// False when the private power-toggle symbol could not be resolved.
  var canTogglePower: Bool = true

  var connectedDevices: [BluetoothPairedDevice] { devices.filter { $0.isConnected } }
}

/// A paired Bluetooth device. Named to avoid shadowing IOBluetooth's own
/// `IOBluetoothDevice` and the `Bluetooth*` C types from Bluetooth.h.
struct BluetoothPairedDevice: Identifiable, Equatable {
  /// Normalized address - also the merge key against system_profiler.
  let id: String
  /// Address as IOBluetooth reports it ("ac-bf-71-09-96-af").
  let address: String
  let name: String
  let isConnected: Bool
  let kind: BluetoothDeviceKind
  /// Only known while connected, and only via system_profiler.
  var battery: BluetoothBatteryLevels?
}

/// Battery levels reported by `system_profiler`. Any combination may be absent:
/// single-battery headsets report only `main`, AirPods report left/right/case.
struct BluetoothBatteryLevels: Equatable {
  var main: Int?
  var left: Int?
  var right: Int?
  var caseLevel: Int?

  var isEmpty: Bool { main == nil && left == nil && right == nil && caseLevel == nil }
  /// Lowest known level, used for the "low battery" tint.
  var lowest: Int? { [main, left, right, caseLevel].compactMap { $0 }.min() }
}

/// Coarse device family, used to pick an SF Symbol.
enum BluetoothDeviceKind: Equatable {
  case headphones, speaker, keyboard, mouse, gamepad, phone, watch, computer, other

  var symbolName: String {
    switch self {
    case .headphones: return "headphones"
    case .speaker: return "hifispeaker"
    case .keyboard: return "keyboard"
    case .mouse: return "computermouse"
    case .gamepad: return "gamecontroller"
    case .phone: return "iphone"
    case .watch: return "applewatch"
    case .computer: return "laptopcomputer"
    case .other: return "dot.radiowaves.left.and.right"
    }
  }
}
