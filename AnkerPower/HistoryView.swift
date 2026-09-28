import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var history: HistoryStore
    @State private var range: HistoryRange = .hour
    @State private var source: HistorySource = .mac
    @State private var confirmClear = false
    @Environment(\.isScreenshotExport) private var isScreenshotExport

    private static let maxConnectableGap: TimeInterval = 2 * 60
    private static let seriesOrder = ["Total", "C1", "C2", "C3"]

    init(model: AppModel) {
        self.model = model
        _history = ObservedObject(wrappedValue: model.history)
    }

    private enum HistoryRange: String, CaseIterable, Identifiable {
        case hour = "1 hour"
        case sixHours = "6 hours"
        case day = "24 hours"

        var id: Self { self }
        var interval: TimeInterval {
            switch self {
            case .hour: return 60 * 60
            case .sixHours: return 6 * 60 * 60
            case .day: return 24 * 60 * 60
            }
        }
    }

    private enum HistorySource: String, CaseIterable, Identifiable {
        case mac = "This Mac"
        case charger = "Charger"

        var id: Self { self }
    }

    private struct ChartPoint: Identifiable {
        let id: String
        let timestamp: Date
        let series: String
        let power: Double
        let segment: Int

        init(id: String, timestamp: Date, series: String, power: Double, segment: Int = 0) {
            self.id = id
            self.timestamp = timestamp
            self.series = series
            self.power = power
            self.segment = segment
        }
    }

    /// Everything the chart and the stat tiles need, derived once per render.
    private struct ChartData {
        var points: [ChartPoint]
        var plotPoints: [ChartPoint]
        var summary: HistorySummary
        var domain: ClosedRange<Date>?
        var yMax: Double
    }

    private func makeChartData(now: Date) -> ChartData {
        let points: [ChartPoint]
        let totals: [(timestamp: Date, watts: Double)]
        var domain: ClosedRange<Date>?

        switch source {
        case .mac:
            let start = now.addingTimeInterval(-range.interval)
            let samples = history.samples.filter { $0.timestamp >= start }
            points = samples.flatMap { sample in
                [
                    ChartPoint(id: "\(sample.id)-total", timestamp: sample.timestamp, series: "Total", power: sample.total),
                    ChartPoint(id: "\(sample.id)-c1", timestamp: sample.timestamp, series: "C1", power: sample.port1),
                    ChartPoint(id: "\(sample.id)-c2", timestamp: sample.timestamp, series: "C2", power: sample.port2),
                    ChartPoint(id: "\(sample.id)-c3", timestamp: sample.timestamp, series: "C3", power: sample.port3)
                ]
            }
            totals = samples.map { (timestamp: $0.timestamp, watts: $0.total) }
            domain = start...now
        case .charger:
            guard let chargerHistory = model.chargerHistory else {
                return ChartData(points: [], plotPoints: [], summary: .empty, domain: nil, yMax: 1)
            }
            // The newest sample is the one read at capture time; earlier ones step back from it.
            let lastStep = chargerHistory.sampleCount - 1
            func timestamp(_ step: Int) -> Date {
                chargerHistory.capturedAt.addingTimeInterval(TimeInterval(step - lastStep))
            }
            var perPort: [ChartPoint] = []
            var totalByStep: [Int: Double] = [:]
            for port in chargerHistory.ports {
                for (step, power) in port.powers.enumerated() {
                    perPort.append(ChartPoint(
                        id: "charger-\(port.index)-\(step)",
                        timestamp: timestamp(step),
                        series: "C\(port.index)",
                        power: power
                    ))
                    totalByStep[step, default: 0] += power
                }
            }
            totals = totalByStep.keys.sorted().map { step in
                (timestamp: timestamp(step), watts: totalByStep[step] ?? 0)
            }
            points = totals.enumerated().map { step, total in
                ChartPoint(id: "charger-total-\(step)", timestamp: total.timestamp, series: "Total", power: total.watts)
            } + perPort
        }

        let plotPoints = Self.segmented(points)
        let peak = plotPoints.map(\.power).max() ?? 0
        return ChartData(
            points: points,
            plotPoints: plotPoints,
            summary: HistorySummary.compute(totals),
            domain: domain,
            yMax: max(10, (peak * 1.1).rounded(.up))
        )
    }

    var body: some View {
        let data = makeChartData(now: Date())

        VStack(alignment: .leading, spacing: 16) {
            header
            statTiles(data.summary)
            // A separate view owns the hover state, so moving the pointer re-renders only the
            // chart instead of rebuilding up to 24 hours of points on every mouse move.
            ChartPanel(data: data, showsDate: source == .mac && range != .hour, emptyTitle: emptyTitle, emptyMessage: emptyMessage)
            footer
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
        .confirmationDialog("Clear charging history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all readings stored on this Mac. The charger's own curve is not affected.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Charging History")
                    .font(.title2.weight(.semibold))
                Text(source == .charger
                     ? "Curve read from the charger once per connection."
                     : "Up to 24 hours, stored only on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                if model.chargerHistory != nil {
                    if isScreenshotExport {
                        screenshotSegments(HistorySource.allCases.map(\.rawValue), selected: source.rawValue, width: 84)
                    } else {
                        Picker("Source", selection: $source) {
                            ForEach(HistorySource.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if source == .mac {
                    if isScreenshotExport {
                        screenshotSegments(HistoryRange.allCases.map(\.rawValue), selected: range.rawValue, width: 72)
                    } else {
                        Picker("Range", selection: $range) {
                            ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
    }

    // MARK: Stat tiles

    private func statTiles(_ summary: HistorySummary) -> some View {
        HStack(spacing: 10) {
            statTile("Peak", value: AppModel.compactWatts(summary.peakWatts), unit: "W")
            statTile("Average", value: AppModel.compactWatts(summary.averageWatts), unit: "W")
            statTile("Energy", value: summary.energyWh.formatted(.number.precision(.fractionLength(1))), unit: "Wh")
            statTile("Charging time", value: Self.formatDuration(summary.chargingDuration), unit: nil)
        }
        .animation(.snappy(duration: 0.3), value: summary)
    }

    private func statTile(_ label: String, value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .platter()
        .accessibilityElement(children: .combine)
    }

    // MARK: Chart

    private var emptyTitle: String {
        source == .charger ? "No charger curve yet" : "No readings in this range"
    }

    private var emptyMessage: String {
        source == .charger
            ? "The charger-side history is requested once after connecting."
            : "Readings appear here while Anker Power is connected to the charger."
    }

    private struct ChartPanel: View {
        let data: ChartData
        let showsDate: Bool
        let emptyTitle: String
        let emptyMessage: String

        @State private var selectedTimestamp: Date?
        @Environment(\.isScreenshotExport) private var isScreenshotExport

        var body: some View {
            if data.plotPoints.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "chart.xyaxis.line",
                    description: Text(emptyMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }

        private var chart: some View {
            let selected = selectedTimestamp.flatMap { nearestTimestamp(to: $0) }
            let totalPoints = data.plotPoints.filter { $0.series == "Total" }

            return Chart {
                ForEach(totalPoints) { point in
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Power", point.power),
                        series: .value("Segment", "wash-\(point.segment)"),
                        stacking: .unstacked
                    )
                    .foregroundStyle(Color.primary.opacity(0.07))
                    .interpolationMethod(.linear)
                }

                ForEach(data.plotPoints) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Power", point.power),
                        series: .value("Segment", "\(point.series)-\(point.segment)")
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(StrokeStyle(
                        lineWidth: point.series == "Total" ? 2 : 1.5,
                        lineCap: .round,
                        lineJoin: .round
                    ))
                    .interpolationMethod(.linear)
                }

                if let selected {
                    let selectedPoints = points(at: selected)
                    RuleMark(x: .value("Selected", selected))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(
                            position: .top,
                            spacing: 0,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            selectionCallout(selectedPoints, at: selected)
                        }

                    ForEach(selectedPoints) { point in
                        PointMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Power", point.power)
                        )
                        .foregroundStyle(by: .value("Series", point.series))
                        .symbolSize(48)
                    }
                }
            }
            .chartForegroundStyleScale([
                "Total": Color.primary,
                "C1": PortPalette.color(1),
                "C2": PortPalette.color(2),
                "C3": PortPalette.color(3)
            ])
            .chartYScale(domain: 0...data.yMax)
            .modifier(OptionalXDomain(domain: data.domain))
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxisLabel("W")
            .chartLegend(position: .top, alignment: .leading, spacing: 10)
            .chartXSelection(value: isScreenshotExport ? .constant(nil) : $selectedTimestamp)
        }

        private func selectionCallout(_ selected: [ChartPoint], at timestamp: Date) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(showsDate
                     ? timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
                     : timestamp.formatted(.dateTime.hour().minute().second()))
                    .font(.caption.weight(.semibold))
                ForEach(selected) { point in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(HistoryView.seriesColor(point.series))
                            .frame(width: 7, height: 7)
                        Text(point.series)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 10)
                        Text("\(AppModel.compactWatts(point.power)) W")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(minWidth: 112)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }

        private func nearestTimestamp(to selected: Date) -> Date? {
            guard let nearest = data.points.min(by: {
                abs($0.timestamp.timeIntervalSince(selected)) < abs($1.timestamp.timeIntervalSince(selected))
            })?.timestamp else {
                return nil
            }
            guard abs(nearest.timeIntervalSince(selected)) <= HistoryView.maxConnectableGap else {
                return nil
            }
            return nearest
        }

        private func points(at timestamp: Date) -> [ChartPoint] {
            data.points
                .filter { $0.timestamp == timestamp }
                .sorted { HistoryView.seriesIndex($0.series) < HistoryView.seriesIndex($1.series) }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(source == .charger
                 ? "The charger's own recent curve, read once per connection."
                 : "Readings older than an hour are averaged over 30 seconds.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Export CSV…") { exportCSV() }
                .disabled(history.samples.isEmpty)
            Button("Clear History…", role: .destructive) { confirmClear = true }
                .disabled(history.samples.isEmpty)
        }
    }

    private func screenshotSegments(_ titles: [String], selected: String, width: CGFloat) -> some View {
        HStack(spacing: 1) {
            ForEach(titles, id: \.self) { title in
                Text(title)
                    .font(.subheadline.weight(title == selected ? .semibold : .regular))
                    .padding(.vertical, 4)
                    .frame(width: width)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(title == selected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                            .shadow(color: .black.opacity(title == selected ? 0.12 : 0), radius: 1, y: 0.5)
                    )
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: Helpers

    private static func seriesColor(_ series: String) -> Color {
        switch series {
        case "Total": return .primary
        case "C1": return PortPalette.color(1)
        case "C2": return PortPalette.color(2)
        case "C3": return PortPalette.color(3)
        default: return .secondary
        }
    }

    private static func seriesIndex(_ series: String) -> Int {
        seriesOrder.firstIndex(of: series) ?? seriesOrder.count
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "\(total)s"
    }

    private static func segmented(_ points: [ChartPoint]) -> [ChartPoint] {
        var result: [ChartPoint] = []
        for seriesName in seriesOrder {
            let seriesPoints = points
                .filter { $0.series == seriesName }
                .sorted { $0.timestamp < $1.timestamp }
            var segment = 0
            var previous: Date?
            for point in seriesPoints {
                if let previous, point.timestamp.timeIntervalSince(previous) > maxConnectableGap {
                    segment += 1
                }
                result.append(ChartPoint(
                    id: point.id,
                    timestamp: point.timestamp,
                    series: point.series,
                    power: point.power,
                    segment: segment
                ))
                previous = point.timestamp
            }
        }
        // Preserve any unexpected series names not in seriesOrder.
        let known = Set(seriesOrder)
        let extras = points.filter { !known.contains($0.series) }
        if !extras.isEmpty {
            result.append(contentsOf: extras)
        }
        return result
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "anker-power-history.csv"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? history.csvString().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Pins the x axis to the selected range so a short recording is not stretched across it.
private struct OptionalXDomain: ViewModifier {
    let domain: ClosedRange<Date>?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let domain {
            content.chartXScale(domain: domain)
        } else {
            content
        }
    }
}

#Preview("History") {
    HistoryView(model: PreviewSample.connectedModel())
        .frame(width: 760, height: 520)
}
