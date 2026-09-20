import Foundation

/// Error types for user widget operations
enum UserWidgetError: LocalizedError, Equatable {
  case duplicateName(String)
  case widgetNotFound(String)

  var errorDescription: String? {
    switch self {
    case .duplicateName(let name):
      return "A widget with the name '\(name)' already exists. Widget names must be unique."
    case .widgetNotFound(let name):
      return "No widget found with the name '\(name)'."
    }
  }
}

extension Notification.Name {
  /// Asks the widget with the given `widgetId` in `userInfo` to re-run its script. Posted by
  /// the AppleScript commands and by the Preferences window; every `UserWidget` on every bar
  /// listens, and only the one whose id matches acts.
  static let refreshUserWidget = Notification.Name("RefreshUserWidget")
}

/// The custom widgets, and the four things AppleScript can ask of one.
///
/// Lifted out of `UserWidget.swift`, where it sat underneath the SwiftUI view it feeds. None
/// of this is view code - it reads and writes the widget list in settings - but living in a
/// file that imports SwiftUI meant it could not be compiled into the test bundle, and the
/// AppleScript surface went untested as a result.
///
/// Visibility changes persist immediately. An AppleScript `hide` has to survive a restart,
/// and must not be reverted by the next save from the Preferences window.
class UserWidgetManager: ObservableObject {
  static let shared = UserWidgetManager()

  private let settingsManager: SettingsManager
  private let notificationCenter: NotificationCenter

  var widgets: [UserWidgetDefinition] {
    settingsManager.settings.userWidgets
  }

  init(
    settingsManager: SettingsManager = .shared,
    notificationCenter: NotificationCenter = .default
  ) {
    self.settingsManager = settingsManager
    self.notificationCenter = notificationCenter
  }

  func removeWidget(id: UUID) {
    settingsManager.update { $0.userWidgets.removeAll { $0.id == id } }
  }

  @discardableResult
  func refreshWidget(named name: String) -> Bool {
    guard let widget = widgets.first(where: { $0.name == name }) else {
      return false
    }

    notificationCenter.post(
      name: .refreshUserWidget,
      object: nil,
      userInfo: ["widgetId": widget.id]
    )

    return true
  }

  /// Returns the state the widget ended up in.
  func toggleWidget(named name: String) -> Result<Bool, UserWidgetError> {
    setActive(named: name) { !$0 }.map { $0.isActive }
  }

  /// Returns whether this call actually hid the widget.
  func hideWidget(named name: String) -> Result<Bool, UserWidgetError> {
    setActive(named: name) { _ in false }.map { $0.didChange }
  }

  /// Returns whether this call actually showed the widget.
  func showWidget(named name: String) -> Result<Bool, UserWidgetError> {
    setActive(named: name) { _ in true }.map { $0.didChange }
  }

  /// Set a widget's visibility and persist it, so an AppleScript toggle survives a restart
  /// and is not reverted by the next save from the Preferences window.
  private func setActive(named name: String, to newValue: (Bool) -> Bool)
    -> Result<(isActive: Bool, didChange: Bool), UserWidgetError>
  {
    guard let widget = widgets.first(where: { $0.name == name }) else {
      return .failure(.widgetNotFound(name))
    }

    let wasActive = widget.isActive
    let isActive = newValue(wasActive)

    if isActive != wasActive {
      settingsManager.update { settings in
        if let index = settings.userWidgets.firstIndex(where: { $0.id == widget.id }) {
          settings.userWidgets[index].isActive = isActive
        }
      }
    }

    return .success((isActive: isActive, didChange: isActive != wasActive))
  }
}
