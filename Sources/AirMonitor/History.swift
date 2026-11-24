import Foundation
import SwiftUI

// History = hourly aggregates per source, cached in ~/Library/Application Support/AirMonitor/History/.
//  • Past days come from archive.sensor.community (one CSV per sensor per day) and are downloaded once.
//  • The app also records its own readings (every refresh), so today is covered and so is the
//    local device, which has no public archive.

// MARK: - Ranges

enum HistoryRange: Int, CaseIterable, Identifiable {
    case day = 1, week = 7, month = 30, halfYear = 180

    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { self == .day ? "24 h" : "\(rawValue) days" }

    /// Hours per chart point.
    var binHours: Int {
        switch self {
        case .day, .week: return 1
        case .month: return 3
        case .halfYear: return 24
        }
    }
}

// MARK: - Stored model

/// Aggregate of all readings within one hour. Stored compactly as [sum, count, min, max].
struct Bucket: Codable, Sendable {
    var sum: Double
    var count: Int
    var min: Double
    var max: Double

    init(_ v: Double) {
        sum = v; count = 1; min = v; max = v
    }

    mutating func add(_ v: Double) {
        sum += v; count += 1
        min = Swift.min(min, v); max = Swift.max(max, v)
    }

    mutating func merge(_ o: Bucket) {
        sum += o.sum; count += o.count
        min = Swift.min(min, o.min); max = Swift.max(max, o.max)
    }

    var average: Double { sum / Double(Swift.max(count, 1)) }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        sum = try c.decode(Double.self)
        count = try c.decode(Int.self)
        min = try c.decode(Double.self)
        max = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(sum); try c.encode(count); try c.encode(min); try c.encode(max)
    }
}

enum DayStatus: String, Codable {
    case ok      // archive day downloaded
    case empty   // archive has no data for that day (sensor offline / didn't exist yet)
}

/// Everything stored for one source ("sc-88562" or "local").
struct SourceHistory: Codable {
    var days: [String: DayStatus] = [:]          // archive status per UTC day ("yyyy-MM-dd")
    var buckets: [String: [Int: Bucket]] = [:]   // metric → unix hour → bucket
    var lastLive: [String: Double] = [:]         // metric → timestamp of the last recorded live reading

    mutating func add(_ value: Double, metric: Metric, hour: Int) {
        if buckets[metric.rawValue]?[hour] != nil {
            buckets[metric.rawValue]![hour]!.add(value)
        } else {
            buckets[metric.rawValue, default: [:]][hour] = Bucket(value)
        }
    }

    /// Archive data is complete, so it replaces whatever was recorded live for that day.
    mutating func replaceDay(startHour: Int, with dayBuckets: [Metric: [Int: Bucket]]) {
        for key in Array(buckets.keys) {
            for h in startHour..<(startHour + 24) { buckets[key]?[h] = nil }
        }
        for (metric, hours) in dayBuckets {
            for (h, b) in hours { buckets[metric.rawValue, default: [:]][h] = b }
        }
    }

    mutating func prune(beforeHour minHour: Int) {
        for key in Array(buckets.keys) {
            buckets[key] = buckets[key]?.filter { $0.key >= minHour }
        }
        let minDay = ArchiveAPI.dayString(fromUnixDay: minHour / 24)
        days = days.filter { $0.key >= minDay }
    }
}

/// A source whose history is shown: a sensor.community sensor (with archive) or the local device.
struct HistorySource: Hashable, Sendable {
    let key: String            // "sc-88562" / "local"
    let sensorID: Int?
    let archiveType: String?   // "sds011", "bme280"… – nil for the local device
}

struct HistoryPoint: Identifiable {
    let id: Int          // first hour of the bin
    let date: Date       // middle of the bin
    let avg: Double
    let min: Double
    let max: Double
    let segment: Int     // a new segment starts after a gap, so the line isn't drawn across it
}

struct HistoryStats {
    let avg: Double
    let min: Double
    let max: Double
    let daysWithData: Int
    let daysOverLimit: Int?
    let limit: Double?
}

struct HistoryProgress: Equatable {
    let done: Int
    let total: Int
}

// MARK: - Archive download & parsing

enum DayFetchResult: Sendable {
    case data([Metric: [Int: Bucket]])
    case notFound
    case failed
}

struct ArchiveJob: Sendable {
    let key: String
    let sensorID: Int
    let type: String
    let day: String
    let daysAgo: Int
}

enum ArchiveAPI {
    static let trackedMetrics: Set<Metric> = [.pm1, .pm25, .pm10, .temperature, .humidity]

    /// This year:      https://archive.sensor.community/2026-11-23/2026-11-23_sds011_sensor_88562.csv
    /// Earlier years:  https://archive.sensor.community/2025/2025-11-23/2025-11-23_sds011_sensor_88562.csv.gz
    static func fetchDay(sensorID: Int, type: String, day: String) async -> DayFetchResult {
        let year = String(day.prefix(4))
        let file = "\(day)_\(type)_sensor_\(sensorID).csv"
        let candidates = [
            "https://archive.sensor.community/\(day)/\(file)",
            "https://archive.sensor.community/\(year)/\(day)/\(file).gz",
        ]
        var sawNotFound = false
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("AirMonitor-macOS/1.4", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if code == 404 { sawNotFound = true; continue }
                guard (200..<300).contains(code) else { return .failed }
                let raw = isGzip(data) ? gunzip(data) : data
                guard let raw, let text = String(data: raw, encoding: .utf8) else { return .failed }
                return .data(parseCSV(text))
            } catch {
                return .failed
            }
        }
        return sawNotFound ? .notFound : .failed
    }

    /// "sensor_id;sensor_type;location;lat;lon;timestamp;P1;durP1;ratioP1;P2;…" → hourly buckets.
    static func parseCSV(_ text: String) -> [Metric: [Int: Bucket]] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first else { return [:] }
        let names = header.split(separator: ";", omittingEmptySubsequences: false).map { String($0) }
        guard let tsIndex = names.firstIndex(of: "timestamp") else { return [:] }

        var columns: [(index: Int, metric: Metric)] = []
        for (i, name) in names.enumerated() {
            if let m = Metric.from(valueType: name), trackedMetrics.contains(m) { columns.append((i, m)) }
        }
        guard !columns.isEmpty else { return [:] }

        var result: [Metric: [Int: Bucket]] = [:]
        for line in lines.dropFirst() {
            let fields = line.split(separator: ";", omittingEmptySubsequences: false)
            guard tsIndex < fields.count, let hour = unixHour(isoTimestamp: fields[tsIndex]) else { continue }
            for column in columns where column.index < fields.count {
                guard let v = Double(fields[column.index]), v.isFinite else { continue }
                if result[column.metric]?[hour] != nil {
                    result[column.metric]![hour]!.add(v)
                } else {
                    result[column.metric, default: [:]][hour] = Bucket(v)
                }
            }
        }
        return result
    }

    // MARK: gzip

    static func isGzip(_ data: Data) -> Bool {
        data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Strips the gzip header/trailer and inflates the raw DEFLATE stream.
    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            guard i + 2 <= b.count else { return nil }
            i += 2 + (Int(b[i]) | (Int(b[i + 1]) << 8))
        }
        if flags & 0x08 != 0 {                       // FNAME
            while i < b.count && b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x10 != 0 {                       // FCOMMENT
            while i < b.count && b[i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }              // FHCRC
        guard i < b.count - 8 else { return nil }
        let deflated = Data(b[i..<(b.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: Dates (UTC, no Calendar/DateFormatter needed)

    /// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    static func civil(fromDays z0: Int) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    static func dayString(fromUnixDay days: Int) -> String {
        let c = civil(fromDays: days)
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    static func utcDayString(daysAgo: Int, from now: Date) -> String {
        let today = Int((now.timeIntervalSince1970 / 86400).rounded(.down))
        return dayString(fromUnixDay: today - daysAgo)
    }

    /// "2026-11-23T00:03:24" (UTC) → hours since 1970.
    static func unixHour(isoTimestamp s: Substring) -> Int? {
        let b = Array(s.utf8)
        guard b.count >= 13 else { return nil }
        func number(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r {
                let digit = Int(b[i]) - 48
                guard digit >= 0 && digit <= 9 else { return nil }
                v = v * 10 + digit
            }
            return v
        }
        guard let y = number(0..<4), let m = number(5..<7), let d = number(8..<10), let h = number(11..<13),
              (1...12).contains(m), (1...31).contains(d), h < 24 else { return nil }
        return daysFromCivil(y, m, d) * 24 + h
    }

    /// "2026-11-23" → first unix hour of that UTC day.
    static func dayStartHour(_ day: String) -> Int? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return daysFromCivil(parts[0], parts[1], parts[2]) * 24
    }
}

// MARK: - Store

@MainActor
final class HistoryStore: ObservableObject {
    @Published var range: HistoryRange {
        didSet {
            UserDefaults.standard.set(range.rawValue, forKey: "historyRange")
            hoverDate = nil
            requestArchive()
        }
    }
    @Published var metric: Metric {
        didSet {
            UserDefaults.standard.set(metric.rawValue, forKey: "historyMetric")
            hoverDate = nil
        }
    }
    @Published var hoverDate: Date? = nil
    @Published var showClearConfirm = false
    @Published private(set) var progress: HistoryProgress? = nil
    @Published private(set) var revision = 0
    @Published private(set) var cacheSize: Int64 = 0

    /// Supplies the sources currently selected in the app (set by AirStore).
    var sourcesProvider: @MainActor () -> [HistorySource] = { [] }

    static let metrics: [Metric] = [.pm25, .pm10, .temperature, .humidity]
    static let keepDays = 200   // longest range is 180 days
    static let parallelDownloads = 4

    let directory: URL
    private var histories: [String: SourceHistory] = [:]
    private var dirty = Set<String>()
    private var loadTask: Task<Void, Never>?
    private var rerunRequested = false
    private var saveTask: Task<Void, Never>?
    private var recentMisses: [String: Date] = [:]
    private var generation = 0
    private var memoKey = ""
    private var memoPoints: [HistoryPoint] = []
    private var memoStats: HistoryStats? = nil

    init() {
        let d = UserDefaults.standard
        range = HistoryRange(rawValue: d.integer(forKey: "historyRange")) ?? .day
        metric = Metric(rawValue: d.string(forKey: "historyMetric") ?? "") ?? .pm25
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("AirMonitor/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        updateCacheSize()
    }

    static func title(_ m: Metric) -> String {
        switch m {
        case .pm25: return "PM2.5"
        case .pm10: return "PM10"
        case .pm1: return "PM1"
        case .temperature: return "Temperature"
        case .humidity: return "Humidity"
        default: return m.rawValue
        }
    }

    static func unit(_ m: Metric) -> String {
        switch m {
        case .temperature: return "°C"
        case .humidity: return "%"
        default: return "µg/m³"
        }
    }

    // MARK: Files

    private func fileURL(_ key: String) -> URL { directory.appendingPathComponent(key + ".json") }

    private func history(_ key: String) -> SourceHistory {
        if let h = histories[key] { return h }
        var h = SourceHistory()
        if let data = try? Data(contentsOf: fileURL(key)),
           let decoded = try? JSONDecoder().decode(SourceHistory.self, from: data) {
            h = decoded
        }
        histories[key] = h
        return h
    }

    private func mutate(_ key: String, _ body: (inout SourceHistory) -> Void) {
        _ = history(key)   // make sure it's loaded
        body(&histories[key]!)
        dirty.insert(key)
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let minHour = Int(Date().timeIntervalSince1970 / 3600) - Self.keepDays * 24
        for key in dirty {
            guard var h = histories[key] else { continue }
            h.prune(beforeHour: minHour)
            histories[key] = h
            if let data = try? JSONEncoder().encode(h) {
                try? data.write(to: fileURL(key), options: .atomic)
            }
        }
        dirty.removeAll()
        updateCacheSize()
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func updateCacheSize() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        cacheSize = files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func clearAll() {
        generation += 1
        loadTask?.cancel()
        saveTask?.cancel()
        saveTask = nil
        histories = [:]
        dirty = []
        recentMisses = [:]
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        revision += 1
        updateCacheSize()
    }

    // MARK: Recording the app's own readings

    func recordLive(sourceKey: String, values: [Metric: MetricValue]) {
        let tracked = values.filter { ArchiveAPI.trackedMetrics.contains($0.key) }
        guard !tracked.isEmpty else { return }
        var changed = false
        mutate(sourceKey) { h in
            for (metric, v) in tracked {
                let ts = v.timestamp.timeIntervalSince1970
                if let last = h.lastLive[metric.rawValue], ts <= last { continue }   // same reading as last time
                h.lastLive[metric.rawValue] = ts
                let hour = Int((ts / 3600).rounded(.down))
                if h.days[ArchiveAPI.dayString(fromUnixDay: hour / 24)] == .ok { continue }  // day already archived
                h.add(v.value, metric: metric, hour: hour)
                changed = true
            }
        }
        if changed {
            revision += 1
            scheduleSave()
        }
    }

    // MARK: Downloading the archive

    /// Downloads every missing day of the selected range (newest first). Cheap when everything is cached.
    func requestArchive() {
        if loadTask != nil { rerunRequested = true; return }
        let now = Date()
        let sources = sourcesProvider().filter { $0.sensorID != nil && $0.archiveType != nil }
        var jobs: [ArchiveJob] = []
        for daysAgo in 1...range.days {
            let day = ArchiveAPI.utcDayString(daysAgo: daysAgo, from: now)
            for source in sources {
                guard let id = source.sensorID, let type = source.archiveType else { continue }
                if history(source.key).days[day] != nil { continue }
                if let t = recentMisses["\(source.key)|\(day)"], now.timeIntervalSince(t) < 3600 { continue }
                jobs.append(ArchiveJob(key: source.key, sensorID: id, type: type, day: day, daysAgo: daysAgo))
            }
        }
        guard !jobs.isEmpty else { return }
        progress = HistoryProgress(done: 0, total: jobs.count)
        let gen = generation
        loadTask = Task { [weak self] in
            await self?.run(jobs, gen: gen)
        }
    }

    private func run(_ jobs: [ArchiveJob], gen: Int) async {
        var next = 0
        var done = 0
        await withTaskGroup(of: (ArchiveJob, DayFetchResult).self) { group in
            while next < jobs.count && next < Self.parallelDownloads {
                let job = jobs[next]
                next += 1
                group.addTask {
                    let result = await ArchiveAPI.fetchDay(sensorID: job.sensorID, type: job.type, day: job.day)
                    return (job, result)
                }
            }
            while let finished = await group.next() {
                guard gen == generation else { continue }    // history was cleared meanwhile
                apply(finished.0, finished.1)
                done += 1
                progress = HistoryProgress(done: done, total: jobs.count)
                if done % 25 == 0 {
                    revision += 1
                    saveNow()
                }
                if next < jobs.count && !Task.isCancelled {
                    let job = jobs[next]
                    next += 1
                    group.addTask {
                        let result = await ArchiveAPI.fetchDay(sensorID: job.sensorID, type: job.type, day: job.day)
                        return (job, result)
                    }
                }
            }
        }
        progress = nil
        loadTask = nil
        revision += 1
        saveNow()
        if rerunRequested {
            rerunRequested = false
            requestArchive()
        }
    }

    private func apply(_ job: ArchiveJob, _ result: DayFetchResult) {
        let missKey = "\(job.key)|\(job.day)"
        switch result {
        case .data(let buckets):
            guard let start = ArchiveAPI.dayStartHour(job.day) else { return }
            mutate(job.key) { h in
                h.replaceDay(startHour: start, with: buckets)
                h.days[job.day] = buckets.isEmpty ? .empty : .ok
            }
        case .notFound:
            // The archive publishes a day only after it's over – recent days may still appear.
            if job.daysAgo > 2 {
                mutate(job.key) { $0.days[job.day] = .empty }
            } else {
                recentMisses[missKey] = Date()
            }
        case .failed:
            recentMisses[missKey] = Date()
        }
    }

    // MARK: Chart data

    func chartData() -> (points: [HistoryPoint], stats: HistoryStats?) {
        let sources = sourcesProvider().map(\.key)
        let nowHour = Int(Date().timeIntervalSince1970 / 3600)
        let key = "\(revision)|\(range.rawValue)|\(metric.rawValue)|\(sources.joined(separator: ","))|\(nowHour)"
        if key == memoKey { return (memoPoints, memoStats) }

        let startHour = nowHour - range.days * 24 + 1
        let tz = TimeZone.current.secondsFromGMT() / 3600
        let bin = range.binHours
        var bins: [Int: Bucket] = [:]
        var daily: [Int: Bucket] = [:]

        for source in sources {
            guard let series = history(source).buckets[metric.rawValue] else { continue }
            for (hour, b) in series where hour >= startHour && hour <= nowHour {
                let binStart = Int((Double(hour + tz) / Double(bin)).rounded(.down)) * bin - tz
                if bins[binStart] != nil { bins[binStart]!.merge(b) } else { bins[binStart] = b }
                let localDay = Int((Double(hour + tz) / 24).rounded(.down))
                if daily[localDay] != nil { daily[localDay]!.merge(b) } else { daily[localDay] = b }
            }
        }

        var points: [HistoryPoint] = []
        var segment = 0
        var previous: Int?
        for binStart in bins.keys.sorted() {
            guard let b = bins[binStart] else { continue }
            if let p = previous, binStart - p > bin * 3 { segment += 1 }
            previous = binStart
            let center = Double(binStart) * 3600 + Double(bin) * 1800
            points.append(HistoryPoint(id: binStart, date: Date(timeIntervalSince1970: center),
                                       avg: b.average, min: b.min, max: b.max, segment: segment))
        }

        var stats: HistoryStats?
        if !bins.isEmpty {
            var total = Bucket(0)
            total.sum = 0; total.count = 0
            total.min = .infinity; total.max = -.infinity
            for b in bins.values { total.merge(b) }
            let limit: Double? = metric == .pm25 ? 15 : (metric == .pm10 ? 45 : nil)   // WHO 24-hour guidelines
            let over = limit.map { l in daily.values.filter { $0.average > l }.count }
            stats = HistoryStats(avg: total.average, min: total.min, max: total.max,
                                 daysWithData: daily.count, daysOverLimit: over, limit: limit)
        }

        memoKey = key
        memoPoints = points
        memoStats = stats
        return (points, stats)
    }
}
