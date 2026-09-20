import XCTest

/// These strings are the AppleScript API. An `osascript` caller sees nothing else - no exit
/// code, no structured result - so the exact wording is the contract, and the `ok:`/`error:`
/// prefix is the only thing a script can branch on.
final class WidgetCommandDispatchTests: XCTestCase {

    // MARK: - Choosing a handler

    func testTheWindowManagersAnswerToTheirOwnNames() {
        XCTAssertEqual(WidgetCommandDispatch.RefreshTarget(widgetName: "yabai"), .yabai)
        XCTAssertEqual(WidgetCommandDispatch.RefreshTarget(widgetName: "aerospace"), .aerospace)
    }

    func testTheWindowManagerNamesAreMatchedRegardlessOfCase() {
        // Somebody typing this into Script Editor writes "Yabai" as often as "yabai".
        XCTAssertEqual(WidgetCommandDispatch.RefreshTarget(widgetName: "Yabai"), .yabai)
        XCTAssertEqual(WidgetCommandDispatch.RefreshTarget(widgetName: "AeroSpace"), .aerospace)
    }

    func testAnyOtherNameIsACustomWidget() {
        XCTAssertEqual(
            WidgetCommandDispatch.RefreshTarget(widgetName: "Disk"), .userWidget("Disk"))
    }

    func testACustomWidgetKeepsItsNameAsWritten() {
        // The name is matched exactly against the widget list, so case must not be folded.
        XCTAssertEqual(
            WidgetCommandDispatch.RefreshTarget(widgetName: "DiSk"), .userWidget("DiSk"))
    }

    func testAnEmptyNameIsTreatedAsACustomWidgetAndWillSimplyNotBeFound() {
        XCTAssertEqual(WidgetCommandDispatch.RefreshTarget(widgetName: ""), .userWidget(""))
    }

    // MARK: - Replies

    func testEveryReplyIsPrefixedOkOrError() {
        let replies = [
            WidgetCommandDispatch.missingParameter("widget name"),
            WidgetCommandDispatch.refreshed(.yabai),
            WidgetCommandDispatch.refreshed(.aerospace),
            WidgetCommandDispatch.refreshed(.userWidget("Disk")),
            WidgetCommandDispatch.notFound("Disk"),
            WidgetCommandDispatch.toggled("Disk", isNowActive: true),
            WidgetCommandDispatch.toggled("Disk", isNowActive: false),
            WidgetCommandDispatch.hidden("Disk", didChange: true),
            WidgetCommandDispatch.hidden("Disk", didChange: false),
            WidgetCommandDispatch.shown("Disk", didChange: true),
            WidgetCommandDispatch.shown("Disk", didChange: false),
            WidgetCommandDispatch.failed(UserWidgetError.widgetNotFound("Disk")),
            WidgetCommandDispatch.switchedToProfile("Work"),
            WidgetCommandDispatch.profileNotFound("Work", available: ["Default"]),
            WidgetCommandDispatch.noActiveProfile,
        ]
        for reply in replies {
            XCTAssertTrue(
                reply.hasPrefix("ok: ") || reply.hasPrefix("error: "),
                "a script can only branch on the prefix, but got '\(reply)'")
        }
    }

    func testRefreshRepliesNameWhatWasRefreshed() {
        XCTAssertEqual(WidgetCommandDispatch.refreshed(.yabai), "ok: refreshed yabai widgets")
        XCTAssertEqual(
            WidgetCommandDispatch.refreshed(.aerospace), "ok: refreshed aerospace widgets")
        XCTAssertEqual(
            WidgetCommandDispatch.refreshed(.userWidget("Disk")), "ok: refreshed widget 'Disk'")
    }

    func testToggleDistinguishesShownFromHidden() {
        XCTAssertEqual(
            WidgetCommandDispatch.toggled("Disk", isNowActive: true), "ok: widget 'Disk' is now shown")
        XCTAssertEqual(
            WidgetCommandDispatch.toggled("Disk", isNowActive: false), "ok: widget 'Disk' is now hidden")
    }

    func testHideAndShowSayWhetherAnythingActuallyChanged() {
        XCTAssertEqual(
            WidgetCommandDispatch.hidden("Disk", didChange: true), "ok: widget 'Disk' is now hidden")
        XCTAssertEqual(
            WidgetCommandDispatch.hidden("Disk", didChange: false),
            "ok: widget 'Disk' was already hidden")
        XCTAssertEqual(
            WidgetCommandDispatch.shown("Disk", didChange: true), "ok: widget 'Disk' is now shown")
        XCTAssertEqual(
            WidgetCommandDispatch.shown("Disk", didChange: false),
            "ok: widget 'Disk' was already shown")
    }

    func testANotFoundReplyNamesTheWidget() {
        XCTAssertEqual(WidgetCommandDispatch.notFound("Disk"), "error: widget 'Disk' not found")
    }

    func testAMissingParameterSaysWhichOne() {
        XCTAssertEqual(
            WidgetCommandDispatch.missingParameter("widget name"), "error: missing widget name")
        XCTAssertEqual(
            WidgetCommandDispatch.missingParameter("profile name"), "error: missing profile name")
    }

    // MARK: - Errors reach the caller intact

    func testAFailureCarriesTheUnderlyingDescription() {
        let reply = WidgetCommandDispatch.failed(UserWidgetError.widgetNotFound("Disk"))

        XCTAssertTrue(reply.contains("Disk"), "got '\(reply)'")
    }

    func testReplyPassesASuccessThroughTheFormatter() {
        let reply = WidgetCommandDispatch.reply(
            for: Result<Bool, UserWidgetError>.success(true)) { $0 ? "ok: yes" : "ok: no" }

        XCTAssertEqual(reply, "ok: yes")
    }

    func testReplyTurnsAFailureIntoAnErrorString() {
        let reply = WidgetCommandDispatch.reply(
            for: Result<Bool, UserWidgetError>.failure(.widgetNotFound("Disk"))) { _ in "ok: never" }

        XCTAssertTrue(reply.hasPrefix("error: "))
        XCTAssertTrue(reply.contains("Disk"))
    }

    // MARK: - Profiles

    func testAnUnknownProfileListsTheOnesThatExist() {
        let reply = WidgetCommandDispatch.profileNotFound("Gaming", available: ["Default", "Work"])

        XCTAssertEqual(
            reply, "error: profile 'Gaming' not found. Available profiles: Default, Work")
    }

    func testAnUnknownProfileWithNoAlternativesStillReplies() {
        XCTAssertEqual(
            WidgetCommandDispatch.profileNotFound("Gaming", available: []),
            "error: profile 'Gaming' not found. Available profiles: ")
    }

    func testSwitchingNamesTheProfile() {
        XCTAssertEqual(
            WidgetCommandDispatch.switchedToProfile("Work"), "ok: switched to profile 'Work'")
    }
}
