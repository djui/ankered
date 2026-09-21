import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var samples: [PowerHistorySample] = []

    private let historyURL: URL?
    private var saveWorkItem: DispatchWorkItem?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("AnkerPower", isDirectory: true)
        historyURL = folder.appendingPathComponent("power-history.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    init(persist: Bool, samples: [PowerHistorySample] = []) {
        if persist {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let folder = support.appendingPathComponent("AnkerPower", isDirectory: true)
            historyURL = folder.appendingPathComponent("power-history.json")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            self.samples = samples
            if samples.isEmpty {
                load()
            }
        } else {
            historyURL = nil
            self.samples = samples
        }
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

    func csvString() -> String {
        var lines = ["timestamp,total_w,c1_w,c2_w,c3_w"]
        let formatter = ISO8601DateFormatter()
        for sample in samples {
            lines.append([
                formatter.string(from: sample.timestamp),
                String(format: "%.2f", sample.total),
                String(format: "%.2f", sample.port1),
                String(format: "%.2f", sample.port2),
                String(format: "%.2f", sample.port3)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
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
        guard let historyURL,
              let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([PowerHistorySample].self, from: data) else { return }
        samples = decoded
        trim()
    }

    private func scheduleSave() {
        guard let historyURL else { return }
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

struct ScreensaverSlot: Equatable, Identifiable, Sendable {
    var pictureID: UInt32
    var hash: UInt32
    var jpeg: Data
    var createdAt: Date

    var id: UInt32 { pictureID }
    var reportedID: UInt16 { UInt16(truncatingIfNeeded: pictureID) }
}

@MainActor
final class ScreensaverStore: ObservableObject {
    static let slotCount = ScreensaverImage.slotCount

    @Published private(set) var slots: [ScreensaverSlot] = []

    private let catalogURL: URL?
    private let imagesFolder: URL?

    init() {
        let paths = Self.supportPaths()
        catalogURL = paths.catalog
        imagesFolder = paths.images
        try? FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.images, withIntermediateDirectories: true)
        load()
    }

    init(persist: Bool, slots: [ScreensaverSlot] = []) {
        if persist {
            let paths = Self.supportPaths()
            catalogURL = paths.catalog
            imagesFolder = paths.images
            try? FileManager.default.createDirectory(at: paths.folder, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: paths.images, withIntermediateDirectories: true)
            self.slots = slots
            if slots.isEmpty {
                load()
            }
        } else {
            catalogURL = nil
            imagesFolder = nil
            self.slots = slots
        }
    }

    var isFull: Bool { slots.count >= Self.slotCount }
    var oldest: ScreensaverSlot? { slots.min(by: { $0.createdAt < $1.createdAt }) }

    func slot(reportedID: UInt16?) -> ScreensaverSlot? {
        guard let reportedID else { return nil }
        return slots.first { $0.reportedID == reportedID }
    }

    func add(_ plan: ScreensaverImage.Plan) {
        let slot = ScreensaverSlot(
            pictureID: plan.pictureID,
            hash: plan.hash,
            jpeg: plan.jpeg,
            createdAt: Date()
        )
        let removed = slots.filter { $0.pictureID == slot.pictureID || $0.reportedID == slot.reportedID }
        slots.removeAll { $0.pictureID == slot.pictureID || $0.reportedID == slot.reportedID }
        if slots.count >= Self.slotCount, let oldest {
            slots.removeAll { $0.pictureID == oldest.pictureID }
            deleteImage(for: oldest.pictureID)
        }
        for previous in removed {
            if previous.pictureID != slot.pictureID {
                deleteImage(for: previous.pictureID)
            }
        }
        slots.append(slot)
        slots.sort { $0.createdAt < $1.createdAt }
        save()
    }

    private func load() {
        guard let catalogURL,
              let data = try? Data(contentsOf: catalogURL),
              let decoded = try? JSONDecoder().decode([ScreensaverCatalogEntry].self, from: data) else { return }
        slots = decoded.sorted { $0.createdAt < $1.createdAt }.prefix(Self.slotCount).compactMap { entry in
            guard let jpeg = try? Data(contentsOf: imageURL(for: entry.pictureID)) else { return nil }
            return ScreensaverSlot(
                pictureID: entry.pictureID,
                hash: entry.hash,
                jpeg: jpeg,
                createdAt: entry.createdAt
            )
        }
    }

    private func save() {
        guard let catalogURL else { return }
        let entries = slots.map {
            ScreensaverCatalogEntry(pictureID: $0.pictureID, hash: $0.hash, createdAt: $0.createdAt)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: catalogURL, options: .atomic)
        for slot in slots {
            let url = imageURL(for: slot.pictureID)
            try? slot.jpeg.write(to: url, options: .atomic)
        }
    }

    private func deleteImage(for pictureID: UInt32) {
        guard imagesFolder != nil else { return }
        try? FileManager.default.removeItem(at: imageURL(for: pictureID))
    }

    private func imageURL(for pictureID: UInt32) -> URL {
        let name = String(format: "%08x.jpg", pictureID)
        if let imagesFolder {
            return imagesFolder.appendingPathComponent(name)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    private static func supportPaths() -> (folder: URL, catalog: URL, images: URL) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("AnkerPower", isDirectory: true)
        return (
            folder,
            folder.appendingPathComponent("screensavers.json"),
            folder.appendingPathComponent("screensavers", isDirectory: true)
        )
    }
}

private struct ScreensaverCatalogEntry: Codable {
    var pictureID: UInt32
    var hash: UInt32
    var createdAt: Date
}
