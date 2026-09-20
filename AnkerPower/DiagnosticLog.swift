import Foundation
import OSLog

struct DiagnosticEntry: Identifiable, Equatable, Sendable {
    enum Level: String, Sendable {
        case info = "INFO"
        case success = "OK"
        case warning = "WARN"
        case error = "ERROR"
    }

    let id: UUID
    let timestamp: Date
    let level: Level
    let category: String
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: Level = .info,
        category: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

@MainActor
final class DiagnosticLog: ObservableObject {
    @Published private(set) var entries: [DiagnosticEntry] = []

    private let logger = Logger(subsystem: "com.djui.AnkerPower", category: "Bluetooth")
    private let maximumEntryCount = 500

    func record(
        _ message: String,
        level: DiagnosticEntry.Level = .info,
        category: String = "Bluetooth"
    ) {
        let entry = DiagnosticEntry(level: level, category: category, message: message)
        entries.append(entry)
        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
        logger.log(level: osLogType(for: level), "[\(category, privacy: .public)] \(message, privacy: .public)")
    }

    func clear() {
        entries.removeAll()
        record("Diagnostics cleared", category: "App")
    }

    var exportedText: String {
        entries.map { entry in
            "\(Self.timestampFormatter.string(from: entry.timestamp)) [\(entry.level.rawValue)] [\(entry.category)] \(entry.message)"
        }
        .joined(separator: "\n")
    }

    private func osLogType(for level: DiagnosticEntry.Level) -> OSLogType {
        switch level {
        case .info, .success: return .info
        case .warning: return .default
        case .error: return .error
        }
    }

    nonisolated private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
