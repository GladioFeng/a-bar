import Foundation

/// Snapshots the system widgets publish.
///
/// These used to live at the tail of `SystemInfoService`, behind IOKit, CoreAudio, Mach and
/// Carbon. Nothing here needs any of that - they are the plain numbers the battery, storage and
/// disk widgets read - so they sit on their own where the thresholds that change what the user
/// sees can be tested.

/// Battery charge and the power state around it.
struct BatteryInfo: Equatable {
  var percentage: Int = 100
  var isCharging: Bool = false
  var isLowPowerMode: Bool = false

  /// A battery on the way out. Charging is not low however little is left, because the number is
  /// already climbing.
  var isLow: Bool {
    percentage < 20 && !isCharging
  }
}

/// One mounted volume.
struct StorageVolume: Identifiable, Equatable {
  /// Freshly minted per instance, so `Equatable` compares identity rather than contents: two
  /// readings of the same disk are never equal.
  let id = UUID()
  let name: String
  let url: URL
  let totalBytes: Int
  let usedBytes: Int

  /// Used share of the volume, `0...1`. An unreadable volume reports a total of zero, which would
  /// divide to NaN and take every threshold with it.
  var fullness: Double {
    guard totalBytes > 0 else { return 0 }
    return Double(usedBytes) / Double(totalBytes)
  }

  var fullnessPercent: Int {
    Int((fullness * 100).rounded())
  }

  var formattedTotal: String {
    ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
  }

  var formattedUsed: String {
    ByteCountFormatter.string(fromByteCount: Int64(usedBytes), countStyle: .file)
  }
}

/// Disk throughput, in bytes per second.
struct DiskIOStats: Equatable {
  var read: UInt64 = 0
  var write: UInt64 = 0

  var formattedRead: String {
    Double(read).formattedTransferRate(spacedUnits: true)
  }

  var formattedWrite: String {
    Double(write).formattedTransferRate(spacedUnits: true)
  }
}
