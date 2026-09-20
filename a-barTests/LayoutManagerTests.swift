import Combine
import XCTest

/// `LayoutManager` is what the bar windows read to decide what to draw. It holds no store of
/// its own - it starts on the active profile's layout and then follows `.profileDidChange`.
/// The subscription is the whole point: without it, switching profiles updates the settings
/// and leaves the bar showing the old one.
final class LayoutManagerTests: XCTestCase {
    private var center: NotificationCenter!
    private var manager: LayoutManager!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        manager = LayoutManager(initialLayout: .defaultLayout, notificationCenter: center)
    }

    override func tearDown() {
        manager = nil; center = nil
        super.tearDown()
    }

    private func layout(display: Int, top: SingleBarLayout? = nil, bottom: SingleBarLayout? = nil)
        -> MultiDisplayLayout
    {
        var result = MultiDisplayLayout(displays: [])
        result.setConfiguration(
            DisplayConfiguration(displayIndex: display, name: "D\(display)",
                                 topBar: top, bottomBar: bottom),
            forDisplay: display)
        return result
    }

    // MARK: - Following the active profile

    func testAProfileChangeReplacesTheLayout() {
        let next = layout(display: 1, top: SingleBarLayout(left: [WidgetInstance(identifier: .time)]))
        let profile = LayoutProfile(name: "Other", multiDisplayLayout: next)

        center.post(name: .profileDidChange, object: profile)

        XCTAssertEqual(manager.multiDisplayLayout, next)
    }

    func testAProfileChangePublishesSoTheBarRedraws() {
        var notified = false
        let token = manager.objectWillChange.sink { _ in notified = true }
        defer { token.cancel() }

        center.post(name: .profileDidChange,
                    object: LayoutProfile(name: "Other", multiDisplayLayout: layout(display: 0)))

        XCTAssertTrue(notified, "an ObservableObject that goes quiet leaves a stale bar on screen")
    }

    func testANotificationCarryingSomethingElseIsIgnored() {
        let before = manager.multiDisplayLayout

        center.post(name: .profileDidChange, object: "not a profile")

        XCTAssertEqual(manager.multiDisplayLayout, before)
    }

    func testANotificationCarryingNothingIsIgnored() {
        let before = manager.multiDisplayLayout

        center.post(name: .profileDidChange, object: nil)

        XCTAssertEqual(manager.multiDisplayLayout, before)
    }

    func testAnotherCentersTrafficDoesNotReachIt() {
        let before = manager.multiDisplayLayout

        NotificationCenter.default.post(
            name: .profileDidChange,
            object: LayoutProfile(name: "Elsewhere", multiDisplayLayout: layout(display: 7)))

        XCTAssertEqual(manager.multiDisplayLayout, before)
    }

    // MARK: - Direct updates

    func testUpdateLayoutReplacesWhatTheBarReads() {
        let next = layout(display: 2)

        manager.updateLayout(next)

        XCTAssertEqual(manager.multiDisplayLayout, next)
    }

    // MARK: - Lookups

    func testBarLayoutFindsTheRequestedPosition() {
        let top = SingleBarLayout(left: [WidgetInstance(identifier: .time)])
        manager.updateLayout(layout(display: 0, top: top))

        XCTAssertEqual(manager.barLayout(forDisplay: 0, position: .top), top)
        XCTAssertNil(manager.barLayout(forDisplay: 0, position: .bottom))
    }

    func testBarLayoutForAnUnconfiguredDisplayIsNothing() {
        manager.updateLayout(layout(display: 0, top: SingleBarLayout()))

        XCTAssertNil(manager.barLayout(forDisplay: 9, position: .top))
    }

    func testHasBarIsTrueOnlyForADisplayThatActuallyHasOne() {
        manager.updateLayout(layout(display: 0, top: SingleBarLayout()))

        XCTAssertTrue(manager.hasBar(forDisplay: 0))
        XCTAssertFalse(manager.hasBar(forDisplay: 1), "an unconfigured display has no bar")
    }

    func testHasBarAtAPositionDistinguishesTopFromBottom() {
        manager.updateLayout(layout(display: 0, bottom: SingleBarLayout()))

        XCTAssertTrue(manager.hasBar(forDisplay: 0, position: .bottom))
        XCTAssertFalse(manager.hasBar(forDisplay: 0, position: .top))
    }
}
