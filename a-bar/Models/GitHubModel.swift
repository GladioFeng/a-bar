import Foundation
import Combine

/// Owns one in-flight request; settings changes invalidate its result before queuing the latest input.
@MainActor
final class GitHubModel: ObservableObject {
    @Published private(set) var count: Int?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var isRefreshing = false
    var isLoading: Bool { count == nil && isRefreshing }

    private let load: (String) async throws -> Int
    private var task: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var input: String?
    private var generation = 0
    private var isActive = false
    private var hasQueuedRefresh = false

    init(load: @escaping (String) async throws -> Int = { try await GitHubModel.load($0) }) {
        self.load = load
    }

    /// The app owns visibility; all mounted copies share this one polling schedule.
    func start(executable: String, refreshInterval: TimeInterval) {
        let next = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldRefresh = refreshTimer == nil || input != next
        if refreshTimer?.timeInterval != refreshInterval {
            refreshTimer?.invalidate()
            let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] timer in
                Task { @MainActor [weak self] in
                    // A queued tick from a replaced or stopped timer must not restart polling.
                    guard let self, self.refreshTimer === timer, let input = self.input else { return }
                    self.refresh(executable: input)
                }
            }
            refreshTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if shouldRefresh { refresh(executable: next) }
    }

    func refresh(executable: String) {
        let next = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        isActive = true
        if input != next {
            input = next
            generation += 1
            count = nil
            errorMessage = nil
            lastSuccess = nil
            task?.cancel()
        }
        if let task {
            // A CLI may ignore cancellation. Wait for it before starting the latest input.
            if task.isCancelled { hasQueuedRefresh = true }
            return
        }
        startRequest(next)
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        isActive = false
        hasQueuedRefresh = false
        generation += 1
        task?.cancel()
        isRefreshing = false
    }

    private func startRequest(_ input: String) {
        let version = generation
        let load = load
        isRefreshing = true
        task = Task { [weak self] in
            let result: Result<Int, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await load(input))
            }
            catch { result = .failure(error) }
            self?.finish(result, generation: version)
        }
    }

    private func finish(_ result: Result<Int, Error>, generation version: Int) {
        task = nil
        isRefreshing = false
        if isActive && version == generation {
            switch result {
            case .success(let value):
                count = value
                errorMessage = nil
                lastSuccess = Date()
            case .failure(let error):
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
        if isActive && hasQueuedRefresh, let input {
            hasQueuedRefresh = false
            startRequest(input)
        }
    }
}

extension GitHubModel {
    nonisolated static func load(_ executable: String) async throws -> Int {
        let output = try await ShellExecutor.run(executable: executable, arguments: ["api", "notifications"])
        try Task.checkCancellation()
        guard let data = output.data(using: .utf8),
              let notifications = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "GitHub", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid notifications response."])
        }
        return notifications.count
    }
}
