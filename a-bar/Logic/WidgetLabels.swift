import Foundation

/// The short strings the bar puts on screen.
///
/// Every formatter here takes the values it reads rather than the ambient ones, so a test can
/// pin a clock without waiting for a second to pass and without depending on the machine's
/// locale. The production defaults are the ambient reads the views used to make inline.
enum WidgetLabels {

  // MARK: - Clock

  /// The clock face.
  ///
  /// The locale is a parameter rather than fixed to POSIX because the am/pm marker is localized
  /// and forcing it would change what non-English users see. Tests pass an explicit one.
  static func time(
    _ date: Date, hour12: Bool, showSeconds: Bool,
    locale: Locale = .current, timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone

    if hour12 {
      formatter.dateFormat = showSeconds ? "h:mm:ss a" : "h:mm a"
    } else {
      formatter.dateFormat = showSeconds ? "HH:mm:ss" : "HH:mm"
    }

    return formatter.string(from: date)
  }

  static func date(
    _ date: Date, localeIdentifier: String, shortFormat: Bool, timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: localeIdentifier)
    formatter.timeZone = timeZone
    formatter.dateFormat = shortFormat ? "EE, MMM d" : "EEEE, MMM d"

    return formatter.string(from: date)
  }

  // MARK: - Counts and names

  /// A notification count wide enough to fit in the bar.
  static func notificationCount(_ count: Int) -> String {
    count > 99 ? "99+" : "\(count)"
  }

  /// The boot volume is called "Macintosh HD" by default, which is too wide to be worth showing.
  static func storageVolumeName(_ name: String) -> String {
    name.lowercased().contains("macintosh") ? "Mac" : name
  }

  /// A keyboard layout name short enough for the bar.
  ///
  /// The first word is usually the language ("British PC" -> "British"), but a single long word
  /// has no space to cut at, so it is truncated instead. That fallback used to be unreachable:
  /// it was guarded by `split(separator: " ").first`, which is never nil for a non-empty string,
  /// so "Vietnamese" came through at full width while "British PC" was shortened.
  static func keyboardLayout(_ layout: String, maxLength: Int = 10) -> String {
    guard layout.count > maxLength else { return layout }

    if let firstWord = layout.split(separator: " ").first, firstWord.count <= maxLength {
      return String(firstWord)
    }

    return layout.truncated(to: maxLength - 2)
  }
}
