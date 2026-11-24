import SwiftUI
import AppKit
import Charts

/// History chart shown in the popover, below the current values.
@MainActor
struct HistorySection: View {
    @ObservedObject var store: AirStore
    @ObservedObject var history: HistoryStore

    private struct Band: Identifiable {
        let id: Int
        let low: Double
        let high: Double
        let color: Color
    }

    var body: some View {
        let data = history.chartData()

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: "History").font(.headline)
                Spacer()
                Picker("", selection: $history.metric) {
                    ForEach(HistoryStore.metrics, id: \.self) { m in
                        Text(verbatim: HistoryStore.title(m)).tag(m)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            Picker("", selection: $history.range) {
                ForEach(HistoryRange.allCases) { r in
                    Text(verbatim: r.title).tag(r)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            ZStack(alignment: .topTrailing) {
                if data.points.isEmpty {
                    placeholder
                } else {
                    chart(data.points)
                }
                if let p = history.progress {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(verbatim: "\(p.done)/\(p.total) days")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .frame(height: 150)

            Text(verbatim: statsLine(data.points, data.stats))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Chart

    /// Half a bin of padding on both sides, so the first and last point aren't cut off.
    private var halfBin: TimeInterval { Double(history.range.binHours) * 1800 }
    private var domainEnd: Date { Date().addingTimeInterval(halfBin) }
    private var domainStart: Date { Date().addingTimeInterval(-Double(history.range.days) * 86400 - halfBin) }

    private var isParticles: Bool { history.metric == .pm25 || history.metric == .pm10 || history.metric == .pm1 }

    private var lineColor: Color {
        switch history.metric {
        case .temperature: return .orange
        case .humidity: return .blue
        default: return Color.primary.opacity(0.85)
        }
    }

    private var xFormat: Date.FormatStyle {
        switch history.range {
        case .week: return .dateTime.weekday(.abbreviated)
        case .month: return .dateTime.day().month(.abbreviated)
        case .halfYear, .year: return .dateTime.month(.abbreviated)
        }
    }

    @ViewBuilder
    private func chart(_ points: [HistoryPoint]) -> some View {
        let daily = history.range.binHours >= 24
        let domain = yDomain(points, daily: daily)
        let bands = levelBands(maxY: domain.upperBound)
        let hovered = nearest(points, to: history.hoverDate)

        Chart {
            ForEach(bands) { band in
                RectangleMark(
                    xStart: .value("Start", domainStart),
                    xEnd: .value("End", domainEnd),
                    yStart: .value("Low", band.low),
                    yEnd: .value("High", band.high)
                )
                .foregroundStyle(band.color.opacity(0.14))
            }

            if daily {
                ForEach(points) { p in
                    RuleMark(
                        x: .value("Day", p.date),
                        yStart: .value("Min", p.min),
                        yEnd: .value("Max", p.max)
                    )
                    .foregroundStyle(lineColor.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }

            ForEach(points) { p in
                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Value", p.avg),
                    series: .value("Segment", p.segment)
                )
                .foregroundStyle(lineColor)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }

            if let h = hovered {
                RuleMark(x: .value("Selected", h.date))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                PointMark(x: .value("Time", h.date), y: .value("Value", h.avg))
                    .foregroundStyle(lineColor)
                    .symbolSize(30)
            }
        }
        .chartXScale(domain: domainStart...domainEnd)
        .chartYScale(domain: domain)
        .chartXSelection(value: $history.hoverDate)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: xFormat)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
        }
    }

    private func yDomain(_ points: [HistoryPoint], daily: Bool) -> ClosedRange<Double> {
        let highs = points.map { daily ? $0.max : $0.avg }
        let lows = points.map { daily ? $0.min : $0.avg }
        let hi = highs.max() ?? 1
        let lo = lows.min() ?? 0
        switch history.metric {
        case .temperature:
            return (lo - 2).rounded(.down)...(hi + 2).rounded(.up)
        case .humidity:
            return 0...100
        default:
            // Always show at least the first quality band so "good" air still has context.
            let firstLimit = particleLimits.first ?? 10
            return 0...max(hi * 1.15, firstLimit * 1.3, 5)
        }
    }

    private var particleLimits: [Double] {
        switch (store.standard, history.metric) {
        case (.eu, .pm10): return AirQuality.euPM10Limits
        case (.eu, _):     return AirQuality.euPM25Limits
        case (.us, .pm10): return AirQuality.usPM10Limits
        case (.us, _):     return AirQuality.usPM25Limits
        }
    }

    /// Background bands in the air quality colors (particles only).
    private func levelBands(maxY: Double) -> [Band] {
        guard history.metric == .pm25 || history.metric == .pm10 else { return [] }
        let colors = store.standard == .eu ? AirQuality.euColors : AirQuality.usColors
        var bands: [Band] = []
        var low = 0.0
        for (i, limit) in (particleLimits + [Double.greatestFiniteMagnitude]).enumerated() where low < maxY {
            bands.append(Band(id: i, low: low, high: min(limit, maxY), color: Color(nsColor: colors[min(i, colors.count - 1)])))
            low = limit
        }
        return bands
    }

    private func nearest(_ points: [HistoryPoint], to date: Date?) -> HistoryPoint? {
        guard let date else { return nil }
        return points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    // MARK: Texts

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line").font(.title2)
            Text(verbatim: placeholderText)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private var placeholderText: String {
        if history.progress != nil { return "Loading history from the sensor.community archive…" }
        switch history.metric {
        case .temperature, .humidity:
            return "No \(HistoryStore.title(history.metric).lowercased()) history yet.\nAirMonitor records it from now on."
        default:
            return "No data for this period."
        }
    }

    private func statsLine(_ points: [HistoryPoint], _ stats: HistoryStats?) -> String {
        let unit = HistoryStore.unit(history.metric)
        let decimals = history.metric == .humidity ? 0 : 1

        if let h = nearest(points, to: history.hoverDate) {
            let when: String
            if history.range.binHours >= 24 {
                when = h.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
                return "\(when): avg \(Fmt.number(h.avg, decimals: decimals)) \(unit) (min \(Fmt.number(h.min, decimals: decimals)), max \(Fmt.number(h.max, decimals: decimals)))"
            } else {
                let start = Date(timeIntervalSince1970: Double(h.id) * 3600)
                when = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                return "\(when): \(Fmt.number(h.avg, decimals: decimals)) \(unit)"
            }
        }

        guard let s = stats else {
            return history.progress.map { "Loading \($0.done)/\($0.total) days…" } ?? " "
        }
        var parts = ["Avg \(Fmt.number(s.avg, decimals: decimals))",
                     "Min \(Fmt.number(s.min, decimals: decimals))",
                     "Max \(Fmt.number(s.max, decimals: decimals)) \(unit)"]
        if let over = s.daysOverLimit, let limit = s.limit {
            parts.append("\(over) of \(s.daysWithData) days above WHO limit (\(Fmt.number(limit, decimals: 0)))")
        } else if s.daysWithData < history.range.days {
            parts.append("\(s.daysWithData) of \(history.range.days) days with data")
        }
        return parts.joined(separator: " · ")
    }
}
