import AppKit
import Combine
import ServiceManagement

/// Holds the data and the settings, and refreshes everything every N minutes.
@MainActor
final class AirStore: ObservableObject {

    // MARK: Data
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var sources: [SourceStatus] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastAttempt: Date? = nil
    /// Where each sensor.community sensor is (used to center the map) and what type it is.
    @Published private(set) var sensorLocations: [Int: GeoPoint] = [:]
    @Published private(set) var sensorTypes: [Int: String] = [:]

    /// Cached history (archive + the app's own readings).
    let history: HistoryStore

    @Published var launchError: String? = nil
    @Published var launchAtLogin = false {
        didSet { if launchAtLogin != oldValue && !syncingLoginItem { updateLoginItem() } }
    }
    private var syncingLoginItem = false

    // MARK: Settings (persisted in UserDefaults)
    @Published var sensorIDsText: String { didSet { defaults.set(sensorIDsText, forKey: Keys.sensorIDs) } }
    @Published var localHost: String { didSet { defaults.set(localHost, forKey: Keys.localHost) } }
    @Published var standard: AQIStandard { didSet { defaults.set(standard.rawValue, forKey: Keys.standard) } }
    @Published var menuBarStyle: MenuBarStyle { didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) } }
    @Published var iconStyle: IconStyle { didSet { defaults.set(iconStyle.rawValue, forKey: Keys.iconStyle) } }
    @Published var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
            if refreshMinutes != oldValue { scheduleTimer() }
        }
    }

    static let refreshChoices = [1, 2, 5, 10, 15, 30]

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var refreshPending = false

    private enum Keys {
        static let sensorIDs = "sensorIDs"
        static let localHost = "localHost"
        static let standard = "aqiStandard"
        static let menuBarStyle = "menuBarStyle"
        static let iconStyle = "iconStyle"
        static let refreshMinutes = "refreshMinutes"
    }

    init() {
        history = HistoryStore()
        let d = UserDefaults.standard
        sensorIDsText = d.string(forKey: Keys.sensorIDs) ?? ""   // no default sensor – picked on first launch
        localHost = d.string(forKey: Keys.localHost) ?? ""
        standard = AQIStandard(rawValue: d.string(forKey: Keys.standard) ?? "") ?? .eu
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: Keys.menuBarStyle) ?? "") ?? .pmAndTemp
        iconStyle = IconStyle(rawValue: d.string(forKey: Keys.iconStyle) ?? "") ?? .symbol
        let savedMinutes = d.integer(forKey: Keys.refreshMinutes)
        refreshMinutes = savedMinutes > 0 ? savedMinutes : 5
        launchAtLogin = SMAppService.mainApp.status == .enabled
        history.sourcesProvider = { [weak self] in self?.historySources ?? [] }
    }

    // MARK: Startup and timer

    func start() {
        scheduleTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let store = self else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000) // give the network a moment
                await store.refresh()
            }
        }
        Task { await refresh() }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: TimeInterval(max(1, refreshMinutes) * 60), repeats: true) { [weak self] _ in
            guard let store = self else { return }
            Task { @MainActor in await store.refresh() }
        }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Refresh if the last attempt is older than `seconds` (e.g. when the popover opens).
    func refreshIfOlder(than seconds: TimeInterval) {
        if let last = lastAttempt, Date().timeIntervalSince(last) < seconds { return }
        Task { await refresh() }
    }

    // MARK: Choosing sources

    var sensorIDs: [Int] {
        var seen = Set<Int>()
        return sensorIDsText
            .split(whereSeparator: { ",; \n\t".contains($0) })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { seen.insert($0).inserted }
    }

    func setSensorIDs(_ ids: [Int]) {
        sensorIDsText = ids.map { String($0) }.joined(separator: ", ")
        Task { await refresh() }
    }

    func applySources(sensorIDs: String, localHost: String) {
        self.sensorIDsText = sensorIDs
        self.localHost = localHost.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await refresh() }
    }

    /// Nothing configured yet (first launch).
    var hasNoSources: Bool {
        sensorIDs.isEmpty && localHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sources whose history is shown: every selected sensor (with its archive file type) and the local device.
    var historySources: [HistorySource] {
        var result = sensorIDs.map {
            HistorySource(key: "sc-\($0)", sensorID: $0, archiveType: sensorTypes[$0]?.lowercased())
        }
        if !localHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(HistorySource(key: "local", sensorID: nil, archiveType: nil))
        }
        return result
    }

    func label(for id: Int) -> String {
        "\(sensorTypes[id] ?? "Sensor") #\(id)"
    }

    // MARK: Fetching

    func refresh() async {
        // If a refresh is already running (e.g. sources just changed), run another one right after it.
        if isLoading { refreshPending = true; return }
        isLoading = true
        repeat {
            refreshPending = false
            await fetchAll()
        } while refreshPending
        isLoading = false
    }

    private func fetchAll() async {
        lastAttempt = Date()

        let ids = sensorIDs
        let host = localHost.trimmingCharacters(in: .whitespacesAndNewlines)

        let results = await withTaskGroup(of: (Int, SourceResult).self, returning: [SourceResult].self) { group in
            for (i, id) in ids.enumerated() {
                group.addTask {
                    let r = await SensorAPI.sensorCommunity(id: id)
                    return (i, r)
                }
            }
            if !host.isEmpty {
                let order = ids.count
                group.addTask {
                    let r = await SensorAPI.local(host: host)
                    return (order, r)
                }
            }
            var collected: [(Int, SourceResult)] = []
            for await r in group { collected.append(r) }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        var updated = snapshot
        var locations = sensorLocations
        var types = sensorTypes
        for r in results {
            updated.merge(r.values)
            if let alt = r.altitude { updated.altitude = alt }
            if let id = r.sensorID {
                if let loc = r.location { locations[id] = loc }
                if let type = r.sensorType { types[id] = type }
            }
        }
        // Drop values of sources that were removed in the meantime.
        updated.removeValues(notFrom: Set(results.map { $0.status.id }))

        snapshot = updated
        sensorLocations = locations
        sensorTypes = types
        sources = results.map { $0.status }

        // History: keep the app's own readings and fetch any missing archive days.
        for r in results where r.status.ok {
            history.recordLive(sourceKey: r.status.id, values: r.values)
        }
        history.requestArchive()
    }

    // MARK: Derived values for display

    var pm25: Double? { snapshot.value(.pm25, maxAge: 3600) }
    var pm10: Double? { snapshot.value(.pm10, maxAge: 3600) }
    /// Temperature older than 30 min (e.g. the last local reading after you left home) isn't shown.
    var temperature: Double? { snapshot.value(.temperature, maxAge: 1800) }

    var level: AQLevel? { AirQuality.level(pm25: pm25, pm10: pm10, standard: standard) }

    var usAQI: Int? { AirQuality.combinedUSAQI(pm25: pm25, pm10: pm10) }

    /// Particulate data older than 30 min → gray icon.
    var isStale: Bool {
        guard let t = snapshot.timestamp(.pm25) ?? snapshot.timestamp(.pm10) else { return true }
        return Date().timeIntervalSince(t) > 30 * 60
    }

    var menuBarText: String {
        let temp = temperature.map { Fmt.temperature($0, decimals: 1) }
        var parts: [String] = []
        switch menuBarStyle {
        case .pmAndTemp:
            if let pm = pm25 { parts.append(Fmt.number(pm, decimals: 0)) }
            if let temp { parts.append(temp) }
        case .aqiAndTemp:
            if let aqi = usAQI { parts.append("AQI \(aqi)") }
            if let temp { parts.append(temp) }
        case .tempOnly:
            if let temp { parts.append(temp) }
        case .iconOnly:
            return ""
        }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }

    var tooltip: String {
        var lines: [String] = []
        if let level { lines.append("Air quality: \(level.name)") }
        var row: [String] = []
        if let pm25 { row.append("PM2.5 \(Fmt.number(pm25, decimals: 1)) µg/m³") }
        if let pm10 { row.append("PM10 \(Fmt.number(pm10, decimals: 1)) µg/m³") }
        if !row.isEmpty { lines.append(row.joined(separator: " · ")) }
        if let t = temperature { lines.append("Temperature \(Fmt.temperature(t, decimals: 1))C") }
        if let d = snapshot.lastUpdated { lines.append("Measured at \(Fmt.time(d))") }
        return lines.isEmpty ? "AirMonitor – no data yet" : lines.joined(separator: "\n")
    }

    // MARK: Launch at login

    private func updateLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "Couldn't change the login item: \(error.localizedDescription). Run the app from the Applications folder (./build.sh --install)."
            syncingLoginItem = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            syncingLoginItem = false
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static func number(_ v: Double, decimals: Int) -> String {
        v.formatted(.number.precision(.fractionLength(decimals)).grouping(.never))
    }

    static func temperature(_ v: Double, decimals: Int) -> String {
        number(v, decimals: decimals) + "°"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }

    static func ago(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "just now" }
        let m = s / 60
        if m < 60 { return "\(m) min ago" }
        let h = m / 60
        if h < 24 { return "\(h) h ago" }
        return "\(h / 24) d ago"
    }
}
