import SwiftUI
import AppKit

/// Hacker News widget showing frontpage stories
struct HackerNewsWidget: View {
    let position: BarPosition
    
    @EnvironmentObject var settings: SettingsManager
    
    @StateObject private var model = HackerNewsModel()
    private var stories: [HNStory] { model.stories ?? [] }
    private var currentIndex: Int { model.currentIndex }
    @State private var isChevronHovered = false
    @State private var isChevronPressed = false
    @State private var isTitlePressed = false
    @StateObject private var popoverManager = WidgetPopoverManager(
        minWidth: 400, maxHeight: 520, alignment: .trailing)
    
    private var hnSettings: HackerNewsWidgetSettings {
        settings.settings.widgets.hackerNews
    }
    
    private var theme: ABarTheme {
        ThemeManager.currentTheme(for: settings.settings.theme)
    }

    private var globalSettings: GlobalSettings {
        settings.settings.global
    }
    
    var body: some View {
        BaseWidgetView(onRightClick: refreshStories) {
          HStack(spacing: 4) {
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            } else if !stories.isEmpty {
                HStack(spacing: 4) {
                    if hnSettings.showIcon {
                        Image(systemName: "newspaper.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.foreground)
                    }
                    
                    Button(action: {
                        openStoryURL(stories[currentIndex])
                    }) {
                        Text((stories[currentIndex].title ?? "").truncated(to: hnSettings.maxTitleLength))
                            .foregroundColor(theme.foreground)
                            .font(globalSettings.settingsFont())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .scaleEffect(isTitlePressed ? 0.97 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isTitlePressed)
                    .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                        isTitlePressed = pressing
                    }) {}
                    .help(stories[currentIndex].title ?? "")
                    
                    if hnSettings.showPoints {
                        Text("(\(stories[currentIndex].points))")
                            .font(globalSettings.settingsFont(scaledBy: 0.8))
                            .foregroundColor(theme.foreground.opacity(0.7))
                    }
                    
                    // Chevron button to show popover
                    Button(action: {
                        togglePopover()
                    }) {
                        Image(systemName: position == .top ? "chevron.down" : "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.foreground.opacity(0.6))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .background(isChevronHovered ? theme.foreground.opacity(0.1) : Color.clear)
                    .cornerRadius(4)
                    .scaleEffect(isChevronPressed ? 0.94 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isChevronPressed)
                    .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                        isChevronPressed = pressing
                    }) {}
                    .onHover { hovering in
                        withAnimation(.abarFast) {
                            isChevronHovered = hovering
                        }
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                  
                }
            } else {
                HStack(spacing: 4) {
                    if hnSettings.showIcon {
                        Image(systemName: "newspaper.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.minor)
                    }
                    Text("No stories")
                        .foregroundColor(theme.minor)
                }
            }
            NetworkRefreshWarning(errorMessage: model.errorMessage, lastSuccess: model.lastSuccess)
          }
        }
        .background(
            WidgetPopoverAnchor(
                onMake: { view in
                    popoverManager.attach(anchorView: view, position: position)
                    popoverManager.setContent {
                        PopoverContent(onOpenStory: openStoryURL, onOpenComments: openHNComments)
                            .environmentObject(model)
                            .environmentObject(settings)
                    }
                }
            )
        )
        .onAppear {
            refreshStories()
        }
        .onDisappear { model.stop(); popoverManager.close() }
        .onChange(of: model.lastSuccess) { _ in popoverManager.refreshSize() }
        .onReceive(Timer.publish(every: hnSettings.refreshInterval, on: .main, in: .common).autoconnect()) { _ in
            refreshStories()
        }
        .onReceive(Timer.publish(every: hnSettings.rotationInterval, on: .main, in: .common).autoconnect()) { _ in
            rotateStory()
        }
    }
    
    private func refreshStories() { model.refresh() }

    private func rotateStory() { model.rotate() }

    private func togglePopover() {
        if !popoverManager.isOpen {
            NSApp.activate(ignoringOtherApps: true)
        }
        popoverManager.toggle()
    }

    private func openStoryURL(_ story: HNStory) {
        guard let url = story.url else { return }
        NSWorkspace.shared.open(url)
        popoverManager.close()
    }

    private func openHNComments(_ story: HNStory) {
        let commentsURL = URL(string: "https://news.ycombinator.com/item?id=\(story.objectID)")!
        NSWorkspace.shared.open(commentsURL)
        popoverManager.close()
    }
    
    // Popover content view
    private struct PopoverContent: View {
        @EnvironmentObject var settings: SettingsManager
        @EnvironmentObject var model: HackerNewsModel
        private var stories: [HNStory] { model.stories ?? [] }
        let onOpenStory: (HNStory) -> Void
        let onOpenComments: (HNStory) -> Void
        
        @State private var hoveredTitleIndex: Int? = nil
        @State private var hoveredMetadataIndex: Int? = nil
        
        private var theme: ABarTheme {
            ThemeManager.currentTheme(for: settings.settings.theme)
        }
        
        private var globalSettings: GlobalSettings {
            settings.settings.global
        }
        
        var body: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(stories.prefix(30).enumerated()), id: \.element.objectID) { index, story in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("#\(index + 1)")
                                        .font(globalSettings.settingsFont(scaledBy: 0.9))
                                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                                        .frame(width: 20, alignment: .trailing)
                                        .padding(.top, 3)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        // Title - click to open story URL
                                        Button(action: {
                                            onOpenStory(story)
                                        }) {
                                            Text(story.title ?? "")
                                                .font(globalSettings.settingsFont(weight: .semibold))
                                                .foregroundColor(theme.foreground)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 2)
                                                .padding(.horizontal, 4)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 4)
                                                      .fill(hoveredTitleIndex == index ? theme.foreground.opacity(0.1) : Color.clear)
                                                )
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .onHover { hovering in
                                            hoveredTitleIndex = hovering ? index : nil
                                            if hovering {
                                                NSCursor.pointingHand.push()
                                            } else {
                                                NSCursor.pop()
                                            }
                                        }
                                        
                                        // Metadata - click to open HN comments
                                        Button(action: {
                                            onOpenComments(story)
                                        }) {
                                            HStack(spacing: 8) {
                                                Text("\(story.points) points")
                                                    .font(globalSettings.settingsFont(scaledBy: 0.8))
                                                    .foregroundColor(theme.foreground)
                                                
                                                if let author = story.author {
                                                    Text("by \(author)")
                                                        .font(globalSettings.settingsFont(scaledBy: 0.8))
                                                        .foregroundColor(theme.foreground)
                                                }
                                                
                                                if story.numComments > 0 {
                                                    Text("\(story.numComments) comments")
                                                        .font(globalSettings.settingsFont(scaledBy: 0.8))
                                                        .foregroundColor(theme.foreground)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.vertical, 2)
                                            .padding(.horizontal, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                  .fill(hoveredMetadataIndex == index ? theme.foreground.opacity(0.1) : Color.clear)
                                            )
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .onHover { hovering in
                                            hoveredMetadataIndex = hovering ? index : nil
                                            if hovering {
                                                NSCursor.pointingHand.push()
                                            } else {
                                                NSCursor.pop()
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.all, 4)
                            
                            if index < stories.prefix(30).count - 1 {
                                Divider()
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                    .padding(.all, 8)
                }
                .frame(maxHeight: 500)
            }
            .frame(width: 400)
            .background(
                RoundedRectangle(cornerRadius: 8)
                  .fill(theme.background)
            )
            .padding(6)
        }
    }
    
}
