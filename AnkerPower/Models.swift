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

    /// Cable, protocol, or device details mean something is plugged in, even at 0 W.
    var hasAttachedDevice: Bool {
        cableInfo != nil || chargingInfo != nil || deviceInfo != nil
    }

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
    var screensaverReportedID: UInt16? = nil

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
    var screensaverReportedID: UInt16? = nil

    var isEmpty: Bool {
        brightnessPercent == nil
            && screenTimeout == nil
            && orientation == nil
            && autoRotate == nil
            && language == nil
            && chargingMode == nil
            && customSplit == nil
            && fault == nil
            && screensaverReportedID == nil
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
        if let screensaverReportedID { next.screensaverReportedID = screensaverReportedID }
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
    /// Combined output limit of the A2687 across all three ports.
    static let capacityWatts = 160.0

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

/// Display-only hysteresis so sub-watt noise (e.g. Apple Watch 0 ↔ 0.5 W) does not flicker the UI.
enum PowerDisplayStabilizer {
    static let enterWatts = 1.0
    static let exitWatts = 0.3

    static func stabilize(previous: ChargerTelemetry, incoming: ChargerTelemetry) -> ChargerTelemetry {
        var result = incoming
        for index in result.ports.indices {
            let raw = incoming.ports[index]
            let prior = previous.ports[safe: index] ?? .inactive(raw.index)
            result.ports[index] = stabilizePort(previous: prior, incoming: raw)
        }
        return result
    }

    static func stabilizePort(previous: PortTelemetry, incoming: PortTelemetry) -> PortTelemetry {
        var port = incoming
        if incoming.power >= enterWatts {
            port.power = incoming.power
            port.isActive = true
        } else if incoming.power < exitWatts {
            port.power = 0
            port.isActive = false
            port.voltage = 0
            port.current = 0
        } else if previous.isActive {
            port.power = previous.power
            port.isActive = true
            port.voltage = previous.voltage
            port.current = previous.current
        } else {
            port.power = 0
            port.isActive = false
            port.voltage = 0
            port.current = 0
        }
        return port
    }
}

/// One port's bar in the menu bar: nothing plugged in, plugged in but idle, or a watt step from 1 to 4.
enum PortLoad: Hashable, Sendable {
    case empty
    case idle
    case charging(Int)

    /// Floors of steps 2–4, by device class: watch or slow phone, phone or iPad, laptop, fast laptop.
    static let stepWatts: [Double] = [15, 45, 90]
    /// A step holds until the reading drops 10% below its floor, so a laptop near 45 W does not flicker.
    static let holdFactor = 0.9

    static func make(_ port: PortTelemetry, previous: PortLoad) -> PortLoad {
        guard port.isActive, port.isOutputOn else {
            return port.hasAttachedDevice ? .idle : .empty
        }
        return .charging(step(watts: port.power, previous: previous.step))
    }

    static func step(watts: Double, previous: Int) -> Int {
        var step = 1
        for (offset, floor) in stepWatts.enumerated() {
            let candidate = offset + 2
            if watts >= (candidate <= previous ? floor * holdFactor : floor) {
                step = candidate
            }
        }
        return step
    }

    var step: Int {
        if case .charging(let step) = self { return step }
        return 0
    }
}

/// What the status item draws: a bar per port while connected, faint bars otherwise.
enum MenuBarGlyph: Hashable, Sendable {
    /// C1 to C3, left to right.
    case ports([PortLoad])
    /// Searching, connecting, or waiting to retry. One glyph for all of them, because the
    /// Bluetooth layer cycles through these while the charger is away.
    case noCharger
    /// Paused, or Bluetooth is off, not allowed, or not supported: faint bars with a slash.
    case unavailable

    static func make(state: ChargerConnectionState, isPaused: Bool, loads: [PortLoad]) -> MenuBarGlyph {
        if state.isConnected {
            return .ports(loads)
        }
        if isPaused {
            return .unavailable
        }
        switch state {
        case .bluetoothUnavailable(.resetting), .bluetoothUnavailable(.checking):
            return .noCharger
        case .bluetoothUnavailable:
            return .unavailable
        default:
            return .noCharger
        }
    }
}

struct ChargerIdentity: Codable, Equatable, Sendable {
    static let modelName = "Anker Prime 160W"

    var productName: String?
    var firmware: String?
    var serialNumber: String?
    var macAddress: String?

    /// The handshake's A2 field is not always a product name: some A2687 firmware reports
    /// a state word such as "Charging" there. Only trust it when it names the product.
    var displayName: String {
        guard let productName, Self.looksLikeProductName(productName) else { return Self.modelName }
        return productName
    }

    static func looksLikeProductName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["anker", "prime", "a2687"].contains { lowered.contains($0) }
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

enum BluetoothIssue: Equatable, Sendable {
    case poweredOff
    case unauthorized
    case unsupported
    case resetting
    case checking
    case unavailable

    var label: String {
        switch self {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission is required"
        case .unsupported: return "Bluetooth LE is unavailable"
        case .resetting: return "Bluetooth is resetting…"
        case .checking: return "Checking Bluetooth…"
        case .unavailable: return "Bluetooth is unavailable"
        }
    }
}

enum ChargerConnectionState: Equatable, Sendable {
    case bluetoothUnavailable(BluetoothIssue)
    case idle
    case scanning
    case connecting
    case discovering
    case negotiating
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .bluetoothUnavailable(let issue): return issue.label
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

/// What the popover says about the Bluetooth session: a short header caption plus,
/// while there is no live data, a headline, an explanation, and the one action that helps.
struct ConnectionStatus: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case live
        case pending
        case neutral
        case warning
        case critical
    }

    enum Action: Equatable, Sendable {
        case resume
        case reconnect
        case openBluetoothSettings
        case openPrivacySettings

        var title: String {
            switch self {
            case .resume: return "Resume"
            case .reconnect: return "Reconnect"
            case .openBluetoothSettings: return "Open Bluetooth Settings"
            case .openPrivacySettings: return "Open Privacy Settings"
            }
        }
    }

    var title: String
    var detail: String? = nil
    var symbol: String
    var tone: Tone
    var isWorking = false
    var headline: String
    var message: String
    var action: Action? = nil

    var caption: String {
        [title, detail].compactMap { $0 }.joined(separator: " · ")
    }

    static func make(
        state: ChargerConnectionState,
        isPaused: Bool,
        isSuspendedForSleep: Bool,
        identity: ChargerIdentity
    ) -> ConnectionStatus {
        if isSuspendedForSleep {
            return ConnectionStatus(
                title: "Paused while this Mac sleeps",
                symbol: "moon.fill",
                tone: .neutral,
                headline: "Paused while this Mac sleeps",
                message: "Anker Power reconnects when the Mac wakes."
            )
        }
        if isPaused {
            return ConnectionStatus(
                title: "Paused",
                symbol: "pause.fill",
                tone: .neutral,
                headline: "Connection paused",
                message: "The charger is free for the Anker app. Resume to see live power again.",
                action: .resume
            )
        }
        switch state {
        case .connected:
            return ConnectionStatus(
                title: "Connected",
                detail: identity.firmwareLabel,
                symbol: "bolt.fill",
                tone: .live,
                headline: "Connected",
                message: ""
            )
        case .scanning:
            return ConnectionStatus(
                title: "Searching…",
                symbol: "antenna.radiowaves.left.and.right",
                tone: .pending,
                isWorking: true,
                headline: "Looking for your charger",
                message: "Keep it powered and nearby, and disconnect it in the Anker app on your phone."
            )
        case .connecting, .discovering:
            return ConnectionStatus(
                title: "Connecting…",
                symbol: "antenna.radiowaves.left.and.right",
                tone: .pending,
                isWorking: true,
                headline: "Connecting to your charger",
                message: "This usually takes a few seconds."
            )
        case .negotiating:
            return ConnectionStatus(
                title: "Securing connection…",
                symbol: "lock.fill",
                tone: .pending,
                isWorking: true,
                headline: "Starting a secure session",
                message: "This usually takes a few seconds."
            )
        case .failed(let reason):
            let sentence = reason.hasSuffix(".") ? reason : "\(reason)."
            return ConnectionStatus(
                title: "Connection lost",
                symbol: "exclamationmark",
                tone: .warning,
                headline: "Charger not reachable",
                message: "\(sentence) Anker Power keeps retrying in the background.",
                action: .reconnect
            )
        case .bluetoothUnavailable(.poweredOff):
            return ConnectionStatus(
                title: "Bluetooth is off",
                symbol: "bolt.slash.fill",
                tone: .critical,
                headline: "Bluetooth is off",
                message: "Turn on Bluetooth to see live charging power.",
                action: .openBluetoothSettings
            )
        case .bluetoothUnavailable(.unauthorized):
            return ConnectionStatus(
                title: "Bluetooth access needed",
                symbol: "hand.raised.fill",
                tone: .critical,
                headline: "Bluetooth access needed",
                message: "Allow Anker Power under Privacy & Security › Bluetooth.",
                action: .openPrivacySettings
            )
        case .bluetoothUnavailable(let issue):
            return ConnectionStatus(
                title: issue.label,
                symbol: "bolt.slash.fill",
                tone: .warning,
                headline: issue.label,
                message: "Anker Power connects as soon as Bluetooth is available."
            )
        case .idle:
            return ConnectionStatus(
                title: "Not connected",
                symbol: "bolt.slash.fill",
                tone: .neutral,
                headline: "Not connected",
                message: "Connect to see live charging power.",
                action: .reconnect
            )
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

    init(id: UUID = UUID(), timestamp: Date, port1: Double, port2: Double, port3: Double) {
        self.id = id
        self.timestamp = timestamp
        self.port1 = port1
        self.port2 = port2
        self.port3 = port3
    }

    var total: Double { port1 + port2 + port3 }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, port1, port2, port3
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Older history files carry a per-sample UUID; it is only a view identity.
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        port1 = try container.decode(Double.self, forKey: .port1)
        port2 = try container.decode(Double.self, forKey: .port2)
        port3 = try container.decode(Double.self, forKey: .port3)
    }

    /// Stores centiwatt precision and no UUID, which keeps the file about half the size.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(Self.centiwatts(port1), forKey: .port1)
        try container.encode(Self.centiwatts(port2), forKey: .port2)
        try container.encode(Self.centiwatts(port3), forKey: .port3)
    }

    private static func centiwatts(_ watts: Double) -> Double {
        (watts * 100).rounded() / 100
    }
}

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

enum ScreensaverTransferProgress: Equatable, Sendable {
    case idle
    case selecting
    case uploading(current: Int, total: Int)
    case verifying
    case succeeded
    case failed(String)

    var label: String? {
        switch self {
        case .idle, .succeeded:
            return nil
        case .selecting:
            return "Selecting screensaver…"
        case .uploading(let current, let total):
            return "Sending image \(current)/\(total)…"
        case .verifying:
            return "Confirming screensaver…"
        case .failed(let message):
            return message
        }
    }

    var uploadCounts: (current: Int, total: Int)? {
        if case .uploading(let current, let total) = self, total > 0 {
            return (current, total)
        }
        return nil
    }
}

enum ScreensaverTransferError: Error, Equatable, LocalizedError {
    case emptyImage
    case unreadableImage
    case tooManyChunks(Int)
    case sessionBusy
    case disconnected
    case timeout
    case rejected(UInt8)
    case pixelsMissing
    case overrun
    case indexMismatch(expected: Int, got: Int?)
    case verifyMismatch(expected: UInt16, got: UInt16?)
    case notReady

    var errorDescription: String? {
        switch self {
        case .emptyImage: return "The screensaver image is empty"
        case .unreadableImage: return "Could not read that image"
        case .tooManyChunks(let count): return "Screensaver is too large (\(count) chunks)"
        case .sessionBusy: return "A screensaver transfer is already running"
        case .disconnected: return "The charger disconnected during the screensaver transfer"
        case .timeout: return "The charger did not acknowledge the screensaver transfer"
        case .rejected(let status): return "The charger rejected the screensaver command (status \(status))"
        case .pixelsMissing: return "That picture is not stored on the charger"
        case .overrun: return "Screensaver transfer overran the charger; wait and try again"
        case .indexMismatch(let expected, let got):
            if let got {
                return "Screensaver chunk ACK expected \(expected), got \(got)"
            }
            return "Screensaver chunk ACK did not report index \(expected)"
        case .verifyMismatch(let expected, let got):
            if let got {
                return "Charger still reports picture \(got), expected \(expected)"
            }
            return "Charger did not confirm picture \(expected)"
        case .notReady: return "Screensaver control needs the modern Bluetooth session"
        }
    }
}
