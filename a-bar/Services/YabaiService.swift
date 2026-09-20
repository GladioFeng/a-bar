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
    ]
    private let settingsManager: SettingsManager
    private var isStarted = false
    private var refreshGeneration = 0
    private var isRefreshing = false
    private var refreshPending = false

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
        // Observe macOS Space changes
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
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
                self?.handleAppNotification(note)
            }
            appObservers.append(observer)
        }

        // Observe display add/removal/reconfiguration
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    // Handle NSWorkspace app notifications
    private func handleAppNotification(_ note: Notification) {
        refresh()
    }

    /// Start the yabai service
    func start() {
        if isStarted {
            if signalPath != yabaiPath {
                refreshGeneration += 1
                isRefreshing = false
                refreshPending = false
                updateSignals(register: false, path: signalPath ?? yabaiPath)
                signalPath = yabaiPath
                setupYabaiSignals()
                refresh()
            }
            return
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let service = Unmanaged<YabaiService>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { [weak service] in
                    guard let service, service.isStarted else { return }
                    service.refresh()
                }
            },
            refreshNotification as CFString, nil, .deliverImmediately)
        isStarted = true
        signalPath = yabaiPath
        setupObservers()
        refresh()
        setupYabaiSignals()
        startSignalTimer()
    }

    /// Stop the yabai service
    func stop() {
        isStarted = false
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(refreshNotification as CFString), nil)
        refreshGeneration += 1
        isRefreshing = false
        refreshPending = false
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
        signalTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.setupYabaiSignals()
        }
    }
    
    /// Stop the periodic signal timer
    private func stopSignalTimer() {
        signalTimer?.invalidate()
        signalTimer = nil
    }
    
    /// Darwin notifications avoid an AppleScript process and watchdog per window event.
    private var signalAction: String {
        "/usr/bin/notifyutil -p \(refreshNotification)"
    }

    private func setupYabaiSignals() {
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
            guard isStarted, generation == refreshGeneration else { return }
            do {
                let output = try await ShellExecutor.run(executable: path, arguments: ["-m", "signal", "--list"])
                let signals = try JSONDecoder().decode([YabaiSignal].self, from: Data(output.utf8))
                for (event, label) in Self.signalEvents {
                    // Replace old AppleScript actions too, not just missing labels.
                    if signals.contains(where: { $0.label == label && $0.action == signalAction }) { continue }
                    try await ShellExecutor.run(executable: path, arguments: [
                        "-m", "signal", "--add", "event=\(event)", "action=\(signalAction)", "label=\(label)"])
                }
                guard isStarted, generation == refreshGeneration else { return }
                if !signalsRegistered { signalsRegistered = true }
            } catch {
                guard isStarted, generation == refreshGeneration else { return }
                if signalsRegistered { signalsRegistered = false }
                print("Failed to register yabai signals: \(error). Retrying in 20 seconds.")
            }
        }
    }

    /// Refresh immediately, retaining one follow-up if events arrive during a query.
    func refresh() {
        let generation = refreshGeneration
        Task { @MainActor in
            guard generation == refreshGeneration else { return }
            guard !isRefreshing else {
                refreshPending = true
                return
            }
            isRefreshing = true
            repeat {
                refreshPending = false
                let path = yabaiPath
                do {
                    async let spaces: [YabaiSpace] = fetch("spaces", path: path)
                    async let windows: [YabaiWindow] = fetch("windows", path: path)
                    async let displays: [YabaiDisplay] = fetch("displays", path: path)
                    var next = try await YabaiState(spaces: spaces, windows: windows, displays: displays)
                    next.windows.removeAll { window in
                        guard let subrole = window.subrole else { return true }
                        return subrole.isEmpty || subrole == "AXDialog"
                    }
                    // A stopped service must not overwrite a newer generation's state or flags.
                    guard generation == refreshGeneration else { return }
                    if state != next { state = next }
                    if !isConnected { isConnected = true }
                    if lastError != nil { lastError = nil }
                } catch {
                    guard generation == refreshGeneration else { return }
                    handleError(error)
                }
            } while refreshPending
            isRefreshing = false
        }
    }

    /// Process I/O and decoding stay off the main actor.
    private func fetch<T: Decodable>(_ collection: String, path: String) async throws -> T {
        let output = try await ShellExecutor.run(executable: path, arguments: ["-m", "query", "--\(collection)"])
        return try JSONDecoder().decode(T.self, from: Data(cleanupJSON(output).utf8))
    }

    /// Focus on a specific space
    func goToSpace(_ index: Int) async {
        do {
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", "--focus", String(index)])
        } catch {
            await handleError(error)
        }
    }

    /// Rename a space
    func renameSpace(_ index: Int, label: String) async {
        do {
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", String(index), "--label", label])
        } catch {
            await handleError(error)
        }
    }

    /// Create a new space on a display
    func createSpace(onDisplay displayIndex: Int) async {
        do {
            try await focusDisplay(displayIndex)
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", "--create"])
        } catch {
            await handleError(error)
        }
    }

    /// Remove a space
    func removeSpace(_ index: Int, onDisplay displayIndex: Int) async {
        do {
            try await focusDisplay(displayIndex)
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", String(index), "--destroy"])
        } catch {
            await handleError(error)
        }
    }

    /// Swap a space with another in the given direction
    func swapSpace(_ index: Int, direction: SwapDirection) async {
        let targetIndex = direction == .left ? index - 1 : index + 1
        do {
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "space", String(index), "--swap", String(targetIndex)])
        } catch {
            await handleError(error)
        }
    }

    /// Focus on a specific window
    func focusWindow(_ id: Int) async {
        do {
            try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "window", "--focus", String(id)])
        } catch {
            await handleError(error)
        }
    }

    /// Focus on a specific display
    private func focusDisplay(_ index: Int) async throws {
        try await ShellExecutor.run(executable: yabaiPath, arguments: ["-m", "display", "--focus", String(index)])
    }

    // Timer logic removed

    /// Clean up JSON with escape sequences and malformed arrays
    private func cleanupJSON(_ json: String) -> String {
        var cleaned = json
        
        // Remove newline escape sequences
        cleaned = cleaned.replacingOccurrences(of: "\\\n", with: "")
        
        // Fix empty arrays with commas: [,] -> []
        cleaned = cleaned.replacingOccurrences(of: "\\[,+", with: "[", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: ",+\\]", with: "]", options: .regularExpression)
        
        // Fix multiple consecutive commas
        cleaned = cleaned.replacingOccurrences(of: ",+,", with: ",", options: .regularExpression)
        
        // Fix comma after opening bracket and before closing bracket
        cleaned = cleaned.replacingOccurrences(of: "\\[,", with: "[", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: ",\\]", with: "]", options: .regularExpression)
        
        // Escape backslashes then unescape quotes
        cleaned = cleaned.replacingOccurrences(of: "\\", with: "\\\\")
        cleaned = cleaned.replacingOccurrences(of: "\\\\\"", with: "\"")
        
        // Handle yabai quirks with 00000
        cleaned = cleaned.replacingOccurrences(of: "00000", with: "0")
        
        return cleaned
    }

    @MainActor
    private func handleError(_ error: Error) {
        self.lastError = error
        self.isConnected = false
        print("Yabai error: \(error)")
    }

    enum SwapDirection {
        case left
        case right
    }
}
