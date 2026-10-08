import AppKit
import Foundation
import Darwin

/// Service for interacting with yabai window manager
class YabaiService: ObservableObject {
    static let shared = YabaiService()

    @Published private(set) var state = YabaiState()
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: Error?
    @Published private(set) var signalsRegistered = false

    private var signalTimer: Timer?
    private var signalTask: Task<Void, Never>?
    private let refreshNotification: String
    private var signalPath: String?
    private static let signalEvents = [
        ("window_destroyed", "abar-window-destroyed"),
        ("window_title_changed", "abar-window-title-changed"),
        ("window_focused", "abar-window-focused"),
        ("window_moved", "abar-window-moved"),
    ]
    private let settingsManager: SettingsManager
    private enum RefreshScope { case windows, full }
    private var isStarted = false
    private var refreshGeneration = 0
    private var refreshTask: Task<Void, Never>?
    private var moveRefreshTask: Task<Void, Never>?
    private var pendingRefresh: RefreshScope?
    private var hasFullSnapshot = false

    private var titleRefreshNotification: String {
        refreshNotification + ".window-title-changed"
    }

    private var moveRefreshNotification: String {
        refreshNotification + ".window-moved"
    }

    private var yabaiPath: String {
        settingsManager.settings.global.yabaiPath
    }

    private var spaceObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []
    private var screenObserver: NSObjectProtocol?

    init(
        settingsManager: SettingsManager = .shared,
        refreshNotification: String = "user.uid.\(getuid()).com.jeantinland.a-bar.yabai"
    ) {
        self.settingsManager = settingsManager
        self.refreshNotification = refreshNotification
    }

    private func setupObservers() {
        let generation = refreshGeneration
        // Observe macOS Space changes
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isStarted, generation == self.refreshGeneration else { return }
            self.refresh()
        }

        // Observe app activation/deactivation/launch/termination/hide/unhide
        let nc = NSWorkspace.shared.notificationCenter
        let notifications: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ]
        for name in notifications {
            let observer = nc.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self, self.isStarted, generation == self.refreshGeneration else { return }
                self.handleAppNotification(note)
            }
            appObservers.append(observer)
        }

        // Observe display add/removal/reconfiguration
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isStarted, generation == self.refreshGeneration else { return }
            self.refresh()
        }
    }

    // Handle NSWorkspace app notifications
    private func handleAppNotification(_ note: Notification) {
        refresh()
    }

    /// Start the yabai service
    func start() {
        if isStarted {
            guard signalPath != yabaiPath else { return }
            stop()
        }
        for notification in [refreshNotification, titleRefreshNotification, moveRefreshNotification] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let service = Unmanaged<YabaiService>.fromOpaque(observer).takeUnretainedValue()
                    let notification = name.rawValue as String
                    let generation = service.refreshGeneration
                    DispatchQueue.main.async { [weak service] in
                        guard let service, service.isStarted, generation == service.refreshGeneration else { return }
                        if notification == service.moveRefreshNotification {
                            service.scheduleMoveRefresh()
                        } else {
                            service.refresh(notification == service.titleRefreshNotification ? .windows : .full)
                        }
                    }
                },
                notification as CFString, nil, .deliverImmediately)
        }
        isStarted = true
        hasFullSnapshot = false
        signalPath = yabaiPath
        setupObservers()
        refresh()
        setupYabaiSignals()
        startSignalTimer()
    }

    /// Stop the yabai service
    func stop() {
        guard isStarted else { return }
        isStarted = false
        for notification in [refreshNotification, titleRefreshNotification, moveRefreshNotification] {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(notification as CFString), nil)
        }
        refreshGeneration += 1
        cancelMoveRefresh()
        refreshTask?.cancel()
        refreshTask = nil
        signalTask?.cancel()
        pendingRefresh = nil
        hasFullSnapshot = false
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
        let nc = NSWorkspace.shared.notificationCenter
        for observer in appObservers {
            nc.removeObserver(observer)
        }
        appObservers.removeAll()

        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        
        // Stop signal timer
        stopSignalTimer()
        
        // Serialize removal with registration, including a quick stop/start cycle.
        updateSignals(register: false, path: signalPath ?? yabaiPath)
        signalPath = nil
        if signalsRegistered { signalsRegistered = false }
    }
    
    /// Start the periodic timer to re-register yabai signals
    private func startSignalTimer() {
        // Stop any existing timer
        stopSignalTimer()
        
        // Create a new timer that fires every 20 seconds
        let generation = refreshGeneration
        signalTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            guard let self, self.isStarted, generation == self.refreshGeneration else { return }
            self.setupYabaiSignals()
        }
    }
    
    /// Stop the periodic signal timer
    private func stopSignalTimer() {
        signalTimer?.invalidate()
        signalTimer = nil
    }
    
    /// Darwin notifications avoid an AppleScript process and watchdog per window event.
    private func signalAction(for event: String) -> String {
        let notification: String
        switch event {
        case "window_title_changed": notification = titleRefreshNotification
        case "window_moved": notification = moveRefreshNotification
        default: notification = refreshNotification
        }
        return "/usr/bin/notifyutil -p \(notification)"
    }

    private func setupYabaiSignals() {
        guard isStarted else { return }
        updateSignals(register: true, path: yabaiPath)
    }

    private func updateSignals(register: Bool, path: String) {
        let previous = signalTask
        let generation = refreshGeneration
        signalTask = Task { @MainActor in
            await previous?.value
            if !register {
                for (_, label) in Self.signalEvents {
                    _ = try? await ShellExecutor.run(executable: path, arguments: ["-m", "signal", "--remove", label])
                }
                return
            }
            guard isStarted, generation == refreshGeneration, !Task.isCancelled else { return }
            do {
                let output = try await ShellExecutor.run(executable: path, arguments: ["-m", "signal", "--list"])
                let signals = try JSONDecoder().decode([YabaiSignal].self, from: Data(output.utf8))
                for (event, label) in Self.signalEvents {
                    guard isStarted, generation == refreshGeneration, !Task.isCancelled else { return }
                    // Keep the labels while migrating old AppleScript and full-refresh title actions.
                    let action = signalAction(for: event)
                    if signals.contains(where: { $0.label == label && $0.event == event && $0.action == action }) { continue }
                    try await ShellExecutor.run(executable: path, arguments: [
                        "-m", "signal", "--add", "event=\(event)", "action=\(action)", "label=\(label)"])
                }
                guard isStarted, generation == refreshGeneration, !Task.isCancelled else { return }
                if !signalsRegistered { signalsRegistered = true }
            } catch {
                guard isStarted, generation == refreshGeneration, !Task.isCancelled else { return }
                if signalsRegistered { signalsRegistered = false }
                print("Failed to register yabai signals: \(error). Retrying in 20 seconds.")
            }
        }
    }

    /// Manual and structural events always request a complete snapshot.
    func refresh() {
        refresh(.full)
    }

    /// Keep one pending request, with complete snapshots taking precedence over title updates.
    private func enqueueRefresh(_ scope: RefreshScope) {
        if scope == .full || pendingRefresh == nil { pendingRefresh = scope }
    }

    /// AX move delivery can be 140-290ms apart during a drag. Wait 300ms for the final relationships.
    private func scheduleMoveRefresh() {
        guard isStarted else { return }
        cancelMoveRefresh()
        let generation = refreshGeneration
        moveRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch { return }
            guard let self, self.isStarted, generation == self.refreshGeneration, !Task.isCancelled else { return }
            self.moveRefreshTask = nil
            self.refresh(.full)
        }
    }

    private func cancelMoveRefresh() {
        moveRefreshTask?.cancel()
        moveRefreshTask = nil
    }

    private func refresh(_ requestedScope: RefreshScope) {
        guard isStarted else { return }
        if requestedScope == .full { cancelMoveRefresh() }
        enqueueRefresh(requestedScope)
        guard refreshTask == nil else { return }
        let generation = refreshGeneration
        refreshTask = Task { @MainActor in
            while let requested = pendingRefresh {
                guard isStarted, generation == refreshGeneration, !Task.isCancelled else { return }
                pendingRefresh = nil
                let scope: RefreshScope = hasFullSnapshot ? requested : .full
                // A structural event or title fallback supersedes any delayed move snapshot.
                if scope == .full { cancelMoveRefresh() }
                let path = yabaiPath
                do {
                    var next: YabaiState
                    switch scope {
                    case .full:
                        async let spaces: [YabaiSpace] = fetch("spaces", path: path)
                        async let windows: [YabaiWindow] = fetch("windows", path: path)
                        async let displays: [YabaiDisplay] = fetch("displays", path: path)
                        next = try await YabaiState(spaces: spaces, windows: windows, displays: displays)
                        next.windows = filteredWindows(next.windows)
                    case .windows:
                        let windows = filteredWindows(try await fetch("windows", path: path))
                        guard isStarted, generation == refreshGeneration, !Task.isCancelled else { return }
                        // A title event may race a structural change. Do not combine those windows
                        // with cached Space/display membership; wait for the complete follow-up.
                        guard pendingRefresh != .full, canApplyTitleUpdate(windows) else {
                            enqueueRefresh(.full)
                            continue
                        }
                        next = state
                        next.windows = windows
                    }
                    // A stopped service must not overwrite a newer generation's state or flags.
                    guard isStarted, generation == refreshGeneration, !Task.isCancelled else { return }
                    if scope == .full { hasFullSnapshot = true }
                    if state != next { state = next }
                    if !isConnected { isConnected = true }
                    if lastError != nil { lastError = nil }
                } catch {
                    guard isStarted, generation == refreshGeneration, !Task.isCancelled else { return }
                    hasFullSnapshot = false
                    handleError(error, generation: generation)
                    // Retry a failed partial read once as a full snapshot. A failed full read
                    // waits for another event instead of creating an unbounded retry loop.
                    if scope == .windows { enqueueRefresh(.full) }
                }
            }
            refreshTask = nil
        }
    }

    private func filteredWindows(_ windows: [YabaiWindow]) -> [YabaiWindow] {
        windows.filter { window in
            guard let subrole = window.subrole else { return false }
            return !subrole.isEmpty && subrole != "AXDialog"
        }
    }

    /// Match identities and the fields that connect windows to cached Spaces/displays.
    /// Removing each ID also rejects duplicates without trapping on malformed input.
    private func canApplyTitleUpdate(_ windows: [YabaiWindow]) -> Bool {
        guard state.windows.count == windows.count else { return false }
        var previous: [Int: YabaiWindow] = [:]
        for window in state.windows {
            guard previous.updateValue(window, forKey: window.id) == nil else { return false }
        }
        for window in windows {
            guard let old = previous.removeValue(forKey: window.id),
                  old.pid == window.pid, old.space == window.space, old.display == window.display,
                  old.hasFocus == window.hasFocus, old.isVisible == window.isVisible,
                  old.isMinimized == window.isMinimized, old.isHidden == window.isHidden,
                  old.isSticky == window.isSticky else { return false }
        }
        return previous.isEmpty
    }

    /// Process I/O and decoding stay off the main actor.
    private func fetch<T: Decodable>(_ collection: String, path: String) async throws -> T {
        try Task.checkCancellation()
        let output = try await ShellExecutor.run(executable: path, arguments: ["-m", "query", "--\(collection)"])
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        // Valid output needs no repair and must retain its literal string values.
        if let value = try? decoder.decode(T.self, from: Data(output.utf8)) { return value }
        return try decoder.decode(
            T.self, from: Data(YabaiJSONSanitizer.sanitize(output).utf8))
    }

    /// Focus on a specific space
    func goToSpace(_ index: Int) async {
        let generation = refreshGeneration
        do {
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", "--focus", String(index)])
            await refreshAfterMutation(generation: generation)
        } catch {
            await handleError(error, generation: generation)
        }
    }

    /// Rename a space
    func renameSpace(_ index: Int, label: String) async {
        let generation = refreshGeneration
        do {
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", String(index), "--label", label])
            await refreshAfterMutation(generation: generation)
        } catch {
            await handleError(error, generation: generation)
        }
    }

    /// Create a new space on a display
    func createSpace(onDisplay displayIndex: Int) async {
        let generation = refreshGeneration
        do {
            try await focusDisplay(displayIndex)
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", "--create"])
            await refreshAfterMutation(generation: generation)
        } catch {
            await handleError(error, generation: generation)
        }
    }

    /// Remove a space
    func removeSpace(_ index: Int, onDisplay displayIndex: Int) async {
        let generation = refreshGeneration
        do {
            try await focusDisplay(displayIndex)
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", String(index), "--destroy"])
            await refreshAfterMutation(generation: generation)
        } catch {
            await handleError(error, generation: generation)
        }
    }

    /// Swap a space with another in the given direction
    func swapSpace(_ index: Int, direction: SwapDirection) async {
        let generation = refreshGeneration
        let targetIndex = direction == .left ? index - 1 : index + 1
        do {
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", String(index), "--swap", String(targetIndex)])
            await refreshAfterMutation(generation: generation)
        } catch {
            await handleError(error, generation: generation)
        }
    }

    /// Focus on a specific window
    func focusWindow(_ id: Int) async {
        let generation = refreshGeneration
        do {
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "window", "--focus", String(id)])
            await refreshAfterMutation(generation: generation)
        } catch {
            await handleError(error, generation: generation)
        }
    }

    /// Focus on a specific display
    private func focusDisplay(_ index: Int) async throws {
        try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "display", "--focus", String(index)])
    }

    @MainActor
    private func refreshAfterMutation(generation: Int) {
        guard generation == refreshGeneration else { return }
        refresh()
    }

    @MainActor
    private func handleError(_ error: Error, generation: Int) {
        guard generation == refreshGeneration else { return }
        self.lastError = error
        self.isConnected = false
        print("Yabai error: \(error)")
    }

    enum SwapDirection {
        case left
        case right
    }
}
