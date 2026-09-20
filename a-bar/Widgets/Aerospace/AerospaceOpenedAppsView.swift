import SwiftUI

/// View showing app icons for windows in an AeroSpace workspace
struct AerospaceOpenedAppsView: View {
    let workspace: AerospaceWorkspace

    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var aerospaceService: AerospaceService

    private var spacesSettings: SpacesWidgetSettings {
        settings.settings.widgets.spaces
    }

    private var theme: ABarTheme {
        ThemeManager.currentTheme(for: settings.settings.theme)
    }

    var body: some View {
        if !displayedApps.isEmpty {
            HStack(spacing: 1) {
                ForEach(displayedApps) { window in
                    AerospaceAppIconButton(window: window)
                }
            }
        }
    }

    private var displayedApps: [AerospaceWindow] {
        // Apply exclusions - the same rules the yabai opened-apps row applies
        var windows = WindowFilter.excludingWindows(
            workspace.windows,
            excludingApps: spacesSettings.exclusions,
            excludingTitles: spacesSettings.titleExclusions,
            asRegex: spacesSettings.exclusionsAsRegex,
            appName: \.appName,
            title: \.windowTitle
        )

        // Remove duplicates if enabled
        if spacesSettings.hideDuplicateApps {
            windows = WindowFilter.deduplicatedByApp(windows, appName: \.appName)
        }

        // AeroSpace reports neither a stack index nor a frame, so there is nothing to order by:
        // the row stays in the order `aerospace list-windows` returned.
        return windows
    }
}

struct AerospaceAppIconButton: View {
    let window: AerospaceWindow

    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var aerospaceService: AerospaceService

    @State private var isHovered = false

    private var theme: ABarTheme {
        ThemeManager.currentTheme(for: settings.settings.theme)
    }

    var body: some View {
        AppIconView(appName: window.appName, size: 14)
            .opacity(window.isFocused ? 1.0 : 0.7)
            .scaleEffect(isHovered ? 1.1 : 1.0)
            .onHover { hovering in
                withAnimation(.abarFast) {
                    isHovered = hovering
                }
            }
            .onTapGesture {
                focusWindow()
            }
            .help(window.windowTitle.isEmpty ? window.appName : "\(window.appName) - \(window.windowTitle)")
    }

    private func focusWindow() {
        Task {
            await aerospaceService.focusWindow(window.windowId)
        }
    }
}
