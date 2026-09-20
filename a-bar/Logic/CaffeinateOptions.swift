import Foundation

/// Translating the user's `caffeinate` setting into command-line flags.
///
/// The setting is free text in the config file, so this has to cope with anything: a name it
/// knows, a raw flag typed by someone reading the `caffeinate` man page, an empty string, or a
/// typo. Nothing here may throw or return nothing - a bad setting falls back to the default
/// rather than launching `caffeinate` with no flags, which would hold nothing awake at all.
enum CaffeinateOptions {

  /// Arguments for `caffeinate`, for the option named in settings.
  static func arguments(for option: String) -> [String] {
    let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "systemsleep":
      return ["-s"]  // Prevent system sleep
    case "displaysleep":
      return ["-d"]  // Prevent display sleep
    case "idlesleep":
      return ["-i"]  // Prevent idle sleep
    case "user":
      return ["-u"]  // Prevent sleep due to user inactivity
    case "displayidle":
      return ["-di"]  // Prevent display and idle sleep
    case "all":
      return ["-dimu"]  // Prevent all sleep types
    case "":
      return ["-di"]  // Default: prevent display and idle sleep
    default:
      // Anything starting with a dash is taken to be a flag the user meant; everything else is a
      // typo, and a typo must not silently do nothing.
      return trimmed.hasPrefix("-") ? [trimmed] : ["-di"]
    }
  }
}
