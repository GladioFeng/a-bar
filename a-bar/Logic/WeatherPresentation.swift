import Foundation

/// Turning a weather provider's answer into something the bar can show.
enum WeatherPresentation {

  // MARK: - Finding the place the user meant

  /// Progressively looser spellings of a location, to try against a geocoder that only matches
  /// what it already knows.
  ///
  /// A user types "Saint-Étienne, 42000, France"; the geocoder wants "Saint-Etienne". Each rule
  /// drops one thing the geocoder is likely to choke on, and the order matters - the most
  /// faithful spelling is tried first so an exact match is never passed over for a looser one.
  static func locationVariants(_ location: String) -> [String] {
    let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
    var variants: [String] = [trimmed]

    let parts = trimmed.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if parts.count > 1 {
      variants.append(parts[0])
      variants.append(parts[0] + ", " + parts[1])
    }

    let withoutDigits = trimmed.replacingOccurrences(
      of: "\\d+", with: "", options: .regularExpression)
    variants.append(
      withoutDigits.replacingOccurrences(of: "-", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines))

    let folded = trimmed.folding(options: .diacriticInsensitive, locale: .current)
    if folded != trimmed { variants.append(folded) }

    var seen = Set<String>()
    return variants.filter { variant in
      guard !variant.isEmpty, !seen.contains(variant) else { return false }
      seen.insert(variant)
      return true
    }
  }

  // MARK: - Reading the forecast

  /// WMO weather codes, as Open-Meteo reports them.
  static func openMeteoDescription(for code: Int) -> String {
    switch code {
    case 0: return "Clear sky"
    case 1, 2, 3: return "Mainly clear"
    case 45, 48: return "Fog"
    case 51, 53, 55: return "Drizzle"
    case 56, 57: return "Freezing Drizzle"
    case 61, 63, 65: return "Rain"
    case 66, 67: return "Freezing Rain"
    case 71, 73, 75, 77: return "Snow"
    case 80, 81, 82: return "Rain showers"
    case 85, 86: return "Snow showers"
    case 95: return "Thunderstorm"
    case 96, 99: return "Thunderstorm with hail"
    default: return "Unknown"
    }
  }

  static func celsius(fromFahrenheit fahrenheit: Double) -> Int {
    Int(round((fahrenheit - 32) * 5 / 9))
  }

  static func fahrenheit(fromCelsius celsius: Double) -> Int {
    Int(round((celsius * 9 / 5) + 32))
  }

  // MARK: - Choosing an icon

  /// The symbol and colour for a description.
  ///
  /// Matching is by substring, so the order is the whole logic: the most specific sky has to be
  /// tested first. "Partly sunny with cloud" used to be claimed by the plain `sun` branch above
  /// it, which left the cloud-and-sun symbol unreachable no matter what a provider sent.
  static func icon(
    for description: String, atNight: Bool
  ) -> (symbol: String, role: ThemeColorRole) {
    let text = description.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    let mentionsSun = text.contains("sun") || text.contains("clear")

    if text.contains("cloud") && mentionsSun {
      return (atNight ? "cloud.moon.fill" : "cloud.sun.fill", .foreground)
    }
    if mentionsSun {
      return (atNight ? "moon.fill" : "sun.max.fill", .yellow)
    }
    if text.contains("cloud") {
      return ("cloud.fill", .foreground)
    }
    if text.contains("rain") || text.contains("drizzle") {
      return ("cloud.rain.fill", .blue)
    }
    if text.contains("thunder") || text.contains("storm") {
      return ("cloud.bolt.fill", .yellow)
    }
    if text.contains("snow") {
      return ("cloud.snow.fill", .cyan)
    }
    if text.contains("fog") || text.contains("mist") {
      return ("cloud.fog.fill", .foreground)
    }

    return (atNight ? "moon.fill" : "cloud.fill", .foreground)
  }
}
