import Foundation

/// Which network interfaces count as traffic.
///
/// The byte counters are read per interface and summed. Loopback and the various virtual
/// interfaces would either double-count traffic already counted on a real one or report traffic
/// that never left the Mac, so the sum is taken over an allow-list of prefixes rather than over
/// everything the kernel lists.
enum NetworkInterfaces {

  /// Whether an interface carries traffic worth showing in the bar.
  static func isValidDataInterface(_ name: String) -> Bool {
    name.hasPrefix("en")  // Ethernet / Wi-Fi (en0, en1, etc.)
      || name.hasPrefix("bridge")  // Network bridge interfaces
      || name.hasPrefix("ap")  // Access point interfaces
      || name.hasPrefix("awdl")  // Apple Wireless Direct Link
      || name.hasPrefix("llw")  // Low Latency WLAN
      || name.hasPrefix("utun")  // VPN / system tunnels
      || name.hasPrefix("ipsec")  // IPSec tunnels
      || name.hasPrefix("pdp_ip")  // iPhone tethering
      || name.hasPrefix("ppp")  // Point-to-Point Protocol
  }
}
