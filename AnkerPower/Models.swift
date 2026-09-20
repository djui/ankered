import Foundation

struct PortTelemetry: Codable, Equatable, Identifiable, Sendable {
    let index: Int
    var isActive: Bool
    var voltage: Double
    var current: Double
    var power: Double
    var cableInfo: String? = nil
    var chargingInfo: String? = nil
    var deviceInfo: String? = nil
    var isOutputEnabled: Bool? = nil
    var shutdownDurationSeconds: UInt32? = nil
    var shutdownEndsAt: Date? = nil

    var id: Int { index }

    var isOutputOn: Bool { isOutputEnabled ?? true }

    func shutdownRemaining(at date: Date = Date()) -> TimeInterval? {
        guard let shutdownEndsAt, shutdownEndsAt > date else { return nil }
        return shutdownEndsAt.timeIntervalSince(date)
    }

    static func inactive(_ index: Int) -> PortTelemetry {
        PortTelemetry(index: index, isActive: false, voltage: 0, current: 0, power: 0)
    }
}

enum ChargerChargingMode: Equatable, Sendable {
    case ai2
    case c1Priority
    case dualLaptop
    case custom

    var label: String {
        switch self {
        case .ai2: return "AI 2.0"
        case .c1Priority: return "C1 Priority"
        case .dualLaptop: return "Dual Laptop"
        case .custom: return "Custom"
        }
    }
}

struct ChargerTelemetry: Equatable, Sendable {
    var ports: [PortTelemetry]
    var receivedAt: Date
    var chargingMode: ChargerChargingMode? = nil

    var totalPower: Double {
        ports.reduce(0) { $0 + $1.power }
    }

    static let empty = ChargerTelemetry(
        ports: (1...3).map(PortTelemetry.inactive),
        receivedAt: .distantPast
    )
}

struct ChargerIdentity: Equatable, Sendable {
    var productName: String?
    var firmware: String?
    var serialNumber: String?
    var macAddress: String?

    var displayName: String {
        guard let productName, !productName.isEmpty else { return "Anker Prime 160W" }
        return productName
    }
}

enum ChargerConnectionState: Equatable, Sendable {
    case bluetoothUnavailable(String)
    case idle
    case scanning
    case connecting
    case discovering
    case negotiating
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .bluetoothUnavailable(let reason): return reason
        case .idle: return "Disconnected"
        case .scanning: return "Looking for Anker Prime 160W…"
        case .connecting: return "Connecting…"
        case .discovering: return "Discovering charger…"
        case .negotiating: return "Starting secure session…"
        case .connected: return "Connected: Anker Prime 160W"
        case .failed(let message): return message
        }
    }

    var isConnected: Bool {
        self == .connected
    }
}

struct PowerHistorySample: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var port1: Double
    var port2: Double
    var port3: Double

    init(id: UUID = UUID(), timestamp: Date, ports: [PortTelemetry]) {
        self.id = id
        self.timestamp = timestamp
        self.port1 = ports[safe: 0]?.power ?? 0
        self.port2 = ports[safe: 1]?.power ?? 0
        self.port3 = ports[safe: 2]?.power ?? 0
    }

    var total: Double { port1 + port2 + port3 }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
