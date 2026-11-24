import SwiftUI
import MapKit

extension MapLocation {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

// MARK: - Map model

/// State of the Settings window: map camera, loaded sensors, selection and the manual-entry drafts.
@MainActor
final class SensorMapModel: ObservableObject {
    @Published var position: MapCameraPosition = .automatic
    @Published var selectedLocationID: Int? = nil {
        didSet { updateSelectedLocation() }
    }
    @Published private(set) var selectedLocation: MapLocation? = nil
    @Published private(set) var locations: [MapLocation] = []
    @Published private(set) var isLoading = false
    @Published private(set) var status = "Move the map to load sensors"
    @Published var idsDraft = ""
    @Published var hostDraft = ""
    @Published var searchText = ""

    let store: AirStore
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var hasCentered = false

    /// Bigger areas would mean thousands of markers, so the user is asked to zoom in instead.
    static let maxLatitudeSpan = 1.0
    static let maxLongitudeSpan = 1.6
    static let fallbackCenter = CLLocationCoordinate2D(latitude: 52.52, longitude: 13.405)   // Berlin

    init(store: AirStore) {
        self.store = store
    }

    /// Called every time the Settings window opens.
    func prepare() {
        idsDraft = store.sensorIDsText
        hostDraft = store.localHost
        if !hasCentered {
            hasCentered = true
            centerOnMySensors(animated: false)
        }
    }

    func centerOnMySensors(animated: Bool = true) {
        let points = store.sensorIDs.compactMap { store.sensorLocations[$0] }
        let region: MKCoordinateRegion
        if let first = points.first {
            let lats = points.map(\.latitude)
            let lons = points.map(\.longitude)
            let minLat = lats.min() ?? first.latitude, maxLat = lats.max() ?? first.latitude
            let minLon = lons.min() ?? first.longitude, maxLon = lons.max() ?? first.longitude
            region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: MKCoordinateSpan(latitudeDelta: max(0.12, (maxLat - minLat) * 1.6),
                                       longitudeDelta: max(0.18, (maxLon - minLon) * 1.6))
            )
        } else {
            // Nothing picked yet: start near the city of the Mac's time zone (no location permission needed),
            // with Berlin as the fallback.
            region = MKCoordinateRegion(center: Self.fallbackCenter, span: Self.citySpan)
            if let city = Self.timeZoneCity {
                Task {
                    if let cityRegion = await Self.searchRegion(city) { self.move(to: cityRegion, animated: true) }
                }
            }
        }
        move(to: region, animated: animated)
    }

    func search() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        status = "Searching…"
        Task {
            if let region = await Self.searchRegion(query) {
                self.move(to: region, animated: true)
            } else {
                self.status = "Couldn't find “\(query)”"
            }
        }
    }

    private func move(to region: MKCoordinateRegion, animated: Bool) {
        if animated {
            withAnimation(.easeInOut) { position = .region(region) }
        } else {
            position = .region(region)
        }
        regionChanged(region)
    }

    static let citySpan = MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.45)

    /// "Europe/Belgrade" → "Belgrade", "America/New_York" → "New York".
    static var timeZoneCity: String? {
        let parts = TimeZone.current.identifier.split(separator: "/")
        guard parts.count >= 2, let last = parts.last else { return nil }
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// Finds a place with Apple Maps search and returns a city-sized region around it.
    nonisolated static func searchRegion(_ query: String) async -> MKCoordinateRegion? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .address
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        return MKCoordinateRegion(center: response.boundingRegion.center,
                                  span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.45))
    }

    // MARK: Loading sensors for the visible area

    func regionChanged(_ region: MKCoordinateRegion) {
        loadTask?.cancel()
        generation += 1
        let gen = generation

        guard region.span.latitudeDelta <= Self.maxLatitudeSpan,
              region.span.longitudeDelta <= Self.maxLongitudeSpan else {
            isLoading = false
            status = "Zoom in to load sensors"
            return
        }

        let south = region.center.latitude - region.span.latitudeDelta / 2
        let north = region.center.latitude + region.span.latitudeDelta / 2
        let west = region.center.longitude - region.span.longitudeDelta / 2
        let east = region.center.longitude + region.span.longitudeDelta / 2

        loadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)   // wait until the user stops moving the map
            guard !Task.isCancelled else { return }
            await self?.load(south: south, west: west, north: north, east: east, gen: gen)
        }
    }

    private func load(south: Double, west: Double, north: Double, east: Double, gen: Int) async {
        isLoading = true
        status = "Loading sensors…"
        do {
            let result = try await SensorAPI.sensorsInBox(south: south, west: west, north: north, east: east)
            guard gen == generation else { return }
            locations = result
            let sensorCount = result.reduce(0) { $0 + $1.sensors.count }
            status = result.isEmpty
                ? "No active sensors here"
                : "\(result.count) locations · \(sensorCount) sensors"
            updateSelectedLocation()
        } catch {
            guard gen == generation else { return }
            status = "Couldn't load sensors: \(SensorAPI.describe(error))"
        }
        isLoading = false
    }

    private func updateSelectedLocation() {
        guard let id = selectedLocationID else { selectedLocation = nil; return }
        if let loc = locations.first(where: { $0.id == id }) { selectedLocation = loc }
    }

    // MARK: Marker appearance

    func isMine(_ loc: MapLocation) -> Bool {
        let mine = Set(store.sensorIDs)
        return loc.sensors.contains { mine.contains($0.id) }
    }

    func tint(for loc: MapLocation) -> Color {
        if let level = AirQuality.level(pm25: loc.value(.pm25), pm10: loc.value(.pm10), standard: store.standard) {
            return Color(nsColor: level.color)
        }
        return .gray
    }

    func glyph(for loc: MapLocation) -> String {
        if isMine(loc) { return "star.fill" }
        if loc.indoor { return "house.fill" }
        if loc.hasPM { return "aqi.medium" }
        return "thermometer.medium"
    }

    // MARK: Changing the selection

    func add(_ ids: [Int]) {
        let current = store.sensorIDs
        store.setSensorIDs(current + ids.filter { !current.contains($0) })
        idsDraft = store.sensorIDsText
    }

    func remove(_ id: Int) {
        store.setSensorIDs(store.sensorIDs.filter { $0 != id })
        idsDraft = store.sensorIDsText
    }

    var hasManualChanges: Bool {
        idsDraft != store.sensorIDsText
            || hostDraft.trimmingCharacters(in: .whitespacesAndNewlines) != store.localHost
    }

    func applyManual() {
        store.applySources(sensorIDs: idsDraft, localHost: hostDraft)
        hostDraft = store.localHost
    }
}

// MARK: - Settings window

@MainActor
struct SettingsView: View {
    @ObservedObject var store: AirStore
    @ObservedObject var map: SensorMapModel

    var body: some View {
        TabView {
            SensorsTab(store: store, map: map)
                .tabItem { Label("Sensors", systemImage: "map") }
            GeneralTab(store: store, history: store.history)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .padding(12)
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
    }
}

// MARK: Sensors tab (map + sidebar)

@MainActor
struct SensorsTab: View {
    @ObservedObject var store: AirStore
    @ObservedObject var map: SensorMapModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .top) {
                Map(position: $map.position, selection: $map.selectedLocationID) {
                    ForEach(map.locations) { loc in
                        Marker(loc.markerTitle, systemImage: map.glyph(for: loc), coordinate: loc.coordinate)
                            .tint(map.tint(for: loc))
                            .tag(loc.id)
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .mapControls {
                    MapZoomStepper()
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    map.regionChanged(context.region)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search a city or address", text: $map.searchText)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                        .onSubmit { map.search() }
                    Divider().frame(height: 14)
                    if map.isLoading { ProgressView().controlSize(.small) }
                    Text(verbatim: map.status).font(.callout).lineLimit(1)
                    if !store.sensorIDs.isEmpty {
                        Divider().frame(height: 14)
                        Button { map.centerOnMySensors() } label: {
                            Label("My sensors", systemImage: "scope")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 10)
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                SensorSidebar(store: store, map: map)
                    .padding(.trailing, 4)
            }
            .frame(width: 320)
        }
    }
}

@MainActor
struct SensorSidebar: View {
    @ObservedObject var store: AirStore
    @ObservedObject var map: SensorMapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Selected on map") {
                Group {
                    if let loc = map.selectedLocation {
                        LocationDetail(store: store, map: map, location: loc)
                    } else {
                        Text(verbatim: "Click a marker to see its sensors and add them.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Your sensors") {
                VStack(alignment: .leading, spacing: 6) {
                    if store.sensorIDs.isEmpty {
                        Text(verbatim: "None yet – add one from the map.").foregroundStyle(.secondary)
                    }
                    ForEach(store.sensorIDs, id: \.self) { id in
                        HStack {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                            Text(verbatim: store.label(for: id))
                            Spacer()
                            Button { map.remove(id) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this sensor")
                        }
                    }
                    if !store.localHost.isEmpty {
                        HStack {
                            Image(systemName: "wifi").foregroundStyle(.blue)
                            Text(verbatim: "Local device: \(store.localHost)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Enter manually") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Sensor IDs").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. 12345, 12346", text: $map.idsDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { map.applyManual() }

                    Text(verbatim: "Local device address (optional)").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. 192.168.1.50 or nam-123456.local", text: $map.hostDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { map.applyManual() }
                    Text(verbatim: "Reads http://address/data.json straight from your Nettigo Air Monitor while you're on the same network.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Spacer()
                        Button("Apply") { map.applyManual() }
                            .disabled(!map.hasManualChanges)
                    }
                }
                .padding(4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Your sensors", systemImage: "star.fill")
                Label("Indoor sensor", systemImage: "house.fill")
                Label("Temperature/humidity only", systemImage: "thermometer.medium")
                Text(verbatim: "Marker color = air quality (\(store.standard.title) index)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct LocationDetail: View {
    @ObservedObject var store: AirStore
    @ObservedObject var map: SensorMapModel
    let location: MapLocation

    var body: some View {
        let mine = Set(store.sensorIDs)
        let missing = location.sensors.map(\.id).filter { !mine.contains($0) }

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: "Location #\(location.id)").font(.headline)
                Spacer()
                Text(verbatim: location.indoor ? "Indoor" : "Outdoor")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }

            ForEach(location.sensors) { sensor in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(sensor.type) #\(sensor.id)").font(.callout.weight(.medium))
                        Text(verbatim: sensor.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if mine.contains(sensor.id) {
                        Button("Remove") { map.remove(sensor.id) }
                    } else {
                        Button("Add") { map.add([sensor.id]) }
                    }
                }
            }

            if location.sensors.count > 1 && missing.count > 1 {
                Button {
                    map.add(missing)
                } label: {
                    Label("Add all sensors at this location", systemImage: "plus.circle.fill")
                }
            }
        }
    }
}

// MARK: General tab

@MainActor
struct GeneralTab: View {
    @ObservedObject var store: AirStore
    @ObservedObject var history: HistoryStore

    var body: some View {
        Form {
            Section("Air quality") {
                Picker("Index", selection: $store.standard) {
                    ForEach(AQIStandard.allCases) { Text(verbatim: $0.title).tag($0) }
                }
            }

            Section("Menu bar") {
                Picker("Show", selection: $store.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                Picker("Icon", selection: $store.iconStyle) {
                    ForEach(IconStyle.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Updates") {
                Picker("Refresh", selection: $store.refreshMinutes) {
                    ForEach(AirStore.refreshChoices, id: \.self) { m in
                        Text(verbatim: m == 1 ? "Every minute" : "Every \(m) minutes").tag(m)
                    }
                }
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                if let e = store.launchError {
                    Text(verbatim: e).font(.caption).foregroundStyle(.red)
                }
            }

            Section("History") {
                LabeledContent("Stored on this Mac") {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: history.cacheSize, countStyle: .file))
                }
                Text(verbatim: "Past days are downloaded once from archive.sensor.community and kept for 200 days. AirMonitor also records its own readings, including your local device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear History…") { history.showClearConfirm = true }
                    .confirmationDialog("Clear all stored history?", isPresented: $history.showClearConfirm) {
                        Button("Clear History", role: .destructive) { history.clearAll() }
                    } message: {
                        Text(verbatim: "Archive days can be downloaded again, but readings recorded from your local device can't be restored.")
                    }
            }

            Section("Sources") {
                if store.sources.isEmpty {
                    Text(verbatim: "No sources yet").foregroundStyle(.secondary)
                }
                ForEach(store.sources) { s in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: s.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(s.ok ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: s.label)
                            Text(verbatim: s.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Refresh now") { Task { await store.refresh() } }
            }
        }
        .formStyle(.grouped)
    }
}
