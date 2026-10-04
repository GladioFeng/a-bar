import Foundation

/// Current conditions for the configured city, or the IP-located one when it is empty.
typealias WeatherModel = PollingModel<WeatherSnapshot>

struct WeatherSnapshot: Equatable {
    let location: String
    let data: WeatherData
}

struct WeatherData: Equatable {
    let temperatureC: Int
    let temperatureF: Int
    let description: String
    let isNight: Bool
}

enum WeatherForecast {
    static func load(
        _ location: String, session: URLSession = .shared,
        resolveLocation: () async throws -> String = { try await locate() }
    ) async throws -> WeatherSnapshot {
        let resolved: String
        if location.isEmpty { resolved = try await resolveLocation() }
        else { resolved = location }
        try Task.checkCancellation()
        let data = try await fetchWeather(for: resolved, session: session)
        return WeatherSnapshot(location: resolved, data: data)
    }

    private static func locate() async throws -> String {
        let output = try await ShellExecutor.run(executable: "/usr/bin/curl", arguments: [
            "-fsS", "--max-time", "10", "http://ip-api.com/json/?fields=city,zip"
        ])
        try Task.checkCancellation()
        if let data = output.data(using: .utf8),
           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["city", "zip"] {
                if let value = json[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }
        throw NSError(domain: "Weather", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not determine your location. Set a city in Preferences."])
    }

    private static func responseData(for request: URLRequest, session: URLSession) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    static func fetchWeather(for location: String, session: URLSession) async throws -> WeatherData {
        // Try Open-Meteo geocoding with multiple location variants to improve match rate
        var lat: Double? = nil
        var lon: Double? = nil

        let candidates = WeatherPresentation.locationVariants(location)
        for candidate in candidates {
            do {
                let geoUrl = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(candidate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? candidate)&count=1")!
                let geoData = try await responseData(for: URLRequest(url: geoUrl), session: session)
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
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                continue
            }
        }

        // Fallback to Nominatim (OpenStreetMap) if Open-Meteo geocoding failed
        if lat == nil || lon == nil {
            do {
                let nominatimUrl = URL(string: "https://nominatim.openstreetmap.org/search?format=json&q=\(location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? location)&limit=1")!
                var req = URLRequest(url: nominatimUrl)
                req.setValue("a-bar/1.0 (your-email@example.com)", forHTTPHeaderField: "User-Agent")
                let nomData = try await responseData(for: req, session: session)
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
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                // A failed fallback is reported by the missing-location guard below.
            }
        }

        guard let finalLat = lat, let finalLon = lon else {
            throw NSError(domain: "Weather", code: 2, userInfo: [NSLocalizedDescriptionKey: "Location not found"])
        }

        // Use Open-Meteo Weather API to get current weather
        let unit = "celsius"
        let tempParam = "temperature_2m"
        let weatherUrl = URL(
            string: "https://api.open-meteo.com/v1/forecast?latitude=\(finalLat)&longitude=\(finalLon)&current_weather=true&hourly=weathercode,\(tempParam)&temperature_unit=\(unit)"
        )!
        let weatherData = try await responseData(for: URLRequest(url: weatherUrl), session: session)
        guard let weatherJson = try? JSONSerialization.jsonObject(with: weatherData) as? [String: Any],
              let current = weatherJson["current_weather"] as? [String: Any],
              let temp = current["temperature"] as? Double, temp.isFinite, (-200...200).contains(temp),
              let weatherCode = current["weathercode"] as? Int,
              let isDay = current["is_day"] as? Int else {
            throw NSError(domain: "Weather", code: 3, userInfo: [NSLocalizedDescriptionKey: "Weather data not found"])
        }

        // Use is_day (1=day, 0=night) from Open-Meteo
        let isNight = isDay == 0

        // Map Open-Meteo weathercode to description
        let description = WeatherPresentation.openMeteoDescription(for: weatherCode)

        let tempC = Int(round(temp))
        let tempF = WeatherPresentation.fahrenheit(fromCelsius: temp)

        return WeatherData(
            temperatureC: tempC,
            temperatureF: tempF,
            description: description,
            isNight: isNight
        )
    }

}
