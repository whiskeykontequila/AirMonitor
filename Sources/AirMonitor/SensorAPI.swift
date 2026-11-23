import Foundation

/// Result of reading one source (one sensor.community sensor or the local device).
struct SourceResult: Sendable {
    let status: SourceStatus
    let values: [Metric: MetricValue]
    var altitude: Double? = nil
    var location: GeoPoint? = nil
    var sensorID: Int? = nil
    var sensorType: String? = nil
}

enum SensorAPI {

    static let base = "https://data.sensor.community/airrohr/v1"

    // MARK: sensor.community – one sensor

    /// https://data.sensor.community/airrohr/v1/sensor/<id>/
    /// Returns every measurement of that sensor from the last ~5 minutes.
    static func sensorCommunity(id: Int) async -> SourceResult {
        let sourceID = "sc-\(id)"
        let url = URL(string: "\(base)/sensor/\(id)/")!
        do {
            let data = try await get(url, timeout: 20)
            let entries = try JSONDecoder().decode([SCEntry].self, from: data)
            return parseSensorCommunity(entries, id: id)
        } catch {
            return SourceResult(
                status: SourceStatus(id: sourceID, label: "Sensor #\(id)", ok: false, detail: describe(error)),
                values: [:], sensorID: id
            )
        }
    }

    static func parseSensorCommunity(_ entries: [SCEntry], id: Int) -> SourceResult {
        let sourceID = "sc-\(id)"
        let dated = entries.compactMap { e -> (SCEntry, Date)? in
            guard let d = scDateFormatter.date(from: e.timestamp) else { return nil }
            return (e, d)
        }
        guard let best = dated.max(by: { $0.1 < $1.1 }) else {
            return SourceResult(
                status: SourceStatus(id: sourceID, label: "Sensor #\(id)", ok: true, detail: "no readings in the last 5 min"),
                values: [:], sensorID: id
            )
        }
        let latest = best.0
        let date = best.1
        let typeName = latest.sensor?.sensor_type?.name
        let label = "\(typeName ?? "Sensor") #\(id)"

        var values: [Metric: MetricValue] = [:]
        for v in latest.sensordatavalues {
            guard let metric = Metric.from(valueType: v.value_type), let number = v.value.double else { continue }
            values[metric] = MetricValue(value: number, timestamp: date, sourceID: sourceID)
        }
        let names = values.keys.map(\.rawValue).sorted().joined(separator: ", ")

        var location: GeoPoint?
        if let lat = latest.location?.latitude?.double, let lon = latest.location?.longitude?.double {
            location = GeoPoint(latitude: lat, longitude: lon)
        }
        return SourceResult(
            status: SourceStatus(id: sourceID, label: label, ok: true, detail: names.isEmpty ? "no known values" : names),
            values: values,
            altitude: latest.location?.altitude?.double,
            location: location,
            sensorID: id,
            sensorType: typeName
        )
    }

    // MARK: sensor.community – every sensor inside a map rectangle

    /// https://data.sensor.community/airrohr/v1/filter/box=lat1,lon1,lat2,lon2
    static func sensorsInBox(south: Double, west: Double, north: Double, east: Double) async throws -> [MapLocation] {
        let box = String(format: "%.4f,%.4f,%.4f,%.4f", south, west, north, east)
        let url = URL(string: "\(base)/filter/box=\(box)")!
        let data = try await get(url, timeout: 25)
        let entries = try JSONDecoder().decode([SCEntry].self, from: data)
        return groupByLocation(entries)
    }

    /// Keeps the latest reading of every sensor and groups sensors by location (= device).
    static func groupByLocation(_ entries: [SCEntry]) -> [MapLocation] {
        var latest: [Int: (SCEntry, Date)] = [:]
        for e in entries {
            guard let sid = e.sensor?.id, let d = scDateFormatter.date(from: e.timestamp) else { continue }
            if let current = latest[sid], current.1 >= d { continue }
            latest[sid] = (e, d)
        }

        var byLocation: [Int: MapLocation] = [:]
        for (sid, pair) in latest {
            let (e, date) = pair
            guard let lat = e.location?.latitude?.double, let lon = e.location?.longitude?.double else { continue }
            let locationID = e.location?.id ?? -sid
            var values: [Metric: Double] = [:]
            for v in e.sensordatavalues {
                if let m = Metric.from(valueType: v.value_type), let x = v.value.double { values[m] = x }
            }
            let sensor = MapSensor(id: sid, type: e.sensor?.sensor_type?.name ?? "Sensor", values: values, timestamp: date)
            if byLocation[locationID] == nil {
                byLocation[locationID] = MapLocation(
                    id: locationID, latitude: lat, longitude: lon,
                    indoor: (e.location?.indoor?.double ?? 0) != 0, sensors: []
                )
            }
            byLocation[locationID]?.sensors.append(sensor)
        }

        return byLocation.values
            .map { loc -> MapLocation in
                var l = loc
                l.sensors.sort { $0.id < $1.id }
                return l
            }
            .sorted { $0.id < $1.id }
    }

    // MARK: Local Nettigo Air Monitor

    /// http://<device-address>/data.json – current values straight from the device on your network.
    static func local(host: String) async -> SourceResult {
        let label = "Local device (\(host))"
        guard let url = localURL(from: host) else {
            return SourceResult(status: SourceStatus(id: "local", label: label, ok: false, detail: "invalid address"),
                                values: [:])
        }
        do {
            let data = try await get(url, timeout: 6)
            let parsed = try parseLocal(data, now: Date())
            let names = parsed.keys.map(\.rawValue).sorted().joined(separator: ", ")
            return SourceResult(
                status: SourceStatus(id: "local", label: label, ok: true, detail: names.isEmpty ? "no known values" : names),
                values: parsed
            )
        } catch {
            return SourceResult(status: SourceStatus(id: "local", label: label, ok: false, detail: describe(error)),
                                values: [:])
        }
    }

    static func localURL(from input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        guard var comps = URLComponents(string: s) else { return nil }
        if comps.path.isEmpty || comps.path == "/" { comps.path = "/data.json" }
        return comps.url
    }

    static func parseLocal(_ data: Data, now: Date) throws -> [Metric: MetricValue] {
        let json = try JSONDecoder().decode(LocalData.self, from: data)
        // "age" = seconds since the last measurement
        var timestamp = now
        if let age = json.age?.double, age >= 0, age < 3600 { timestamp = now.addingTimeInterval(-age) }

        var values: [Metric: MetricValue] = [:]
        for v in json.sensordatavalues {
            // HECA sits inside the inlet heater – it doesn't measure outside temperature/humidity.
            if v.value_type.lowercased().hasPrefix("heca_") { continue }
            guard let metric = Metric.from(valueType: v.value_type), let number = v.value.double else { continue }
            if values[metric] == nil {   // first sensor in the list wins
                values[metric] = MetricValue(value: number, timestamp: timestamp, sourceID: "local")
            }
        }
        return values
    }

    // MARK: Helpers

    private static func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("AirMonitor-macOS/1.1", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
        return data
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? APIError { return e.description }
        if error is DecodingError { return "unexpected response format" }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "timed out"
            case NSURLErrorNotConnectedToInternet: return "no internet connection"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "device not reachable"
            case NSURLErrorCancelled: return "cancelled"
            default: break
            }
        }
        return error.localizedDescription
    }

    static let scDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

enum APIError: Error, CustomStringConvertible {
    case http(Int)
    var description: String {
        switch self {
        case .http(let code): return "HTTP error \(code)"
        }
    }
}

// MARK: - JSON models

/// A value that may arrive as a string ("20.40"), a number (20.4) or a bool.
struct FlexValue: Decodable {
    let string: String

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { string = s }
        else if let d = try? c.decode(Double.self) { string = String(d) }
        else if let b = try? c.decode(Bool.self) { string = b ? "1" : "0" }
        else if c.decodeNil() { string = "" }
        else { throw DecodingError.typeMismatch(String.self, .init(codingPath: decoder.codingPath, debugDescription: "neither string nor number")) }
    }

    var double: Double? { Double(string.trimmingCharacters(in: .whitespaces)) }
}

struct SCEntry: Decodable {
    let timestamp: String
    let location: SCLocation?
    let sensor: SCSensor?
    let sensordatavalues: [SCValue]
}

struct SCLocation: Decodable {
    let id: Int?
    let latitude: FlexValue?
    let longitude: FlexValue?
    let altitude: FlexValue?
    let indoor: FlexValue?
    let country: String?
}

struct SCSensor: Decodable {
    let id: Int?
    let sensor_type: SCSensorType?
}

struct SCSensorType: Decodable {
    let name: String?
}

struct SCValue: Decodable {
    let value_type: String
    let value: FlexValue
}

struct LocalData: Decodable {
    let software_version: String?
    let age: FlexValue?
    let sensordatavalues: [SCValue]
}
