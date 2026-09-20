import SwiftUI

/// Weather widget showing current conditions
struct WeatherWidget: View {
    @EnvironmentObject var settings: SettingsManager
    
    @State private var weatherData: WeatherData?
    @State private var lastWeatherData: WeatherData?
    @State private var isLoading = true
    @State private var location: String = ""
    
    private var weatherSettings: WeatherWidgetSettings {
        settings.settings.widgets.weather
    }
    
    private var theme: ABarTheme {
        ThemeManager.currentTheme(for: settings.settings.theme)
    }

    private var globalSettings: GlobalSettings {
        settings.settings.global
    }
    
    var body: some View {
        BaseWidgetView(onRightClick: refreshWeather) {
            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            } else if let data = (weatherData ?? lastWeatherData) {
                HStack(spacing: 4) {
                    if weatherSettings.showIcon {
                        weatherIcon(for: data.description, atNight: data.isNight)
                    }
                    
                    Text(temperatureString(weatherSettings.unit == .fahrenheit ? data.temperatureF : data.temperatureC))
                        .foregroundColor(theme.foreground)
                    
                    if !weatherSettings.hideLocation {
                            Text(location.truncated(to: 15))
                                .font(globalSettings.settingsFont(scaledBy: 0.75))
                                .foregroundColor(theme.minor)
                    }
                }
            } else {
                HStack(spacing: 4) {
                    if weatherSettings.showIcon {
                        Image(systemName: "cloud.fill")
                            .font(.system(size: 10))
                            .foregroundColor(theme.minor)
                    }
                    Text("--°")
                        .foregroundColor(theme.minor)
                }
            }
        }
        .onAppear {
            if weatherData == nil {
                refreshWeather()
            }
        }
        .onReceive(Timer.publish(every: weatherSettings.refreshInterval, on: .main, in: .common).autoconnect()) { _ in
            refreshWeather()
        }
    }
    
    private func refreshWeather() {
        isLoading = true
        
        Task {
            do {
                let loc = weatherSettings.customLocation.isEmpty ? await getLocation() : weatherSettings.customLocation
                location = loc
                
                let data = try await fetchWeather(for: loc)
                await MainActor.run {
                    weatherData = data
                    lastWeatherData = data
                    isLoading = false
                }
            } catch {
                print("Weather fetch error: \(error)")
                await MainActor.run {
                    // Keep showing last successful data if available
                    if weatherData == nil, let last = lastWeatherData {
                        weatherData = last
                    }
                    isLoading = false
                }
            }
        }
    }
    
    private func getLocation() async -> String {
        // Try to get location from IP geolocation
        do {
            let output = try await ShellExecutor.run("curl -s 'http://ip-api.com/json/?fields=city,zip' 2>/dev/null")
            if let data = output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Prefer city name (works better with Open-Meteo geocoding); fallback to zip
                if let city = json["city"] as? String, !city.isEmpty {
                    return city
                }
                if let zip = json["zip"] as? String, !zip.isEmpty {
                    return zip
                }
            }
        } catch {
            print("Location fetch error: \(error)")
        }
        return "London" // Default fallback
    }
    
    private func fetchWeather(for location: String) async throws -> WeatherData {
        // Try Open-Meteo geocoding with multiple location variants to improve match rate
        var lat: Double? = nil
        var lon: Double? = nil

        let candidates = WeatherPresentation.locationVariants(location)
        for candidate in candidates {
            do {
                let geoUrl = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(candidate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? candidate)&count=1")!
                let (geoData, _) = try await URLSession.shared.data(from: geoUrl)
                if let geoJson = try? JSONSerialization.jsonObject(with: geoData) as? [String: Any],
                   let results = geoJson["results"] as? [[String: Any]],
                   let first = results.first,
                   let gLat = first["latitude"] as? Double,
                   let gLon = first["longitude"] as? Double {
                    lat = gLat
                    lon = gLon
                    break
                }
            } catch {
                continue
            }
        }

        // Fallback to Nominatim (OpenStreetMap) if Open-Meteo geocoding failed
        if lat == nil || lon == nil {
            do {
                let nominatimUrl = URL(string: "https://nominatim.openstreetmap.org/search?format=json&q=\(location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? location)&limit=1")!
                var req = URLRequest(url: nominatimUrl)
                req.setValue("a-bar/1.0 (your-email@example.com)", forHTTPHeaderField: "User-Agent")
                let (nomData, _) = try await URLSession.shared.data(for: req)
                if let nomJson = try? JSONSerialization.jsonObject(with: nomData) as? [[String: Any]],
                   let first = nomJson.first,
                   let latStr = first["lat"] as? String,
                   let lonStr = first["lon"] as? String,
                   let nLat = Double(latStr),
                   let nLon = Double(lonStr) {
                    lat = nLat
                    lon = nLon
                }
            } catch {
                // Keep fallback behavior: failure here is handled by the guard below.
            }
        }

        guard let finalLat = lat, let finalLon = lon else {
            throw NSError(domain: "Weather", code: 2, userInfo: [NSLocalizedDescriptionKey: "Location not found"])
        }

        // Use Open-Meteo Weather API to get current weather
        let unit = weatherSettings.unit == .celsius ? "celsius" : "fahrenheit"
        let tempParam = "temperature_2m"
        let weatherUrl = URL(
            string: "https://api.open-meteo.com/v1/forecast?latitude=\(finalLat)&longitude=\(finalLon)&current_weather=true&hourly=weathercode,\(tempParam)&temperature_unit=\(unit)"
        )!
        let (weatherData, _) = try await URLSession.shared.data(from: weatherUrl)
        guard let weatherJson = try? JSONSerialization.jsonObject(with: weatherData) as? [String: Any],
              let current = weatherJson["current_weather"] as? [String: Any],
              let temp = current["temperature"] as? Double,
              let weatherCode = current["weathercode"] as? Int,
              let isDay = current["is_day"] as? Int else {
            throw NSError(domain: "Weather", code: 3, userInfo: [NSLocalizedDescriptionKey: "Weather data not found"])
        }

        // Use is_day (1=day, 0=night) from Open-Meteo
        let isNight = isDay == 0

        // Map Open-Meteo weathercode to description
        let description = WeatherPresentation.openMeteoDescription(for: weatherCode)

        let tempC =
            weatherSettings.unit == .celsius
            ? Int(round(temp)) : WeatherPresentation.celsius(fromFahrenheit: temp)
        let tempF =
            weatherSettings.unit == .fahrenheit
            ? Int(round(temp)) : WeatherPresentation.fahrenheit(fromCelsius: temp)

        return WeatherData(
            temperatureC: tempC,
            temperatureF: tempF,
            description: description,
            isNight: isNight
        )
    }

    private func temperatureString(_ temp: Int) -> String {
        "\(temp)°\(weatherSettings.unit.rawValue)"
    }
    
    private func weatherIcon(for description: String, atNight: Bool) -> some View {
        let icon = WeatherPresentation.icon(for: description, atNight: atNight)
        let iconName: String? = icon.symbol
        let iconColor: Color = icon.role.color(in: theme)

        return Image(systemName: iconName!)
            .font(.system(size: 12))
            .foregroundColor(iconColor)
    }
}

struct WeatherData {
    let temperatureC: Int
    let temperatureF: Int
    let description: String
    let isNight: Bool
}
