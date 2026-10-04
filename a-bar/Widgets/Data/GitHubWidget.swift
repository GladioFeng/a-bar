import SwiftUI

/// GitHub notifications widget
struct GitHubWidget: View {
    @EnvironmentObject var settings: SettingsManager
    
    @ObservedObject private var model: GitHubModel

    init(model: GitHubModel) {
        _model = ObservedObject(wrappedValue: model)
    }
    private var count: Int? { model.value }
    private var notificationCount: Int { count ?? 0 }
    
    private var githubSettings: GitHubWidgetSettings {
        settings.settings.widgets.github
    }
    
    private var theme: ABarTheme {
        ThemeManager.currentTheme(for: settings.settings.theme)
    }
    
    var body: some View {
        // The shared model keeps polling when a zero count hides this content. An empty
        // `Group` takes no slot in the bar's stack, so a hidden widget leaves no extra gap.
        Group {
            if !(githubSettings.hideWhenNoNotifications && count == 0 && model.errorMessage == nil) {
                BaseWidgetView(
                    onClick: openNotifications,
                    onRightClick: refreshNotifications
                ) {
                    HStack(spacing: 4) {
                        if githubSettings.showIcon {
                            Image("GitHubIcon")
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 12, height: 12)
                                .foregroundColor(notificationCount > 0 ? theme.blue : theme.foreground)
                        }
                        
                        if model.isLoading {
                            ProgressView()
                                .scaleEffect(0.4)
                                .frame(width: 12, height: 12)
                        } else {
                            Text(notificationText)
                                .foregroundColor(notificationCount > 0 ? theme.blue : theme.foreground)
                        }
                        NetworkRefreshWarning(errorMessage: model.errorMessage, lastSuccess: model.lastSuccess)
                    }
                }
            }
        }
    }
    
    private var notificationText: String {
        count.map(WidgetLabels.notificationCount) ?? "--"
    }
    
    private func refreshNotifications() {
        model.refresh(input: githubSettings.ghBinaryPath)
    }

    private func openNotifications() {
        if let url = URL(string: githubSettings.notificationUrl) {
            NSWorkspace.shared.open(url)
        }
    }
}
