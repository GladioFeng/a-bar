import SwiftUI

/// A slot in the current theme, named rather than resolved.
///
/// Widgets choose a colour by asking a question about their data - is the battery critical, is
/// the disk nearly full - and that decision is pure. Returning a `Color` would bind it to a live
/// theme and drag it back into the view, so these functions return the *role* and the view looks
/// it up. That is what lets every threshold in the bar be tested.
enum ThemeColorRole: String, CaseIterable, Equatable {
  case main
  case mainAlt
  case minor
  case accent
  case red
  case green
  case yellow
  case orange
  case blue
  case magenta
  case cyan
  case foreground
  case background

  func color(in theme: ABarTheme) -> Color {
    switch self {
    case .main: return theme.main
    case .mainAlt: return theme.mainAlt
    case .minor: return theme.minor
    case .accent: return theme.accent
    case .red: return theme.red
    case .green: return theme.green
    case .yellow: return theme.yellow
    case .orange: return theme.orange
    case .blue: return theme.blue
    case .magenta: return theme.magenta
    case .cyan: return theme.cyan
    case .foreground: return theme.foreground
    case .background: return theme.background
    }
  }
}
