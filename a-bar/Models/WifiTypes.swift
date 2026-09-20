import Foundation

/// The Wi-Fi state the widgets read.
///
/// Lifted out of `WifiService`, which imports CoreWLAN. The two initializers that translate a
/// `CWSecurity` or a `CWNetwork` into a `WifiSecurity` stay behind with that framework; what is
/// here is plain data, so the scan-collapsing logic that builds it can be tested.

/// Aggregate Wi-Fi state published to the widgets.
struct WifiInfo: Equatable {
  /// A Wi-Fi interface exists on this Mac.
  var hasInterface: Bool = false
  /// The radio is powered on.
  var isPoweredOn: Bool = false
  /// Associated with a network. Distinct from `ssid` being non-nil: macOS redacts the
  /// name without Location Services but still reports the interface mode, so this stays
  /// truthful where the name cannot.
  var isAssociated: Bool = false
  /// Current network name. Nil when unassociated - or when Location Services is denied,
  /// since macOS redacts the name in that case.
  var ssid: String?
  /// Nearby networks, deduped by SSID, current first then by signal strength.
  ///
  /// The connected network's own signal lives on its row here rather than on this
  /// struct: a live RSSI reading drifts by a dBm every few seconds, and holding it in
  /// the published snapshot would defeat the equality check in `publish` and re-render
  /// every bar on every display on each tick.
  var networks: [WifiNetwork] = []
  /// Whether the app may read network names at all.
  var locationAuthorized: Bool = false

  var isConnected: Bool { isAssociated }
}

/// One nearby network, collapsed from every BSSID advertising that SSID.
struct WifiNetwork: Identifiable, Equatable {
  /// The SSID doubles as the identity: rows are per network, not per radio.
  let id: String
  let ssid: String
  let rssi: Int
  let security: WifiSecurity
  let isCurrent: Bool
  /// Already in the preferred-networks list, so macOS has its passphrase.
  let isKnown: Bool

  var ssidData: Data? { ssid.data(using: .utf8) }

  /// A passphrase must be collected only for a secured network we have never joined.
  var needsPassword: Bool { security.isSecured && !isKnown }

  /// Signal strength bucketed to four bars, on the usual dBm boundaries.
  var signalBars: Int {
    switch rssi {
    case (-50)...: return 4
    case (-60)..<(-50): return 3
    case (-70)..<(-60): return 2
    default: return 1
    }
  }
}

/// Coarse security class. CoreWLAN distinguishes far more cases than the popover needs;
/// what matters here is whether a passphrase is required and whether joining is even
/// possible without an enterprise identity.
enum WifiSecurity: Equatable {
  case none
  case personal
  case enterprise
  case unknown

  var isSecured: Bool { self != .none }
  var isEnterprise: Bool { self == .enterprise }
}
