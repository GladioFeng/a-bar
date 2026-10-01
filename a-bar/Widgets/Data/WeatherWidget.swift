import SwiftUI

/// Weather widget showing current conditions
struct WeatherWidget: View {
    @EnvironmentObject var settings: SettingsManager
    
    @ObservedObject private var model: WeatherModel

    init(model: WeatherModel) {
        _model = ObservedObject(wrappedValue: model)
    }
    
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
          HStack(spacing: 4) {
            if model.isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 16, height: 16)
            } else if let snapshot = model.snapshot {
                let data = snapshot.data
                HStack(spacing: 4) {
                    if weatherSettings.showIcon {
                        weatherIcon(for: data.description, atNight: data.isNight)
                    }
                    
                    Text(temperatureString(weatherSettings.unit == .fahrenheit ? data.temperatureF : data.temperatureC))
                        .foregroundColor(theme.foreground)
                    
                    if !weatherSettings.hideLocation {
                            Text(snapshot.location.truncated(to: 15))
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
            NetworkRefreshWarning(errorMessage: model.errorMessage, lastSuccess: model.lastSuccess)
          }
        }
    }
    
    private func refreshWeather() {
        model.refresh(location: weatherSettings.customLocation)
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
