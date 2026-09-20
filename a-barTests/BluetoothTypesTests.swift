import XCTest

/// The derived properties on the Bluetooth models decide what the popover shows: which rows
/// count as connected, whether a battery reading exists at all, and which level drives the
/// low-battery tint. Each one has an empty or all-absent case that has to behave.
final class BluetoothTypesTests: XCTestCase {

    private func device(
        _ name: String,
        connected: Bool = false,
        kind: BluetoothDeviceKind = .other
    ) -> BluetoothPairedDevice {
        BluetoothPairedDevice(
            id: name.lowercased(), address: "ac-bf-71-09-96-af",
            name: name, isConnected: connected, kind: kind)
    }

    // MARK: - BluetoothInfo

    func testConnectedDevicesKeepsOnlyTheConnectedOnes() {
        let info = BluetoothInfo(devices: [
            device("Keyboard", connected: true),
            device("Old Mouse"),
            device("AirPods", connected: true),
        ])

        XCTAssertEqual(info.connectedDevices.map(\.name), ["Keyboard", "AirPods"])
    }

    func testConnectedDevicesIsEmptyWhenNothingIsConnected() {
        XCTAssertTrue(BluetoothInfo(devices: [device("Old Mouse")]).connectedDevices.isEmpty)
    }

    func testAFreshInfoReportsNoControllerButAssumesTheToggleWorks() {
        let info = BluetoothInfo()

        XCTAssertFalse(info.hasController)
        XCTAssertFalse(info.isPoweredOn)
        XCTAssertTrue(info.canTogglePower,
                      "the toggle is only ruled out once resolving its symbol has failed")
    }

    // MARK: - BluetoothBatteryLevels

    func testLevelsAreEmptyOnlyWhenEveryReadingIsAbsent() {
        XCTAssertTrue(BluetoothBatteryLevels().isEmpty)
        XCTAssertFalse(BluetoothBatteryLevels(main: 80).isEmpty)
        XCTAssertFalse(BluetoothBatteryLevels(left: 80).isEmpty)
        XCTAssertFalse(BluetoothBatteryLevels(right: 80).isEmpty)
        XCTAssertFalse(BluetoothBatteryLevels(caseLevel: 80).isEmpty)
    }

    func testLowestIgnoresAbsentReadings() {
        // AirPods report three levels and no `main`; a headset reports only `main`.
        XCTAssertEqual(BluetoothBatteryLevels(left: 70, right: 55, caseLevel: 90).lowest, 55)
        XCTAssertEqual(BluetoothBatteryLevels(main: 42).lowest, 42)
    }

    func testLowestOfNothingIsNothing() {
        XCTAssertNil(BluetoothBatteryLevels().lowest,
                     "no reading is not the same as a reading of zero")
    }

    func testAZeroReadingIsStillAReading() {
        XCTAssertEqual(BluetoothBatteryLevels(main: 0, left: 50).lowest, 0)
        XCTAssertFalse(BluetoothBatteryLevels(main: 0).isEmpty)
    }

    // MARK: - BluetoothDeviceKind

    func testEveryKindMapsToADistinctSymbol() {
        let kinds: [BluetoothDeviceKind] = [
            .headphones, .speaker, .keyboard, .mouse, .gamepad, .phone, .watch, .computer, .other,
        ]
        let symbols = kinds.map(\.symbolName)

        XCTAssertFalse(symbols.contains(where: \.isEmpty))
        XCTAssertEqual(Set(symbols).count, kinds.count,
                       "two kinds sharing an icon makes them indistinguishable in the popover")
    }
}
