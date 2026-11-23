import SwiftUI
import AppKit

// Note: no SwiftUI `State` property wrappers anywhere in the app. In the newest macOS SDK they are macros
// that need full Xcode, so ObservableObject is used instead and the app also builds with Command Line Tools.

// MARK: - Popover

@MainActor
struct PopoverView: View {
    @ObservedObject var store: AirStore
    let openSettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderCard(store: store)
            MetricsGrid(store: store)
            NoticesView(store: store, openSettings: openSettings)
            Divider()
            FooterView(store: store, openSettings: openSettings)
        }
        .padding(14)
        .frame(width: 340)
    }
}

// MARK: - Header with the air quality rating

@MainActor
struct HeaderCard: View {
    @ObservedObject var store: AirStore

    var body: some View {
        let level = store.level
        let tint = Color(nsColor: store.isStale ? .systemGray : (level?.color ?? .systemGray))

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: level?.symbolName ?? "aqi.medium")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: level?.name ?? "No data")
                        .font(.title2.weight(.semibold))
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if let t = store.temperature {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(verbatim: Fmt.number(t, decimals: 1) + "°C")
                            .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                        Image(systemName: thermometerSymbol(t))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let level, !store.isStale {
                Text(verbatim: level.advice)
                    .font(.callout)
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.4), lineWidth: 1))
    }

    private var subtitle: String {
        if store.isStale, let d = store.snapshot.timestamp(.pm25) ?? store.snapshot.timestamp(.pm10) {
            return "Data is stale – measured \(Fmt.ago(d))"
        }
        switch store.standard {
        case .eu: return "European Air Quality Index"
        case .us: return store.usAQI.map { "US AQI \($0)" } ?? "US AQI"
        }
    }

    private func thermometerSymbol(_ t: Double) -> String {
        switch t {
        case ..<0:  return "thermometer.snowflake"
        case ..<10: return "thermometer.low"
        case ..<25: return "thermometer.medium"
        default:    return "thermometer.high"
        }
    }
}

// MARK: - Value tiles

@MainActor
struct MetricsGrid: View {
    @ObservedObject var store: AirStore

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        let s = store.snapshot
        LazyVGrid(columns: columns, spacing: 8) {
            pmTile("PM2.5", .pm25, symbol: "aqi.low")
            pmTile("PM10", .pm10, symbol: "aqi.medium")
            if let pm1 = s.value(.pm1, maxAge: 3600) {
                MetricTile(title: "PM1", systemImage: "aqi.low", value: Fmt.number(pm1, decimals: 1), unit: "µg/m³")
            }
            MetricTile(title: "Temperature", systemImage: "thermometer.medium",
                       value: store.temperature.map { Fmt.number($0, decimals: 1) } ?? "–", unit: "°C")
            if let h = s.value(.humidity, maxAge: 1800) {
                MetricTile(title: "Humidity", systemImage: "humidity.fill", value: Fmt.number(h, decimals: 0), unit: "%")
            }
            if let p = s.seaLevelPressureHPa {
                MetricTile(title: "Pressure", systemImage: "gauge.medium", value: Fmt.number(p, decimals: 0), unit: "hPa")
            }
            if let co2 = s.value(.co2, maxAge: 3600) {
                MetricTile(title: "CO₂", systemImage: "carbon.dioxide.cloud", value: Fmt.number(co2, decimals: 0), unit: "ppm")
            }
        }
    }

    private func pmTile(_ title: String, _ metric: Metric, symbol: String) -> MetricTile {
        let v = store.snapshot.value(metric, maxAge: 3600)
        let color = v
            .flatMap { AirQuality.level(for: metric, value: $0, standard: store.standard) }
            .map { Color(nsColor: $0.color) }
        return MetricTile(title: title, systemImage: symbol,
                          value: v.map { Fmt.number($0, decimals: 1) } ?? "–",
                          unit: "µg/m³", dotColor: store.isStale ? nil : color)
    }
}

struct MetricTile: View {
    let title: String
    let systemImage: String
    let value: String
    let unit: String
    var dotColor: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(verbatim: title)
                Spacer(minLength: 0)
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                        .frame(width: 9, height: 9)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                Text(verbatim: unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Notices (no temperature, failing sources…)

@MainActor
struct NoticesView: View {
    @ObservedObject var store: AirStore
    let openSettings: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.hasNoSources {
                notice("No sensor picked yet. Choose one on the map in Settings.", symbol: "info.circle", color: .blue, withButton: true)
            } else if store.temperature == nil && !store.sources.isEmpty {
                notice("None of your sources reports temperature. Add a temperature sensor (e.g. BME280) on the map, or your device's local address.",
                       symbol: "thermometer.medium.slash", color: .orange, withButton: true)
            }

            if let h = store.snapshot.value(.humidity, maxAge: 3600), h >= 90 {
                notice("High humidity: SDS011 particle readings tend to run high.",
                       symbol: "humidity", color: .secondary, withButton: false)
            }

            ForEach(store.sources.filter { !$0.ok }) { source in
                if source.id == "local" && store.sources.contains(where: { $0.ok && $0.id != "local" }) {
                    // Normal when you're away from home with the laptop – not an error.
                    notice("Local device not reachable – using sensor.community data.",
                           symbol: "wifi.slash", color: .secondary, withButton: false)
                } else {
                    notice("\(source.label): \(source.detail)", symbol: "exclamationmark.triangle.fill", color: .orange, withButton: false)
                }
            }
        }
    }

    @ViewBuilder
    private func notice(_ text: String, symbol: String, color: Color, withButton: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
            if withButton {
                Spacer(minLength: 4)
                Button("Settings…") { openSettings() }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Footer

@MainActor
struct FooterView: View {
    @ObservedObject var store: AirStore
    let openSettings: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Group {
                    if let d = store.snapshot.lastUpdated {
                        Text(verbatim: "Measured \(Fmt.ago(d, now: context.date)) · \(Fmt.time(d))")
                    } else {
                        Text(verbatim: store.isLoading ? "Loading…" : "No data yet")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh now")
            }
            Button { openSettings() } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit AirMonitor")
        }
        .buttonStyle(.borderless)
    }
}
