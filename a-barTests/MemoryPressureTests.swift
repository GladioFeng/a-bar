import XCTest

/// Which of the kernel's page buckets count as "used" is the whole decision here, and it is
/// not the obvious one: compressed pages are in use even though they have been squeezed, and
/// inactive pages are available even though they still hold something. Getting either wrong
/// moves the number on the bar without changing anything about the machine.
final class MemoryPressureTests: XCTestCase {

    private func pages(
        active: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0,
        free: UInt64 = 0, inactive: UInt64 = 0
    ) -> MemoryPressure.Pages {
        MemoryPressure.Pages(
            active: active, wired: wired, compressed: compressed, free: free, inactive: inactive)
    }

    func testUsedIsActivePlusWiredPlusCompressed() {
        // 30 used against 70 available.
        let value = MemoryPressure.percentage(
            pages(active: 10, wired: 10, compressed: 10, free: 70))

        XCTAssertEqual(value, 30, accuracy: 0.001)
    }

    func testAvailableIsFreePlusInactive() {
        let value = MemoryPressure.percentage(pages(active: 50, free: 25, inactive: 25))

        XCTAssertEqual(value, 50, accuracy: 0.001)
    }

    func testCompressedPagesCountAsUsed() {
        let withCompression = MemoryPressure.percentage(pages(compressed: 50, free: 50))

        XCTAssertEqual(withCompression, 50, accuracy: 0.001,
                       "squeezed is still occupied")
    }

    func testInactivePagesCountAsAvailable() {
        let value = MemoryPressure.percentage(pages(active: 50, inactive: 50))

        XCTAssertEqual(value, 50, accuracy: 0.001,
                       "inactive holds something but can be reclaimed")
    }

    func testEverythingInUseReadsAsOneHundred() {
        XCTAssertEqual(MemoryPressure.percentage(pages(active: 8, wired: 2)), 100)
    }

    func testEverythingFreeReadsAsZero() {
        XCTAssertEqual(MemoryPressure.percentage(pages(free: 8, inactive: 2)), 0)
    }

    func testAllZeroPageCountsReadAsZeroRatherThanDividingByNothing() {
        XCTAssertEqual(MemoryPressure.percentage(pages()), 0)
    }

    func testTheResultIsARatioSoTheScaleOfTheCountsDoesNotMatter() {
        let small = MemoryPressure.percentage(pages(active: 3, free: 1))
        let large = MemoryPressure.percentage(pages(active: 3_000_000, free: 1_000_000))

        XCTAssertEqual(small, large, accuracy: 0.001)
    }

    func testRealisticCountsStayInRange() {
        let value = MemoryPressure.percentage(
            pages(active: 1_200_000, wired: 900_000, compressed: 300_000,
                  free: 80_000, inactive: 1_100_000))

        XCTAssertGreaterThan(value, 0)
        XCTAssertLessThan(value, 100)
    }
}
