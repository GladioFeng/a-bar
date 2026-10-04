import Foundation

/// Unread notification count, polled with `gh`. The input is the `gh` executable.
typealias GitHubModel = PollingModel<Int>

enum GitHubNotifications {
    static func load(_ executable: String) async throws -> Int {
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
