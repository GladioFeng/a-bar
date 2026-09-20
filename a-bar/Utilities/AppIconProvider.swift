import AppKit
import SwiftUI

/// Provides native application icons for windows
class AppIconProvider {
    static let shared = AppIconProvider()

    private var iconCache: [String: NSImage] = [:]
    private var resizedIconCache: [String: [CGFloat: NSImage]] = [:]
    private let queue = DispatchQueue(label: "com.abar.icon-provider", attributes: .concurrent)

    /// Apps currently being looked up via mdfind to avoid duplicate searches.
    private var pendingLookups = Set<String>()

    private let findAppPath: (String) -> String?

    init(findAppPath: @escaping (String) -> String? = AppIconProvider.findAppPathViaMdfind) {
        self.findAppPath = findAppPath
    }

    /// Get the icon for an application by name.
    /// Returns a cached icon immediately, or kicks off an async lookup and
    /// returns nil (the view will re-render once the cache is populated).
    func icon(forApp appName: String) -> NSImage? {
        // Check cache first (concurrent read is safe)
        if let cached = queue.sync(execute: { iconCache[appName] }) {
            return cached
        }

        // Try fast, synchronous paths first (running apps + known dirs)
        if let icon = findAppIconFast(appName: appName) {
            queue.async(flags: .barrier) {
                self.iconCache[appName] = icon
            }
            return icon
        }

        // Slow path (mdfind) – dispatch off the calling thread.
        // Return nil now; the caller will get a placeholder and the cache
        // will eventually be filled for the next render.
        queue.async(flags: .barrier) {
            guard !self.pendingLookups.contains(appName) else { return }
            guard self.iconCache[appName] == nil else { return }
            self.pendingLookups.insert(appName)

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let icon = self.findAppPath(appName).map { NSWorkspace.shared.icon(forFile: $0) }
                self.queue.async(flags: .barrier) {
                    if let icon { self.iconCache[appName] = icon }
                    self.pendingLookups.remove(appName)
                }
            }
        }

        return nil
    }

    /// Get a SwiftUI Image for an application
    func iconImage(forApp appName: String, size: CGFloat = 16) -> Image {
        if let nsImage = resizedIcon(forApp: appName, to: size) {
            return Image(nsImage: nsImage)
        }
        return Image(systemName: "app.fill")
    }

    /// Fast icon lookup – no shell processes.
    private func findAppIconFast(appName: String) -> NSImage? {
        // 1. Running applications (most common case)
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
            if let icon = runningApp.icon {
                return icon
            }
            if let bundleURL = runningApp.bundleURL {
                return NSWorkspace.shared.icon(forFile: bundleURL.path)
            }
        }

        // 2. Well-known application directories
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications"
        ]
        for path in searchPaths {
            let appPath = "\(path)/\(appName).app"
            if FileManager.default.fileExists(atPath: appPath) {
                return NSWorkspace.shared.icon(forFile: appPath)
            }
        }

        return nil
    }

    /// Slow fallback via mdfind – **never call on the main thread**.
    private static func findAppPathViaMdfind(appName: String) -> String? {
        let command = "mdfind 'kMDItemKind == \"Application\" && kMDItemDisplayName == \"\(appName)\"' | head -1"
        let result = ShellExecutor.runSync(command, timeout: 5)
        let path = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }

    func resizedIcon(forApp appName: String, to size: CGFloat) -> NSImage? {
        if let cached = queue.sync(execute: { resizedIconCache[appName]?[size] }) {
            return cached
        }
        guard let image = icon(forApp: appName) else { return nil }
        let newSize = NSSize(width: size, height: size)
        let newImage = NSImage(size: newSize)

        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()

        queue.async(flags: .barrier) {
            self.resizedIconCache[appName, default: [:]][size] = newImage
        }
        return newImage
    }
}

struct AppIconView: View {
    let appName: String
    var size: CGFloat = 16
    
    private var iconProvider: AppIconProvider { .shared }
    @ObservedObject private var settingsManager = SettingsManager.shared
    private var useGrayscale: Bool {
        settingsManager.settings.global.grayscaleAppIcons
    }
    
    var body: some View {
        iconProvider.iconImage(forApp: appName, size: size)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .saturation(useGrayscale ? 0 : 1)
    }
}
