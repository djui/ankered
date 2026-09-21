import Foundation

@MainActor
enum AppRuntime {
    static weak var model: AppModel?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var connectionState: ChargerConnectionState = .idle
    @Published private(set) var isPaused = false
    @Published private(set) var identity = ChargerIdentity()
    @Published private(set) var telemetry = ChargerTelemetry.empty
    @Published private(set) var settings = ChargerSettings.empty
    @Published private(set) var chargerHistory: ChargerPortHistory?
    @Published private(set) var portCommandsInFlight: Set<Int> = []
    @Published var preferences: AppPreferences

    let history: HistoryStore
    let diagnostics: DiagnosticLog

    private let bluetooth: ChargerBluetooth?
    private let previewCanControl: Bool
    private var lastLocalControlAt: [Int: Date] = [:]
    private var lastLocalSettingsAt: Date?
    private var lastChargingAt: [Int: Date] = [:]
    private var idleNotifiedPorts: Set<Int> = []

    init() {
        let diagnostics = DiagnosticLog()
        let bluetooth = ChargerBluetooth(diagnostics: diagnostics)
        let preferences = AppPreferences.shared
        self.history = HistoryStore()
        self.diagnostics = diagnostics
        self.bluetooth = bluetooth
        self.previewCanControl = false
        self.preferences = preferences
        if let stored = preferences.loadPersistedIdentity() {
            self.identity = stored
        }
        bluetooth.delegate = self
        AppRuntime.model = self
        // Creating CBCentralManager during App.init() races the Bluetooth
        // permission sheet and can leave the central stuck at `.unauthorized`.
        DispatchQueue.main.async { [bluetooth] in
            bluetooth.start()
        }
    }

    /// In-memory sample used by SwiftUI previews and screenshot export. Does not start Bluetooth.
    init(
        previewState: ChargerConnectionState,
        identity: ChargerIdentity,
        telemetry: ChargerTelemetry,
        historySamples: [PowerHistorySample] = [],
        diagnosticEntries: [DiagnosticEntry] = [],
        canControlPorts: Bool = true,
        settings: ChargerSettings = .empty,
        chargerHistory: ChargerPortHistory? = nil,
        preferences: AppPreferences? = nil,
        isPaused: Bool = false
    ) {
        self.history = HistoryStore(persist: false, samples: historySamples)
        let diagnostics = DiagnosticLog()
        diagnostics.seedForPreview(diagnosticEntries)
        self.diagnostics = diagnostics
        self.bluetooth = nil
        self.previewCanControl = canControlPorts
        self.connectionState = previewState
        self.isPaused = isPaused
        self.identity = identity
        self.telemetry = telemetry
        self.settings = settings
        self.chargerHistory = chargerHistory
        self.preferences = preferences ?? AppPreferences.shared
    }

    var totalPower: Double { telemetry.totalPower }

    var menuBarTitle: String {
        "\(Self.compactWatts(totalPower)) W"
    }

    var canControlPorts: Bool {
        connectionState.isConnected && (bluetooth?.canControlPorts ?? previewCanControl)
    }

    var statusCaption: String {
        if isPaused {
            if identity.isEmpty {
                return "Paused"
            }
            return "Paused · \(identity.displayName)"
        }
        if connectionState.isConnected {
            if let firmware = identity.firmwareLabel {
                return "\(identity.displayName) · \(firmware)"
            }
            return "Connected: \(identity.displayName)"
        }
        if !identity.isEmpty {
            if let firmware = identity.firmwareLabel {
                return "Last seen \(identity.displayName) · \(firmware)"
            }
            return "Last seen \(identity.displayName)"
        }
        return connectionState.label
    }

    func reconnect() {
        isPaused = false
        bluetooth?.reconnect()
    }

    func pauseConnection() {
        isPaused = true
        bluetooth?.disconnect()
    }

    func resumeConnection() {
        reconnect()
    }

    func disconnect() {
        bluetooth?.disconnect()
    }

    func isPortCommandInFlight(_ index: Int) -> Bool {
        portCommandsInFlight.contains(index)
    }

    func setPortOutput(index: Int, enabled: Bool) {
        guard canControlPorts, !portCommandsInFlight.contains(index) else { return }
        portCommandsInFlight.insert(index)
        applyLocalOutput(index: index, enabled: enabled)
        do {
            try bluetooth?.setPortOutput(index: index, enabled: enabled)
        } catch {
            diagnostics.record(
                "Could not set C\(index) output: \(error.localizedDescription)",
                level: .error,
                category: "Control"
            )
        }
        scheduleClearInFlight(index)
    }

    func setPortShutdownTimer(index: Int, seconds: UInt32) {
        guard canControlPorts, !portCommandsInFlight.contains(index) else { return }
        portCommandsInFlight.insert(index)
        applyLocalTimer(index: index, seconds: seconds)
        do {
            try bluetooth?.setPortShutdownTimer(index: index, seconds: seconds)
        } catch {
            diagnostics.record(
                "Could not set C\(index) shutdown timer: \(error.localizedDescription)",
                level: .error,
                category: "Control"
            )
        }
        scheduleClearInFlight(index)
    }

    func setChargingMode(_ mode: ChargerChargingMode) {
        guard canControlPorts else { return }
        lastLocalSettingsAt = Date()
        telemetry.chargingMode = mode
        do {
            try bluetooth?.setChargingMode(mode)
        } catch {
            diagnostics.record(
                "Could not set charging mode: \(error.localizedDescription)",
                level: .error,
                category: "Control"
            )
        }
    }

    func setCustomChargeSplit(_ split: CustomChargeSplit) {
        guard canControlPorts else { return }
        if let error = split.validationError {
            diagnostics.record(error, level: .error, category: "Control")
            return
        }
        lastLocalSettingsAt = Date()
        telemetry.chargingMode = .custom
        settings.customSplit = split
        do {
            try bluetooth?.setCustomChargeMode(split)
        } catch {
            diagnostics.record(
                "Could not set custom split: \(error.localizedDescription)",
                level: .error,
                category: "Control"
            )
        }
    }

    func setLanguage(_ language: ChargerLanguage) {
        guard canControlPorts else { return }
        lastLocalSettingsAt = Date()
        settings.language = language
        do {
            try bluetooth?.setLanguage(language)
        } catch {
            diagnostics.record(
                "Could not set language: \(error.localizedDescription)",
                level: .error,
                category: "Control"
            )
        }
    }

    func setScreenTimeout(_ timeout: ChargerScreenTimeout) {
        guard canControlPorts else { return }
        lastLocalSettingsAt = Date()
        settings.screenTimeout = timeout
        do {
            try bluetooth?.setScreenTimeout(timeout)
        } catch {
            diagnostics.record(
                "Could not set screen timeout: \(error.localizedDescription)",
                level: .error,
                category: "Control"
            )
        }
    }

    func setScreenBrightness(_ percent: Int) {
        guard canControlPorts else { return }
        lastLocalSettingsAt = Date()
        settings.brightnessPercent = min(100, max(25, percent))
        do {
            try bluetooth?.setScreenBrightness(percent)
        } catch {
            diagnostics.record(
                "Could not set brightness: \(error.localizedDescription)",
                level: .error,
                category: "Control"
            )
        }
    }

    func setScreenOrientation(_ orientation: ChargerOrientation) {
        guard canControlPorts else { return }
        lastLocalSettingsAt = Date()
        settings.orientation = orientation
        do {
            try bluetooth?.setScreenOrientation(orientation)
        } catch {
            diagnostics.record(
                "Could not set orientation: \(error.localizedDescription)",
                level: .error,
                category: "Control"
            )
        }
    }

    func setAutoRotate(_ enabled: Bool) {
        guard canControlPorts else { return }
        lastLocalSettingsAt = Date()
        settings.autoRotate = enabled
        do {
            try bluetooth?.setAutoRotate(enabled)
        } catch {
            diagnostics.record(
                "Could not set auto-rotate: \(error.localizedDescription)",
                level: .error,
                category: "Control"
            )
        }
    }

    func noteTimerExpired(portIndex: Int) {
        guard let port = telemetry.ports[safe: portIndex - 1],
              let end = port.shutdownEndsAt, end <= Date() else { return }
        applyLocalOutput(index: portIndex, enabled: false)
    }

    static func compactWatts(_ value: Double) -> String {
        if value > 0, value < 10 {
            return value.formatted(.number.precision(.fractionLength(1)))
        }
        return value.formatted(.number.precision(.fractionLength(0)))
    }

    private func applyLocalOutput(index: Int, enabled: Bool) {
        guard let offset = telemetry.ports.firstIndex(where: { $0.index == index }) else { return }
        lastLocalControlAt[index] = Date()
        telemetry.ports[offset].isOutputEnabled = enabled
        telemetry.ports[offset].shutdownEndsAt = nil
        telemetry.ports[offset].shutdownDurationSeconds = enabled ? telemetry.ports[offset].shutdownDurationSeconds : 0
        if !enabled {
            telemetry.ports[offset].isActive = false
            telemetry.ports[offset].voltage = 0
            telemetry.ports[offset].current = 0
            telemetry.ports[offset].power = 0
            telemetry.ports[offset].shutdownDurationSeconds = 0
        }
    }

    private func applyLocalTimer(index: Int, seconds: UInt32) {
        guard let offset = telemetry.ports.firstIndex(where: { $0.index == index }) else { return }
        lastLocalControlAt[index] = Date()
        telemetry.ports[offset].shutdownDurationSeconds = seconds
        telemetry.ports[offset].shutdownEndsAt = seconds == 0 ? nil : Date().addingTimeInterval(TimeInterval(seconds))
    }

    private func applyDeviceControl(_ control: PortControlUpdate) {
        guard let offset = telemetry.ports.firstIndex(where: { $0.index == control.portIndex }) else { return }
        if let enabled = control.isOutputEnabled {
            telemetry.ports[offset].isOutputEnabled = enabled
            if !enabled {
                telemetry.ports[offset].isActive = false
                telemetry.ports[offset].voltage = 0
                telemetry.ports[offset].current = 0
                telemetry.ports[offset].power = 0
            }
        }
        if let remaining = control.remainingSeconds {
            telemetry.ports[offset].shutdownDurationSeconds = remaining
            telemetry.ports[offset].shutdownEndsAt = remaining == 0
                ? nil
                : Date().addingTimeInterval(TimeInterval(remaining))
        }
    }

    private func mergeControlState(from previous: ChargerTelemetry, into next: inout ChargerTelemetry) {
        let now = Date()
        for index in next.ports.indices {
            let portIndex = next.ports[index].index
            let previousPort = previous.ports[safe: index]
            let preserveLocal = lastLocalControlAt[portIndex]
                .map { now.timeIntervalSince($0) < 2.5 } ?? false

            if preserveLocal, let previousPort {
                next.ports[index].isOutputEnabled = previousPort.isOutputEnabled
                next.ports[index].shutdownDurationSeconds = previousPort.shutdownDurationSeconds
                next.ports[index].shutdownEndsAt = previousPort.shutdownEndsAt
                if previousPort.isOutputEnabled == false {
                    next.ports[index].isActive = false
                    next.ports[index].voltage = 0
                    next.ports[index].current = 0
                    next.ports[index].power = 0
                }
                continue
            }

            if next.ports[index].isActive {
                next.ports[index].isOutputEnabled = true
            } else if let enabled = previousPort?.isOutputEnabled {
                next.ports[index].isOutputEnabled = enabled
            }

            if let end = previousPort?.shutdownEndsAt, end > now {
                next.ports[index].shutdownEndsAt = end
                next.ports[index].shutdownDurationSeconds = previousPort?.shutdownDurationSeconds
            } else if let end = previousPort?.shutdownEndsAt, end <= now {
                next.ports[index].isOutputEnabled = false
                next.ports[index].shutdownEndsAt = nil
                next.ports[index].shutdownDurationSeconds = 0
            }
        }

        let preserveMode = lastLocalSettingsAt.map { now.timeIntervalSince($0) < 2.5 } ?? false
        if preserveMode {
            next.chargingMode = previous.chargingMode
        }
    }

    private func applySettings(_ update: ChargerSettingsUpdate) {
        let preserveLocal = lastLocalSettingsAt.map { Date().timeIntervalSince($0) < 2.5 } ?? false
        if !preserveLocal, let mode = update.chargingMode {
            telemetry.chargingMode = mode
        }
        if preserveLocal {
            var filtered = update
            filtered.chargingMode = nil
            filtered.brightnessPercent = settings.brightnessPercent != nil ? nil : update.brightnessPercent
            filtered.screenTimeout = settings.screenTimeout != nil ? nil : update.screenTimeout
            filtered.orientation = settings.orientation != nil ? nil : update.orientation
            filtered.autoRotate = settings.autoRotate != nil ? nil : update.autoRotate
            filtered.language = settings.language != nil ? nil : update.language
            filtered.customSplit = settings.customSplit != nil ? nil : update.customSplit
            settings = filtered.merging(into: settings)
        } else {
            settings = update.merging(into: settings)
        }
    }

    private func noteIdlePorts(in telemetry: ChargerTelemetry) {
        guard preferences.idleNotificationsEnabled, connectionState.isConnected else { return }
        let now = Date()
        for port in telemetry.ports {
            if port.power > 1 {
                lastChargingAt[port.index] = now
                idleNotifiedPorts.remove(port.index)
                continue
            }
            guard port.power <= 0.05, let lastCharging = lastChargingAt[port.index] else { continue }
            guard now.timeIntervalSince(lastCharging) >= IdleChargeNotifier.idleInterval else { continue }
            guard !idleNotifiedPorts.contains(port.index) else { continue }
            idleNotifiedPorts.insert(port.index)
            IdleChargeNotifier.notify(
                portIndex: port.index,
                label: preferences.displayName(forPort: port.index)
            )
        }
    }

    private func scheduleClearInFlight(_ index: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.portCommandsInFlight.remove(index)
        }
    }
}

extension AppModel: ChargerBluetoothDelegate {
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, changedState state: ChargerConnectionState) {
        connectionState = state
        if state.isConnectingActivity {
            isPaused = false
        }
        if !state.isConnected {
            telemetry = .empty
            portCommandsInFlight = []
            lastLocalControlAt = [:]
            lastChargingAt = [:]
            idleNotifiedPorts = []
        }
    }

    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received identity: ChargerIdentity) {
        self.identity = self.identity.merging(identity)
        preferences.persistIdentity(self.identity)
    }

    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received telemetry: ChargerTelemetry) {
        var merged = telemetry
        mergeControlState(from: self.telemetry, into: &merged)
        self.telemetry = merged
        history.append(merged)
        noteIdlePorts(in: merged)
    }

    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received control: PortControlUpdate) {
        applyDeviceControl(control)
    }

    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received settings: ChargerSettingsUpdate) {
        applySettings(settings)
    }

    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received history: ChargerPortHistory) {
        chargerHistory = history
    }
}
