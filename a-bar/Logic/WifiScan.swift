import Foundation

/// Collapsing a Wi-Fi scan into the list the popover shows, and quoting an SSID for a shell.
///
/// This used to sit on `WifiService` and take CoreWLAN's `CWNetwork` directly, which no test
/// could construct: the class has no public initializer. Taking a plain `ScanResult` instead -
/// mapped from `CWNetwork` at the call site - is what makes the collapsing rules reachable.
enum WifiScan {

  /// The three fields the collapse actually reads, lifted off `CWNetwork`.
  struct ScanResult: Equatable {
    /// Nil when macOS redacted the name because Location Services is denied.
    var ssid: String?
    var rssiValue: Int
    var security: WifiSecurity

    init(ssid: String?, rssiValue: Int, security: WifiSecurity) {
      self.ssid = ssid
      self.rssiValue = rssiValue
      self.security = security
    }
  }

  /// A scan returns one result per BSSID, so a single network shows up once per
  /// band and once per mesh node. Collapse by SSID, keeping the strongest signal.
  ///
  /// Networks with a nil or empty SSID are dropped: those are the ones macOS redacted because
  /// the app is not authorized for Location Services, and an unnamed row is useless.
  static func dedupe(
    _ networks: [ScanResult], currentSSID: String?, knownSSIDs: Set<String> = []
  ) -> [WifiNetwork] {
    var strongest: [String: WifiNetwork] = [:]

    for network in networks {
      guard let ssid = network.ssid, !ssid.isEmpty else { continue }
      let candidate = WifiNetwork(
        id: ssid,
        ssid: ssid,
        rssi: network.rssiValue,
        security: network.security,
        isCurrent: ssid == currentSSID,
        isKnown: knownSSIDs.contains(ssid)
      )
      if let existing = strongest[ssid], existing.rssi >= candidate.rssi { continue }
      strongest[ssid] = candidate
    }

    return strongest.values.sorted {
      $0.isCurrent == $1.isCurrent
        ? $0.rssi > $1.rssi
        : $0.isCurrent
    }
  }

  /// Single-quote for the shell, escaping embedded quotes. SSIDs can contain spaces and
  /// shell metacharacters, and they are attacker-chosen: anyone within radio range picks the
  /// name of the network the scan reports, and that name is interpolated into a `networksetup`
  /// command line.
  static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
