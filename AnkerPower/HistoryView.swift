import Charts
import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var history: HistoryStore
    @State private var range: HistoryRange = .hour

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

    private struct ChartPoint: Identifiable {
        let id: String
        let timestamp: Date
        let series: String
        let power: Double
    }

    private var visibleSamples: [PowerHistorySample] {
        let cutoff = Date().addingTimeInterval(-range.interval)
        return history.samples.filter { $0.timestamp >= cutoff }
    }

    private var points: [ChartPoint] {
        visibleSamples.flatMap { sample in
            [
                ChartPoint(id: "\(sample.id)-total", timestamp: sample.timestamp, series: "Total", power: sample.total),
                ChartPoint(id: "\(sample.id)-c1", timestamp: sample.timestamp, series: "C1", power: sample.port1),
                ChartPoint(id: "\(sample.id)-c2", timestamp: sample.timestamp, series: "C2", power: sample.port2),
                ChartPoint(id: "\(sample.id)-c3", timestamp: sample.timestamp, series: "C3", power: sample.port3)
            ]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Charging history")
                        .font(.title2.bold())
                    Text("Up to 24 hours are stored locally on this Mac.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("History range")
                .frame(width: 250)
            }

            if points.isEmpty {
                ContentUnavailableView(
                    "No charging data yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Connect to the charger and the graph will update automatically.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Power", point.power)
                    )
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(StrokeStyle(lineWidth: point.series == "Total" ? 2.5 : 1.25))
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxisLabel("Watts")
                .chartForegroundStyleScale([
                    "Total": .yellow,
                    "C1": .blue,
                    "C2": .green,
                    "C3": .orange
                ])
            }

            HStack {
                Label(
                    "\(history.recordedEnergyWh.formatted(.number.precision(.fractionLength(1)))) Wh recorded",
                    systemImage: "bolt.circle"
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button("Clear History", role: .destructive) { history.clear() }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 380)
    }
}
