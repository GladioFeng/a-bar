import XCTest

/// The kernel's tick counters are cumulative since boot, so the percentage on screen is
/// entirely a property of the difference between two readings. The cases that matter are the
/// ones where no honest percentage exists - and there, saying nothing has to be distinct from
/// saying zero, because a reported 0% draws a notch on the graph that never happened.
final class CPUTicksTests: XCTestCase {

    /// One core's worth of counters: user, system, idle, nice.
    private func core(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64 = 0) -> [UInt64] {
        [user, system, idle, nice]
    }

    // MARK: - The ordinary case

    func testAFullyBusyCoreReadsAsOneHundredPercent() {
        let usage = CPUTicks.usage(
            previous: core(user: 0, system: 0, idle: 0),
            current: core(user: 50, system: 50, idle: 0))

        XCTAssertEqual(usage, 100)
    }

    func testAFullyIdleCoreReadsAsZero() {
        let usage = CPUTicks.usage(
            previous: core(user: 0, system: 0, idle: 0),
            current: core(user: 0, system: 0, idle: 100))

        XCTAssertEqual(usage, 0)
    }

    func testHalfBusyReadsAsFifty() {
        let usage = CPUTicks.usage(
            previous: core(user: 0, system: 0, idle: 0),
            current: core(user: 40, system: 10, idle: 50))

        XCTAssertEqual(try XCTUnwrap(usage), 50, accuracy: 0.001)
    }

    func testNiceTimeCountsAsBusy() {
        let usage = CPUTicks.usage(
            previous: core(user: 0, system: 0, idle: 0, nice: 0),
            current: core(user: 0, system: 0, idle: 50, nice: 50))

        XCTAssertEqual(try XCTUnwrap(usage), 50, accuracy: 0.001)
    }

    func testOnlyTheDifferenceCountsNotTheAbsoluteCounters() {
        // Two readings taken long after boot, with one busy tick and one idle tick between.
        let usage = CPUTicks.usage(
            previous: core(user: 1_000_000, system: 500_000, idle: 9_000_000),
            current: core(user: 1_000_001, system: 500_000, idle: 9_000_001))

        XCTAssertEqual(try XCTUnwrap(usage), 50, accuracy: 0.001)
    }

    func testUsageAveragesAcrossCores() {
        // One core pinned, one idle, across the same interval.
        let usage = CPUTicks.usage(
            previous: core(user: 0, system: 0, idle: 0) + core(user: 0, system: 0, idle: 0),
            current: core(user: 100, system: 0, idle: 0) + core(user: 0, system: 0, idle: 100))

        XCTAssertEqual(try XCTUnwrap(usage), 50, accuracy: 0.001)
    }

    // MARK: - When no percentage can be computed

    func testTheFirstReadingHasNothingToCompareAgainst() {
        XCTAssertNil(CPUTicks.usage(previous: nil, current: core(user: 1, system: 1, idle: 1)),
                     "nil, not zero - there is no measurement yet")
    }

    func testACoreCountThatChangedBetweenReadingsIsNotComparable() {
        let usage = CPUTicks.usage(
            previous: core(user: 0, system: 0, idle: 0),
            current: core(user: 1, system: 1, idle: 1) + core(user: 1, system: 1, idle: 1))

        XCTAssertNil(usage)
    }

    func testNoElapsedTicksMeansNoMeasurement() {
        let same = core(user: 10, system: 10, idle: 10)

        XCTAssertNil(CPUTicks.usage(previous: same, current: same),
                     "two identical readings measure nothing, they do not measure idle")
    }

    func testACounterGoingBackwardsIsDiscardedRatherThanWrapped() {
        // A core that went offline and came back resets its counters. Subtracting through
        // that on unsigned arithmetic would wrap to an astronomical delta.
        let usage = CPUTicks.usage(
            previous: core(user: 500, system: 500, idle: 500),
            current: core(user: 10, system: 10, idle: 10))

        XCTAssertNil(usage)
    }

    func testAResetOnAnySingleCounterDiscardsTheWholeReading() {
        let usage = CPUTicks.usage(
            previous: core(user: 100, system: 100, idle: 100, nice: 100),
            current: core(user: 200, system: 200, idle: 200, nice: 50))

        XCTAssertNil(usage, "the nice counter alone went backwards")
    }

    func testAnEmptyReadingIsNotAMeasurement() {
        XCTAssertNil(CPUTicks.usage(previous: [], current: []))
    }

    func testATruncatedReadingIsRejected() {
        // Not a whole number of cores, so the stride would read past the end.
        XCTAssertNil(CPUTicks.usage(previous: [0, 0, 0], current: [1, 1, 1]))
    }

    // MARK: - Range

    func testUsageStaysWithinZeroAndOneHundred() {
        for busy in stride(from: UInt64(0), through: 100, by: 7) {
            let usage = CPUTicks.usage(
                previous: core(user: 0, system: 0, idle: 0),
                current: core(user: busy, system: 0, idle: 100 - busy))
            let value = try? XCTUnwrap(usage)
            XCTAssertNotNil(value)
            XCTAssertGreaterThanOrEqual(value ?? -1, 0)
            XCTAssertLessThanOrEqual(value ?? 101, 100)
        }
    }
}
