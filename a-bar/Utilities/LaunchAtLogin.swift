import ServiceManagement

/// The one place that talks to `SMAppService`.
///
/// Launch at login has to be reconciled, not commanded. The user can remove the login item
/// in System Settings without the app ever hearing about it, macOS can hold a registration
/// pending approval, and registration legitimately fails for a bundle running outside
/// /Applications. Treating the stored setting as the only truth - and writing it from two
/// places that disagreed - is what made the toggle appear to do nothing.
enum LaunchAtLogin {

  enum Status: Equatable {
    case enabled
    case disabled
    /// Registered, but macOS wants the user to allow it in System Settings first.
    case requiresApproval
  }

  static var status: Status {
    switch SMAppService.mainApp.status {
    case .enabled: return .enabled
    case .requiresApproval: return .requiresApproval
    default: return .disabled
    }
  }

  /// Whether a login item is registered, approved or not.
  static var isEnabled: Bool {
    status != .disabled
  }

  static func setEnabled(_ enabled: Bool) throws {
    guard enabled != isEnabled else { return }

    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }

  /// Open System Settings › General › Login Items, for the approval case.
  static func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
