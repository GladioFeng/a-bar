import AppKit
import Combine
import SwiftUI
import XCTest

final class NetworkWidgetViewTests: XCTestCase {
    @MainActor
    func testGitHubKeepsCachedContentDuringRefreshAndShowsFailureEvenForHiddenZero() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("settings.json")
        var initial = ABarSettings()
        initial.widgets.github.hideWhenNoNotifications = true
        SettingsCodec.normalize(&initial)
        try SettingsCodec.encode(initial).write(to: config)
        let settings = SettingsManager(store: SettingsStore(fileURL: config))
        var pending: CheckedContinuation<Int, Error>?
        var starts = 0
        var onStart: (() -> Void)?
        let model = GitHubModel { _ in
            starts += 1
            if starts == 1 { return 9 }
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                onStart?()
            }
        }
        let loaded = expectation(description: "initial count")
        let observation = model.$count.compactMap { $0 }.first().sink { _ in loaded.fulfill() }
        defer { observation.cancel(); model.stop(); pending?.resume(throwing: CancellationError()) }
        let host = NSHostingView(rootView: GitHubWidget(model: model)
            .environmentObject(settings).fixedSize(horizontal: true, vertical: false).frame(height: 30))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 120, height: 30),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        model.start(executable: initial.widgets.github.ghBinaryPath,
                    refreshInterval: initial.widgets.github.refreshInterval)
        await fulfillment(of: [loaded], timeout: 3)

        func renderedSize() -> NSSize {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }

        func startRefresh() async {
            let started = expectation(description: "refresh started")
            onStart = { started.fulfill() }
            model.refresh(executable: initial.widgets.github.ghBinaryPath)
            await fulfillment(of: [started], timeout: 3)
            onStart = nil
        }

        func finish(_ result: Result<Int, Error>) async throws {
            let finished = expectation(description: "refresh finished")
            let observation = model.$isRefreshing.dropFirst().filter { !$0 }.first()
                .sink { _ in finished.fulfill() }
            let request = try XCTUnwrap(pending)
            pending = nil
            request.resume(with: result)
            await fulfillment(of: [finished], timeout: 3)
            withExtendedLifetime(observation) {}
        }

        let cached = renderedSize()
        await startRefresh()
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(renderedSize().width, cached.width, accuracy: 0.5,
                       "background refresh must not replace the count with a spinner")
        try await finish(.failure(URLError(.notConnectedToInternet)))
        XCTAssertGreaterThan(renderedSize().width, cached.width + 5, "failure adds a visible warning")
        XCTAssertEqual(model.count, 9)

        await startRefresh()
        try await finish(.success(0))
        let hidden = renderedSize().width
        XCTAssertLessThan(hidden, cached.width)
        await startRefresh()
        try await finish(.failure(URLError(.notConnectedToInternet)))
        XCTAssertGreaterThan(renderedSize().width, hidden + 5,
                             "an error must remain visible even when the cached count is zero")
        XCTAssertEqual(model.count, 0)
    }

    @MainActor
    func testTwoWindowsShareNetworkCachesAndOnlyTheOwnerStopsRequests() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("settings.json")
        var initial = ABarSettings()
        initial.widgets.github.showIcon = false
        initial.widgets.weather.showIcon = false
        initial.widgets.weather.hideLocation = false
        try SettingsCodec.encode(initial).write(to: config)
        let settings = SettingsManager(store: SettingsStore(fileURL: config))
        let githubRequest = ControlledNetworkRequest<Int>()
        let weatherRequest = ControlledNetworkRequest<WeatherSnapshot>()
        let github = GitHubModel(load: githubRequest.load)
        let weather = WeatherModel(load: weatherRequest.load)
        defer {
            github.stop()
            weather.stop()
            githubRequest.cancelRemaining()
            weatherRequest.cancelRemaining()
        }
        let hosts = (0..<2).map { _ in
            NSHostingView(rootView: HStack(spacing: 4) {
                GitHubWidget(model: github)
                WeatherWidget(model: weather)
            }
            .environmentObject(settings)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 30))
        }
        let windows = hosts.map { host in
            let window = NSWindow(
                contentRect: NSRect(x: -10000, y: -10000, width: 250, height: 30),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            return window
        }
        defer { windows.forEach { $0.contentView = nil; $0.close() } }

        func widths() -> [CGFloat] {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
            return hosts.map { host in
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.width
            }
        }
        func snapshot(_ celsius: Int) -> WeatherSnapshot {
            WeatherSnapshot(location: "Lyon", data: WeatherData(
                temperatureC: celsius, temperatureF: celsius * 9 / 5 + 32,
                description: "Clear sky", isNight: false))
        }

        _ = widths()
        XCTAssertTrue(githubRequest.inputs.isEmpty, "mounting a view must not own the polling schedule")
        XCTAssertTrue(weatherRequest.inputs.isEmpty)
        await waitForStart(githubRequest) { github.start(executable: "gh", refreshInterval: 60) }
        await waitForStart(weatherRequest) { weather.start(location: "Lyon", refreshInterval: 60) }
        await finish(.success(9), githubRequest, github.$isRefreshing)
        await finish(.success(snapshot(20)), weatherRequest, weather.$isRefreshing)
        github.start(executable: "gh", refreshInterval: 60)
        weather.start(location: "Lyon", refreshInterval: 60)
        XCTAssertFalse(github.isRefreshing)
        XCTAssertFalse(weather.isRefreshing)
        XCTAssertEqual(githubRequest.inputs, ["gh"])
        XCTAssertEqual(weatherRequest.inputs, ["Lyon"])
        let cachedWidths = widths()
        XCTAssertEqual(cachedWidths[0], cachedWidths[1], accuracy: 0.5)

        await waitForStart(githubRequest) { github.refresh(executable: "gh") }
        XCTAssertFalse(github.isLoading)
        XCTAssertEqual(widths()[1], cachedWidths[1], accuracy: 0.5)
        await finish(.failure(URLError(.notConnectedToInternet)), githubRequest, github.$isRefreshing)
        let githubErrorWidths = widths()
        XCTAssertGreaterThan(githubErrorWidths[0], cachedWidths[0] + 5)
        XCTAssertEqual(githubErrorWidths[0], githubErrorWidths[1], accuracy: 0.5)
        XCTAssertEqual(github.count, 9)

        await waitForStart(weatherRequest) { weather.refresh(location: "Lyon") }
        XCTAssertFalse(weather.isLoading)
        XCTAssertEqual(widths()[1], githubErrorWidths[1], accuracy: 0.5)
        await finish(.failure(URLError(.notConnectedToInternet)), weatherRequest, weather.$isRefreshing)
        let errorWidths = widths()
        XCTAssertGreaterThan(errorWidths[0], githubErrorWidths[0] + 5)
        XCTAssertEqual(errorWidths[0], errorWidths[1], accuracy: 0.5)
        XCTAssertEqual(weather.snapshot, snapshot(20))

        await waitForStart(githubRequest) { github.refresh(executable: "gh") }
        await waitForStart(weatherRequest) { weather.refresh(location: "Lyon") }
        windows[0].contentView = nil
        windows[0].close()
        _ = widths()
        XCTAssertTrue(github.isRefreshing, "one disappearing view cannot cancel shared work")
        XCTAssertTrue(weather.isRefreshing)
        await finish(.success(10), githubRequest, github.$isRefreshing)
        await finish(.success(snapshot(21)), weatherRequest, weather.$isRefreshing)
        XCTAssertEqual(github.count, 10)
        XCTAssertEqual(weather.snapshot, snapshot(21))
        XCTAssertNil(github.errorMessage)
        XCTAssertNil(weather.errorMessage)
        XCTAssertLessThan(widths()[1], errorWidths[1])

        await waitForStart(githubRequest) { github.refresh(executable: "gh") }
        await waitForStart(weatherRequest) { weather.refresh(location: "Lyon") }
        let githubSuccess = github.lastSuccess
        let weatherSuccess = weather.lastSuccess
        windows[1].contentView = nil
        windows[1].close()
        github.stop()
        weather.stop()
        await finish(.success(99), githubRequest, github.$isRefreshing)
        await finish(.success(snapshot(99)), weatherRequest, weather.$isRefreshing)
        XCTAssertEqual(github.count, 10)
        XCTAssertEqual(weather.snapshot, snapshot(21))
        XCTAssertEqual(github.lastSuccess, githubSuccess)
        XCTAssertEqual(weather.lastSuccess, weatherSuccess)
        XCTAssertEqual(githubRequest.maximumActiveCount, 1)
        XCTAssertEqual(weatherRequest.maximumActiveCount, 1)
    }

    @MainActor
    private func waitForStart<Value>(_ request: ControlledNetworkRequest<Value>, action: () -> Void) async {
        let started = expectation(description: "shared loader entered")
        request.onStart = { started.fulfill() }
        action()
        await fulfillment(of: [started], timeout: 3)
        request.onStart = nil
    }

    @MainActor
    private func finish<Value>(
        _ result: Result<Value, Error>, _ request: ControlledNetworkRequest<Value>,
        _ refreshing: Published<Bool>.Publisher
    ) async {
        let finished = expectation(description: "shared request finished")
        let observation = refreshing.dropFirst().filter { !$0 }.first()
            .sink { _ in finished.fulfill() }
        request.complete(result)
        await fulfillment(of: [finished], timeout: 3)
        withExtendedLifetime(observation) {}
    }
}
