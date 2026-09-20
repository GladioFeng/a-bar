import Foundation

/// Turning two readings of the kernel's per-core tick counters into a utilization percentage.
///
/// Lifted out of `SystemInfoService`, where it sat between a `host_processor_info` call and a
/// `vm_deallocate`, so the arithmetic could not be reached without the syscall. The counters
/// are cumulative since boot: a single reading says nothing, and the number on screen is
/// entirely a property of the difference between two of them.
enum CPUTicks {

  /// The four counters the kernel keeps per core, in the order `PROCESSOR_CPU_LOAD_INFO`
  /// reports them.
  static let statesPerCore = 4

  /// Percentage of non-idle time across all cores between two readings, 0...100.
  ///
  /// Returns nil when no percentage can be honestly computed: no previous reading, a core
  /// count that changed between readings, or no time elapsed at all. Nil means "say nothing",
  /// which is not the same as 0% - reporting an idle CPU because a reading was missing is how
  /// a graph grows a notch that never happened.
  static func usage(previous: [UInt64]?, current: [UInt64]) -> Double? {
    guard let previous,
          previous.count == current.count,
          !current.isEmpty,
          current.count % statesPerCore == 0
    else { return nil }

    var totalDelta: UInt64 = 0
    var idleDelta: UInt64 = 0

    for base in stride(from: 0, to: current.count, by: statesPerCore) {
      // Counters only climb, but a core that goes offline and comes back can reset them.
      // Subtracting through that would wrap into an enormous delta, so the whole reading is
      // discarded rather than allowed to spike the graph.
      for offset in 0..<statesPerCore where current[base + offset] < previous[base + offset] {
        return nil
      }
      let user = current[base] - previous[base]
      let system = current[base + 1] - previous[base + 1]
      let idle = current[base + 2] - previous[base + 2]
      let nice = current[base + 3] - previous[base + 3]

      totalDelta += user + system + idle + nice
      idleDelta += idle
    }

    guard totalDelta > 0 else { return nil }
    return 100.0 * Double(totalDelta - idleDelta) / Double(totalDelta)
  }
}
