import XCTest

/// A counter that resets, stalls or jumps must not produce a negative, infinite or absurd rate.
/// These are cumulative byte counters read off live hardware: an interface re-attaches, a disk is
/// unmounted, NTP corrects the clock. Each of those used to be handled differently by the network
/// and the disk widget, in code no test could reach.
final class RateSamplerTests: XCTestCase {

  private let start = Date(timeIntervalSince1970: 1_000_000)

  private func advanced(_ seconds: TimeInterval) -> Date {
    start.addingTimeInterval(seconds)
  }

  // MARK: - The baseline

  func testTheFirstSampleReportsNothing() {
    // One reading of a running total says nothing about a rate. Reporting the counter itself
    // would spike the graph to the machine's lifetime traffic on the first tick.
    var sampler = RateSampler(onCounterReset: .countWholeReading)

    let rates = sampler.sample(inbound: 5_000_000, outbound: 900_000, at: start)

    XCTAssertEqual(rates, RateSampler.Rates())
  }

  func testTheSecondSampleMeasuresAcrossTheInterval() {
    var sampler = RateSampler(onCounterReset: .countWholeReading)
    _ = sampler.sample(inbound: 1000, outbound: 100, at: start)

    let rates = sampler.sample(inbound: 3000, outbound: 300, at: advanced(2))

    XCTAssertEqual(rates.inbound, 1000, "2000 bytes over 2 seconds")
    XCTAssertEqual(rates.outbound, 100)
  }

  func testEachSampleMeasuresFromTheOneBeforeIt() {
    var sampler = RateSampler(onCounterReset: .countWholeReading)
    _ = sampler.sample(inbound: 0, outbound: 0, at: start)
    _ = sampler.sample(inbound: 100, outbound: 0, at: advanced(1))

    let rates = sampler.sample(inbound: 150, outbound: 0, at: advanced(2))

    XCTAssertEqual(rates.inbound, 50, "not 150 - the baseline moves with every sample")
  }

  func testAStalledCounterReportsZeroRatherThanHoldingTheLastRate() {
    var sampler = RateSampler(onCounterReset: .countWholeReading)
    _ = sampler.sample(inbound: 1000, outbound: 1000, at: start)
    _ = sampler.sample(inbound: 9000, outbound: 9000, at: advanced(1))

    let rates = sampler.sample(inbound: 9000, outbound: 9000, at: advanced(2))

    XCTAssertEqual(rates, RateSampler.Rates(), "an idle interface is idle, not busy")
  }

  // MARK: - A counter that goes backwards

  func testTheNetworkPolicyCountsTheWholeReadingAfterAReset() {
    // An interface that re-attaches starts counting from zero again, so what it reports now is
    // what has moved since it came back.
    var sampler = RateSampler(onCounterReset: .countWholeReading)
    _ = sampler.sample(inbound: 9_000_000, outbound: 9_000_000, at: start)

    let rates = sampler.sample(inbound: 400, outbound: 200, at: advanced(2))

    XCTAssertEqual(rates.inbound, 200)
    XCTAssertEqual(rates.outbound, 100)
  }

  func testTheDiskPolicyReportsNothingAfterAReset() {
    // A disk that disappears and comes back is not a burst of I/O. The two policies differ on
    // purpose: both call sites were written this way, and both readings are defensible.
    var sampler = RateSampler(onCounterReset: .reportNothing)
    _ = sampler.sample(inbound: 9_000_000, outbound: 9_000_000, at: start)

    let rates = sampler.sample(inbound: 400, outbound: 200, at: advanced(2))

    XCTAssertEqual(rates, RateSampler.Rates())
  }

  func testAResetOnOneChannelDoesNotAffectTheOther() {
    var sampler = RateSampler(onCounterReset: .reportNothing)
    _ = sampler.sample(inbound: 5000, outbound: 5000, at: start)

    let rates = sampler.sample(inbound: 10, outbound: 6000, at: advanced(1))

    XCTAssertEqual(rates.inbound, 0, "inbound reset")
    XCTAssertEqual(rates.outbound, 1000, "outbound did not")
  }

  func testAResetStillMovesTheBaseline() {
    var sampler = RateSampler(onCounterReset: .reportNothing)
    _ = sampler.sample(inbound: 5000, outbound: 0, at: start)
    _ = sampler.sample(inbound: 100, outbound: 0, at: advanced(1))

    let rates = sampler.sample(inbound: 300, outbound: 0, at: advanced(2))

    XCTAssertEqual(rates.inbound, 200, "measured from 100, not from 5000")
  }

  // MARK: - A clock that does not move forwards

  func testTwoSamplesInTheSameInstantMeasureNothingAndKeepTheirBaseline() {
    // No time passed, so there is no rate to report. The baseline deliberately stays where it
    // was, so the next real sample still measures across the whole interval instead of losing it.
    var sampler = RateSampler(onCounterReset: .countWholeReading)
    _ = sampler.sample(inbound: 0, outbound: 0, at: start)

    let duplicate = sampler.sample(inbound: 500, outbound: 0, at: start)
    let next = sampler.sample(inbound: 1000, outbound: 0, at: advanced(1))

    XCTAssertEqual(duplicate, RateSampler.Rates())
    XCTAssertEqual(next.inbound, 1000, "1000 bytes since the baseline, over 1 second")
  }

  func testAClockThatGoesBackwardsReportsNothingAndRebaselines() {
    // An NTP correction steps the clock back. Holding the old baseline would stall the graph at
    // zero until wall-clock time caught back up, so the next sample restarts from the new time.
    var sampler = RateSampler(onCounterReset: .countWholeReading)
    _ = sampler.sample(inbound: 1000, outbound: 0, at: advanced(10))

    let backwards = sampler.sample(inbound: 2000, outbound: 0, at: start)
    let recovered = sampler.sample(inbound: 2500, outbound: 0, at: advanced(1))

    XCTAssertEqual(backwards, RateSampler.Rates())
    XCTAssertEqual(recovered.inbound, 500, "measured from the corrected clock, not the old one")
  }

  // MARK: - Arithmetic that must not trap

  func testAnImmeasurablyShortIntervalSaturatesRatherThanTrapping() {
    // `UInt64(someDouble)` traps rather than saturating, so a short enough interval crashes the
    // app rather than drawing a tall bar. No timer fires close enough for this today - it is
    // hardening, not a repair - but the type's promise should hold for every input.
    //
    // The base date is the reference epoch: a nanosecond added to a date far from it rounds away
    // entirely, because a `Double` holding 1e6 seconds cannot resolve one.
    let epoch = Date(timeIntervalSinceReferenceDate: 0)
    var sampler = RateSampler(onCounterReset: .countWholeReading)
    _ = sampler.sample(inbound: 0, outbound: 0, at: epoch)

    let rates = sampler.sample(
      inbound: .max, outbound: .max, at: epoch.addingTimeInterval(1e-9))

    XCTAssertEqual(rates.inbound, .max)
    XCTAssertEqual(rates.outbound, .max)
  }

  func testALongIntervalRoundsDownRatherThanReportingANegativeRate() {
    var sampler = RateSampler(onCounterReset: .countWholeReading)
    _ = sampler.sample(inbound: 0, outbound: 0, at: start)

    let rates = sampler.sample(inbound: 10, outbound: 1, at: advanced(3600))

    XCTAssertEqual(rates.inbound, 0, "a trickle over an hour is under a byte per second")
    XCTAssertEqual(rates.outbound, 0)
  }
}
