import Foundation

/// Turning a pair of monotonic byte counters into a per-second rate.
///
/// The network and disk widgets each read a counter that only ever climbs, and each used to do
/// its own subtraction against its own pair of stored properties and an ambient `Date()`. Both
/// had to answer the same awkward questions - what a counter going backwards means, what a
/// zero-length interval means - and they answered them differently, in code no test could reach.
///
/// The timestamp is a defaulted parameter rather than an injected clock, the same shape
/// `SettingsStore(writeDelay:)` uses: production call sites are unchanged.
struct RateSampler {

  /// What it means for a counter to read lower than it did last time.
  ///
  /// The two call sites genuinely disagreed, and both readings are defensible, so this stays a
  /// choice rather than being unified away.
  enum ResetPolicy {
    /// The counter restarted, so the whole new reading is this interval's traffic. What the
    /// network stats have always done - an interface that re-attaches reports from zero again.
    case countWholeReading
    /// Report no traffic for the interval. What the disk stats have always done - a disk that
    /// disappears and returns is not a burst of I/O.
    case reportNothing
  }

  /// A pair of rates in bytes per second. Inbound is download for the network and reads for the
  /// disk; outbound is upload and writes.
  struct Rates: Equatable {
    var inbound: UInt64 = 0
    var outbound: UInt64 = 0
  }

  private let policy: ResetPolicy
  private var previous: (inbound: UInt64, outbound: UInt64)?
  private var lastSampleTime: Date?

  init(onCounterReset policy: ResetPolicy) {
    self.policy = policy
  }

  /// Rate since the last sample. The first sample of all establishes the baseline and reports
  /// nothing, because one reading of a running total says nothing about a rate.
  mutating func sample(
    inbound: UInt64, outbound: UInt64, at now: Date = Date()
  ) -> Rates {
    guard let previous, let lastSampleTime else {
      self.previous = (inbound, outbound)
      self.lastSampleTime = now
      return Rates()
    }

    let elapsed = now.timeIntervalSince(lastSampleTime)

    // Two samples inside the same instant measure nothing. The baseline deliberately stays where
    // it is, so the next real sample still measures across the whole interval rather than losing
    // everything that moved in between.
    if elapsed == 0 { return Rates() }

    self.previous = (inbound, outbound)
    self.lastSampleTime = now

    // The clock went backwards, which an NTP correction does. The baseline has already moved to
    // the new time - holding the old one would stall the graph at zero until wall-clock time
    // caught back up.
    guard elapsed > 0 else { return Rates() }

    return Rates(
      inbound: rate(from: previous.inbound, to: inbound, over: elapsed),
      outbound: rate(from: previous.outbound, to: outbound, over: elapsed))
  }

  private func rate(from previous: UInt64, to current: UInt64, over elapsed: TimeInterval) -> UInt64
  {
    let delta: UInt64
    if current >= previous {
      delta = current - previous
    } else {
      switch policy {
      case .countWholeReading: delta = current
      case .reportNothing: delta = 0
      }
    }

    // `UInt64(someDouble)` traps rather than saturating, and a short enough interval divides any
    // delta past `UInt64.max`. No timer fires close enough for that today; the clamp costs one
    // comparison and means the type's promise holds for every input rather than every expected
    // one.
    let perSecond = Double(delta) / elapsed
    guard perSecond > 0 else { return 0 }
    guard perSecond < Double(UInt64.max) else { return .max }
    return UInt64(perSecond)
  }
}
