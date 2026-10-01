import Foundation
import Combine

/// Owns one in-flight request; settings changes invalidate its result before queuing the latest input.
@MainActor
final class WeatherModel: ObservableObject {
    @Published private(set) var snapshot: WeatherSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var isRefreshing = false
    var isLoading: Bool { snapshot == nil && isRefreshing }

    private let load: (String) async throws -> WeatherSnapshot
    private var task: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var input: String?
    private var generation = 0
    private var isActive = false
    private var hasQueuedRefresh = false

    init(load: @escaping (String) async throws -> WeatherSnapshot = { try await WeatherModel.load($0) }) {
        self.load = load
    }

    /// The app owns visibility; all mounted copies share this one polling schedule.
    func start(location: String, refreshInterval: TimeInterval) {
        let next = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldRefresh = refreshTimer == nil || input != next
        if refreshTimer?.timeInterval != refreshInterval {
            refreshTimer?.invalidate()
            let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] timer in
                Task { @MainActor [weak self] in
                    // A queued tick from a replaced or stopped timer must not restart polling.
                    guard let self, self.refreshTimer === timer, let input = self.input else { return }
                    self.refresh(location: input)
                }
            }
            refreshTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if shouldRefresh { refresh(location: next) }
    }

    func refresh(location: String) {
        let next = location.trimmingCharacters(in: .whitespacesAndNewlines)
        isActive = true
        if input != next {
            input = next
            generation += 1
            snapshot = nil
            errorMessage = nil
            lastSuccess = nil
            task?.cancel()
        }
        if let task {
            // A CLI may ignore cancellation. Wait for it before starting the latest input.
            if task.isCancelled { hasQueuedRefresh = true }
            return
        }
        startRequest(next)
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        isActive = false
        hasQueuedRefresh = false
        generation += 1
        task?.cancel()
        isRefreshing = false
    }

    private func startRequest(_ input: String) {
        let version = generation
        let load = load
        isRefreshing = true
        task = Task { [weak self] in
            let result: Result<WeatherSnapshot, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await load(input))
            }
            catch { result = .failure(error) }
            self?.finish(result, generation: version)
        }
    }

    private func finish(_ result: Result<WeatherSnapshot, Error>, generation version: Int) {
        task = nil
        isRefreshing = false
        if isActive && version == generation {
            switch result {
            case .success(let value):
                snapshot = value
                errorMessage = nil
                lastSuccess = Date()
            case .failure(let error):
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
        if isActive && hasQueuedRefresh, let input {
            hasQueuedRefresh = false
            startRequest(input)
        }
    }
}

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

extension WeatherModel {
    nonisolated static func load(
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

    private nonisolated static func locate() async throws -> String {
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

    private nonisolated static func responseData(for request: URLRequest, session: URLSession) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    nonisolated static func fetchWeather(for location: String, session: URLSession) async throws -> WeatherData {
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
