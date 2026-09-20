import Foundation

/// Deciding when to touch the login item, and what to believe afterwards.
///
/// macOS owns the login item and the app only gets to ask. Two things follow. At launch the
/// stored setting is the guess and `SMAppService` is the truth, so the truth is adopted rather
/// than forced back. Afterwards the app remembers what it last applied, because reacting to
/// every settings change is what used to unregister the login item the moment any unrelated
/// setting was saved - and a refused change must clear that memory, or the app spends the rest
/// of the session believing a registration that never happened.
enum LaunchAtLoginReconciler {

  /// What became of a requested change, and what to remember from it.
  enum Outcome: Equatable {
    /// The request already matches what was applied; the login item was not touched.
    case unchanged(Bool)
    /// macOS accepted the change.
    case applied(Bool)
    /// macOS refused. The login item's state is no longer known.
    case failed(Bool, message: String)

    /// The value to keep as "last applied" - `nil` after a refusal, so the next request is
    /// tried again instead of being skipped as redundant.
    var lastApplied: Bool? {
      switch self {
      case .unchanged(let enabled), .applied(let enabled): return enabled
      case .failed: return nil
      }
    }
  }

  /// Ask for the login item to be enabled or disabled, skipping the ask when nothing changed.
  static func apply(
    _ enabled: Bool,
    lastApplied: Bool?,
    setEnabled: (Bool) throws -> Void
  ) -> Outcome {
    guard lastApplied != enabled else { return .unchanged(enabled) }

    do {
      try setEnabled(enabled)
      return .applied(enabled)
    } catch {
      return .failed(enabled, message: error.localizedDescription)
    }
  }

  /// What to do at launch with what macOS reports.
  struct Adoption: Equatable {
    /// What the app now knows is applied - always what macOS reports.
    let lastApplied: Bool
    /// The value the stored setting has to be rewritten to, or `nil` when it already agrees.
    /// A user who removed the login item in System Settings must not see the toggle still on.
    let settingToWrite: Bool?
  }

  static func adopt(registered: Bool, stored: Bool) -> Adoption {
    Adoption(lastApplied: registered, settingToWrite: stored == registered ? nil : registered)
  }
}
