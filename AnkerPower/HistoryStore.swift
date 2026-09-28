import AppKit
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    static let retention: TimeInterval = 24 * 60 * 60
    /// Samples newer than this keep the charger's own cadence (about every 3 s).
    static let fullResolutionWindow: TimeInterval = 60 * 60
    /// Older samples are averaged into buckets this long, so 24 hours fit in a few thousand points.
    static let compactedBucket: TimeInterval = 30
    /// Longest the file on disk may lag behind memory. Quit and sleep flush immediately.
    static let saveInterval: TimeInterval = 60
    private static let maximumSampleCount = 10_000
    /// Serializes writes so a flush at quit cannot be overtaken by an older periodic save.
    nonisolated private static let writeQueue = DispatchQueue(label: "com.djui.AnkerPower.history-write", qos: .utility)

    @Published private(set) var samples: [PowerHistorySample] = []

    private let historyURL: URL?
    private var saveWorkItem: DispatchWorkItem?
    private var lastCompaction = Date.distantPast
    private var terminationObserver: (any NSObjectProtocol)?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("AnkerPower", isDirectory: true)
        historyURL = folder.appendingPathComponent("power-history.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        observeTermination()
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
            observeTermination()
        } else {
            historyURL = nil
            self.samples = samples
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func append(_ telemetry: ChargerTelemetry) {
        let sample = PowerHistorySample(timestamp: telemetry.receivedAt, ports: telemetry.ports)
        guard Self.isPlausible(sample) else { return }
        if let last = samples.last, sample.timestamp.timeIntervalSince(last.timestamp) < 1 {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
        let now = Date()
        if now.timeIntervalSince(lastCompaction) >= 60 {
            compact(now: now)
        }
        trim(now: now)
        scheduleSave()
    }

    func clear() {
        samples.removeAll()
        flush()
    }

    /// Writes pending samples now instead of waiting for the next periodic save.
    func flush() {
        guard let historyURL else { return }
        saveWorkItem?.cancel()
        saveWorkItem = nil
        let snapshot = samples
        Self.writeQueue.sync {
            Self.write(snapshot, to: historyURL)
        }
    }

    /// Averages samples older than `fullResolutionWindow` into `compactedBucket` slots.
    /// The cutoff snaps to a bucket boundary so each bucket is averaged once, when it is
    /// complete; later passes find a single sample per bucket and leave it alone.
    func compact(now: Date = Date()) {
        lastCompaction = now
        let horizon = now.addingTimeInterval(-Self.fullResolutionWindow).timeIntervalSinceReferenceDate
        let cutoff = Date(
            timeIntervalSinceReferenceDate: (horizon / Self.compactedBucket).rounded(.down) * Self.compactedBucket
        )
        let splitIndex = samples.firstIndex { $0.timestamp >= cutoff } ?? samples.count
        guard splitIndex > 1 else { return }

        var compacted: [PowerHistorySample] = []
        compacted.reserveCapacity(splitIndex / 4)
        var bucket: [PowerHistorySample] = []
        var bucketKey: Int?

        func closeBucket() {
            guard let first = bucket.first else { return }
            if bucket.count == 1 {
                compacted.append(first)
            } else {
                let count = Double(bucket.count)
                let meanOffset = bucket.reduce(0) { $0 + $1.timestamp.timeIntervalSince(first.timestamp) } / count
                compacted.append(PowerHistorySample(
                    timestamp: first.timestamp.addingTimeInterval(meanOffset),
                    port1: bucket.reduce(0) { $0 + $1.port1 } / count,
                    port2: bucket.reduce(0) { $0 + $1.port2 } / count,
                    port3: bucket.reduce(0) { $0 + $1.port3 } / count
                ))
            }
            bucket.removeAll(keepingCapacity: true)
        }

        for sample in samples[..<splitIndex] {
            let key = Int((sample.timestamp.timeIntervalSinceReferenceDate / Self.compactedBucket).rounded(.down))
            if key != bucketKey {
                closeBucket()
                bucketKey = key
            }
            bucket.append(sample)
        }
        closeBucket()

        guard compacted.count < splitIndex else { return }
        samples = compacted + samples[splitIndex...]
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

    func summary(since start: Date) -> HistorySummary {
        HistorySummary.compute(
            samples
                .filter { $0.timestamp >= start }
                .map { (timestamp: $0.timestamp, watts: $0.total) }
        )
    }

    private static let maximumPortWatts = 200.0

    private static func isPlausible(_ sample: PowerHistorySample) -> Bool {
        [sample.port1, sample.port2, sample.port3].allSatisfy { $0 <= maximumPortWatts }
    }

    private func trim(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        if let first = samples.first, first.timestamp < cutoff {
            samples.removeAll { $0.timestamp < cutoff }
        }
        if samples.count > Self.maximumSampleCount {
            samples.removeFirst(samples.count - Self.maximumSampleCount)
        }
    }

    private func load() {
        guard let historyURL,
              let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([PowerHistorySample].self, from: data) else { return }
        samples = decoded.filter(Self.isPlausible)
        compact()
        trim()
        if samples.count != decoded.count {
            scheduleSave()
        }
    }

    /// Saves at most once per `saveInterval`. The old per-sample save rewrote the whole
    /// file every few seconds, which added up to gigabytes of disk writes a day.
    private func scheduleSave() {
        guard let historyURL, saveWorkItem == nil else { return }
        let url = historyURL
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveWorkItem = nil
                let snapshot = self.samples
                Self.writeQueue.async {
                    Self.write(snapshot, to: url)
                }
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveInterval, execute: workItem)
    }

    nonisolated private static func write(_ samples: [PowerHistorySample], to url: URL) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func observeTermination() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }
    }
}

/// Figures for the history window's stat tiles, integrated over time rather than averaged
/// per sample, so irregular sample spacing does not skew them.
struct HistorySummary: Equatable, Sendable {
    /// Readings further apart than this are treated as a gap (disconnected or asleep).
    static let maximumStep: TimeInterval = 60

    var peakWatts: Double
    var averageWatts: Double
    var energyWh: Double
    var chargingDuration: TimeInterval

    static let empty = HistorySummary(peakWatts: 0, averageWatts: 0, energyWh: 0, chargingDuration: 0)

    /// - Parameter readings: total watts over time, sorted by timestamp.
    static func compute(_ readings: [(timestamp: Date, watts: Double)]) -> HistorySummary {
        guard let first = readings.first else { return .empty }
        var energyWattSeconds = 0.0
        var coveredSeconds = 0.0
        var chargingSeconds = 0.0
        var peak = first.watts
        for (previous, next) in zip(readings, readings.dropFirst()) {
            peak = max(peak, next.watts)
            let step = next.timestamp.timeIntervalSince(previous.timestamp)
            guard step > 0, step <= maximumStep else { continue }
            energyWattSeconds += (previous.watts + next.watts) / 2 * step
            coveredSeconds += step
            if previous.watts > 1, next.watts > 1 {
                chargingSeconds += step
            }
        }
        return HistorySummary(
            peakWatts: peak,
            averageWatts: coveredSeconds > 0 ? energyWattSeconds / coveredSeconds : first.watts,
            energyWh: energyWattSeconds / 3_600,
            chargingDuration: chargingSeconds
        )
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
