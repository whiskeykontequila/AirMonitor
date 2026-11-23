import AppKit

/// Which air quality index is used for colors and labels.
enum AQIStandard: String, CaseIterable, Identifiable {
    case eu, us
    var id: String { rawValue }
    var title: String {
        switch self {
        case .eu: return "European (EEA)"
        case .us: return "US (EPA)"
        }
    }
}

struct AQLevel: Equatable {
    /// 0 = best … 5 = worst
    let rank: Int
    let name: String
    let advice: String
    let color: NSColor

    static func == (a: AQLevel, b: AQLevel) -> Bool { a.rank == b.rank && a.name == b.name }

    /// SF Symbol for the level (denser dots as the air gets worse).
    var symbolName: String {
        switch rank {
        case 0...1: return "aqi.low"
        case 2...3: return "aqi.medium"
        default:    return "aqi.high"
        }
    }
}

enum AirQuality {

    static let advice = [
        "The air is clean, enjoy the outdoors!",
        "Air quality is fine for most people.",
        "Sensitive people should cut back on long outdoor exertion.",
        "Limit time outside and keep the windows closed.",
        "Avoid spending time outdoors.",
        "Stay inside – an air purifier is a good idea.",
    ]

    // MARK: European index (EEA bands from 2024, hourly values)
    // PM2.5: 0–5 / 6–15 / 16–50 / 51–90 / 91–140 / >140 µg/m³
    // PM10:  0–15 / 16–45 / 46–120 / 121–195 / 196–270 / >270 µg/m³

    static let euNames = ["Good", "Fair", "Moderate", "Poor", "Very poor", "Extremely poor"]
    static let euColors: [NSColor] = [
        hex(0x50F0E6), hex(0x50CCAA), hex(0xF0E641), hex(0xFF5050), hex(0x960032), hex(0x7D2181),
    ]
    static let euPM25Limits: [Double] = [5, 15, 50, 90, 140]
    static let euPM10Limits: [Double] = [15, 45, 120, 195, 270]

    static func euRank(_ value: Double, limits: [Double]) -> Int {
        let v = value.rounded()
        return limits.firstIndex(where: { v <= $0 }) ?? limits.count
    }

    // MARK: US AQI (EPA, PM2.5 breakpoints from May 2024)

    static let usNames = ["Good", "Moderate", "Unhealthy for sensitive groups", "Unhealthy", "Very unhealthy", "Hazardous"]
    static let usColors: [NSColor] = [
        hex(0x00E400), hex(0xFFFF00), hex(0xFF7E00), hex(0xFF0000), hex(0x8F3F97), hex(0x7E0023),
    ]

    private typealias Breakpoint = (cLow: Double, cHigh: Double, iLow: Double, iHigh: Double)

    private static let usPM25: [Breakpoint] = [
        (0.0, 9.0, 0, 50), (9.1, 35.4, 51, 100), (35.5, 55.4, 101, 150),
        (55.5, 125.4, 151, 200), (125.5, 225.4, 201, 300), (225.5, 325.4, 301, 500),
    ]
    private static let usPM10: [Breakpoint] = [
        (0, 54, 0, 50), (55, 154, 51, 100), (155, 254, 101, 150),
        (255, 354, 151, 200), (355, 424, 201, 300), (425, 604, 301, 500),
    ]

    static func usAQI(pm25: Double) -> Int {
        interpolate((pm25 * 10).rounded(.down) / 10, usPM25)   // EPA: truncate to 1 decimal
    }

    static func usAQI(pm10: Double) -> Int {
        interpolate(pm10.rounded(.down), usPM10)                 // EPA: truncate to an integer
    }

    private static func interpolate(_ c: Double, _ table: [Breakpoint]) -> Int {
        guard c > 0 else { return 0 }
        for bp in table where c <= bp.cHigh {
            let clamped = max(c, bp.cLow)
            return Int(((bp.iHigh - bp.iLow) / (bp.cHigh - bp.cLow) * (clamped - bp.cLow) + bp.iLow).rounded())
        }
        return 500
    }

    static func usRank(aqi: Int) -> Int {
        switch aqi {
        case ...50:  return 0
        case ...100: return 1
        case ...150: return 2
        case ...200: return 3
        case ...300: return 4
        default:     return 5
        }
    }

    /// Overall level – the worse of PM2.5 and PM10.
    static func level(pm25: Double?, pm10: Double?, standard: AQIStandard) -> AQLevel? {
        guard pm25 != nil || pm10 != nil else { return nil }
        let rank: Int
        switch standard {
        case .eu:
            rank = max(pm25.map { euRank($0, limits: euPM25Limits) } ?? 0,
                       pm10.map { euRank($0, limits: euPM10Limits) } ?? 0)
            return AQLevel(rank: rank, name: euNames[rank], advice: advice[rank], color: euColors[rank])
        case .us:
            let aqi = combinedUSAQI(pm25: pm25, pm10: pm10) ?? 0
            rank = usRank(aqi: aqi)
            return AQLevel(rank: rank, name: usNames[rank], advice: advice[rank], color: usColors[rank])
        }
    }

    /// Level for a single pollutant (for the colored dots next to PM values).
    static func level(for metric: Metric, value: Double, standard: AQIStandard) -> AQLevel? {
        switch metric {
        case .pm25: return level(pm25: value, pm10: nil, standard: standard)
        case .pm10: return level(pm25: nil, pm10: value, standard: standard)
        default:    return nil
        }
    }

    static func combinedUSAQI(pm25: Double?, pm10: Double?) -> Int? {
        let values = [pm25.map(usAQI(pm25:)), pm10.map(usAQI(pm10:))].compactMap { $0 }
        return values.max()
    }

    static func hex(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1)
    }
}
