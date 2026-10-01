import AppKit
import Combine
import XCTest
import Darwin

/// Window and Space events arrive in bursts, and each one used to start its own overlapping
/// set of yabai queries. A burst has to collapse into one active batch plus a single
/// follow-up. Full snapshots publish atomically; title updates may reuse cached Spaces and
/// displays only while their window relationships remain unchanged. A stopped or repointed
/// generation must never write over a newer one.
///
/// A temporary stand-in for the yabai binary returns fixed JSON on demand, so these tests can
/// count queries and watch what gets published without touching the real desktop, the user's
/// config, or the yabai signals they already have registered.
final class YabaiServiceTests: XCTestCase {
    private var directory: URL!
    private var service: YabaiService!
    private var manager: SettingsManager!
    private var notificationName: String!
    private var observations = Set<AnyCancellable>()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("abar-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("yabai")
        try """
        #!/bin/sh
        # Stands in for yabai, so nothing here reaches the real one. Logs every call, holds
        # each query at the test's gate file, then prints the fixture for the collection asked
        # for. Reads the JSON fixtures beside it; writes the call log next to them.
        root=${0%/*}
        printf '%s\\n' "$2 $3" >> "$root/calls"
        printf '%s\\n' "$*" >> "$root/arguments"
        if [ "$2" = query ]; then
          while [ -f "$root/hold" ]; do sleep 0.01; done
          sleep 0.02
          cat "$root/$3.json"
        elif [ "$3" = --list ]; then
          if [ -f "$root/signals.json" ]; then cat "$root/signals.json"; else printf '[]\\n'; fi
        fi
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try write("calls", "")
        try write("--spaces.json", #"[{"id":1,"index":1,"display":1,"type":"bsp","windows":[10],"has-focus":true}]"#)
        try write("--windows.json", #"[{"id":10,"pid":123,"app":"Fixture","title":"Example","display":1,"space":1,"subrole":"AXStandardWindow","frame":{"x":0,"y":0,"w":100,"h":100},"has-focus":true}]"#)
        try write("--displays.json", #"[{"id":1,"uuid":"fixture","index":1,"frame":{"x":0,"y":0,"w":1920,"h":1080},"spaces":[1]}]"#)
        var settings = ABarSettings()
        settings.global.yabaiPath = executable.path
        let config = directory.appendingPathComponent("config.json")
        try SettingsCodec.encode(settings).write(to: config)
        manager = SettingsManager(store: SettingsStore(fileURL: config))
        notificationName = "user.uid.\(getuid()).a-bar-test.\(UUID())"
        service = YabaiService(
            settingsManager: manager,
            refreshNotification: notificationName)
    }

    override func tearDownWithError() throws {
        observations.removeAll()
        manager.flush()
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("hold"))
        // Tests that start observers explicitly stop them and await signal removal first.
        service = nil
        try FileManager.default.removeItem(at: directory)
    }

    private func write(_ name: String, _ value: String) throws {
        try value.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private var calls: [String] {
        ((try? String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private var queries: [String] { calls.filter { $0.hasPrefix("query ") } }

    private var arguments: [String] {
        ((try? String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    private func readFixture(_ name: String) throws -> [[String: Any]] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func writeFixture(_ name: String, _ value: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try write(name, String(decoding: data, as: UTF8.self))
    }

    @MainActor
    private func postRefresh(titleOnly: Bool) async throws {
        let name = titleOnly ? notificationName + ".window-title-changed" : notificationName!
        try await ShellExecutor.run(executable: "/usr/bin/notifyutil", arguments: ["-p", name])
    }

    @MainActor
    private func startAndClearCalls() async throws {
        service.start()
        await waitFor { service.isConnected && service.signalsRegistered }
        try write("calls", "")
        try write("arguments", "")
    }

    @MainActor
    private func stopAndWait() async {
        service.stop()
        await waitFor { calls.filter { $0 == "signal --remove" }.count == 3 }
    }

    @MainActor
    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "condition did not become true", file: file, line: line)
    }

    @MainActor
    func testQueriesRunConcurrentlyAndBurstPublishesOneCompleteSnapshot() async throws {
        try write("hold", "")
        var states: [YabaiState] = []
        service.$state.dropFirst().sink { states.append($0) }.store(in: &observations)
        service.refresh()
        await waitFor { queries.count == 3 }
        // All three processes reached the gate before any one was allowed to finish.
        XCTAssertTrue(states.isEmpty)
        for _ in 0..<20 { service.refresh() }
        await Task.yield()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("hold"))
        await waitFor { queries.count == 6 && service.isConnected }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(queries.count, 6, "one active batch plus one latest follow-up")
        XCTAssertEqual(states.count, 1, "identical snapshots must not invalidate every widget")
        XCTAssertEqual(states.first?.spaces.count, 1)
        XCTAssertEqual(states.first?.windows.count, 1)
        XCTAssertEqual(states.first?.displays.count, 1)
    }

    @MainActor
    func testFailureKeepsCompleteStateAndEqualSuccessRestoresConnection() async throws {
        service.refresh()
        await waitFor { service.isConnected }
        let original = service.state
        let windows = try String(contentsOf: directory.appendingPathComponent("--windows.json"), encoding: .utf8)
        try write("--windows.json", "invalid JSON")
        service.refresh()
        await waitFor { service.lastError != nil }
        XCTAssertFalse(service.isConnected)
        XCTAssertEqual(service.state, original)
        try write("--windows.json", windows)
        service.refresh()
        await waitFor { service.isConnected && service.lastError == nil }
        XCTAssertEqual(service.state, original)
    }

    @MainActor
    func testValidJSONPreservesCombiningMarksAndLiteralRepairPatterns() async throws {
        let title = "\u{301}[,] 00000 \"quoted\" \\path\nnext"
        let data = try Data(contentsOf: directory.appendingPathComponent("--windows.json"))
        var windows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        windows[0]["title"] = title
        let output = try JSONSerialization.data(withJSONObject: windows)
        try write("--windows.json", String(decoding: output, as: UTF8.self))
        service.refresh()
        await waitFor { service.isConnected }
        XCTAssertEqual(service.state.windows.first?.title, title)
    }

    @MainActor
    func testMalformedLegacyArraysStillUseTheSanitizer() async throws {
        let output = try String(contentsOf: directory.appendingPathComponent("--windows.json"), encoding: .utf8)
        try write("--windows.json", "[," + output.dropFirst().dropLast() + ",]")
        service.refresh()
        await waitFor { service.isConnected }
        XCTAssertEqual(service.state.windows.count, 1)
        XCTAssertEqual(service.state.windows.first?.title, "Example")
    }

    @MainActor
    func testStoppedGenerationCannotPublishItsResult() async throws {
        try write("hold", "")
        service.refresh()
        await waitFor { queries.count == 3 }
        service.stop()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("hold"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.state, YabaiState())
        XCTAssertFalse(service.isConnected)
        service.refresh()
        await waitFor { service.isConnected }
        await waitFor { calls.filter { $0 == "signal --remove" }.count == 3 }
    }

    @MainActor
    func testRepeatedStartDoesNotDuplicateSpaceObserver() async throws {
        service.start()
        service.start()
        await waitFor { service.isConnected && service.signalsRegistered }
        XCTAssertEqual(queries.count, 3)
        try write("calls", "")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await waitFor { queries.count >= 3 }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(queries.count, 3)
        service.stop()
        await waitFor { calls.filter { $0 == "signal --remove" }.count == 3 }
    }

    @MainActor
    func testNativeNotificationRefreshesAndQuickRestartKeepsSignals() async throws {
        service.start()
        await waitFor { service.isConnected && service.signalsRegistered }
        service.stop()
        service.start()
        await waitFor { service.signalsRegistered }
        let lastRemove = calls.lastIndex(of: "signal --remove")
        let lastAdd = calls.lastIndex(of: "signal --add")
        XCTAssertNotNil(lastRemove)
        XCTAssertNotNil(lastAdd)
        if let lastRemove, let lastAdd { XCTAssertLessThan(lastRemove, lastAdd) }
        try await Task.sleep(nanoseconds: 100_000_000)
        try write("calls", "")
        try await ShellExecutor.run("/usr/bin/notifyutil -p \(notificationName!)")
        await waitFor { queries.count >= 3 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(queries.count, 3)
        service.stop()
        await waitFor { calls.filter { $0 == "signal --remove" }.count == 3 }
    }

    @MainActor
    func testNewYabaiPathDoesNotWaitForOrPublishOldInFlightQuery() async throws {
        service.start()
        await waitFor { service.isConnected && service.signalsRegistered }
        let other = directory.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        for name in ["yabai", "--spaces.json", "--windows.json", "--displays.json"] {
            try FileManager.default.copyItem(at: directory.appendingPathComponent(name), to: other.appendingPathComponent(name))
        }
        let windows = other.appendingPathComponent("--windows.json")
        try String(contentsOf: windows, encoding: .utf8).replacingOccurrences(of: "Example", with: "New source")
            .write(to: windows, atomically: true, encoding: .utf8)
        try write("calls", "")
        try write("hold", "")
        service.refresh()
        await waitFor { queries.count == 3 }
        manager.update { $0.global.yabaiPath = other.appendingPathComponent("yabai").path }
        service.start()
        await waitFor { service.state.focusedWindow?.title == "New source" }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("hold"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.state.focusedWindow?.title, "New source")
        service.stop()
        await waitFor {
            let log = (try? String(contentsOf: other.appendingPathComponent("calls"), encoding: .utf8)) ?? ""
            return log.components(separatedBy: "signal --remove").count == 4
        }
    }

    @MainActor
    func testTitleNotificationOnlyQueriesWindowsAndCollapsesBurst() async throws {
        try await startAndClearCalls()
        let original = service.state
        var windows = try readFixture("--windows.json")
        windows[0]["title"] = "Updated title"
        var dialog = windows[0]
        dialog["id"] = 11
        dialog["subrole"] = "AXDialog"
        try writeFixture("--windows.json", windows + [dialog])
        var states: [YabaiState] = []
        service.$state.dropFirst().sink { states.append($0) }.store(in: &observations)
        try write("hold", "")
        try await postRefresh(titleOnly: true)
        await waitFor { queries.count == 1 }
        for _ in 0..<5 { try await postRefresh(titleOnly: true) }
        // Let the posted notifications enqueue their follow-up while the first query is held.
        try await Task.sleep(nanoseconds: 50_000_000)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("hold"))
        await waitFor { queries.count == 2 && service.state.focusedWindow?.title == "Updated title" }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(queries, ["query --windows", "query --windows"])
        XCTAssertEqual(service.state.spaces, original.spaces)
        XCTAssertEqual(service.state.displays, original.displays)
        XCTAssertEqual(service.state.windows.count, 1, "title reads must apply the existing dialog filter")
        XCTAssertEqual(states.count, 1, "an equal follow-up must not republish the state")
        await stopAndWait()
    }

    @MainActor
    func testPendingFullWinsOverLaterTitleAndSkipsPartialPublication() async throws {
        try await startAndClearCalls()
        var windows = try readFixture("--windows.json")
        windows[0]["title"] = "Latest title"
        try writeFixture("--windows.json", windows)
        var spaces = try readFixture("--spaces.json")
        spaces[0]["label"] = "Latest Space"
        try writeFixture("--spaces.json", spaces)
        var states: [YabaiState] = []
        service.$state.dropFirst().sink { states.append($0) }.store(in: &observations)
        try write("hold", "")
        try await postRefresh(titleOnly: true)
        await waitFor { queries.count == 1 }
        service.refresh()
        try await postRefresh(titleOnly: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("hold"))
        await waitFor { queries.count == 4 && service.state.spaces.first?.label == "Latest Space" }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(queries.filter { $0 == "query --windows" }.count, 2)
        XCTAssertEqual(queries.filter { $0 == "query --spaces" }.count, 1)
        XCTAssertEqual(queries.filter { $0 == "query --displays" }.count, 1)
        XCTAssertEqual(states.count, 1, "the pending full refresh must suppress the partial publication")
        XCTAssertEqual(states.first?.focusedWindow?.title, "Latest title")
        XCTAssertEqual(states.first?.spaces.first?.label, "Latest Space")
        await stopAndWait()
    }

    @MainActor
    func testTitleDuringFullReadQueuesWindowsFollowUp() async throws {
        try await startAndClearCalls()
        try write("hold", "")
        service.refresh()
        await waitFor { queries.count == 3 }
        try await postRefresh(titleOnly: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("hold"))
        await waitFor { queries.count == 4 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(queries.count, 4)
        XCTAssertEqual(queries.filter { $0 == "query --windows" }.count, 2)
        XCTAssertEqual(queries.last, "query --windows")
        await stopAndWait()
    }

    @MainActor
    func testTitleUpdateFallsBackWhenWindowRelationshipsChange() async throws {
        var windows = try readFixture("--windows.json")
        var second = windows[0]
        second["id"] = 11
        second["has-focus"] = false
        windows.append(second)
        var spaces = try readFixture("--spaces.json")
        spaces[0]["windows"] = [10, 11]
        let displays = try readFixture("--displays.json")
        try writeFixture("--windows.json", windows)
        try writeFixture("--spaces.json", spaces)
        try await startAndClearCalls()
        let original = service.state
        var variants: [(String, [[String: Any]])] = [
            ("removed", [windows[0]]),
            ("duplicate", [windows[0], windows[0]])
        ]
        var extra = windows[0]
        extra["id"] = 12
        variants.append(("added", windows + [extra]))
        let changes: [(String, Any)] = [
            ("id", 12), ("pid", 456), ("space", 2), ("display", 2), ("has-focus", false),
            ("is-visible", true), ("is-minimized", true), ("is-hidden", true), ("is-sticky", true)
        ]
        for (field, value) in changes {
            var changed = windows
            changed[0][field] = value
            variants.append((field, changed))
        }
        var states: [YabaiState] = []
        service.$state.dropFirst().sink { states.append($0) }.store(in: &observations)
        for (name, changed) in variants {
            states.removeAll()
            var changedSpaces = spaces
            changedSpaces[0]["label"] = name
            var changedDisplays = displays
            changedDisplays[0]["label"] = name
            try writeFixture("--windows.json", changed)
            try writeFixture("--spaces.json", changedSpaces)
            try writeFixture("--displays.json", changedDisplays)
            try await postRefresh(titleOnly: true)
            await waitFor { queries.count == 4 && service.state.spaces.first?.label == name }
            XCTAssertEqual(queries.filter { $0 == "query --windows" }.count, 2, name)
            XCTAssertEqual(queries.filter { $0 == "query --spaces" }.count, 1, name)
            XCTAssertEqual(queries.filter { $0 == "query --displays" }.count, 1, name)
            XCTAssertEqual(states.count, 1, "\(name) must not publish windows with cached relationships")
            XCTAssertEqual(states.first?.displays.first?.label, name)
            try writeFixture("--windows.json", windows)
            try writeFixture("--spaces.json", spaces)
            try writeFixture("--displays.json", displays)
            service.refresh()
            await waitFor { service.state == original }
            try write("calls", "")
        }
        await stopAndWait()
    }

    @MainActor
    func testFailedTitleReadRetriesFullOnceAndRequiresFullRecovery() async throws {
        try await startAndClearCalls()
        let original = service.state
        let windows = try String(contentsOf: directory.appendingPathComponent("--windows.json"), encoding: .utf8)
        var failures = 0
        service.$lastError.dropFirst().sink { if $0 != nil { failures += 1 } }.store(in: &observations)
        try write("--windows.json", "invalid JSON")
        try await postRefresh(titleOnly: true)
        await waitFor { queries.count == 4 && failures == 2 }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(queries.count, 4, "a failed full fallback must not retry itself")
        XCTAssertEqual(service.state, original)
        XCTAssertFalse(service.isConnected)
        try write("--windows.json", windows)
        try await postRefresh(titleOnly: true)
        await waitFor { queries.count == 7 && service.isConnected && service.lastError == nil }
        XCTAssertEqual(Array(queries.suffix(3)).sorted(), ["query --displays", "query --spaces", "query --windows"])
        XCTAssertEqual(service.state, original)
        await stopAndWait()
    }

    @MainActor
    func testTitleBeforeFirstSuccessfulSnapshotUsesFull() async throws {
        let spaces = try String(contentsOf: directory.appendingPathComponent("--spaces.json"), encoding: .utf8)
        try write("--spaces.json", "invalid JSON")
        service.start()
        await waitFor { service.lastError != nil && service.signalsRegistered }
        XCTAssertEqual(service.state, YabaiState())
        try write("--spaces.json", spaces)
        try write("calls", "")
        try await postRefresh(titleOnly: true)
        await waitFor { queries.count == 3 && service.isConnected }
        XCTAssertEqual(queries.sorted(), ["query --displays", "query --spaces", "query --windows"])
        XCTAssertEqual(service.state.spaces.count, 1)
        XCTAssertEqual(service.state.displays.count, 1)
        await stopAndWait()
    }

    @MainActor
    func testSignalMigrationChecksEventAndActionAndKeepsLabels() async throws {
        let fullAction = "/usr/bin/notifyutil -p \(notificationName!)"
        let titleAction = fullAction + ".window-title-changed"
        try writeFixture("signals.json", [
            ["index": 0, "label": "abar-window-destroyed", "event": "window_destroyed", "app": "", "title": "", "action": fullAction],
            ["index": 1, "label": "abar-window-title-changed", "event": "window_title_changed", "app": "", "title": "", "action": fullAction],
            ["index": 2, "label": "abar-window-focused", "event": "window_created", "app": "", "title": "", "action": fullAction]
        ])
        service.start()
        await waitFor { service.isConnected && service.signalsRegistered }
        let adds = arguments.filter { $0.hasPrefix("-m signal --add ") }
        XCTAssertEqual(adds.count, 2, "the already correct destroyed signal should not be registered again")
        XCTAssertTrue(adds.contains("-m signal --add event=window_title_changed action=\(titleAction) label=abar-window-title-changed"))
        XCTAssertTrue(adds.contains("-m signal --add event=window_focused action=\(fullAction) label=abar-window-focused"))
        await stopAndWait()
    }

    @MainActor
    func testCurrentSignalActionsAreNotRegisteredAgain() async throws {
        let fullAction = "/usr/bin/notifyutil -p \(notificationName!)"
        try writeFixture("signals.json", [
            ["index": 0, "label": "abar-window-destroyed", "event": "window_destroyed", "app": "", "title": "", "action": fullAction],
            ["index": 1, "label": "abar-window-title-changed", "event": "window_title_changed", "app": "", "title": "", "action": fullAction + ".window-title-changed"],
            ["index": 2, "label": "abar-window-focused", "event": "window_focused", "app": "", "title": "", "action": fullAction]
        ])
        service.start()
        await waitFor { service.isConnected && service.signalsRegistered }
        XCTAssertFalse(calls.contains("signal --add"))
        await stopAndWait()
    }

    @MainActor
    func testBothNotificationsRefreshAndStopTogether() async throws {
        try await startAndClearCalls()
        var windows = try readFixture("--windows.json")
        windows[0]["title"] = "Title notification"
        try writeFixture("--windows.json", windows)
        try await postRefresh(titleOnly: true)
        await waitFor { service.state.focusedWindow?.title == "Title notification" }
        XCTAssertEqual(queries, ["query --windows"])
        try await postRefresh(titleOnly: false)
        await waitFor { queries.count == 4 }
        try await Task.sleep(nanoseconds: 100_000_000)
        await stopAndWait()
        try write("calls", "")
        try await postRefresh(titleOnly: true)
        try await postRefresh(titleOnly: false)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(queries.isEmpty)
    }

    @MainActor
    func testStoppedTitleReadCannotPublishOrQueueFull() async throws {
        try await startAndClearCalls()
        let original = service.state
        var windows = try readFixture("--windows.json")
        windows[0]["space"] = 2
        try writeFixture("--windows.json", windows)
        try write("hold", "")
        try await postRefresh(titleOnly: true)
        await waitFor { queries.count == 1 }
        await stopAndWait()
        try FileManager.default.removeItem(at: directory.appendingPathComponent("hold"))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(service.state, original)
        XCTAssertEqual(queries.count, 1, "a stopped title query must not enqueue a structural fallback")
    }

}
