import Foundation

/// What each AppleScript command replies.
///
/// Lifted out of the `NSScriptCommand` subclasses in `RefreshWidgetCommand.swift`. Those are
/// awkward to build in a test - a script command wants a command description from a loaded
/// scripting definition - and they were carrying the whole dispatch: which names are special,
/// which manager handles the rest, and the exact wording of every reply. The wording is the
/// contract here, because it is all an `osascript` caller ever sees.
enum WidgetCommandDispatch {

  /// The window managers answer to their own names; anything else is a custom widget.
  static let yabaiName = "yabai"
  static let aerospaceName = "aerospace"

  /// Which handler a `refresh` is for. The names are matched case-insensitively, because
  /// somebody typing this into Script Editor will write "Yabai" as often as "yabai".
  enum RefreshTarget: Equatable {
    case yabai
    case aerospace
    case userWidget(String)

    init(widgetName: String) {
      switch widgetName.lowercased() {
      case WidgetCommandDispatch.yabaiName: self = .yabai
      case WidgetCommandDispatch.aerospaceName: self = .aerospace
      default: self = .userWidget(widgetName)
      }
    }
  }

  // MARK: - Replies

  static func missingParameter(_ what: String) -> String {
    "error: missing \(what)"
  }

  static func refreshed(_ target: RefreshTarget) -> String {
    switch target {
    case .yabai: return "ok: refreshed yabai widgets"
    case .aerospace: return "ok: refreshed aerospace widgets"
    case .userWidget(let name): return "ok: refreshed widget '\(name)'"
    }
  }

  static func notFound(_ name: String) -> String {
    "error: widget '\(name)' not found"
  }

  static func toggled(_ name: String, isNowActive: Bool) -> String {
    "ok: widget '\(name)' is now \(isNowActive ? "shown" : "hidden")"
  }

  static func hidden(_ name: String, didChange: Bool) -> String {
    didChange
      ? "ok: widget '\(name)' is now hidden"
      : "ok: widget '\(name)' was already hidden"
  }

  static func shown(_ name: String, didChange: Bool) -> String {
    didChange
      ? "ok: widget '\(name)' is now shown"
      : "ok: widget '\(name)' was already shown"
  }

  /// A thrown error is reported with its own description rather than a generic failure, so
  /// `UserWidgetError.widgetNotFound` reaches the caller intact.
  static func failed(_ error: Error) -> String {
    "error: \(error.localizedDescription)"
  }

  static func reply<E: Error>(
    for result: Result<Bool, E>,
    success: (Bool) -> String
  ) -> String {
    switch result {
    case .success(let value): return success(value)
    case .failure(let error): return failed(error)
    }
  }

  // MARK: - Profiles

  static func switchedToProfile(_ name: String) -> String {
    "ok: switched to profile '\(name)'"
  }

  static func profileNotFound(_ name: String, available: [String]) -> String {
    "error: profile '\(name)' not found. Available profiles: \(available.joined(separator: ", "))"
  }

  static let noActiveProfile = "error: no active profile"
}
