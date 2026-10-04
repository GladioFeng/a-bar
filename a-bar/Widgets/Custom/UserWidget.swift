import AppKit
import SwiftUI

/// Captures a reference to the hosting NSView for menu positioning
struct ViewAnchor: NSViewRepresentable {
  @Binding var nsView: NSView?

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { self.nsView = view }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// User-defined custom widget with xbar-compatible output parsing.
///
/// Scripts write to stdout:
/// - Lines before `---` cycle in the bar
/// - Lines after `---` appear in a dropdown menu on click
/// - Parameters are specified via pipe: `text | color=red | href=...`
struct UserWidget: View {
  let config: UserWidgetDefinition
  var position: BarPosition = .top

  @EnvironmentObject var settings: SettingsManager

  @StateObject private var runner: UserWidgetRunner
  @State private var anchorView: NSView?

  private var parsedOutput: XBarParsedOutput { runner.parsedOutput }
  private var menuActionHandler: XBarMenuActionHandler { runner.menuActionHandler }

  init(config: UserWidgetDefinition, position: BarPosition = .top) {
    self.config = config
    self.position = position
    _runner = StateObject(wrappedValue: UserWidgetRunner(config: config))
  }

  private var globalSettings: GlobalSettings {
    settings.settings.global
  }

  private var theme: ABarTheme {
    ThemeManager.currentTheme(for: settings.settings.theme)
  }

  /// Parse backgroundColor string to SwiftUI Color
  private var customBackgroundColor: Color? {
    guard let bg = config.backgroundColor, !bg.isEmpty else { return nil }

    switch bg.lowercased() {
    case "main": return theme.main
    case "mainalt": return theme.mainAlt
    case "minor": return theme.minor
    case "accent": return theme.accent
    case "red": return theme.red
    case "green": return theme.green
    case "yellow": return theme.yellow
    case "orange": return theme.orange
    case "blue": return theme.blue
    case "magenta": return theme.magenta
    case "cyan": return theme.cyan
    default: return Color(cssString: bg)
    }
  }

  /// Get contrasted foreground color based on background
  private var foregroundColor: Color {
    if let bgColor = customBackgroundColor {
      return bgColor.contrastingForeground(
        from: theme,
        opacity: globalSettings.barElementsBackgroundOpacity,
        barBackground: theme.background
      )
    }
    return theme.foreground
  }

  private var errorBackgroundColor: Color { theme.red }

  private var errorForegroundColor: Color {
    theme.red.contrastingForeground(
      from: theme,
      opacity: globalSettings.barElementsBackgroundOpacity,
      barBackground: theme.background
    )
  }

  /// The currently displayed header item (cycles through header lines)
  private var currentHeaderItem: XBarLineItem? {
    let headers = parsedOutput.headerLines
    guard !headers.isEmpty else { return nil }
    let index = runner.currentHeaderIndex % headers.count
    return headers[index]
  }

  /// Whether there are dropdown items to show
  private var hasDropdown: Bool {
    if !parsedOutput.menuItems.isEmpty { return true }
    return parsedOutput.headerLines.filter({ $0.params.dropdown }).count > 1
  }

  var body: some View {
    // No lifecycle modifiers: SwiftUI does not deliver them to a `Group` that renders nothing,
    // which is exactly when a hidden widget must keep polling. `runner` does that instead, and
    // an empty `Group` takes no slot in the bar's stack, so a hidden widget leaves no gap.
    Group {
      if config.isActive {
        if runner.errorMessage != nil {
          // Error state: always visible regardless of hideWhenEmpty
          BaseWidgetView(
            backgroundColor: errorBackgroundColor,
            onClick: showErrorMenu
          ) {
            HStack(spacing: 4) {
              Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundColor(errorForegroundColor)
              Text(config.name)
                .foregroundColor(errorForegroundColor)
                .lineLimit(1)
            }
          }
          .background(ViewAnchor(nsView: $anchorView))
        } else if !(config.hideWhenEmpty && parsedOutput.headerLines.isEmpty && !runner.isLoading) {
          BaseWidgetView(
            backgroundColor: customBackgroundColor,
            onClick: hasDropdown ? showDropdownMenu : nil
          ) {
            if runner.isLoading {
              ProgressView()
                .scaleEffect(0.4)
                .frame(width: 12, height: 12)
            } else if let item = currentHeaderItem {
              headerItemView(item)
            } else {
              Text(config.name)
                .foregroundColor(foregroundColor)
                .lineLimit(1)
            }
          }
          .background(ViewAnchor(nsView: $anchorView))
        }
      }
    }
  }

  @ViewBuilder
  private func headerItemView(_ item: XBarLineItem) -> some View {
    HStack(spacing: 4) {
      if let imageData = item.params.templateImage ?? item.params.image,
        let data = Data(base64Encoded: imageData),
        let nsImage = NSImage(data: data)
      {
        Image(nsImage: nsImage)
          .resizable()
          .scaledToFit()
          .frame(height: 14)
      }

      if !item.title.isEmpty {
        let displayText = truncatedTitle(item)
        Text(displayText)
          .foregroundColor(itemColor(item))
          .lineLimit(1)
          .if(item.params.font != nil || item.params.size != nil) { view in
            view.font(
              .custom(
                item.params.font ?? globalSettings.fontName,
                size: item.params.size ?? CGFloat(globalSettings.fontSize)
              )
            )
          }
      }
    }
  }

  private func itemColor(_ item: XBarLineItem) -> Color {
    if let colorStr = item.params.color,
      let nsColor = NSColor(xbarString: colorStr)
    {
      return Color(nsColor)
    }
    return foregroundColor
  }

  private func truncatedTitle(_ item: XBarLineItem) -> String {
    guard let maxLen = item.params.length, item.title.count > maxLen else {
      return item.title
    }
    return String(item.title.prefix(maxLen)) + "…"
  }

  private func showDropdownMenu() {
    guard let view = anchorView else { return }

    let menu = XBarMenuBuilder.buildMenu(from: parsedOutput, handler: menuActionHandler)
    guard menu.items.count > 0 else { return }

    objc_setAssociatedObject(menu, "handler", menuActionHandler, .OBJC_ASSOCIATION_RETAIN)

    let anchorPoint = position == .bottom
      ? NSPoint(x: 0, y: view.bounds.height)
      : NSPoint(x: 0, y: 0)
    menu.popUp(positioning: nil, at: anchorPoint, in: view)
  }

  private func showErrorMenu() {
    guard let view = anchorView, let errMsg = runner.errorMessage else { return }

    let menu = NSMenu()
    menu.autoenablesItems = false

    let titleItem = NSMenuItem(title: "Script error — \(config.name)", action: nil, keyEquivalent: "")
    titleItem.isEnabled = false
    titleItem.attributedTitle = NSAttributedString(
      string: "Script error — \(config.name)",
      attributes: [
        .foregroundColor: NSColor.systemRed,
        .font: NSFont.menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize),
      ]
    )
    menu.addItem(titleItem)
    menu.addItem(.separator())

    // Show each line of stderr as a disabled item
    let lines = errMsg
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: "\n")
    for line in lines where !line.isEmpty {
      let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }

    menu.addItem(.separator())
    let handler = menuActionHandler
    let retryWrapper = NSMenuItem()
    retryWrapper.title = "Retry"
    retryWrapper.target = handler
    retryWrapper.action = #selector(XBarMenuActionHandler.retryAction(_:))
    retryWrapper.isEnabled = true
    objc_setAssociatedObject(menu, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
    menu.addItem(retryWrapper)

    let anchorPoint = position == .bottom
      ? NSPoint(x: 0, y: view.bounds.height)
      : NSPoint(x: 0, y: 0)
    menu.popUp(positioning: nil, at: anchorPoint, in: view)
  }
}

/// Runs one custom widget's script for as long as the widget is in the bar.
///
/// A `@StateObject` lives exactly as long as its view's identity, whether or not the view
/// renders anything, so polling continues while `hideWhenEmpty` hides the widget and stops
/// when the widget is removed. Every input the runner uses is part of `Identity`, so a changed
/// command, activation or interval replaces the runner instead of reconfiguring it. Main thread
/// only.
final class UserWidgetRunner: ObservableObject {
  struct Identity: Hashable {
    let id: UUID
    let command: String
    let isActive: Bool
    let refreshInterval: TimeInterval
    let cycleDuration: TimeInterval

    init(_ config: UserWidgetDefinition) {
      id = config.id
      command = config.command
      isActive = config.isActive
      refreshInterval = config.refreshInterval
      cycleDuration = config.cycleDuration
    }
  }

  /// Minimum custom widget refresh interval.
  private static let minimumRefreshInterval: TimeInterval = 1

  /// Minimum header cycle duration.
  private static let minimumCycleDuration: TimeInterval = 1

  @Published private(set) var parsedOutput: XBarParsedOutput = .empty
  @Published private(set) var isLoading: Bool
  @Published private(set) var errorMessage: String?
  @Published private(set) var currentHeaderIndex = 0

  let menuActionHandler = XBarMenuActionHandler()

  private let id: UUID
  private let command: String
  private let isRunnable: Bool
  private var refreshTimer: Timer?
  private var cycleTimer: Timer?
  private var refreshObserver: NSObjectProtocol?
  private var isRefreshing = false
  private var hasQueuedRefresh = false

  init(config: UserWidgetDefinition) {
    id = config.id
    command = config.command.trimmingCharacters(in: .whitespacesAndNewlines)
    // An inactive widget or an empty command has nothing to run, so nothing to wait for.
    isRunnable = config.isActive && !command.isEmpty
    isLoading = isRunnable
    guard isRunnable else { return }

    menuActionHandler.onRefresh = { [weak self] in self?.refresh() }
    refreshObserver = NotificationCenter.default.addObserver(
      forName: .refreshUserWidget, object: nil, queue: .main
    ) { [weak self] notification in
      guard let self, notification.userInfo?["widgetId"] as? UUID == self.id else { return }
      self.refresh()
    }
    refreshTimer = Self.schedule(every: max(Self.minimumRefreshInterval, config.refreshInterval)) {
      [weak self] in self?.refresh()
    }
    cycleTimer = Self.schedule(every: max(Self.minimumCycleDuration, config.cycleDuration)) {
      [weak self] in self?.cycleHeader()
    }
    refresh()
  }

  deinit {
    refreshTimer?.invalidate()
    cycleTimer?.invalidate()
    if let refreshObserver { NotificationCenter.default.removeObserver(refreshObserver) }
  }

  private static func schedule(every interval: TimeInterval, _ action: @escaping () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  private func cycleHeader() {
    let count = parsedOutput.headerLines.count
    if count > 1 { currentHeaderIndex = (currentHeaderIndex + 1) % count }
  }

  func refresh() {
    guard isRunnable else { return }
    if isRefreshing {
      hasQueuedRefresh = true
      return
    }
    isRefreshing = true

    let command = command
    // Weak, so a removed widget cannot publish a late result or start a queued command.
    Task { @MainActor [weak self] in
      let result = await ShellExecutor.runWidget(command)
      self?.finish(result)
    }
  }

  private func finish(_ result: ShellExecutor.WidgetRunResult) {
    defer {
      isRefreshing = false
      if hasQueuedRefresh {
        hasQueuedRefresh = false
        refresh()
      }
    }

    if !result.succeeded {
      // Build an informative error message from stderr and exit code
      let stderrTrimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      if let executionError = result.executionError {
        errorMessage = executionError
      } else if result.exitCode == -1 {
        // Process launch failure — stderr already contains the description
        errorMessage = stderrTrimmed.isEmpty
          ? "Script could not be started."
          : stderrTrimmed
      } else {
        let codeNote = "Exit code: \(result.exitCode)"
        errorMessage = stderrTrimmed.isEmpty ? codeNote : "\(codeNote)\n\(stderrTrimmed)"
      }
      parsedOutput = .empty
      currentHeaderIndex = 0
      isLoading = false
      return
    }

    errorMessage = nil
    let newOutput = XBarParser.parse(result.stdout)
    if newOutput.headerLines.count != parsedOutput.headerLines.count {
      currentHeaderIndex = 0
    }
    parsedOutput = newOutput
    isLoading = false
  }
}
