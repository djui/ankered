import CoreBluetooth
import Foundation

/// Waits between discovery attempts so an absent charger does not keep the radio scanning.
enum BluetoothDiscoveryBackoff {
    static let scanWindow: TimeInterval = 8
    /// First miss waits 5s, then 15s, 30s, 60s, and 2 minutes after that.
    static let delays: [TimeInterval] = [5, 15, 30, 60, 120]

    static func delay(afterFailureCount count: Int) -> TimeInterval {
        let index = min(max(count, 1), delays.count) - 1
        return delays[index]
    }
}

@MainActor
protocol ChargerBluetoothDelegate: AnyObject {
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, changedState state: ChargerConnectionState)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received identity: ChargerIdentity)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received telemetry: ChargerTelemetry)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received control: PortControlUpdate)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received settings: ChargerSettingsUpdate)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, received history: ChargerPortHistory)
    func chargerBluetooth(_ bluetooth: ChargerBluetooth, screensaverProgress progress: ScreensaverTransferProgress)
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
    private var central: CBCentralManager!
    private var authorizationPoll: Timer?
    private var didRecreateAfterAllow = false
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var frameDecoder = AnkerFrameStreamDecoder()
    private let session = AnkerSession()
    private var pendingWrites: [Data] = []
    private var awaitingWriteResponse = false
    private var userRequestedDisconnect = false
    private var suspendedForSystemSleep = false
    private var discoveryMissCount = 0
    /// Callbacks for a connection we already dropped. A wake can reconnect the same
    /// peripheral before Core Bluetooth delivers the cancel, and that callback must not
    /// tear the new session down.
    private var disconnectsToIgnore = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var scanWindowWorkItem: DispatchWorkItem?
    private var connectionTimeoutWorkItem: DispatchWorkItem?
    private var handshakeTimeoutWorkItem: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var heartbeatTick = 0
    private var lastTelemetryAt: Date?
    private var didRequestPortHistory = false
    private var screensaverTransferActive = false
    private var screensaverAckContinuation: CheckedContinuation<AnkerControlAck, Error>?
    private var screensaverWaitingCommand: UInt16?
    private var screensaverAckTimeout: DispatchWorkItem?
    private var screensaverIDContinuation: CheckedContinuation<UInt16, Error>?
    private var screensaverIDTimeout: DispatchWorkItem?
    private var screensaverExpectedID: UInt16?

    init(diagnostics: DiagnosticLog) {
        self.diagnostics = diagnostics
        super.init()
    }

    func start() {
        userRequestedDisconnect = false
        didRecreateAfterAllow = false
        diagnostics.record("Starting Bluetooth controller", category: "App")
        if central == nil {
            recreateCentral(reason: "start")
        } else if central.state == .poweredOn {
            scan()
        } else if central.state == .unauthorized {
            watchAuthorization()
        }
    }

    func reconnect() {
        userRequestedDisconnect = false
        suspendedForSystemSleep = false
        discoveryMissCount = 0
        diagnostics.record("Manual reconnect requested", category: "App")
        let wasConnected = peripheral != nil
        cancelDiscoveryTimers()
        disconnectCurrentPeripheral()
        guard central != nil else {
            start()
            return
        }
        if central.state == .unauthorized {
            recreateCentral(reason: "reconnect while unauthorized")
            return
        }
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
        suspendedForSystemSleep = false
        diagnostics.record("Disconnect requested", category: "App")
        cancelDiscoveryTimers()
        central?.stopScan()
        disconnectCurrentPeripheral()
        publish(.idle)
    }

    /// Drops the link and any scan so the Mac can idle-sleep. Does not count as a user pause.
    func suspendForSystemSleep() {
        guard !userRequestedDisconnect else { return }
        suspendedForSystemSleep = true
        diagnostics.record("Releasing Bluetooth so the Mac can sleep", category: "App")
        cancelDiscoveryTimers()
        central?.stopScan()
        disconnectCurrentPeripheral()
        publish(.idle)
    }

    func resumeAfterSystemSleep() {
        guard suspendedForSystemSleep else { return }
        suspendedForSystemSleep = false
        userRequestedDisconnect = false
        discoveryMissCount = 0
        diagnostics.record("Resuming Bluetooth after wake", category: "App")
        if central == nil {
            start()
        } else if central.state == .poweredOn {
            scan()
        } else if central.state == .unauthorized {
            watchAuthorization()
        }
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

    func selectScreensaver(pictureID: UInt32, hash: UInt32) async throws {
        try await performScreensaverTransfer {
            try await sendScreensaverSelect(pictureID: pictureID, hash: hash, beforeUpload: false)
            notifyScreensaverProgress(.verifying)
            async let confirmed: Void = verifyScreensaverID(UInt16(truncatingIfNeeded: pictureID))
            if let packet = try? session.makeStatusProbe() {
                queueWrite(packet)
            }
            try await confirmed
        }
    }

    func uploadScreensaver(_ plan: ScreensaverImage.Plan) async throws {
        try await performScreensaverTransfer {
            try await sendScreensaverSelect(pictureID: plan.pictureID, hash: plan.hash, beforeUpload: true)
            notifyScreensaverProgress(.uploading(current: 0, total: plan.chunkCount))
            queueWrite(try session.makeScreensaverTransferStart(
                pictureID: plan.pictureID,
                hash: plan.hash,
                jpegByteCount: plan.jpeg.count,
                chunkCount: plan.chunkCount
            ))
            let startAck = try await waitForScreensaverAck(command: 0x0220)
            try throwIfScreensaverAckFailed(startAck)
            for index in 0..<plan.chunkCount {
                guard let payload = ScreensaverImage.chunk(plan.jpeg, at: index) else {
                    throw ScreensaverTransferError.emptyImage
                }
                let checkpoint = AnkerSession.isScreensaverChunkAcknowledged(index: index, of: plan.chunkCount)
                if index == 0 || checkpoint {
                    notifyScreensaverProgress(.uploading(current: index + 1, total: plan.chunkCount))
                    await Task.yield()
                }
                queueWrite(try session.makeScreensaverChunk(index: index, of: plan.chunkCount, payload: payload))
                if checkpoint {
                    let isFinal = index == plan.chunkCount - 1
                    let ack = try await waitForScreensaverAck(command: 0x0221, timeout: isFinal ? 8 : 3)
                    if !ack.acceptsScreensaverChunk(isFinal: isFinal) {
                        try throwIfScreensaverAckFailed(ack)
                    }
                    if ack.status == 0x10 {
                        diagnostics.record("Screensaver image stored on the charger", category: "Control")
                    }
                    let expected = index + 1
                    if let next = ack.nextIndex, Int(next) != expected {
                        throw ScreensaverTransferError.indexMismatch(expected: expected, got: Int(next))
                    }
                } else {
                    try await Task.sleep(nanoseconds: 8_000_000)
                }
            }
            notifyScreensaverProgress(.verifying)
            async let confirmed: Void = verifyScreensaverID(plan.reportedID)
            if let packet = try? session.makeStatusProbe() {
                queueWrite(packet)
            }
            try await confirmed
        }
    }

    private func sendScreensaverSelect(pictureID: UInt32, hash: UInt32, beforeUpload: Bool) async throws {
        notifyScreensaverProgress(.selecting)
        diagnostics.record("Selecting screensaver id=\(pictureID)", category: "Control")
        queueWrite(try session.makeScreensaverSelect(pictureID: pictureID, hash: hash))
        let ack = try await waitForScreensaverAck(command: 0x021F)
        if ack.status == 0x11, beforeUpload {
            diagnostics.record(
                "Screensaver id=\(pictureID) has no pixels yet; continuing with transfer",
                category: "Control"
            )
            return
        }
        try throwIfScreensaverAckFailed(ack)
    }

    private func throwIfScreensaverAckFailed(_ ack: AnkerControlAck) throws {
        switch ack.status {
        case 0:
            return
        case 0x11:
            throw ScreensaverTransferError.pixelsMissing
        case 0x12:
            throw ScreensaverTransferError.overrun
        default:
            throw ScreensaverTransferError.rejected(ack.status)
        }
    }

    private func performScreensaverTransfer(_ work: () async throws -> Void) async throws {
        guard session.supportsPortControl else { throw ScreensaverTransferError.notReady }
        guard !screensaverTransferActive else { throw ScreensaverTransferError.sessionBusy }
        screensaverTransferActive = true
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        defer {
            screensaverTransferActive = false
            failScreensaverWaits(ScreensaverTransferError.disconnected)
            if session.isReady, peripheral != nil {
                startHeartbeat()
            }
        }
        do {
            try await work()
            notifyScreensaverProgress(.succeeded)
        } catch {
            notifyScreensaverProgress(.failed(error.localizedDescription))
            throw error
        }
    }

    private func waitForScreensaverAck(command: UInt16, timeout: TimeInterval = 3) async throws -> AnkerControlAck {
        try await withCheckedThrowingContinuation { continuation in
            screensaverAckTimeout?.cancel()
            screensaverAckContinuation = continuation
            screensaverWaitingCommand = command
            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.resumeScreensaverAck(.failure(ScreensaverTransferError.timeout))
            }
            screensaverAckTimeout = timeoutItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        }
    }

    private func verifyScreensaverID(_ expected: UInt16, timeout: TimeInterval = 8) async throws {
        screensaverExpectedID = expected
        defer { screensaverExpectedID = nil }
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            screensaverIDTimeout?.cancel()
            screensaverIDContinuation = continuation
            let timeoutItem = DispatchWorkItem { [weak self] in
                self?.resumeScreensaverID(.failure(ScreensaverTransferError.timeout))
            }
            screensaverIDTimeout = timeoutItem
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        }
    }

    private func noteScreensaverReportedID(_ id: UInt16) {
        guard let expected = screensaverExpectedID, id == expected else { return }
        resumeScreensaverID(.success(id))
    }

    private func resumeScreensaverAck(_ result: Result<AnkerControlAck, Error>) {
        screensaverAckTimeout?.cancel()
        screensaverAckTimeout = nil
        screensaverWaitingCommand = nil
        guard let continuation = screensaverAckContinuation else { return }
        screensaverAckContinuation = nil
        continuation.resume(with: result)
    }

    private func resumeScreensaverID(_ result: Result<UInt16, Error>) {
        screensaverIDTimeout?.cancel()
        screensaverIDTimeout = nil
        guard let continuation = screensaverIDContinuation else { return }
        screensaverIDContinuation = nil
        continuation.resume(with: result)
    }

    private func failScreensaverWaits(_ error: ScreensaverTransferError) {
        resumeScreensaverAck(.failure(error))
        resumeScreensaverID(.failure(error))
    }

    private func notifyScreensaverProgress(_ progress: ScreensaverTransferProgress) {
        delegate?.chargerBluetooth(self, screensaverProgress: progress)
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
        guard !userRequestedDisconnect, !suspendedForSystemSleep else { return }
        guard central.state == .poweredOn, peripheral == nil else { return }
        reconnectWorkItem?.cancel()
        connectionTimeoutWorkItem?.cancel()
        scanWindowWorkItem?.cancel()
        central.stopScan()
        publish(.scanning)
        diagnostics.record("Looking for a previously used or already-connected charger")

        if let remembered = rememberedPeripheral() {
            diagnostics.record("Found remembered peripheral \(remembered.identifier.uuidString)")
            connect(remembered, source: "remembered peripheral")
            return
        }

        if UserDefaults.standard.string(forKey: Self.rememberedPeripheralKey) != nil {
            diagnostics.record("Remembered charger is not in the Bluetooth cache; scanning briefly")
        }

        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            diagnostics.record("Found charger already connected to macOS")
            connect(connected, source: "connected peripheral")
            return
        }

        startDiscoveryScan()
    }

    private func rememberedPeripheral() -> CBPeripheral? {
        guard let value = UserDefaults.standard.string(forKey: Self.rememberedPeripheralKey),
              let identifier = UUID(uuidString: value) else { return nil }
        return central.retrievePeripherals(withIdentifiers: [identifier]).first
    }

    private func startDiscoveryScan() {
        guard !userRequestedDisconnect, !suspendedForSystemSleep else { return }
        guard central.state == .poweredOn, peripheral == nil else { return }
        // Unfiltered so name-only advertisements still match. The window is short;
        // a remembered charger uses directed connect and never reaches here.
        diagnostics.record(
            "Starting unfiltered BLE scan for \(Int(BluetoothDiscoveryBackoff.scanWindow))s (matching FF09/name locally)"
        )
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scanWindowWorkItem?.cancel()
        let window = DispatchWorkItem { [weak self] in
            guard let self, self.peripheral == nil, !self.userRequestedDisconnect, !self.suspendedForSystemSleep else {
                return
            }
            self.central.stopScan()
            self.publish(.idle)
            self.diagnostics.record("Discovery window ended without a charger")
            self.scheduleRetry(reason: "scan window")
        }
        scanWindowWorkItem = window
        DispatchQueue.main.asyncAfter(deadline: .now() + BluetoothDiscoveryBackoff.scanWindow, execute: window)
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
        scanWindowWorkItem?.cancel()
        scanWindowWorkItem = nil
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
                "Connection attempt timed out; retrying later",
                level: .warning
            )
            self.peripheral = nil
            self.cancelAndIgnore(discoveredPeripheral)
            self.publish(.idle)
            self.scheduleRetry(reason: "connection timed out")
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
        failScreensaverWaits(ScreensaverTransferError.disconnected)
        writeCharacteristic = nil
        notifyCharacteristic = nil
        frameDecoder = AnkerFrameStreamDecoder()
        session.reset()
        didRequestPortHistory = false
        if let peripheral {
            let dropping = peripheral
            self.peripheral = nil
            cancelAndIgnore(dropping)
        }
    }

    private func cancelAndIgnore(_ peripheral: CBPeripheral) {
        disconnectsToIgnore += 1
        central.cancelPeripheralConnection(peripheral)
    }

    private func consumeIgnoredDisconnect() -> Bool {
        guard disconnectsToIgnore > 0 else { return false }
        disconnectsToIgnore -= 1
        diagnostics.record("Ignored a disconnect from a connection already dropped", category: "Bluetooth")
        return true
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
                guard let self, self.session.isReady, !self.screensaverTransferActive else { return }
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

    private func scheduleRetry(reason: String) {
        guard !userRequestedDisconnect, !suspendedForSystemSleep, peripheral == nil else { return }
        discoveryMissCount += 1
        let delay = BluetoothDiscoveryBackoff.delay(afterFailureCount: discoveryMissCount)
        diagnostics.record(
            "Charger not reached (\(reason)); retrying in \(Int(delay))s",
            category: "Bluetooth"
        )
        reconnectWorkItem?.cancel()
        scanWindowWorkItem?.cancel()
        central?.stopScan()
        let workItem = DispatchWorkItem { [weak self] in self?.scan() }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelDiscoveryTimers() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        scanWindowWorkItem?.cancel()
        scanWindowWorkItem = nil
        connectionTimeoutWorkItem?.cancel()
        connectionTimeoutWorkItem = nil
    }

    private func failAndDisconnect(_ message: String) {
        publish(.failed(message))
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            scheduleRetry(reason: "session failed")
        }
    }

    private func recreateCentral(reason: String) {
        authorizationPoll?.invalidate()
        authorizationPoll = nil
        diagnostics.record(
            "Creating Bluetooth central (\(reason)); authorization \(Self.authorizationName)",
            category: "Bluetooth"
        )
        central?.delegate = nil
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    private func watchAuthorization() {
        guard authorizationPoll == nil else { return }
        diagnostics.record(
            "Waiting for Bluetooth permission (\(Self.authorizationName))",
            category: "Bluetooth"
        )
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAuthorization()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        authorizationPoll = timer
        checkAuthorization()
    }

    private func checkAuthorization() {
        switch CBCentralManager.authorization {
        case .allowedAlways:
            authorizationPoll?.invalidate()
            authorizationPoll = nil
            if central.state != .poweredOn, !didRecreateAfterAllow {
                didRecreateAfterAllow = true
                recreateCentral(reason: "permission granted")
            }
        case .denied, .restricted:
            authorizationPoll?.invalidate()
            authorizationPoll = nil
            diagnostics.record(
                "Bluetooth authorization is \(Self.authorizationName)",
                level: .error,
                category: "Bluetooth"
            )
        default:
            break
        }
    }

    private static var authorizationName: String {
        switch CBCentralManager.authorization {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowed"
        @unknown default: return "unrecognized"
        }
    }
}

extension ChargerBluetooth: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        diagnostics.record("CoreBluetooth state changed to \(central.state.debugName)", category: "Bluetooth")
        if central.state != .poweredOn {
            disconnectCurrentPeripheral()
        }
        switch central.state {
        case .poweredOn:
            if !userRequestedDisconnect, !suspendedForSystemSleep { scan() }
        case .poweredOff:
            publish(.bluetoothUnavailable("Bluetooth is off"))
        case .unauthorized:
            publish(.bluetoothUnavailable("Bluetooth permission is required"))
            watchAuthorization()
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
        guard central === self.central else { return }
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
        discoveryMissCount = 0
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
        guard central === self.central else { return }
        if consumeIgnoredDisconnect() { return }
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
        scheduleRetry(reason: "connection failed")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard central === self.central else { return }
        if consumeIgnoredDisconnect() { return }
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
        if !userRequestedDisconnect, !suspendedForSystemSleep {
            publish(.failed(error.map { "Disconnected: \($0.localizedDescription)" } ?? "Charger disconnected"))
            scheduleRetry(reason: "disconnected")
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
                if let ack = update.controlAck {
                    if ack.command == screensaverWaitingCommand {
                        resumeScreensaverAck(.success(ack))
                    }
                }
                if let pictureID = update.settings?.screensaverReportedID {
                    noteScreensaverReportedID(pictureID)
                }
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
