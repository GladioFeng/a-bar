import AppKit
import XCTest

final class AppIconProviderTests: XCTestCase {
    @MainActor
    func testConcurrentMissesShareOneLookupAndThenUseTheCache() async throws {
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var lookups = 0
        let started = expectation(description: "fallback started")
        let provider = AppIconProvider { _ in
            lock.lock()
            lookups += 1
            let first = lookups == 1
            lock.unlock()
            if first { started.fulfill() }
            _ = gate.wait(timeout: .now() + 3)
            return "/System/Applications/Calculator.app"
        }
        defer { for _ in 0..<20 { gate.signal() } }
        let name = "MissingFixture-\(UUID())"
        for _ in 0..<20 { XCTAssertNil(provider.icon(forApp: name)) }
        await fulfillment(of: [started], timeout: 1)
        // Let the competing lookups run while the first is still in flight.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(lock.withLock { lookups }, 1)
        gate.signal()
        let deadline = Date().addingTimeInterval(1)
        while provider.icon(forApp: name) == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let cached = try XCTUnwrap(provider.icon(forApp: name))
        for _ in 0..<20 { XCTAssertTrue(provider.icon(forApp: name) === cached) }
        XCTAssertEqual(lock.withLock { lookups }, 1)
        let small = try XCTUnwrap(provider.resizedIcon(forApp: name, to: 14))
        let large = try XCTUnwrap(provider.resizedIcon(forApp: name, to: 16))
        XCTAssertEqual(small.size, NSSize(width: 14, height: 14))
        XCTAssertEqual(large.size, NSSize(width: 16, height: 16))
        XCTAssertFalse(small === large)
        XCTAssertTrue(provider.resizedIcon(forApp: name, to: 14) === small)
        XCTAssertTrue(provider.resizedIcon(forApp: name, to: 16) === large)
    }
}
