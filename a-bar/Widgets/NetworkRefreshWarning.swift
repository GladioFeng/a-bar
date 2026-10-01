import SwiftUI

/// Keeps failures visible even when the widget can still display its last successful result.
struct NetworkRefreshWarning: View {
    let errorMessage: String?
    let lastSuccess: Date?

    var body: some View {
        if let errorMessage {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
                .accessibilityLabel("Refresh failed")
                .help(errorMessage + "\n" + (lastSuccess.map {
                    "Last updated: \($0.formatted(date: .abbreviated, time: .standard))"
                } ?? "No successful update yet."))
        }
    }
}
