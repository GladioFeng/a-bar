import Foundation

/// Owns the config file on disk. Single writer, atomic writes, and a hard rule: a config we
/// could not read is never overwritten by the defaults we fell back to.
///
/// Public API is main-thread only; file I/O happens on a private serial queue.
final class SettingsStore {

  enum Source: String {
    case file
    case backup
    case legacyUserDefaults
    case defaults
  }

  struct LoadResult {
    let settings: ABarSettings
    let repairs: [SettingsCodec.Repair]
    let source: Source
    /// The config file exists but could not be read. Automatic writes stay suppressed.
    let isDegraded: Bool

    /// One line describing anything the user would want to know, or nil when all was well.
    var summary: String? {
      var parts: [String] = []

      // A fresh install landing on the defaults is the normal case, not news.
      switch source {
      case .backup:
        parts.append("restored the last known good config")
      case .legacyUserDefaults:
        parts.append("imported settings from the previous store")
      case .file, .defaults:
        break
      }

      if !repairs.isEmpty {
        let listed = repairs.prefix(5).map { $0.description }.joined(separator: ", ")
        let more = repairs.count > 5 ? ", +\(repairs.count - 5) more" : ""
        parts.append("recovered \(repairs.count) setting(s): \(listed)\(more)")
      }
      if isDegraded {
        parts.append("automatic saving is paused until you save from Preferences")
      }
      return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
  }

  /// Keys the app used to write before the config file became the source of truth. Read once
  /// on first launch after upgrading, then left alone.
  private enum Legacy {
    static let settings = "abar-settings"
    static let profiles = "abar-profiles"
    static let activeProfile = "abar-active-profile"
  }

  static var defaultFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".a-barrc")
  }

  private let fileURL: URL
  private let userDefaults: UserDefaults
  private let writeDelay: TimeInterval
  private let ioQueue = DispatchQueue(label: "com.jeantinland.a-bar.settings-store")
  private let fileManager = FileManager.default

  private var pendingWrite: DispatchWorkItem?
  private var pendingSettings: ABarSettings?

  /// Set when the config file could not be parsed. While true the store refuses to write, so
  /// a corrupt file is preserved for the user instead of being replaced by defaults.
  private(set) var isDegraded = false

  init(
    fileURL: URL = SettingsStore.defaultFileURL,
    userDefaults: UserDefaults = .standard,
    writeDelay: TimeInterval = 0.3
  ) {
    self.fileURL = fileURL
    self.userDefaults = userDefaults
    self.writeDelay = writeDelay
  }

  deinit {
    pendingWrite?.cancel()
  }

  private var backupURL: URL {
    fileURL.appendingPathExtension("bak")
  }

  // MARK: - Loading

  func load() -> LoadResult {
    if fileManager.fileExists(atPath: fileURL.path) {
      return loadFromFile()
    }

    if let imported = importLegacyUserDefaults() {
      // Make the migration durable straight away rather than waiting for the first edit.
      write(imported.settings)
      return imported
    }

    var settings = ABarSettings()
    SettingsCodec.normalize(&settings)
    return LoadResult(settings: settings, repairs: [], source: .defaults, isDegraded: false)
  }

  private func loadFromFile() -> LoadResult {
    guard let data = try? Data(contentsOf: fileURL) else {
      print("⚠️ a-bar: cannot read \(fileURL.path) - leaving it untouched")
      isDegraded = true
      return restoreFromBackup() ?? degradedDefaults()
    }

    switch SettingsCodec.decode(data) {
    case .ok(let settings, let repairs):
      if repairs.isEmpty {
        // This file is known good, so it becomes the thing we fall back to.
        try? data.write(to: backupURL, options: .atomic)
      } else {
        // Keep the original: the repair dropped something the user may want back.
        quarantine(data, kind: "repaired")
      }
      return LoadResult(settings: settings, repairs: repairs, source: .file, isDegraded: false)

    case .unreadable(let reason):
      print("⚠️ a-bar: \(fileURL.lastPathComponent) is unreadable (\(reason)) - not overwriting it")
      quarantine(data, kind: "corrupt")
      isDegraded = true
      return restoreFromBackup() ?? degradedDefaults()
    }
  }

  private func restoreFromBackup() -> LoadResult? {
    guard let data = try? Data(contentsOf: backupURL),
      case .ok(let settings, let repairs) = SettingsCodec.decode(data)
    else { return nil }

    return LoadResult(settings: settings, repairs: repairs, source: .backup, isDegraded: true)
  }

  private func degradedDefaults() -> LoadResult {
    var settings = ABarSettings()
    SettingsCodec.normalize(&settings)
    return LoadResult(settings: settings, repairs: [], source: .defaults, isDegraded: true)
  }

  private func importLegacyUserDefaults() -> LoadResult? {
    guard let settingsData = userDefaults.data(forKey: Legacy.settings),
      var root = (try? JSONSerialization.jsonObject(with: settingsData)) as? [String: Any]
    else { return nil }

    // Profiles used to live in their own key, with the active one beside them.
    if (root["profiles"] as? [Any])?.isEmpty != false,
      let profilesData = userDefaults.data(forKey: Legacy.profiles),
      let profiles = (try? JSONSerialization.jsonObject(with: profilesData)) as? [Any]
    {
      root["profiles"] = profiles
    }
    if root["activeProfileId"] == nil,
      let active = userDefaults.string(forKey: Legacy.activeProfile)
    {
      root["activeProfileId"] = active
    }

    guard let data = try? JSONSerialization.data(withJSONObject: root),
      case .ok(let settings, let repairs) = SettingsCodec.decode(data)
    else { return nil }

    return LoadResult(
      settings: settings, repairs: repairs, source: .legacyUserDefaults, isDegraded: false)
  }

  // MARK: - Saving

  /// Persist after a short delay, coalescing bursts of changes into one write.
  func save(_ settings: ABarSettings) {
    guard !isDegraded else { return }
    schedule(settings)
  }

  /// Persist a state the user explicitly asked for, which also clears degraded mode: they
  /// have seen the settings the app is running on and chose to keep them.
  func saveExplicitly(_ settings: ABarSettings) {
    isDegraded = false
    schedule(settings)
  }

  /// Write any pending change immediately. Called on termination.
  func flush() {
    pendingWrite?.cancel()
    pendingWrite = nil
    guard let settings = pendingSettings else { return }
    pendingSettings = nil
    ioQueue.sync { self.write(settings) }
  }

  private func schedule(_ settings: ABarSettings) {
    pendingSettings = settings
    pendingWrite?.cancel()

    let work = DispatchWorkItem { [weak self] in
      self?.write(settings)
    }
    pendingWrite = work
    ioQueue.asyncAfter(deadline: .now() + writeDelay, execute: work)
  }

  private func write(_ settings: ABarSettings) {
    do {
      let data = try SettingsCodec.encode(settings)
      // Skip no-op writes so quitting the app does not churn the file.
      if let existing = try? Data(contentsOf: fileURL), existing == data { return }
      try data.write(to: fileURL, options: .atomic)
    } catch {
      print("⚠️ a-bar: failed to write \(fileURL.path): \(error.localizedDescription)")
    }
  }

  // MARK: - Quarantine

  /// Keep a copy of a config we could not use as-is, so nothing is lost silently.
  private func quarantine(_ data: Data, kind: String) {
    let formatter = DateFormatter()
    // Milliseconds included so two quarantines in the same second do not collide.
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    let directory = fileURL.deletingLastPathComponent()
    let name = "\(fileURL.lastPathComponent).\(kind)-\(formatter.string(from: Date()))"

    // Never overwrite an existing copy: the whole point is that nothing is lost silently.
    var url = directory.appendingPathComponent(name)
    var attempt = 2
    while fileManager.fileExists(atPath: url.path) {
      url = directory.appendingPathComponent("\(name)-\(attempt)")
      attempt += 1
    }

    try? data.write(to: url, options: .atomic)
    pruneQuarantine(kind: kind, keeping: 3)
  }

  private func pruneQuarantine(kind: String, keeping limit: Int) {
    let directory = fileURL.deletingLastPathComponent()
    let prefix = "\(fileURL.lastPathComponent).\(kind)-"

    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }

    // Timestamped names sort chronologically, so the tail is the oldest.
    let matches =
      entries
      .filter { $0.lastPathComponent.hasPrefix(prefix) }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }

    for url in matches.dropFirst(limit) {
      try? fileManager.removeItem(at: url)
    }
  }
}
