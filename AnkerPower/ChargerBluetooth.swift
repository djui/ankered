import CoreBluetooth
import Foundation

@MainActor
protocol ChargerBluetoothDelegate: AnyObject {
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, changedState state: ChargerConnectionState)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received identity: ChargerIdentity)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received telemetry: ChargerTelemetry)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received control: PortControlUpdate)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received settings: ChargerSettingsUpdate)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received history: ChargerPortHistory)
}

@MainActor
final class ChargerBluetooth: NSObject {
    static let advertisedService = CBUUID(string: "FF09")
    static let service = CBUUID(string: "8C850001-0302-41C5-B46E-CF057C562025")
    static let write = CBUUID(string: "8C850002-0302-41C5-B46E-CF057C562025")
    static let notify = CBUUID(string: "8C850003-0302-41C5-B46E-CF057C562025")
    private static let rememberedPeripheralKey = "lastChargerPeripheralUUID"

    weak var delegate: ChargerBluetoothDelegate?

    private let diagnostics: DiagnosticLog
    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var frameDecoder = AnkerFrameStreamDecoder()
    private let session = AnkerSession()
    private var pendingWrites: [Data] = []
    private var awaitingWriteResponse = false
    private var userRequestedDisconnect = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var heartbeatTick = 0
    private var lastTelemetryAt: Date?
    private var didRequestPortHistory = false

    init(diagnostics: DiagnosticLog) {
        self.diagnostics = diagnostics
        super.init()
    }

    func start() {
        userRequestedDisconnect = false
        diagnostics.record("Starting Bluetooth controller", category: "App")
        _ = central
        if central.state == .poweredOn {
            scan()
        }
    }

    func reconnect() {
        userRequestedDisconnect = false
        diagnostics.record("Manual reconnect requested", category: "App")
        let wasConnected = peripheral != nil
        disconnectCurrentPeripheral()
        if central.state == .poweredOn {
            if wasConnected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    self?.scan()
                }
            } else {
                scan()
            }
        }
    }

    func disconnect() {
        userRequestedDisconnect = true
        diagnostics.record("Disconnect requested", category: "App")
        reconnectWorkItem?.cancel()
        central.stopScan()
        disconnectCurrentPeripheral()
        publish(.idle)
    }

    var canControlPorts: Bool {
        session.supportsPortControl
    }

    func setPortOutput(index: Int, enabled: Bool) throws {
        let portIndex = try Self.wirePortIndex(index)
        diagnostics.record(
            "Setting C\(index) output \(enabled ? "on" : "off")",
            category: "Control"
        )
        queueWrite(try session.makePortOutput(portIndex: portIndex, isOn: enabled))
        refreshTelemetrySoon()
    }

    func setPortShutdownTimer(index: Int, seconds: UInt32) throws {
        let portIndex = try Self.wirePortIndex(index)
        diagnostics.record(
            seconds == 0
                ? "Clearing C\(index) shutdown timer"
                : "Setting C\(index) shutdown timer to \(seconds)s",
            category: "Control"
        )
        queueWrite(try session.makePortShutdownTimer(portIndex: portIndex, seconds: seconds))
        refreshTelemetrySoon()
    }

    func setChargingMode(_ mode: ChargerChargingMode) throws {
        diagnostics.record("Setting charging mode \(mode.label)", category: "Control")
        queueWrites(try session.makeChargingMode(mode), spacing: 0.12)
        refreshTelemetrySoon()
    }

    func setCustomChargeMode(_ split: CustomChargeSplit) throws {
        diagnostics.record(
            "Setting custom charge split C1=\(split.c1)W C2=\(split.c2)W C3=\(split.c3)W",
            category: "Control"
        )
        queueWrite(try session.makeCustomChargeMode(split))
        refreshTelemetrySoon()
    }

    func setLanguage(_ language: ChargerLanguage) throws {
        diagnostics.record("Setting charger language \(language.label)", category: "Control")
        queueWrite(try session.makeLanguage(language))
    }

    func setScreenTimeout(_ timeout: ChargerScreenTimeout) throws {
        diagnostics.record("Setting screen timeout \(timeout.label)", category: "Control")
        queueWrite(try session.makeScreenTimeout(timeout))
    }

    func setScreenBrightness(_ percent: Int) throws {
        diagnostics.record("Setting screen brightness \(percent)%", category: "Control")
        queueWrite(try session.makeScreenBrightness(UInt8(min(100, max(25, percent)))))
    }

    func setScreenOrientation(_ orientation: ChargerOrientation) throws {
        diagnostics.record("Setting screen orientation \(orientation.label)", category: "Control")
        queueWrite(try session.makeScreenOrientation(orientation))
    }

    func setAutoRotate(_ enabled: Bool) throws {
        diagnostics.record("Setting auto-rotate \(enabled ? "on" : "off")", category: "Control")
        queueWrite(try session.makeAutoRotate(enabled))
    }

    private static func wirePortIndex(_ index: Int) throws -> UInt8 {
        guard (1...3).contains(index) else {
            throw AnkerProtocolError.invalidFrame("port number must be 1...3")
        }
        return UInt8(index - 1)
    }

    private func refreshTelemetrySoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.session.supportsPortControl else { return }
            if let packet = try? self.session.makeRealtimeProbe() {
                self.queueWrite(packet)
            }
        }
    }

    private func scan() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        reconnectWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        central.stopScan()
        publish(.scanning)
        diagnostics.record("Looking for a previously used or already-connected charger")

        if let value = UserDefaults.standard.string(forKey: Self.rememberedPeripheralKey),
           let identifier = UUID(uuidString: value),
           let remembered = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            diagnostics.record("Found remembered peripheral \(identifier.uuidString)")
            connect(remembered, source: "remembered peripheral")
            return
        }

        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            diagnostics.record("Found charger already connected to macOS")
            connect(connected, source: "connected peripheral")
            return
        }

        startDiscoveryScan()
    }

    private func startDiscoveryScan() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        diagnostics.record("Starting unfiltered BLE scan (matching FF09/name locally)")
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func looksLikeA2687(
        _ peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> Bool {
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if serviceUUIDs.contains(Self.advertisedService) { return true }
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]
        if serviceData.keys.contains(Self.advertisedService) { return true }

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = (advertisedName ?? peripheral.name ?? "").lowercased()
        return name == "charging" || name.hasPrefix("ashdjw") || name.contains("anker")
    }

    private func connect(_ discoveredPeripheral: CBPeripheral, source: String) {
        central.stopScan()
        peripheral = discoveredPeripheral
        discoveredPeripheral.delegate = self
        diagnostics.record(
            "Connecting to \(discoveredPeripheral.name ?? "unnamed device") (\(source), \(discoveredPeripheral.identifier.uuidString))"
        )
        publish(.connecting)
        central.connect(discoveredPeripheral)

        let timeout = DispatchWorkItem { [weak self, weak discoveredPeripheral] in
            guard let self, let discoveredPeripheral,
                  self.peripheral === discoveredPeripheral else { return }
            self.diagnostics.record(
                "Connection attempt timed out; returning to discovery",
                level: .warning
            )
            self.peripheral = nil
            self.central.cancelPeripheralConnection(discoveredPeripheral)
            self.publish(.scanning)
            self.startDiscoveryScan()
        }
        connectionTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    private func disconnectCurrentPeripheral() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        connectionTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem?.cancel()
        pendingWrites.removeAll()
        awaitingWriteResponse = false
        writeCharacteristic = nil
        notifyCharacteristic = nil
        frameDecoder = AnkerFrameStreamDecoder()
        session.reset()
        didRequestPortHistory = false
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
    }

    private func publish(_ state: ChargerConnectionState) {
        diagnostics.record(
            state.label,
            level: {
                if case .failed = state { return .error }
                return state.isConnected ? .success : .info
            }(),
            category: "State"
        )
        delegate?.chargerBluetooth(self, changedState: state)
    }

    private func queueWrite(_ packet: Data) {
        if let frame = try? AnkerFrame.decode(packet) {
            diagnostics.record(
                "TX pattern=\(frame.pattern.hexString) command=0x\(String(format: "%04X", frame.command)) bytes=\(packet.count)",
                category: "GATT"
            )
        } else {
            diagnostics.record("TX undecoded packet bytes=\(packet.count)", category: "GATT")
        }
        pendingWrites.append(packet)
        flushWrites()
    }

    private func queueWrites(_ packets: [Data], spacing: TimeInterval = 0) {
        for (index, packet) in packets.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(index) * spacing)) { [weak self] in
                guard self?.peripheral != nil else { return }
                self?.queueWrite(packet)
            }
        }
    }

    private func flushWrites() {
        guard let peripheral, let characteristic = writeCharacteristic else { return }
        let supportsWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)

        while !pendingWrites.isEmpty {
            if supportsWithoutResponse {
                guard peripheral.canSendWriteWithoutResponse else { return }
                peripheral.writeValue(pendingWrites.removeFirst(), for: characteristic, type: .withoutResponse)
            } else {
                guard !awaitingWriteResponse else { return }
                awaitingWriteResponse = true
                peripheral.writeValue(pendingWrites.removeFirst(), for: characteristic, type: .withResponse)
                return
            }
        }
    }

    private func beginHandshake() {
        publish(.negotiating)
        diagnostics.record("Starting app-compatible ephemeral AES-GCM handshake", category: "Protocol")
        do {
            queueWrite(try session.start())
            scheduleModernHandshakeFallback()
        } catch {
            fallbackToLegacy(reason: "Could not create AES-GCM handshake: \(error.localizedDescription)")
        }
    }

    private func scheduleModernHandshakeFallback() {
        handshakeTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.session.isReady,
                  self.session.transport == .modernAESGCM else { return }
            self.fallbackToLegacy(reason: "AES-GCM handshake timed out")
        }
        handshakeTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
    }

    private func fallbackToLegacy(reason: String) {
        guard peripheral != nil, !session.isReady else { return }
        diagnostics.record("\(reason); trying AES-CBC fallback", level: .warning, category: "Protocol")
        pendingWrites.removeAll()
        awaitingWriteResponse = false
        queueWrite(session.startLegacy())

        handshakeTimeoutWorkItem?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.session.isReady else { return }
            self.diagnostics.record("Both secure-session handshakes timed out", level: .error, category: "Protocol")
            self.publish(.failed("Secure-session negotiation timed out"))
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
        handshakeTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 18, execute: timeout)
    }

    private func beginTelemetry() {
        handshakeTimeoutWorkItem?.cancel()
        do {
            if session.transport == .legacyAESCBC {
                queueWrite(try session.makeTelemetrySubscription())
            }
            diagnostics.record(
                "Secure session ready using \(session.transport.rawValue); telemetry polling started",
                level: .success,
                category: "Protocol"
            )
            publish(.connected)
            startHeartbeat()
            if session.transport == .modernAESGCM, !didRequestPortHistory {
                didRequestPortHistory = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.session.supportsPortControl else { return }
                    do {
                        self.queueWrite(try self.session.makePortHistoryProbe())
                        self.diagnostics.record("Requested charger-side port history", category: "Protocol")
                    } catch {
                        self.diagnostics.record(
                            "Could not request port history: \(error.localizedDescription)",
                            level: .warning,
                            category: "Protocol"
                        )
                    }
                }
            }
        } catch {
            failAndDisconnect("Could not subscribe: \(error.localizedDescription)")
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTick = 0
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session.isReady else { return }
                self.heartbeatTick += 1
                switch self.session.transport {
                case .modernAESGCM:
                    do {
                        self.queueWrite(try self.session.makeRealtimeProbe())
                        if self.heartbeatTick.isMultiple(of: 2) {
                            self.queueWrite(try self.session.makeStatusProbe())
                        }
                    } catch {
                        self.diagnostics.record(
                            "Could not create telemetry poll: \(error.localizedDescription)",
                            level: .error,
                            category: "Protocol"
                        )
                    }
                case .legacyAESCBC:
                    let isStale = self.lastTelemetryAt.map { Date().timeIntervalSince($0) > 15 } ?? true
                    if isStale, let packet = try? self.session.makeTelemetrySubscription() {
                        self.queueWrite(packet)
                    }
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !userRequestedDisconnect else { return }
        let workItem = DispatchWorkItem { [weak self] in self?.scan() }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func failAndDisconnect(_ message: String) {
        publish(.failed(message))
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            scheduleReconnect()
        }
    }
}

extension ChargerBluetooth: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        diagnostics.record("CoreBluetooth state changed to \(central.state.debugName)", category: "Bluetooth")
        if central.state != .poweredOn {
            disconnectCurrentPeripheral()
        }
        switch central.state {
        case .poweredOn:
            if !userRequestedDisconnect { scan() }
        case .poweredOff:
            publish(.bluetoothUnavailable("Bluetooth is off"))
        case .unauthorized:
            publish(.bluetoothUnavailable("Bluetooth permission is required"))
        case .unsupported:
            publish(.bluetoothUnavailable("Bluetooth LE is unavailable"))
        case .resetting:
            publish(.bluetoothUnavailable("Bluetooth is resetting…"))
        case .unknown:
            publish(.bluetoothUnavailable("Checking Bluetooth…"))
        @unknown default:
            publish(.bluetoothUnavailable("Bluetooth is unavailable"))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil else { return }
        guard looksLikeA2687(peripheral, advertisementData: advertisementData) else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map(\.uuidString)
            .joined(separator: ",")
        diagnostics.record(
            "Matched \(advertisedName ?? peripheral.name ?? "unnamed device"), RSSI \(RSSI), services [\(services)]",
            category: "Discovery"
        )
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.rememberedPeripheralKey)
        connect(peripheral, source: "BLE advertisement")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionTimeoutWorkItem?.cancel()
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.rememberedPeripheralKey)
        diagnostics.record("Connected at BLE transport level", level: .success)
        publish(.discovering)
        peripheral.discoverServices([Self.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral === peripheral else {
            diagnostics.record("Ignored a stale connection-failure callback", category: "Bluetooth")
            return
        }
        connectionTimeoutWorkItem?.cancel()
        self.peripheral = nil
        diagnostics.record(
            "Connection failed: \(error?.localizedDescription ?? "unknown error")",
            level: .error
        )
        publish(.failed("Connection failed: \(error?.localizedDescription ?? "unknown error")"))
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral == nil else { return }
            self.publish(.scanning)
            self.startDiscoveryScan()
        }
        reconnectWorkItem = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral === peripheral else {
            diagnostics.record("Ignored a stale disconnect callback", category: "Bluetooth")
            return
        }
        connectionTimeoutWorkItem?.cancel()
        handshakeTimeoutWorkItem?.cancel()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        self.peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        pendingWrites.removeAll()
        session.reset()
        diagnostics.record(
            error.map { "Disconnected: \($0.localizedDescription)" } ?? "Peripheral disconnected",
            level: error == nil ? .warning : .error
        )
        if !userRequestedDisconnect {
            publish(.failed(error.map { "Disconnected: \($0.localizedDescription)" } ?? "Charger disconnected"))
            scheduleReconnect()
        }
    }
}

extension ChargerBluetooth: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            diagnostics.record("Service discovery failed: \(error.localizedDescription)", level: .error, category: "GATT")
            failAndDisconnect("Service discovery failed: \(error.localizedDescription)")
            return
        }
        diagnostics.record(
            "Discovered services: \(peripheral.services?.map(\.uuid.uuidString).joined(separator: ", ") ?? "none")",
            category: "GATT"
        )
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            failAndDisconnect("A2687 GATT service was not found")
            return
        }
        peripheral.discoverCharacteristics([Self.write, Self.notify], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            diagnostics.record("Characteristic discovery failed: \(error.localizedDescription)", level: .error, category: "GATT")
            failAndDisconnect("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        diagnostics.record(
            "Discovered characteristics: \(service.characteristics?.map(\.uuid.uuidString).joined(separator: ", ") ?? "none")",
            category: "GATT"
        )
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == Self.write { writeCharacteristic = characteristic }
            if characteristic.uuid == Self.notify { notifyCharacteristic = characteristic }
        }
        guard writeCharacteristic != nil, let notifyCharacteristic else {
            failAndDisconnect("A2687 write/notify characteristics were not found")
            return
        }
        diagnostics.record("Enabling charger notifications", category: "GATT")
        peripheral.setNotifyValue(true, for: notifyCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            diagnostics.record("Notification setup failed: \(error.localizedDescription)", level: .error, category: "GATT")
            failAndDisconnect("Notifications failed: \(error.localizedDescription)")
            return
        }
        guard characteristic.uuid == Self.notify, characteristic.isNotifying else { return }
        diagnostics.record("Notifications enabled", level: .success, category: "GATT")
        beginHandshake()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            diagnostics.record("Notification read failed: \(error.localizedDescription)", level: .error, category: "GATT")
            return
        }
        guard characteristic.uuid == Self.notify, let data = characteristic.value else { return }
        diagnostics.record("RX notification bytes=\(data.count)", category: "GATT")
        for frame in frameDecoder.append(data) {
            diagnostics.record(
                "RX pattern=\(frame.pattern.hexString) command=0x\(String(format: "%04X", frame.command)) payload=\(frame.payload.count) bytes",
                category: "GATT"
            )
            do {
                let update = try session.receive(frame)
                update.diagnostics.forEach {
                    diagnostics.record($0, category: "Protocol")
                }
                if session.transport == .modernAESGCM,
                   !update.becameReady,
                   !update.outboundPackets.isEmpty {
                    scheduleModernHandshakeFallback()
                }
                queueWrites(update.outboundPackets, spacing: update.becameReady ? 0.12 : 0)
                if let identity = update.identity {
                    diagnostics.record(
                        "Identity firmware=\(identity.firmwareLabel ?? "unknown") serial=\(identity.serialNumber == nil ? "none" : "present")",
                        level: .success,
                        category: "Protocol"
                    )
                    delegate?.chargerBluetooth(self, received: identity)
                }
                if let telemetry = update.telemetry {
                    lastTelemetryAt = telemetry.receivedAt
                    let powers = telemetry.ports.map { "C\($0.index)=\(String(format: "%.1f", $0.power))W" }.joined(separator: " ")
                    diagnostics.record("Decoded telemetry: \(powers)", level: .success, category: "Telemetry")
                    delegate?.chargerBluetooth(self, received: telemetry)
                }
                if let settings = update.settings, !settings.isEmpty {
                    diagnostics.record("Decoded charger settings", category: "Control")
                    delegate?.chargerBluetooth(self, received: settings)
                }
                if let control = update.portControl {
                    diagnostics.record(
                        "Port control C\(control.portIndex) enabled=\(control.isOutputEnabled.map { $0 ? "on" : "off" } ?? "unknown") remaining=\(control.remainingSeconds.map(String.init) ?? "unknown")s",
                        category: "Control"
                    )
                    delegate?.chargerBluetooth(self, received: control)
                }
                if let history = update.portHistory {
                    diagnostics.record(
                        "Decoded charger port history (\(history.sampleCount) samples)",
                        level: .success,
                        category: "Telemetry"
                    )
                    delegate?.chargerBluetooth(self, received: history)
                }
                if update.becameReady {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.beginTelemetry()
                    }
                }
            } catch {
                diagnostics.record("Protocol error: \(error.localizedDescription)", level: .error, category: "Protocol")
                if !session.isReady, session.transport == .modernAESGCM {
                    fallbackToLegacy(reason: "AES-GCM handshake failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        awaitingWriteResponse = false
        if let error {
            diagnostics.record("Bluetooth write failed: \(error.localizedDescription)", level: .error, category: "GATT")
            failAndDisconnect("Bluetooth write failed: \(error.localizedDescription)")
        } else {
            diagnostics.record("Write acknowledged", category: "GATT")
            flushWrites()
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushWrites()
    }
}

private extension CBManagerState {
    var debugName: String {
        switch self {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "powered off"
        case .poweredOn: return "powered on"
        @unknown default: return "unrecognized"
        }
    }
}
