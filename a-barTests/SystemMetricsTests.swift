import XCTest

/// The numbers behind the battery, storage and disk widgets, at the thresholds where they change
/// what the user sees. These used to sit behind IOKit, CoreAudio, Mach and Carbon in a 1200-line
/// service, so none of the boundaries below had ever been checked.
final class SystemMetricsTests: XCTestCase {

  private func volume(total: Int, used: Int) -> StorageVolume {
    StorageVolume(name: "Macintosh HD", url: URL(fileURLWithPath: "/"), totalBytes: total,
      usedBytes: used)
  }

  // MARK: - Battery

  func testABatteryIsLowOnlyBelowTwentyPercent() {
    XCTAssertTrue(BatteryInfo(percentage: 19).isLow)
    XCTAssertFalse(BatteryInfo(percentage: 20).isLow, "20 is the boundary and is not low")
    XCTAssertFalse(BatteryInfo(percentage: 21).isLow)
  }

  func testAChargingBatteryIsNeverLowHoweverLittleIsLeft() {
    // The number is already climbing, so warning about it would be noise the user cannot act on.
    XCTAssertFalse(BatteryInfo(percentage: 1, isCharging: true).isLow)
    XCTAssertFalse(BatteryInfo(percentage: 0, isCharging: true).isLow)
  }

  func testAnEmptyBatteryOnBatteryPowerIsLow() {
    XCTAssertTrue(BatteryInfo(percentage: 0).isLow)
  }

  func testTheDefaultBatteryReadsAsFullAndNotLow() {
    // What the widget shows before the first IOKit read lands.
    let fresh = BatteryInfo()

    XCTAssertEqual(fresh.percentage, 100)
    XCTAssertFalse(fresh.isLow)
    XCTAssertFalse(fresh.isCharging)
  }

  // MARK: - Storage

  func testFullnessIsTheUsedShareOfTheVolume() {
    XCTAssertEqual(volume(total: 1000, used: 250).fullness, 0.25, accuracy: 0.0001)
    XCTAssertEqual(volume(total: 1000, used: 1000).fullness, 1, accuracy: 0.0001)
    XCTAssertEqual(volume(total: 1000, used: 0).fullness, 0, accuracy: 0.0001)
  }

  func testAVolumeReportingNoCapacityIsNotFullAndIsNotNaN() {
    // An unreadable or still-mounting volume reports a total of zero. Dividing by it yields NaN,
    // which fails every threshold comparison silently and draws a pie chart of nothing.
    let unreadable = volume(total: 0, used: 0)

    XCTAssertEqual(unreadable.fullness, 0)
    XCTAssertFalse(unreadable.fullness.isNaN)
    XCTAssertEqual(unreadable.fullnessPercent, 0)
  }

  func testTheDisplayedPercentageRoundsRatherThanTruncates() {
    // 99.6% full must read 100, not 99 - the number the user checks before a big copy.
    XCTAssertEqual(volume(total: 1000, used: 996).fullnessPercent, 100)
    XCTAssertEqual(volume(total: 1000, used: 994).fullnessPercent, 99)
    XCTAssertEqual(volume(total: 1000, used: 5).fullnessPercent, 1)
  }

  func testAVolumeAtTheThresholdsThePaletteWarnsAt() {
    // `WidgetPalette` turns storage red above 0.9 and yellow above 0.75.
    XCTAssertEqual(volume(total: 100, used: 90).fullness, 0.9, accuracy: 0.0001)
    XCTAssertEqual(volume(total: 100, used: 75).fullness, 0.75, accuracy: 0.0001)
  }

  func testTheFormattedSizesAreHumanReadableAndAgreeWithTheBytes() {
    let ten = volume(total: 10_000_000_000, used: 2_500_000_000)

    XCTAssertTrue(ten.formattedTotal.contains("10"), ten.formattedTotal)
    XCTAssertTrue(ten.formattedTotal.uppercased().contains("GB"), ten.formattedTotal)
    XCTAssertTrue(ten.formattedUsed.contains("2"), ten.formattedUsed)
  }

  func testTwoReadingsOfTheSameVolumeAreNotEqual() {
    // `id` is a fresh UUID per instance, so the synthesized `Equatable` compares identity rather
    // than contents. Nothing depends on it today - the published array is not equality-gated -
    // but a change-detection gate added later would never fire, and every refresh hands SwiftUI
    // brand-new row identities. Pinned so the conformance is not mistaken for a value comparison.
    XCTAssertNotEqual(volume(total: 1000, used: 500), volume(total: 1000, used: 500))
  }

  // MARK: - Disk throughput

  func testAnIdleDiskFormatsAsZeroRatherThanBlank() {
    let idle = DiskIOStats()

    XCTAssertEqual(idle.read, 0)
    XCTAssertFalse(idle.formattedRead.isEmpty)
    XCTAssertTrue(idle.formattedRead.contains("0"), idle.formattedRead)
  }

  func testThroughputCrossesIntoTheNextUnitAtTheBinaryBoundary() {
    XCTAssertEqual(DiskIOStats(read: 1023).formattedRead, 1023.0.formattedTransferRate(
      spacedUnits: true))
    XCTAssertEqual(DiskIOStats(read: 1024).formattedRead, 1024.0.formattedTransferRate(
      spacedUnits: true))
    XCTAssertNotEqual(DiskIOStats(read: 1023).formattedRead, DiskIOStats(read: 1024).formattedRead)
  }

  func testReadsAndWritesAreFormattedIndependently() {
    let busy = DiskIOStats(read: 5_242_880, write: 1024)

    XCTAssertNotEqual(busy.formattedRead, busy.formattedWrite)
  }
}
