import SwiftUI

/// View showing app icons for windows in a space
struct OpenedAppsView: View {
    let space: YabaiSpace
    let displayIndex: Int
    
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var yabaiService: YabaiService
    
    private var spacesSettings: SpacesWidgetSettings {
        settings.settings.widgets.spaces
    }
    
    private var theme: ABarTheme {
        ThemeManager.currentTheme(for: settings.settings.theme)
    }
    
    var body: some View {
        if !displayedApps.isEmpty {
            HStack(spacing: 1) {
                ForEach(displayedApps, id: \.id) { window in
                    AppIconButton(window: window)
                }
            }
        }
    }
    
    private var displayedApps: [YabaiWindow] {
        let windows: [YabaiWindow]
        if spacesSettings.displayStickyWindowsSeparately {
            windows = yabaiService.state.nonStickyWindows(forSpace: space.index)
        } else {
            windows = yabaiService.state.windows(forSpace: space.index)
        }
        // Apply exclusions
        var filtered = WindowFilter.excludingWindows(
            windows,
            excludingApps: spacesSettings.exclusions,
            excludingTitles: spacesSettings.titleExclusions,
            asRegex: spacesSettings.exclusionsAsRegex,
            appName: \.app,
            title: \.title
        )
        // Remove duplicates if enabled
        if spacesSettings.hideDuplicateApps {
            filtered = WindowFilter.deduplicatedByApp(filtered, appName: \.app)
        }
        // Order down a stack first, then left to right
        return WindowFilter.orderedByStackThenPosition(
            filtered, stackIndex: \.stackIndex, x: \.frame.x
        )
    }
}

struct AppIconButton: View {
    let window: YabaiWindow
    
    @EnvironmentObject var settings: SettingsManager
    @EnvironmentObject var yabaiService: YabaiService
    
    @State private var isHovered = false
    
    private var theme: ABarTheme {
        ThemeManager.currentTheme(for: settings.settings.theme)
    }
    
    var body: some View {
        AppIconView(appName: window.app, size: 14)
            .opacity(window.hasFocus ? 1.0 : 0.7)
            .scaleEffect(isHovered ? 1.1 : 1.0)
            .onHover { hovering in
                withAnimation(.abarFast) {
                    isHovered = hovering
                }
            }
            .onTapGesture {
                focusWindow()
            }
            .help(window.title.isEmpty ? window.app : "\(window.app) - \(window.title)")
    }
    
    private func focusWindow() {
        Task {
            await yabaiService.focusWindow(window.id)
        }
    }
}
