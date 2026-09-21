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

enum ChargerChargingMode: Equatable, Sendable, CaseIterable {
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

    var protocolValue: UInt8 {
        switch self {
        case .ai2: return 0
        case .c1Priority, .dualLaptop: return 1
        case .custom: return 4
        }
    }

    var fixedAllocationValue: UInt8? {
        switch self {
        case .dualLaptop: return 0
        case .c1Priority: return 1
        default: return nil
        }
    }
}

enum ChargerFault: Equatable, Sendable {
    case none
    case overTemperature
    case portAbnormality
    case other(UInt32)

    var banner: String? {
        switch self {
        case .none:
            return nil
        case .overTemperature:
            return "Over-temperature protection is active"
        case .portAbnormality:
            return "Port abnormality detected — unplug the device"
        case .other(let code):
            return "Charger reported a fault (code \(code))"
        }
    }

    static func from(errorCode: UInt32) -> ChargerFault {
        switch errorCode {
        case 0: return .none
        case 1: return .overTemperature
        case 2: return .portAbnormality
        default: return .other(errorCode)
        }
    }
}

enum ChargerScreenTimeout: UInt8, Equatable, Sendable, CaseIterable {
    case thirtySeconds = 0
    case oneMinute = 1
    case fiveMinutes = 2
    case thirtyMinutes = 3
    case twelveHours = 4

    var label: String {
        switch self {
        case .thirtySeconds: return "30 seconds"
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .thirtyMinutes: return "30 minutes"
        case .twelveHours: return "12 hours"
        }
    }
}

enum ChargerLanguage: UInt8, Equatable, Sendable, CaseIterable {
    case english = 0
    case chinese = 1
    case japanese = 2
    case german = 3

    var label: String {
        switch self {
        case .english: return "English"
        case .chinese: return "Chinese"
        case .japanese: return "Japanese"
        case .german: return "German"
        }
    }
}

enum ChargerOrientation: UInt8, Equatable, Sendable, CaseIterable {
    case up = 0
    case left = 1
    case down = 2
    case right = 3

    var label: String {
        switch self {
        case .up: return "Up"
        case .left: return "Left"
        case .down: return "Down"
        case .right: return "Right"
        }
    }
}

struct CustomChargeSplit: Equatable, Sendable {
    var profileNumber: UInt8 = 0
    var autoExit: Bool = false
    var portWatts: [UInt8] = [0, 0, 0]
    var protocolMasks: [UInt8] = [0x3B, 0x3B, 0x3B]

    var c1: UInt8 { portWatts[safe: 0] ?? 0 }
    var c2: UInt8 { portWatts[safe: 1] ?? 0 }
    var c3: UInt8 { portWatts[safe: 2] ?? 0 }

    var totalWatts: Int { Int(c1) + Int(c2) + Int(c3) }

    var validationError: String? {
        for (index, watts) in portWatts.prefix(3).enumerated() {
            if watts != 0 && watts < 15 {
                return "C\(index + 1) must be 0 W or at least 15 W"
            }
            if watts > 140 {
                return "C\(index + 1) cannot exceed 140 W"
            }
        }
        if totalWatts > 160 {
            return "Custom split cannot exceed 160 W"
        }
        return nil
    }
}

struct ChargerSettings: Equatable, Sendable {
    var brightnessPercent: Int? = nil
    var screenTimeout: ChargerScreenTimeout? = nil
    var orientation: ChargerOrientation? = nil
    var autoRotate: Bool? = nil
    var language: ChargerLanguage? = nil
    var customSplit: CustomChargeSplit? = nil
    var fault: ChargerFault = .none

    static let empty = ChargerSettings()
}

struct ChargerSettingsUpdate: Equatable, Sendable {
    var brightnessPercent: Int? = nil
    var screenTimeout: ChargerScreenTimeout? = nil
    var orientation: ChargerOrientation? = nil
    var autoRotate: Bool? = nil
    var language: ChargerLanguage? = nil
    var chargingMode: ChargerChargingMode? = nil
    var customSplit: CustomChargeSplit? = nil
    var fault: ChargerFault? = nil

    var isEmpty: Bool {
        brightnessPercent == nil
            && screenTimeout == nil
            && orientation == nil
            && autoRotate == nil
            && language == nil
            && chargingMode == nil
            && customSplit == nil
            && fault == nil
    }

    func merging(into settings: ChargerSettings) -> ChargerSettings {
        var next = settings
        if let brightnessPercent { next.brightnessPercent = brightnessPercent }
        if let screenTimeout { next.screenTimeout = screenTimeout }
        if let orientation { next.orientation = orientation }
        if let autoRotate { next.autoRotate = autoRotate }
        if let language { next.language = language }
        if let customSplit { next.customSplit = customSplit }
        if let fault { next.fault = fault }
        return next
    }
}

struct PortHistorySeries: Equatable, Sendable, Identifiable {
    var index: Int
    var voltages: [Double]
    var currents: [Double]

    var id: Int { index }

    var powers: [Double] {
        zip(voltages, currents).map { $0 * $1 }
    }
}

struct ChargerPortHistory: Equatable, Sendable {
    var capturedAt: Date
    var ports: [PortHistorySeries]

    var sampleCount: Int {
        ports.map(\.voltages.count).max() ?? 0
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

struct ChargerIdentity: Codable, Equatable, Sendable {
    var productName: String?
    var firmware: String?
    var serialNumber: String?
    var macAddress: String?

    var displayName: String {
        guard let productName, !productName.isEmpty else { return "Anker Prime 160W" }
        return productName
    }

    var firmwareLabel: String? {
        guard let firmware, !firmware.isEmpty else { return nil }
        return firmware.hasPrefix("v") || firmware.hasPrefix("V") ? firmware : "v\(firmware)"
    }

    var isEmpty: Bool {
        productName == nil && firmware == nil && serialNumber == nil && macAddress == nil
    }

    func merging(_ other: ChargerIdentity) -> ChargerIdentity {
        var next = self
        if let productName = other.productName { next.productName = productName }
        if let firmware = other.firmware { next.firmware = firmware }
        if let serialNumber = other.serialNumber { next.serialNumber = serialNumber }
        if let macAddress = other.macAddress { next.macAddress = macAddress }
        return next
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

    var isConnectingActivity: Bool {
        switch self {
        case .scanning, .connecting, .discovering, .negotiating, .connected:
            return true
        case .bluetoothUnavailable, .idle, .failed:
            return false
        }
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
