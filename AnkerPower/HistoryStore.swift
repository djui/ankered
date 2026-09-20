import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var samples: [PowerHistorySample] = []

    private let historyURL: URL
    private var saveWorkItem: DispatchWorkItem?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("AnkerPower", isDirectory: true)
        historyURL = folder.appendingPathComponent("power-history.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    func append(_ telemetry: ChargerTelemetry) {
        let sample = PowerHistorySample(timestamp: telemetry.receivedAt, ports: telemetry.ports)
        if let last = samples.last, sample.timestamp.timeIntervalSince(last.timestamp) < 1 {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        trim()
        scheduleSave()
    }

    func clear() {
        samples.removeAll()
        scheduleSave()
    }

    var recordedEnergyWh: Double {
        guard samples.count > 1 else { return 0 }
        return zip(samples, samples.dropFirst()).reduce(0) { result, pair in
            let seconds = min(60, max(0, pair.1.timestamp.timeIntervalSince(pair.0.timestamp)))
            return result + ((pair.0.total + pair.1.total) / 2) * seconds / 3_600
        }
    }

    private func trim() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        samples.removeAll { $0.timestamp < cutoff }
        if samples.count > 5_000 {
            samples.removeFirst(samples.count - 5_000)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([PowerHistorySample].self, from: data) else { return }
        samples = decoded
        trim()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = samples
        let url = historyURL
        let workItem = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        saveWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: workItem)
    }
}
