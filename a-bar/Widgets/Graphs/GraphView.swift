import SwiftUI

/// A reusable graph view for displaying time-series data
struct GraphView: View {
    let values: [Double]
    let maxValue: Double
    let fillColor: Color
    let lineColor: Color
    let showLabels: Bool
    let labelPrefix: String

    @EnvironmentObject var settings: SettingsManager

    private var theme: ABarTheme {
        ThemeManager.currentTheme(for: settings.settings.theme)
    }

    private var globalSettings: GlobalSettings {
        settings.settings.global
    }

    init(
        values: [Double],
        maxValue: Double = 100.0,
        fillColor: Color = .blue,
        lineColor: Color = .blue,
        showLabels: Bool = false,
        labelPrefix: String = ""
    ) {
        self.values = values
        self.maxValue = maxValue
        self.fillColor = fillColor
        self.lineColor = lineColor
        self.showLabels = showLabels
        self.labelPrefix = labelPrefix
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Graph fill
                Path { path in
                    let points = GraphGeometry.points(
                        values: values, maxValue: maxValue, size: geometry.size)
                    guard !points.isEmpty else { return }

                    path.move(to: CGPoint(x: 0, y: geometry.size.height))
                    for point in points {
                        path.addLine(to: point)
                    }
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                    path.closeSubpath()
                }
                .fill(fillColor.opacity(0.3))

                // Graph line
                Path { path in
                    let points = GraphGeometry.points(
                        values: values, maxValue: maxValue, size: geometry.size)

                    for (index, point) in points.enumerated() {
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(lineColor, lineWidth: 1)

                // Current value label
                if showLabels, let lastValue = values.last {
                    Text("\(labelPrefix)\(Int(lastValue))%")
                        .font(globalSettings.settingsFont(scaledBy: 0.6))
                        .foregroundColor(theme.foreground)
                        .padding(1)
                        .background(theme.background.opacity(0.7))
                        .cornerRadius(2)
                        .position(x: geometry.size.width, y: 6)
                }
            }
        }
    }
}

/// A pie chart view for memory usage
struct PieChartView: View {
    let usedPercentage: Double
    let usedColor: Color
    let freeColor: Color

    @EnvironmentObject var settings: SettingsManager

    private var theme: ABarTheme {
        ThemeManager.currentTheme(for: settings.settings.theme)
    }

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = GraphGeometry.pieRadius(in: geometry.size)

            ZStack {
                // Free space
                Circle()
                    .fill(freeColor.opacity(0.3))

                // Used space (pie slice)
                Path { path in
                    path.move(to: center)
                    path.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(
                            GraphGeometry.pieEndAngleDegrees(usedPercentage: usedPercentage)),
                        clockwise: false
                    )
                    path.closeSubpath()
                }
                .fill(usedColor)

                // Border
                Circle()
                    .stroke(theme.minor.opacity(0.5), lineWidth: 0.5)
            }
        }
    }
}
