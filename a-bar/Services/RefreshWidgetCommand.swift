import Cocoa

/// The AppleScript surface. Every reply string these produce lives in
/// `WidgetCommandDispatch`, which is where they are tested - an `NSScriptCommand` needs a
/// command description from a loaded scripting definition to exist at all, so what is left
/// here is only the plumbing between the direct parameter and the dispatch.
private extension NSScriptCommand {
  func withWidgetName(_ body: (String) -> String) -> String {
    guard let widgetName = directParameter as? String else {
      return WidgetCommandDispatch.missingParameter("widget name")
    }
    return body(widgetName)
  }
}

/// AppleScript command handler for refreshing widgets
@objc(RefreshWidgetCommand)
class RefreshWidgetCommand: NSScriptCommand {

  override func performDefaultImplementation() -> Any? {
    withWidgetName { widgetName in
      let target = WidgetCommandDispatch.RefreshTarget(widgetName: widgetName)
      switch target {
      case .yabai:
        YabaiService.shared.refresh()
      case .aerospace:
        AerospaceService.shared.refresh()
      case .userWidget(let name):
        guard UserWidgetManager.shared.refreshWidget(named: name) else {
          return WidgetCommandDispatch.notFound(name)
        }
      }
      return WidgetCommandDispatch.refreshed(target)
    }
  }
}

/// AppleScript command handler for toggling custom widget visibility
@objc(ToggleWidgetCommand)
class ToggleWidgetCommand: NSScriptCommand {

  override func performDefaultImplementation() -> Any? {
    withWidgetName { widgetName in
      WidgetCommandDispatch.reply(for: UserWidgetManager.shared.toggleWidget(named: widgetName)) {
        WidgetCommandDispatch.toggled(widgetName, isNowActive: $0)
      }
    }
  }
}

/// AppleScript command handler for hiding a custom widget
@objc(HideWidgetCommand)
class HideWidgetCommand: NSScriptCommand {

  override func performDefaultImplementation() -> Any? {
    withWidgetName { widgetName in
      WidgetCommandDispatch.reply(for: UserWidgetManager.shared.hideWidget(named: widgetName)) {
        WidgetCommandDispatch.hidden(widgetName, didChange: $0)
      }
    }
  }
}

/// AppleScript command handler for showing a custom widget
@objc(ShowWidgetCommand)
class ShowWidgetCommand: NSScriptCommand {

  override func performDefaultImplementation() -> Any? {
    withWidgetName { widgetName in
      WidgetCommandDispatch.reply(for: UserWidgetManager.shared.showWidget(named: widgetName)) {
        WidgetCommandDispatch.shown(widgetName, didChange: $0)
      }
    }
  }
}

/// AppleScript command handler for setting the active profile
/// Usage: osascript -e 'tell application "a-bar" to set profile "Profile Name"'
@objc(SetProfileCommand)
class SetProfileCommand: NSScriptCommand {

  override func performDefaultImplementation() -> Any? {
    guard let profileName = directParameter as? String else {
      return WidgetCommandDispatch.missingParameter("profile name")
    }

    let profileManager = ProfileManager.shared
    guard profileManager.switchToProfile(named: profileName) else {
      return WidgetCommandDispatch.profileNotFound(
        profileName, available: profileManager.profileNames)
    }
    return WidgetCommandDispatch.switchedToProfile(profileName)
  }
}

/// AppleScript command handler for getting the current profile
/// Usage: osascript -e 'tell application "a-bar" to get profile'
@objc(GetProfileCommand)
class GetProfileCommand: NSScriptCommand {

  override func performDefaultImplementation() -> Any? {
    ProfileManager.shared.activeProfile?.name ?? WidgetCommandDispatch.noActiveProfile
  }
}

/// AppleScript command handler for listing all profiles
/// Usage: osascript -e 'tell application "a-bar" to list profiles'
@objc(ListProfilesCommand)
class ListProfilesCommand: NSScriptCommand {

  override func performDefaultImplementation() -> Any? {
    ProfileManager.shared.profileNames.joined(separator: ", ")
  }
}
