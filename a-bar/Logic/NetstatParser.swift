import Foundation

/// Summing per-interface byte counters out of `netstat -ibn` output.
///
/// This is the fallback path for network throughput, used when the native `getifaddrs` read
/// comes back empty. `netstat` lists one row per interface *per address family*, so a single
/// interface appears several times with the same cumulative counters - adding every row would
/// count the same traffic two or three times over.
enum NetstatParser {

  struct Totals: Equatable {
    var received: UInt64 = 0
    var sent: UInt64 = 0
  }

  /// Total bytes in and out across every real data interface.
  ///
  /// Input is the already-reduced output of `netstat -ibn | awk '{print $1,$7,$10}'`: an
  /// interface name and two counters per line. Loopback and virtual interfaces are dropped by
  /// `NetworkInterfaces.isValidDataInterface`; a row that does not parse is skipped rather
  /// than failing the whole reading.
  static func totals(_ output: String) -> Totals {
    var seen: [String: (rx: UInt64, tx: UInt64)] = [:]

    for line in output.split(separator: "\n") {
      let parts = line.split(separator: " ", omittingEmptySubsequences: true)
      guard parts.count >= 3 else { continue }

      let name = String(parts[0])
      guard NetworkInterfaces.isValidDataInterface(name) else { continue }
      guard let rx = UInt64(parts[1]), let tx = UInt64(parts[2]) else { continue }

      // One row per address family, all carrying the same interface totals. Keep the
      // largest seen rather than summing, so en0 listed for link, inet and inet6 counts once.
      let previous = seen[name] ?? (0, 0)
      seen[name] = (max(previous.rx, rx), max(previous.tx, tx))
    }

    return seen.values.reduce(into: Totals()) { totals, counters in
      totals.received &+= counters.rx
      totals.sent &+= counters.tx
    }
  }
}
