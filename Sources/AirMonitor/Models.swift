import Foundation

/// Every quantity the app knows how to show.
enum Metric: String, CaseIterable, Sendable {
    case pm1, pm25, pm4, pm10
    case temperature, humidity, pressure, pressureSeaLevel
    case co2

    /// Maps a `value_type` from the sensor.community API ("P1", "temperature"…)
    /// or from the device's local data.json ("SDS_P1", "BME280_temperature"…) to a Metric.
    static func from(valueType raw: String) -> Metric? {
        let t = raw.lowercased()
        func ends(_ key: String) -> Bool { t == key || t.hasSuffix("_" + key) }

        if ends("pressure_at_sealevel") { return .pressureSeaLevel }
        if ends("temperature") { return .temperature }
        if ends("humidity") { return .humidity }
        if ends("pressure") { return .pressure }
        if ends("carbon_dioxide") || ends("co2") { return .co2 }
        if ends("p0") { return .pm1 }
        if ends("p1") { return .pm10 }   // sensor.community: P1 = PM10
        if ends("p2") { return .pm25 }   // sensor.community: P2 = PM2.5
        if ends("p4") { return .pm4 }
        return nil
    }
}

struct GeoPoint: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct MetricValue: Sendable {
    let value: Double
    let timestamp: Date
    /// Which source delivered it ("sc-12345", "local"), so values of removed sources can be dropped.
    let sourceID: String
}

/// Latest known values merged from all sources (the freshest reading wins for each metric).
struct Snapshot {
    private(set) var values: [Metric: MetricValue] = [:]
    var altitude: Double?

    init() {}

    func value(_ m: Metric, maxAge: TimeInterval = 3 * 3600) -> Double? {
        guard let v = values[m], Date().timeIntervalSince(v.timestamp) <= maxAge else { return nil }
        return v.value
    }

    func timestamp(_ m: Metric) -> Date? { values[m]?.timestamp }

    var lastUpdated: Date? { values.values.map(\.timestamp).max() }

    var hasAnyData: Bool { !values.isEmpty }

    mutating func merge(_ incoming: [Metric: MetricValue]) {
        for (metric, new) in incoming {
            if let current = values[metric], current.timestamp > new.timestamp { continue }
            values[metric] = new
        }
    }

    mutating func removeValues(notFrom sourceIDs: Set<String>) {
        values = values.filter { sourceIDs.contains($0.value.sourceID) }
    }

    /// Pressure reduced to sea level (like in a weather forecast), in hPa.
    var seaLevelPressureHPa: Double? {
        if let p0 = value(.pressureSeaLevel) { return p0 / 100 }
        guard let p = value(.pressure) else { return nil }
        guard let h = altitude, h > 0 else { return p / 100 }
        let t = value(.temperature) ?? 15
        let factor = pow(1 - (0.0065 * h) / (t + 0.0065 * h + 273.15), -5.257)
        return p * factor / 100
    }
}

/// Status of one data source, shown in the app.
struct SourceStatus: Identifiable, Sendable {
    let id: String
    let label: String
    let ok: Bool
    let detail: String
}

// MARK: - Map

/// One sensor as seen on the map.
struct MapSensor: Identifiable, Sendable {
    let id: Int
    let type: String
    let values: [Metric: Double]
    let timestamp: Date

    var summary: String {
        var parts: [String] = []
        if let v = values[.pm25] { parts.append("PM2.5 " + Fmt.number(v, decimals: 1)) }
        if let v = values[.pm10] { parts.append("PM10 " + Fmt.number(v, decimals: 1)) }
        if let v = values[.temperature] { parts.append(Fmt.number(v, decimals: 1) + " °C") }
        if let v = values[.humidity] { parts.append(Fmt.number(v, decimals: 0) + " %") }
        if let v = values[.pressureSeaLevel] ?? values[.pressure] { parts.append(Fmt.number(v / 100, decimals: 0) + " hPa") }
        return parts.isEmpty ? "No values" : parts.joined(separator: " · ")
    }
}

/// One physical place (usually one device) with all of its sensors.
struct MapLocation: Identifiable, Sendable {
    let id: Int
    let latitude: Double
    let longitude: Double
    let indoor: Bool
    var sensors: [MapSensor]

    func value(_ m: Metric) -> Double? { sensors.lazy.compactMap { $0.values[m] }.first }

    var hasPM: Bool { value(.pm25) != nil || value(.pm10) != nil }

    var markerTitle: String {
        if let pm = value(.pm25) { return Fmt.number(pm, decimals: 0) + " µg/m³" }
        if let t = value(.temperature) { return Fmt.number(t, decimals: 1) + "°" }
        return sensors.first?.type ?? "Sensor"
    }
}

// MARK: - Settings choices

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case pmAndTemp, aqiAndTemp, tempOnly, iconOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pmAndTemp:  return "PM2.5 + temperature"
        case .aqiAndTemp: return "US AQI + temperature"
        case .tempOnly:   return "Temperature only"
        case .iconOnly:   return "Icon only"
        }
    }
}

enum IconStyle: String, CaseIterable, Identifiable {
    case symbol, dot
    var id: String { rawValue }
    var title: String {
        switch self {
        case .symbol: return "AQI symbol"
        case .dot:    return "Dot"
        }
    }
}
