import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var connectionState: ChargerConnectionState = .idle
    @Published private(set) var identity = ChargerIdentity()
    @Published private(set) var telemetry = ChargerTelemetry.empty
    @Published private(set) var portCommandsInFlight: Set<Int> = []

    let history: HistoryStore
    let diagnostics: DiagnosticLog

    private let bluetooth: ChargerBluetooth?
    private let previewCanControl: Bool
    private var lastLocalControlAt: [Int: Date] = [:]

    init() {
        let diagnostics = DiagnosticLog()
        let bluetooth = ChargerBluetooth(diagnostics: diagnostics)
        self.history = HistoryStore()
        self.diagnostics = diagnostics
        self.bluetooth = bluetooth
        self.previewCanControl = false
        bluetooth.delegate = self
        bluetooth.start()
    }

    /// In-memory sample used by SwiftUI previews and screenshot export. Does not start Bluetooth.
    init(
        previewState: ChargerConnectionState,
        identity: ChargerIdentity,
        telemetry: ChargerTelemetry,
        historySamples: [PowerHistorySample] = [],
        diagnosticEntries: [DiagnosticEntry] = [],
        canControlPorts: Bool = true
    ) {
        self.history = HistoryStore(persist: false, samples: historySamples)
        let diagnostics = DiagnosticLog()
        diagnostics.seedForPreview(diagnosticEntries)
        self.diagnostics = diagnostics
        self.bluetooth = nil
        self.previewCanControl = canControlPorts
        self.connectionState = previewState
        self.identity = identity
        self.telemetry = telemetry
    }

    var totalPower: Double { telemetry.totalPower }

    var menuBarTitle: String {
        "\(Self.compactWatts(totalPower)) W"
    }

    var canControlPorts: Bool {
        connectionState.isConnected && (bluetooth?.canControlPorts ?? previewCanControl)
    }

    func reconnect() {
        bluetooth?.reconnect()
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
        if !state.isConnected {
            telemetry = .empty
            portCommandsInFlight = []
            lastLocalControlAt = [:]
        }
    }

    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received identity: ChargerIdentity) {
        self.identity = identity
    }

    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received telemetry: ChargerTelemetry) {
        var merged = telemetry
        mergeControlState(from: self.telemetry, into: &merged)
        self.telemetry = merged
        history.append(merged)
    }

    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received control: PortControlUpdate) {
        applyDeviceControl(control)
    }
}
