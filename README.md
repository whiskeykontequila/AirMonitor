# AirMonitor 🌿 (macOS menu bar)

A small menu bar app that shows air quality and temperature from a **Nettigo Air Monitor**
(or any other sensor.community device) — via the public `data.sensor.community` API and/or
straight from the device on your local network.

- Colored AQI icon in the menu bar (color = air quality) plus PM2.5 and temperature, e.g. `● 7 · 4.6°`
- Click it for a popover with the rating (Good / Fair / Moderate…), PM2.5, PM10, temperature, humidity and pressure
- Refreshes every **5 minutes** (1–30 min configurable) and right after the Mac wakes from sleep
- European (EEA) or US (EPA) index
- Right-click the icon: Refresh Now / Settings… / Quit
- **Settings window with a map**: zoom and pan to any area, click a marker to see that device's sensors and
  add them with one click — or type sensor IDs in directly
- **History** right in the popover: last 24 hours / 7 / 30 / 180 days of PM2.5, PM10, temperature or humidity
- Optional: launch at login

## Install

Requires macOS 14 (Sonoma) or newer and Xcode (or just the Command Line Tools: `xcode-select --install`).

```bash
cd ~/Downloads/AirMonitor      # wherever you unzipped it
chmod +x build.sh
./build.sh --install
```

The script compiles the app, creates `AirMonitor.app`, copies it to `/Applications` and launches it.
The icon appears at the top right of the menu bar (there is no Dock icon — that's on purpose; the Dock
icon only shows up while the Settings window is open).

To work on it in Xcode: `open Package.swift`, then ▶︎ Run.

## Making a DMG

```bash
./build.sh --dmg               # → AirMonitor-<version>.dmg
./build.sh --universal --dmg   # same, but runs on both Apple Silicon and Intel Macs
```

The DMG contains the app and an *Applications* shortcut: open it and drag AirMonitor onto Applications.

**Sharing it with other Macs:** the app is only signed ad hoc (no Apple Developer ID), so on another Mac
Gatekeeper blocks the first launch. Open it once anyway: try to open the app, then go to
*System Settings → Privacy & Security* and click **Open Anyway** (or run
`xattr -dr com.apple.quarantine /Applications/AirMonitor.app`).

To avoid that warning entirely you need an Apple Developer account ($99/year):

1. Create a **Developer ID Application** certificate in Xcode (Settings → Accounts → Manage Certificates).
2. Store notarization credentials once (use an app-specific password from appleid.apple.com):
   ```bash
   xcrun notarytool store-credentials airmonitor \
     --apple-id you@example.com --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
   ```
3. Build a signed and notarized DMG:
   ```bash
   SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=airmonitor \
     ./build.sh --universal --dmg
   ```

## Picking sensors

There is no default sensor. On first launch the Settings window opens by itself; the map starts near the city
of your Mac's time zone (Berlin if that can't be found). Use the search field on the map to jump anywhere.

Open **Settings… → Sensors**:

- **Map:** pan and zoom; the sensors for the visible area load automatically (zoom in far enough — very large
  areas are skipped to keep the map fast). Marker color = current air quality, ★ = your sensors,
  🏠 = indoor sensor, 🌡 = temperature/humidity only. Click a marker to see its sensors and their current values,
  then **Add** / **Remove**, or **Add all sensors at this location**.
- **Enter manually:** comma-separated sensor IDs, e.g. `12345, 12346`.
- **Local device address (optional):** e.g. `192.168.1.50`. The app then also reads `http://<address>/data.json`
  directly from the device, which includes every sensor attached to it (temperature too). It only works while the
  Mac is on the same network; elsewhere the app falls back to sensor.community. macOS may ask once for
  **Local Network** permission — click Allow.

When several sources report the same value, the freshest reading wins.

### Why is there no temperature?

A Nettigo Air Monitor usually has two sensors, and each one has **its own ID** on sensor.community:
a particulate sensor (SDS011, SPS30…) and a temperature/humidity sensor (BME280, SHT3x…).
If you only added the particulate sensor, pick the second one on the map (it sits at the same location)
or add the device's local address. If the temperature sensor doesn't show up on the map at all, check on
<https://devices.sensor.community> that it's registered, and in the device's own settings that it is enabled
and that sending to Sensor.Community is turned on.

## History

The popover shows a history chart below the current values. Pick the period (24 hours, 7, 30 or 180 days) and the
value (PM2.5, PM10, temperature, humidity). Hover over the chart to read a single hour/day.

- **Past days** come from the public archive at archive.sensor.community (one CSV per sensor per day). Each day is
  downloaded **once** (newest first, 4 at a time) and cached as hourly averages/min/max in
  `~/Library/Application Support/AirMonitor/History/` — well under 1 MB per sensor, kept for 200 days.
  The first time you open 180 days it takes about half a minute; after that it's instant and only yesterday's file is
  fetched once a day. The archive publishes a day only after it has ended.
- **Today, and your local device:** AirMonitor also records its own readings on every refresh. That covers today
  and the local device (e.g. a BME280 that isn't registered on sensor.community) — that history starts the day you
  install this version.
- 24 hours and 7 days show hourly points, 30 days 3-hourly points, 180 days daily averages with a min–max bar.
  Background colors are the air quality levels; the summary counts days above the WHO 24-hour guideline
  (PM2.5 15 µg/m³, PM10 45 µg/m³).
- *Settings → General → History* shows the cache size and has **Clear History…**.

## Air quality indexes

**European (EEA, 2024 bands):**

| Level | PM2.5 µg/m³ | PM10 µg/m³ |
|---|---|---|
| Good | 0–5 | 0–15 |
| Fair | 6–15 | 16–45 |
| Moderate | 16–50 | 46–120 |
| Poor | 51–90 | 121–195 |
| Very poor | 91–140 | 196–270 |
| Extremely poor | >140 | >270 |

**US AQI (EPA, PM2.5 breakpoints from May 2024):** 0–50 Good, 51–100 Moderate,
101–150 Unhealthy for sensitive groups, 151–200 Unhealthy, 201–300 Very unhealthy, 301+ Hazardous.

Note: the official indexes use hourly (EEA) or 24-hour (EPA) averages, while the app shows the latest
reading, so the rating is indicative. SDS011 sensors often read too high when humidity is above ~90% (fog).

## Project layout

```
Package.swift
build.sh                       builds AirMonitor.app (+ --install, --dmg, --universal)
Support/Info.plist             LSUIElement, local-network http access
Support/make-icon.swift        draws the app icon at build time
Sources/AirMonitor/
  AirMonitorApp.swift          entry point, menu bar item, popover, Settings window
  AirStore.swift               data, timer, settings
  SensorAPI.swift              sensor.community (sensor + map area) and local data.json
  AirQuality.swift             EU / US index, colors
  Models.swift                 models
  Views.swift                  popover UI
  History.swift                history cache, archive download, own readings
  HistoryView.swift            history chart in the popover
  SettingsView.swift           Settings window: map, sensor picker, general options
```

## Uninstall

Quit the app (right-click the icon → Quit AirMonitor) and delete `/Applications/AirMonitor.app`.
