import XCTest

/// The same list of widgets used to be spelled out twice inside `SystemInfoService`: once to
/// decide what a refresh collects, once to decide what gets a timer. A widget present in one
/// and absent from the other either refreshes at launch and never again, or ticks forever
/// collecting nothing - and neither shows up as a crash.
final class WidgetRefreshScheduleTests: XCTestCase {

    // MARK: - What a widget collects

    func testEachSystemWidgetCollectsItsOwnReading() {
        let expected: [WidgetIdentifier: WidgetRefreshSchedule.Reading] = [
            .cpu: .cpu, .memory: .memory, .gpu: .gpu,
            .netstats: .networkStats, .diskActivity: .diskStats,
            .sound: .volume, .mic: .mic, .keyboard: .keyboard,
            .storage: .storageVolumes,
        ]
        for (widget, reading) in expected {
            XCTAssertEqual(WidgetRefreshSchedule.readings(for: widget), [reading], "\(widget)")
        }
    }

    func testTheBatteryWidgetAlsoCollectsCaffeinate() {
        // It draws the cup next to the percentage, and that is a separate reading.
        XCTAssertEqual(WidgetRefreshSchedule.readings(for: .battery), [.battery, .caffeinate])
    }

    func testWidgetsThatReadNothingFromTheSystemCollectNothing() {
        for widget: WidgetIdentifier in [.time, .date, .spaces, .process, .weather, .github] {
            XCTAssertTrue(WidgetRefreshSchedule.readings(for: widget).isEmpty, "\(widget)")
        }
    }

    // MARK: - Collecting for a set of widgets

    func testAReadingTwoWidgetsWantIsOnlyCollectedOnce() {
        let readings = WidgetRefreshSchedule.readings(for: [.cpu, .memory, .battery])

        XCTAssertEqual(readings, [.cpu, .memory, .battery, .caffeinate])
    }

    func testNoActiveWidgetsMeansNoWork() {
        XCTAssertTrue(WidgetRefreshSchedule.readings(for: []).isEmpty)
    }

    func testWidgetsWithNothingToCollectContributeNothing() {
        XCTAssertTrue(WidgetRefreshSchedule.readings(for: [.time, .date]).isEmpty)
    }

    // MARK: - Intervals

    func testEachIntervalComesFromThatWidgetsOwnSettings() {
        var settings = WidgetSettings()
        settings.cpu.refreshInterval = 3
        settings.memory.refreshInterval = 7
        settings.storage.refreshInterval = 600

        XCTAssertEqual(WidgetRefreshSchedule.interval(for: .cpu, in: settings), 3)
        XCTAssertEqual(WidgetRefreshSchedule.interval(for: .memory, in: settings), 7)
        XCTAssertEqual(WidgetRefreshSchedule.interval(for: .storage, in: settings), 600)
    }

    func testAWidgetThatIsNotOnATimerHasNoInterval() {
        XCTAssertNil(WidgetRefreshSchedule.interval(for: .time, in: WidgetSettings()))
        XCTAssertNil(WidgetRefreshSchedule.interval(for: .spaces, in: WidgetSettings()))
    }

    // MARK: - Building the timer list

    func testOnlyActiveWidgetsGetTimers() {
        let timers = WidgetRefreshSchedule.timers(for: [.cpu, .time], in: WidgetSettings())

        XCTAssertEqual(timers.map(\.widget), [.cpu], "the clock is not driven from here")
    }

    func testEachTimerIsKeyedByItsWidgetsRawValue() {
        let timers = WidgetRefreshSchedule.timers(for: [.cpu], in: WidgetSettings())

        XCTAssertEqual(timers.first?.id, WidgetIdentifier.cpu.rawValue)
    }

    func testTimersCarryTheConfiguredInterval() {
        var settings = WidgetSettings()
        settings.gpu.refreshInterval = 11

        XCTAssertEqual(WidgetRefreshSchedule.timers(for: [.gpu], in: settings).first?.interval, 11)
    }

    func testTheTimerListIsStableAcrossCalls() {
        // The active set is unordered; rebuilding timers must not reshuffle them.
        let widgets: Set<WidgetIdentifier> = [.cpu, .memory, .gpu, .battery, .storage]
        let first = WidgetRefreshSchedule.timers(for: widgets, in: WidgetSettings()).map(\.id)
        let second = WidgetRefreshSchedule.timers(for: widgets, in: WidgetSettings()).map(\.id)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first, first.sorted())
    }

    func testNoActiveWidgetsSchedulesNothing() {
        XCTAssertTrue(WidgetRefreshSchedule.timers(for: [], in: WidgetSettings()).isEmpty)
    }

    // MARK: - The invariant between the two lists

    func testAWidgetHasATimerIfAndOnlyIfItHasSomethingToCollect() {
        // This is the property the extraction exists to protect. If it ever fails, some widget
        // was added to one switch and not the other.
        for widget in WidgetIdentifier.allCases {
            XCTAssertEqual(
                WidgetRefreshSchedule.readings(for: widget).isEmpty,
                WidgetRefreshSchedule.interval(for: widget, in: WidgetSettings()) == nil,
                "\(widget) appears in one list but not the other")
        }
        XCTAssertTrue(WidgetRefreshSchedule.isConsistent)
    }

    func testEveryReadingIsClaimedBySomeWidget() {
        let claimed = WidgetRefreshSchedule.readings(for: Set(WidgetIdentifier.allCases))

        XCTAssertEqual(claimed, Set(WidgetRefreshSchedule.Reading.allCases),
                       "a reading no widget asks for is collected for nobody")
    }
}
