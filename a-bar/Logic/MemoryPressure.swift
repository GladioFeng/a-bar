import Foundation

/// Memory pressure as Activity Monitor computes it, from the kernel's page counts.
///
/// Lifted out of `SystemInfoService`, where it followed a `host_statistics64` call. Which
/// buckets count as used is the whole decision here, and it is not obvious: compressed pages
/// are used even though they have been squeezed, and inactive pages are available even though
/// they hold something.
enum MemoryPressure {

  /// The page counts this needs, named so a caller reading them off `vm_statistics64` has to
  /// say which is which.
  struct Pages: Equatable {
    var active: UInt64
    var wired: UInt64
    var compressed: UInt64
    var free: UInt64
    var inactive: UInt64

    init(active: UInt64, wired: UInt64, compressed: UInt64, free: UInt64, inactive: UInt64) {
      self.active = active
      self.wired = wired
      self.compressed = compressed
      self.free = free
      self.inactive = inactive
    }
  }

  /// Percentage of memory in use, 0...100.
  ///
  /// Used is wired + active + compressed; available is free + inactive. The page size cancels
  /// out of the ratio, so it is not asked for.
  static func percentage(_ pages: Pages) -> Double {
    let used = pages.active + pages.wired + pages.compressed
    let available = pages.free + pages.inactive
    let total = used + available
    guard total > 0 else { return 0 }
    return Double(used) / Double(total) * 100.0
  }
}
