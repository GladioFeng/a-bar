// 代码目的：验证真实 YabaiService 在突发事件、失败和停止时的刷新行为。
//
// 代码逻辑：
// 1. 使用临时 yabai 命令返回受控 JSON，隔离真实桌面。
// 2. 观察查询数量、并发执行和完整状态发布。
// 3. 检查错误恢复、请求合并与生命周期。
//
// 必需输入：无；测试自动创建临时配置和命令。
// 预期输出：XCTest 结果；不修改用户配置或 yabai 信号。
import AppKit
import Combine
import XCTest
import Darwin

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
        # 代码目的：记录测试查询并返回 fixture，不访问真实 yabai。
        # 代码逻辑：记录参数，等待测试闸门，再输出固定数据。
        # 必需输入：yabai query/signal 参数；同目录 JSON fixture。
        # 预期输出：fixture JSON 和 calls 记录。
        root=${0%/*}
        printf '%s\\n' "$2 $3" >> "$root/calls"
        if [ "$2" = query ]; then
          while [ -f "$root/hold" ]; do sleep 0.01; done
          sleep 0.02
          cat "$root/$3.json"
        elif [ "$3" = --list ]; then
          printf '[]\\n'
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

}
