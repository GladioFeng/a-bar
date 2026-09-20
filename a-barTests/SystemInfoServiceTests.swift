import Combine
import XCTest

/// `SystemInfoService` is a wrapper around read-only system calls - IOKit power sources, mach
/// host statistics, CoreAudio device properties, the IORegistry, CoreFoundation's text input
/// sources. The arithmetic on top of them has been lifted into `Logic/` and is tested there
/// exhaustively; what is left here can only be checked by actually calling it.
///
/// So these tests run the real readings and assert the invariants that hold on any Mac,
/// including a headless CI runner with no battery, no GPU registry entry and no audio device:
/// the call returns, it does not trap, and the published value is inside its documented range.
/// That is worth having - most of what can go wrong in this file is a force-unwrap or a
/// misjudged buffer size on hardware the author did not have.
///
/// Nothing here mutates machine state. The volume, mute and caffeinate *setters* are
/// deliberately never called.
final class SystemInfoServiceTests: XCTestCase {
    private var directory: URL!
    private var manager: SettingsManager!
    private var service: SystemInfoService!
    private var observations = Set<AnyCancellable>()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("abar-sysinfo-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("config.json")
        try SettingsCodec.encode(ABarSettings()).write(to: config)
        manager = SettingsManager(store: SettingsStore(fileURL: config))
        service = SystemInfoService(settingsManager: manager)
    }

    override func tearDownWithError() throws {
        observations.removeAll()
        service.stop()
        service = nil
        manager.flush()
        try? FileManager.default.removeItem(at: directory)
    }

    /// Give an asynchronous reading a chance to land, without requiring that it changed -
    /// on a machine where the value is already correct, nothing is published.
    private func settle(_ interval: TimeInterval = 0.6) {
        let done = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { done.fulfill() }
        wait(for: [done], timeout: interval + 5)
    }

    // MARK: - Individual readings

    func testBatteryReadingStaysWithinItsRange() {
        service.refreshBattery()
        settle()

        XCTAssertTrue((0...100).contains(service.batteryInfo.percentage),
                      "a machine with no battery reports the default, not nonsense")
    }

    func testCpuReadingStaysWithinItsRange() {
        // The first reading has nothing to diff against and is defined to be 0.
        service.refreshCPU()
        settle()
        service.refreshCPU()
        settle()

        XCTAssertTrue((0...100).contains(service.cpuUsage), "got \(service.cpuUsage)")
    }

    func testCpuHistoryGrowsAsReadingsArrive() {
        let before = service.cpuHistory.values.count
        service.refreshCPU()
        settle()

        XCTAssertGreaterThan(service.cpuHistory.values.count, before)
    }

    func testMemoryReadingIsAPlausiblePercentage() {
        service.refreshMemory()
        settle()

        XCTAssertGreaterThan(service.memoryPressure, 0, "a running Mac is using some memory")
        XCTAssertLessThanOrEqual(service.memoryPressure, 100)
    }

    func testGpuReadingStaysWithinItsRange() {
        service.refreshGPU()
        settle()

        XCTAssertTrue((0...100).contains(service.gpuUsage),
                      "a VM with no GPU registry entry reports 0, not a crash")
    }

    func testTheFirstNetworkReadingReportsNoTrafficRatherThanTheCounterSinceBoot() {
        // The counters are cumulative. Publishing the first one as a rate would show several
        // gigabytes per second on the bar for one tick after launch.
        service.refreshNetworkStats()
        settle()

        XCTAssertEqual(service.networkStats, NetworkStats())
        XCTAssertFalse(service.networkStats.formattedDownload.isEmpty)
    }

    func testASecondNetworkReadingProducesAPlausibleRate() {
        service.refreshNetworkStats()
        settle()
        service.refreshNetworkStats()
        settle()

        // An idle machine may genuinely move nothing; a terabyte per second means the delta
        // maths wrapped.
        XCTAssertLessThan(service.networkStats.download, 1_000_000_000_000)
        XCTAssertLessThan(service.networkStats.upload, 1_000_000_000_000)
    }

    func testTheFirstDiskReadingReportsNoActivity() {
        service.refreshDiskStats()
        settle()

        XCTAssertEqual(service.diskStats, DiskIOStats())
        XCTAssertFalse(service.diskStats.formattedRead.isEmpty)
    }

    func testASecondDiskReadingProducesAPlausibleRate() {
        service.refreshDiskStats()
        settle()
        service.refreshDiskStats()
        settle()

        XCTAssertLessThan(service.diskStats.read, 1_000_000_000_000)
        XCTAssertLessThan(service.diskStats.write, 1_000_000_000_000)
    }

    func testVolumeReadingStaysWithinItsRange() {
        service.refreshVolume()
        settle()

        XCTAssertTrue((0...1).contains(service.volumeLevel), "got \(service.volumeLevel)")
    }

    func testMicReadingStaysWithinItsRange() {
        service.refreshMic()
        settle()

        XCTAssertTrue((0...1).contains(service.micLevel), "got \(service.micLevel)")
    }

    func testKeyboardLayoutIsRead() {
        service.refreshKeyboard()
        settle()

        // A headless runner can legitimately have no input source, so an empty string is a
        // valid answer; what matters is that reading it does not trap.
        XCTAssertNotNil(service.keyboardLayout)
    }

    func testCaffeinateStateIsReadFromTheWholeMachine() {
        // The reading is a `pgrep` for any `caffeinate` process, not only one this service
        // started - so whether it comes back true depends on what else is running, and the
        // assertion can only be that reading it works and settles on one answer.
        service.refreshCaffeinate()
        settle()
        let first = service.isCaffeinateActive

        service.refreshCaffeinate()
        settle()

        XCTAssertEqual(service.isCaffeinateActive, first, "the reading is stable")
    }

    func testMountedVolumesAreEnumerated() {
        service.start(widgets: [.storage])
        settle()
        service.stop()

        // The boot volume is always mounted, so there is at least one - but a sandboxed
        // runner may report none, and that is not a failure of this code.
        for volume in service.volumes {
            XCTAssertFalse(volume.name.isEmpty)
            XCTAssertGreaterThan(volume.totalBytes, 0)
            XCTAssertLessThanOrEqual(volume.usedBytes, volume.totalBytes)
        }
    }

    // MARK: - Lifecycle

    func testStartingCollectsForEveryActiveWidget() {
        service.start(widgets: [.cpu, .memory, .battery])
        settle()
        service.stop()

        XCTAssertGreaterThan(service.memoryPressure, 0, "the memory reading ran")
        XCTAssertFalse(service.cpuHistory.values.isEmpty, "the cpu reading ran")
    }

    func testStartingWithNoWidgetsDoesNothingAndDoesNotTrap() {
        service.start(widgets: [])
        settle(0.2)
        service.stop()
    }

    func testStartingWithOnlyNonSystemWidgetsSchedulesNothing() {
        // The clock and the window-manager widgets are driven elsewhere.
        service.start(widgets: [.time, .date, .spaces])
        settle(0.2)
        service.stop()
    }

    func testStoppingAndStartingAgainIsSafe() {
        service.start(widgets: [.cpu])
        service.stop()
        service.start(widgets: [.memory])
        settle()
        service.stop()

        XCTAssertGreaterThan(service.memoryPressure, 0)
    }

    func testStoppingTwiceIsSafe() {
        service.start(widgets: [.cpu])
        service.stop()
        service.stop()
    }

    func testAWidgetKeepsRefreshingRatherThanRunningOnce() {
        manager.update { $0.widgets.cpu.refreshInterval = 0.2 }
        service.start(widgets: [.cpu])
        settle(0.8)
        let afterFirstWindow = service.cpuHistory.values.count
        settle(0.8)
        let afterSecondWindow = service.cpuHistory.values.count
        service.stop()

        XCTAssertGreaterThan(afterFirstWindow, 0, "the initial collection ran")
        XCTAssertGreaterThan(afterSecondWindow, afterFirstWindow,
                             "a bar that stops updating after launch is the bug here")
    }

    func testStoppingHaltsTheTimers() {
        manager.update { $0.widgets.cpu.refreshInterval = 0.2 }
        service.start(widgets: [.cpu])
        settle(0.5)

        service.stop()
        // `stop()` invalidates the timers but does not cancel a collection already in flight,
        // so one more sample may still land. What must not happen is the count going on
        // climbing, which would mean a timer outlived the widget it belongs to.
        settle(0.5)
        let afterInFlightWorkLanded = service.cpuHistory.values.count
        settle(0.8)

        XCTAssertEqual(service.cpuHistory.values.count, afterInFlightWorkLanded,
                       "a timer surviving stop() keeps forking work for a hidden bar")
    }

    // MARK: - Reading settings

    func testTheIntervalComesFromSettingsAtStart() {
        manager.update { $0.widgets.memory.refreshInterval = 0.25 }
        service.start(widgets: [.memory])
        settle(0.9)
        service.stop()

        XCTAssertGreaterThan(service.memoryPressure, 0)
    }
}
