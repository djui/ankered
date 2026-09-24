import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var history: HistoryStore
    @State private var range: HistoryRange = .hour
    @State private var source: HistorySource = .mac
    @State private var selectedTimestamp: Date?
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

    private var visibleSamples: [PowerHistorySample] {
        let cutoff = Date().addingTimeInterval(-range.interval)
        return history.samples.filter { $0.timestamp >= cutoff }
    }

    private var macPoints: [ChartPoint] {
        visibleSamples.flatMap { sample in
            [
                ChartPoint(id: "\(sample.id)-total", timestamp: sample.timestamp, series: "Total", power: sample.total),
                ChartPoint(id: "\(sample.id)-c1", timestamp: sample.timestamp, series: "C1", power: sample.port1),
                ChartPoint(id: "\(sample.id)-c2", timestamp: sample.timestamp, series: "C2", power: sample.port2),
                ChartPoint(id: "\(sample.id)-c3", timestamp: sample.timestamp, series: "C3", power: sample.port3)
            ]
        }
    }

    private var chargerPoints: [ChartPoint] {
        guard let chargerHistory = model.chargerHistory else { return [] }
        return chargerHistory.ports.flatMap { port in
            port.powers.enumerated().map { index, power in
                ChartPoint(
                    id: "charger-\(port.index)-\(index)",
                    timestamp: chargerHistory.capturedAt.addingTimeInterval(TimeInterval(index)),
                    series: "C\(port.index)",
                    power: power
                )
            }
        }
    }

    private var points: [ChartPoint] {
        source == .charger ? chargerPoints : macPoints
    }

    private var plotPoints: [ChartPoint] {
        Self.segmented(points)
    }

    private var yDomainMax: Double {
        max(plotPoints.map(\.power).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Charging history")
                        .font(.title2.bold())
                    Text(source == .charger
                         ? "Curve captured from the charger this session."
                         : "Up to 24 hours are stored locally on this Mac.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if model.chargerHistory != nil {
                        if isScreenshotExport {
                            screenshotSourceControl
                        } else {
                            Picker("", selection: $source) {
                                ForEach(HistorySource.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 180)
                        }
                    }
                    if source == .mac {
                        if isScreenshotExport {
                            screenshotRangeControl
                        } else {
                            Picker("", selection: $range) {
                                ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityLabel("History range")
                            .frame(width: 250)
                        }
                    }
                }
            }

            if plotPoints.isEmpty {
                ContentUnavailableView(
                    source == .charger ? "No charger curve yet" : "No charging data yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text(
                        source == .charger
                            ? "The charger-side history is requested once after connecting."
                            : "Connect to the charger and the graph will update automatically."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    ForEach(plotPoints) { point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Power", point.power),
                            series: .value("Segment", "\(point.series)-\(point.segment)")
                        )
                        .foregroundStyle(by: .value("Series", point.series))
                        .lineStyle(StrokeStyle(lineWidth: point.series == "Total" ? 2.5 : 1.25))
                        .interpolationMethod(.linear)
                    }

                    if let selectedTimestamp,
                       let nearest = nearestTimestamp(to: selectedTimestamp) {
                        RuleMark(x: .value("Selected", nearest))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(
                                position: .top,
                                spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                selectionCallout(at: nearest)
                            }

                        ForEach(points(at: nearest)) { point in
                            PointMark(
                                x: .value("Time", point.timestamp),
                                y: .value("Power", point.power)
                            )
                            .foregroundStyle(by: .value("Series", point.series))
                            .symbolSize(40)
                        }
                    }
                }
                .chartYAxisLabel("Watts")
                .chartYScale(domain: 0...yDomainMax)
                .chartForegroundStyleScale([
                    "Total": .yellow,
                    "C1": .blue,
                    "C2": .green,
                    "C3": .orange
                ])
                .chartXSelection(value: isScreenshotExport ? .constant(nil) : $selectedTimestamp)
            }

            HStack {
                Label(
                    "\(history.recordedEnergyWh.formatted(.number.precision(.fractionLength(1)))) Wh recorded",
                    systemImage: "bolt.circle"
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button("Export CSV") { exportCSV() }
                    .disabled(history.samples.isEmpty)
                Button("Clear History", role: .destructive) { history.clear() }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 380)
    }

    @ViewBuilder
    private func selectionCallout(at timestamp: Date) -> some View {
        let selected = points(at: timestamp)
        VStack(alignment: .leading, spacing: 2) {
            Text(formatSelectionTime(timestamp))
                .font(.caption.weight(.semibold))
            ForEach(selected) { point in
                HStack(spacing: 6) {
                    Circle()
                        .fill(seriesColor(point.series))
                        .frame(width: 6, height: 6)
                    Text(point.series)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(AppModel.compactWatts(point.power)) W")
                        .monospacedDigit()
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var screenshotSourceControl: some View {
        HStack(spacing: 1) {
            ForEach(HistorySource.allCases) { option in
                Text(option.rawValue)
                    .font(.caption.weight(option == source ? .semibold : .regular))
                    .padding(.vertical, 6)
                    .frame(width: 88)
                    .background(option == source ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            }
        }
        .padding(2)
        .background(Color(nsColor: .separatorColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private var screenshotRangeControl: some View {
        HStack(spacing: 1) {
            ForEach(HistoryRange.allCases) { option in
                Text(option.rawValue)
                    .font(.caption.weight(option == range ? .semibold : .regular))
                    .padding(.vertical, 6)
                    .frame(width: 80)
                    .background(option == range ? Color(nsColor: .controlBackgroundColor) : Color.clear)
            }
        }
        .padding(2)
        .background(Color(nsColor: .separatorColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }

    private func nearestTimestamp(to selected: Date) -> Date? {
        let timestamps = Set(points.map(\.timestamp))
        guard let nearest = timestamps.min(by: {
            abs($0.timeIntervalSince(selected)) < abs($1.timeIntervalSince(selected))
        }) else {
            return nil
        }
        guard abs(nearest.timeIntervalSince(selected)) <= Self.maxConnectableGap else {
            return nil
        }
        return nearest
    }

    private func points(at timestamp: Date) -> [ChartPoint] {
        let matched = points.filter { $0.timestamp == timestamp }
        return matched.sorted {
            seriesIndex($0.series) < seriesIndex($1.series)
        }
    }

    private func formatSelectionTime(_ date: Date) -> String {
        if source == .charger || range == .hour {
            return date.formatted(.dateTime.hour().minute().second())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }

    private func seriesColor(_ series: String) -> Color {
        switch series {
        case "Total": return .yellow
        case "C1": return .blue
        case "C2": return .green
        case "C3": return .orange
        default: return .secondary
        }
    }

    private func seriesIndex(_ series: String) -> Int {
        Self.seriesOrder.firstIndex(of: series) ?? Self.seriesOrder.count
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

#Preview("History") {
    HistoryView(model: PreviewSample.connectedModel())
        .frame(width: 760, height: 460)
}
