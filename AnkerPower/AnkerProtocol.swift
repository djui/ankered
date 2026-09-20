import CommonCrypto
import CryptoKit
import Foundation

enum AnkerProtocolError: Error, LocalizedError, Equatable {
    case invalidHex
    case invalidFrame(String)
    case invalidTLV(String)
    case invalidKey
    case cryptoFailure(Int32)
    case sessionNotReady

    var errorDescription: String? {
        switch self {
        case .invalidHex: return "Invalid hexadecimal data"
        case .invalidFrame(let reason): return "Invalid Anker frame: \(reason)"
        case .invalidTLV(let reason): return "Invalid Anker TLV: \(reason)"
        case .invalidKey: return "Invalid Anker session key"
        case .cryptoFailure(let status): return "AES operation failed (\(status))"
        case .sessionNotReady: return "The Anker session is not ready"
        }
    }
}

extension Data {
    init(hex: String) throws {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2) else { throw AnkerProtocolError.invalidHex }
        var result = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else {
                throw AnkerProtocolError.invalidHex
            }
            result.append(byte)
            index = next
        }
        self = result
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

struct AnkerFrame: Equatable, Sendable {
    static let header = Data([0xFF, 0x09])

    var pattern: Data
    var command: UInt16
    var payload: Data

    func encode() throws -> Data {
        guard pattern.count == 3 else {
            throw AnkerProtocolError.invalidFrame("pattern must be three bytes")
        }

        let length = 2 + 2 + 3 + 2 + payload.count + 1
        guard length <= Int(UInt16.max) else {
            throw AnkerProtocolError.invalidFrame("packet is too large")
        }

        var packet = Self.header
        packet.append(UInt8(length & 0xFF))
        packet.append(UInt8((length >> 8) & 0xFF))
        packet.append(pattern)
        packet.append(UInt8(command >> 8))
        packet.append(UInt8(command & 0xFF))
        packet.append(payload)
        packet.append(packet.reduce(0, ^))
        return packet
    }

    static func decode(_ packet: Data) throws -> AnkerFrame {
        guard packet.count >= 10 else {
            throw AnkerProtocolError.invalidFrame("packet is too short")
        }
        guard packet.prefix(2) == header else {
            throw AnkerProtocolError.invalidFrame("incorrect header")
        }

        let encodedLength = Int(packet[2]) | (Int(packet[3]) << 8)
        guard encodedLength == packet.count else {
            throw AnkerProtocolError.invalidFrame("length mismatch")
        }
        guard packet.dropLast().reduce(0, ^) == packet.last else {
            throw AnkerProtocolError.invalidFrame("checksum mismatch")
        }

        let command = (UInt16(packet[7]) << 8) | UInt16(packet[8])
        return AnkerFrame(
            pattern: Data(packet[4..<7]),
            command: command,
            payload: Data(packet[9..<(packet.count - 1)])
        )
    }
}

struct AnkerFrameStreamDecoder {
    private var buffer = Data()

    mutating func append(_ bytes: Data) -> [AnkerFrame] {
        buffer.append(bytes)
        var frames: [AnkerFrame] = []

        while true {
            while buffer.count >= 2 && buffer.prefix(2) != AnkerFrame.header {
                buffer = Data(buffer.dropFirst())
            }
            guard buffer.count >= 4 else { break }

            let length = Int(buffer[2]) | (Int(buffer[3]) << 8)
            guard (10...4096).contains(length) else {
                buffer = Data(buffer.dropFirst())
                continue
            }
            guard buffer.count >= length else { break }

            let candidate = Data(buffer.prefix(length))
            do {
                frames.append(try AnkerFrame.decode(candidate))
                buffer = Data(buffer.dropFirst(length))
            } catch {
                buffer = Data(buffer.dropFirst())
            }
        }

        return frames
    }
}

enum AnkerTLV {
    static func build(_ fields: [(UInt8, Data)]) throws -> Data {
        var payload = Data()
        for (tag, value) in fields {
            guard value.count <= Int(UInt8.max) else {
                throw AnkerProtocolError.invalidTLV("field 0x\(String(format: "%02X", tag)) is too large")
            }
            payload.append(tag)
            payload.append(UInt8(value.count))
            payload.append(value)
        }
        return payload
    }

    static func parse(_ payload: Data) throws -> [UInt8: Data] {
        var index = payload.startIndex
        if payload.first == 0x00 { index += 1 }
        var fields: [UInt8: Data] = [:]

        while index < payload.endIndex {
            guard payload.distance(from: index, to: payload.endIndex) >= 2 else {
                throw AnkerProtocolError.invalidTLV("missing length")
            }
            let tag = payload[index]
            index += 1
            let length = Int(payload[index])
            index += 1
            guard payload.distance(from: index, to: payload.endIndex) >= length else {
                throw AnkerProtocolError.invalidTLV("truncated field 0x\(String(format: "%02X", tag))")
            }
            let end = payload.index(index, offsetBy: length)
            fields[tag] = Data(payload[index..<end])
            index = end
        }
        return fields
    }

    // A2687 asynchronous reports use a typed variant:
    // <tag> <data-length> <type> <data>. The type byte is not counted in length.
    // Return type+data as the value so the rest of the decoder can share one model.
    static func parseTyped(_ payload: Data) throws -> [UInt8: Data] {
        var index = payload.startIndex
        if payload.first == 0x00 { index += 1 }
        var fields: [UInt8: Data] = [:]

        while index < payload.endIndex {
            guard payload.distance(from: index, to: payload.endIndex) >= 3 else {
                throw AnkerProtocolError.invalidTLV("missing typed field header")
            }
            let tag = payload[index]
            index += 1
            let dataLength = Int(payload[index])
            index += 1
            let valueLength = dataLength + 1
            guard payload.distance(from: index, to: payload.endIndex) >= valueLength else {
                throw AnkerProtocolError.invalidTLV(
                    "truncated typed field 0x\(String(format: "%02X", tag))"
                )
            }
            let end = payload.index(index, offsetBy: valueLength)
            fields[tag] = Data(payload[index..<end])
            index = end
        }
        return fields
    }
}

enum AES128GCM {
    static func encrypt(
        _ plaintext: Data,
        key: Data,
        nonce: Data,
        authenticatedData: Data
    ) throws -> Data {
        guard key.count == 16, nonce.count == 12 else {
            throw AnkerProtocolError.invalidKey
        }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: AES.GCM.Nonce(data: nonce),
            authenticating: authenticatedData
        )
        return sealed.ciphertext + sealed.tag
    }

    static func decrypt(
        _ ciphertextAndTag: Data,
        key: Data,
        nonce: Data,
        authenticatedData: Data
    ) throws -> Data {
        guard key.count == 16, nonce.count == 12, ciphertextAndTag.count >= 16 else {
            throw AnkerProtocolError.invalidKey
        }
        let tagStart = ciphertextAndTag.index(ciphertextAndTag.endIndex, offsetBy: -16)
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertextAndTag[..<tagStart],
            tag: ciphertextAndTag[tagStart...]
        )
        return try AES.GCM.open(
            box,
            using: SymmetricKey(data: key),
            authenticating: authenticatedData
        )
    }
}

enum AES128CBC {
    static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(plaintext, operation: CCOperation(kCCEncrypt), key: key, iv: iv)
    }

    static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(ciphertext, operation: CCOperation(kCCDecrypt), key: key, iv: iv)
    }

    private static func crypt(
        _ input: Data,
        operation: CCOperation,
        key: Data,
        iv: Data
    ) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw AnkerProtocolError.invalidKey
        }

        let outputCapacity = input.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            input.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw AnkerProtocolError.cryptoFailure(status)
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }
}

struct PortControlUpdate: Equatable, Sendable {
    var portIndex: Int
    var isOutputEnabled: Bool? = nil
    var remainingSeconds: UInt32? = nil
}

struct AnkerSessionUpdate {
    var outboundPackets: [Data] = []
    var identity: ChargerIdentity?
    var telemetry: ChargerTelemetry?
    var portControl: PortControlUpdate?
    var settings: ChargerSettingsUpdate?
    var portHistory: ChargerPortHistory?
    var becameReady = false
    var diagnostics: [String] = []
}

final class LegacyAnkerSession {
    private static let clientPrivateKeyHex =
        "7dfbea61cd95cee49c458ad7419e817f1ade9a66136de3c7d5787af1458e39f4"
    private static let rollingTimestampBase: UInt32 = 0x698CAD42

    // Captured FF09 negotiation writes from the MIT-licensed Anker-BLE A2687 PoC.
    private static let negotiationPackets: [Data] = [
        try! Data(hex: "ff0936000300010001a10442ad8c69a22462326463306231372d623735642d346162662d626136652d656337633939376332336537b9"),
        try! Data(hex: "ff093d000300010003a10442ad8c69a22462326463306231372d623735642d346162662d626136652d656337633939376332336537a30120a40200f064"),
        try! Data(hex: "ff0936000300010029a10442ad8c69a22462326463306231372d623735642d346162662d626136652d65633763393937633233653791"),
        try! Data(hex: "ff0940000300010005a10443ad8c69a22462326463306231372d623735642d346162662d626136652d656337633939376332336537a30120a40200f0a50140fa"),
        try! Data(hex: "ff094c000300010021a140060ea168f232aedb37fb2d120c49180329ac72ab5ec3eb8fd30a2f252dc5e151dabccd9b1dc1e288704ca760a0d8c918e5c94823a1f609a4bf07fb4c33ee219085"),
        try! Data(hex: "ff095a000300014022580bc0532a53c739adf3da7b994a7b5f221bcc16bab6392c215cb4faaf41d9d58e2c81c016e474c78eed5569147cb74a1f22ca2b3fad2e209dbbcfbdaca352034a6c479f055f68581b5f1e22348809f526")
    ]

    private static let nextStage: [UInt16: Int] = [
        0x0801: 1,
        0x0803: 2,
        0x0829: 3,
        0x0805: 4,
        0x0821: 5
    ]

    private static let negotiationPattern = try! Data(hex: "030001")
    private static let sessionPatterns: Set<Data> = [
        try! Data(hex: "03000f"),
        try! Data(hex: "03010f"),
        try! Data(hex: "030111")
    ]
    private var sharedSecret: Data?
    private var negotiationStartedAt: Date?
    private(set) var isReady = false

    func reset() {
        sharedSecret = nil
        negotiationStartedAt = nil
        isReady = false
    }

    func start() -> Data {
        reset()
        return Self.negotiationPackets[0]
    }

    func receive(_ frame: AnkerFrame) throws -> AnkerSessionUpdate {
        if frame.pattern == Self.negotiationPattern {
            return try receiveNegotiation(frame)
        }
        if Self.sessionPatterns.contains(frame.pattern), let secret = sharedSecret {
            return receiveSession(frame, secret: secret)
        }
        return AnkerSessionUpdate()
    }

    func makeTelemetrySubscription(now: Date = Date()) throws -> Data {
        guard let secret = sharedSecret else { throw AnkerProtocolError.sessionNotReady }

        let elapsed = UInt32(max(0, Int(now.timeIntervalSince(negotiationStartedAt ?? now))))
        var payload = Data([0xA1, 0x01, 0x21, 0xFE, 0x05, 0x03])
        payload.appendLittleEndian(Self.rollingTimestampBase &+ elapsed)

        let encrypted = try AES128CBC.encrypt(
            payload,
            key: Data(secret.prefix(16)),
            iv: Data(secret.dropFirst(16).prefix(16))
        )
        return try AnkerFrame(
            pattern: try Data(hex: "03000f"),
            command: 0x4200,
            payload: encrypted
        ).encode()
    }

    private func receiveNegotiation(_ frame: AnkerFrame) throws -> AnkerSessionUpdate {
        guard let stage = Self.nextStage[frame.command] else {
            return AnkerSessionUpdate()
        }

        var update = AnkerSessionUpdate(outboundPackets: [Self.negotiationPackets[stage]])
        if frame.command == 0x0829 {
            negotiationStartedAt = Date()
            update.identity = try parseIdentity(frame.payload)
        } else if frame.command == 0x0821 {
            sharedSecret = try deriveSharedSecret(from: frame.payload)
            isReady = true
            update.becameReady = true
        }
        return update
    }

    private func receiveSession(_ frame: AnkerFrame, secret: Data) -> AnkerSessionUpdate {
        var candidates = [frame.payload]
        if frame.payload.count > 1, (frame.payload.count - 1).isMultiple(of: 16) {
            candidates.append(Data(frame.payload.dropFirst()))
        }

        for candidate in candidates where candidate.count.isMultiple(of: 16) {
            do {
                let plaintext = try AES128CBC.decrypt(
                    candidate,
                    key: Data(secret.prefix(16)),
                    iv: Data(secret.dropFirst(16).prefix(16))
                )
                let fields = try AnkerTLV.parse(plaintext)
                if let telemetry = Self.parseTelemetry(fields) {
                    let command = frame.command & 0x37FF
                    return AnkerSessionUpdate(
                        telemetry: telemetry,
                        settings: AnkerSession.parseSettings(fields, command: command),
                        diagnostics: ["AES-CBC telemetry response 0x\(String(format: "%04X", frame.command))"]
                    )
                }
                let fieldShape = fields
                    .sorted { $0.key < $1.key }
                    .map { "\(String(format: "%02X", $0.key)):\($0.value.count)" }
                    .joined(separator: ",")
                return AnkerSessionUpdate(
                    diagnostics: ["AES-CBC response 0x\(String(format: "%04X", frame.command)) TLVs [\(fieldShape)] (no port values)"]
                )
            } catch {
                continue
            }
        }
        return AnkerSessionUpdate()
    }

    private func deriveSharedSecret(from payload: Data) throws -> Data {
        let fields = try AnkerTLV.parse(payload)
        guard let coordinates = fields[0xA1], coordinates.count == 64 else {
            throw AnkerProtocolError.invalidKey
        }

        var publicRepresentation = Data([0x04])
        publicRepresentation.append(coordinates)
        let privateKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex: Self.clientPrivateKeyHex)
        )
        let publicKey = try P256.KeyAgreement.PublicKey(
            x963Representation: publicRepresentation
        )
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.withUnsafeBytes { Data($0) }
    }

    private func parseIdentity(_ payload: Data) throws -> ChargerIdentity {
        let fields = try AnkerTLV.parse(payload)
        func ascii(_ tag: UInt8) -> String? {
            guard let data = fields[tag], !data.isEmpty else { return nil }
            return String(data: data, encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces))
        }

        var mac: String?
        if let value = fields[0xA5], value.count >= 6 {
            mac = value.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        return ChargerIdentity(
            productName: ascii(0xA2),
            firmware: ascii(0xA3),
            serialNumber: ascii(0xA4),
            macAddress: mac
        )
    }

    static func parseTelemetry(_ fields: [UInt8: Data], at date: Date = Date()) -> ChargerTelemetry? {
        var ports = (1...3).map(PortTelemetry.inactive)
        var foundPort = false

        for (offset, tag) in [UInt8(0xA5), 0xA6, 0xA7].enumerated() {
            guard let value = fields[tag], value.count >= 8, value[0] == 0x04 else { continue }
            let voltageMV = littleEndian16(value, at: 2)
            let currentMA = littleEndian16(value, at: 4)
            let powerCentiW = littleEndian16(value, at: 6)
            let power = Double(powerCentiW) / 100
            ports[offset] = PortTelemetry(
                index: offset + 1,
                isActive: value[1] != 0 && power > 0.05,
                voltage: Double(voltageMV) / 1_000,
                current: Double(currentMA) / 1_000,
                power: power
            )
            foundPort = true
        }

        // Other A2687 firmware uses typed scalar TLVs instead:
        // A2-A4 voltage in 0.1 V, A5-A7 current in 0.1 A, and B0-B2 power in W.
        if !foundPort {
            for offset in 0..<3 {
                let voltageRaw = typedUnsigned(fields[UInt8(0xA2 + offset)])
                let currentRaw = typedUnsigned(fields[UInt8(0xA5 + offset)])
                let powerRaw = typedUnsigned(fields[UInt8(0xB0 + offset)])
                guard currentRaw != nil || powerRaw != nil else { continue }

                let voltage = voltageRaw.map { Double($0) / 10 } ?? 0
                let current = currentRaw.map { Double($0) / 10 } ?? 0
                let power = powerRaw.map(Double.init) ?? (voltage * current)
                ports[offset] = PortTelemetry(
                    index: offset + 1,
                    isActive: power > 0.05,
                    voltage: voltage,
                    current: current,
                    power: power
                )
                foundPort = true
            }
        }

        // Some related Prime firmware reports an eight-byte port shape in A2/A3/A4.
        if !foundPort {
            for (offset, tag) in [UInt8(0xA2), 0xA3, 0xA4].enumerated() {
                guard let value = fields[tag], value.count >= 8 else { continue }
                let power = Double(littleEndian16(value, at: 6)) / 100
                ports[offset] = PortTelemetry(
                    index: offset + 1,
                    isActive: power > 0.05,
                    voltage: value[0] == 0x04 ? Double(littleEndian16(value, at: 2)) / 1_000 : 0,
                    current: value[0] == 0x04 ? Double(littleEndian16(value, at: 4)) / 1_000 : 0,
                    power: power
                )
                foundPort = true
            }
        }

        guard foundPort else { return nil }
        applyPortDetails(fields, to: &ports)
        return ChargerTelemetry(
            ports: ports,
            receivedAt: date,
            chargingMode: chargingMode(fields)
        )
    }

    private static func applyPortDetails(
        _ fields: [UInt8: Data],
        to ports: inout [PortTelemetry]
    ) {
        for (offset, tag) in [UInt8(0xAC), 0xAD, 0xAE].enumerated() {
            guard let value = fields[tag], value.first == 0x04, value.count >= 3 else { continue }
            let cableCode = value[value.count - 2]
            let chargingCode = value[value.count - 1]

            switch cableCode {
            case 0x00: ports[offset].cableInfo = "3A–60W Max"
            case 0x01: ports[offset].cableInfo = "5A–100W Max"
            case 0x02: ports[offset].cableInfo = "EPR–240W Max"
            case 0x03: ports[offset].cableInfo = nil
            default: break
            }

            switch chargingCode {
            case 0x01: ports[offset].chargingInfo = "Apple PD Fast Charging"
            case 0x02: ports[offset].chargingInfo = "Samsung Fast Charging"
            case 0x03: ports[offset].chargingInfo = "Samsung Super Fast Charging"
            default: break
            }
        }

        applyConnectedDevices(fields, to: &ports)
    }

    private static func applyConnectedDevices(
        _ fields: [UInt8: Data],
        to ports: inout [PortTelemetry]
    ) {
        let isAIMode = chargingMode(fields) == .ai2
        guard let identityPayload = typedByteArray(fields[0xB4]),
              identityPayload.count >= 12 else { return }

        let brands = (0..<3).map { littleEndian32(identityPayload, at: $0 * 4) }
        let looksLikeBrandCodes = brands.contains(where: { $0 != 0 })
            && brands.allSatisfy { $0 <= 0x13 }

        if looksLikeBrandCodes {
            let models: [UInt32] = {
                guard let modelPayload = typedByteArray(fields[0xB5]),
                      modelPayload.count >= 12 else {
                    return Array(repeating: 0, count: 3)
                }
                return (0..<3).map { littleEndian32(modelPayload, at: $0 * 4) }
            }()
            for offset in 0..<3 {
                guard let brandName = DeviceCatalog.brandName(brands[offset]) else { continue }
                ports[offset].deviceInfo = DeviceCatalog.deviceLabel(
                    brand: brandName,
                    model: models[offset]
                )
            }
            return
        }

        for offset in 0..<3 {
            let vid = littleEndian16(identityPayload, at: offset * 4)
            let pid = littleEndian16(identityPayload, at: offset * 4 + 2)
            if let ankerProtocol = DeviceCatalog.ankerProtocolLabel(
                vid: vid,
                pid: pid,
                isAIMode: isAIMode
            ) {
                ports[offset].chargingInfo = ankerProtocol
            }
            if let label = DeviceCatalog.usbDeviceLabel(vid: vid, pid: pid) {
                ports[offset].deviceInfo = label
            }
        }
    }

    private static func chargingMode(_ fields: [UInt8: Data]) -> ChargerChargingMode? {
        guard let mode = typedUnsigned(fields[0xAA]) else { return nil }
        switch mode {
        case 0: return .ai2
        case 1:
            return typedUnsigned(fields[0xAF]) == 0 ? .dualLaptop : .c1Priority
        case 4: return .custom
        default: return nil
        }
    }

    private static func typedByteArray(_ data: Data?) -> Data? {
        guard let data, data.first == 0x04, data.count > 1 else { return nil }
        return Data(data.dropFirst())
    }

    private static func littleEndian16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
    }

    private static func littleEndian32(_ data: Data, at index: Int) -> UInt32 {
        UInt32(data[index])
            | (UInt32(data[index + 1]) << 8)
            | (UInt32(data[index + 2]) << 16)
            | (UInt32(data[index + 3]) << 24)
    }

    private static func typedUnsigned(_ data: Data?) -> UInt32? {
        guard let data, let type = data.first else { return nil }
        switch type {
        case 0x01 where data.count >= 2:
            return UInt32(data[1])
        case 0x02 where data.count >= 3:
            return UInt32(data[1]) | (UInt32(data[2]) << 8)
        case 0x03 where data.count >= 5:
            return UInt32(data[1])
                | (UInt32(data[2]) << 8)
                | (UInt32(data[3]) << 16)
                | (UInt32(data[4]) << 24)
        default:
            return nil
        }
    }
}

enum AnkerSessionTransport: String, Sendable {
    case modernAESGCM = "AES-GCM"
    case legacyAESCBC = "AES-CBC fallback"
}

private final class ModernAnkerSession {
    private enum HandshakeStage {
        case response0001
        case response0003
        case response0029
        case response0005
        case response0021
        case complete
    }

    private static let initialKey = try! Data(hex: "b8ff7422955d4eb6d554a2c470280559")
    private static let initialNonce = try! Data(hex: "6ba3e3f2f3a60f2971ce5d1f")
    private static let authenticatedData = try! Data(hex: "3322110077665544bbaa9988ffeeddcc")
    private static let sessionToken = try! Data(hex: "62303932663861346533663832363864376230646339643564336538643062396431306465646264")
    private static let realtimeA2 = try! Data(hex: "045553")
    private static let realtimeA3 = try! Data(hex: "0462303932663861346533663832363864376230646339643564336538643062396431306465646264")
    private static let sessionPatterns: Set<Data> = [
        try! Data(hex: "03000f"),
        try! Data(hex: "03010f"),
        try! Data(hex: "030111")
    ]
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var key: Data?
    private var nonce: Data?
    private var handshakeTimestamp = Data()
    private var stage: HandshakeStage = .response0001
    private var lastSessionDecryptFailureAt: Date?
    private var didLogFieldSnapshot = false
    private(set) var isReady = false

    func reset() {
        privateKey = nil
        key = nil
        nonce = nil
        handshakeTimestamp = Data()
        stage = .response0001
        lastSessionDecryptFailureAt = nil
        didLogFieldSnapshot = false
        isReady = false
    }

    func start(now: Date = Date()) throws -> Data {
        reset()
        privateKey = P256.KeyAgreement.PrivateKey()
        key = Self.initialKey
        nonce = Self.initialNonce
        handshakeTimestamp = Self.epochTimestamp(now)
        return try makePacket(
            group: 0x01,
            command: 0x0001,
            fields: [(0xA1, handshakeTimestamp)]
        )
    }

    func receive(_ frame: AnkerFrame) throws -> AnkerSessionUpdate {
        guard let key, let nonce else {
            return AnkerSessionUpdate()
        }
        // 0x4000 is encrypted, 0x0800 is ACK, and some firmware sets 0x8000 on replies.
        let command = frame.command & 0x37FF

        if !isReady {
            guard frame.command & 0x4000 != 0 else { return AnkerSessionUpdate() }
            let plaintext = try AES128GCM.decrypt(
                frame.payload,
                key: key,
                nonce: nonce,
                authenticatedData: Self.authenticatedData
            )
            return try receiveHandshake(command: command, plaintext: plaintext)
        }
        return receiveSession(frame, command: command, key: key, nonce: nonce)
    }

    private func receiveSession(
        _ frame: AnkerFrame,
        command: UInt16,
        key: Data,
        nonce: Data
    ) -> AnkerSessionUpdate {
        let hasEncryptionFlag = frame.command & 0x4000 != 0
        guard hasEncryptionFlag || Self.sessionPatterns.contains(frame.pattern) else {
            return AnkerSessionUpdate()
        }

        var candidates = [frame.payload]
        // Firmware v0.0.5.2 emits authenticated 030111/03010F reports without
        // the command encryption bit. Some multi-part variants add one prefix byte.
        if frame.payload.count > 17 {
            candidates.append(Data(frame.payload.dropFirst()))
        }

        var decodedPayloads: [(source: String, data: Data)] = []
        for candidate in candidates where candidate.count >= 16 {
            if let plaintext = try? AES128GCM.decrypt(
                candidate,
                key: key,
                nonce: nonce,
                authenticatedData: Self.authenticatedData
            ) {
                decodedPayloads.append(("AES-GCM", plaintext))
            }
        }

        // The v0.0.5.2 asynchronous 0300/0A00 stream omits the encryption bit
        // and may carry a typed TLV report directly. Authentication is attempted
        // first; plaintext parsing is only allowed when the device omitted the bit.
        if !hasEncryptionFlag {
            decodedPayloads.append(("plaintext", frame.payload))
            if frame.payload.count > 1 {
                decodedPayloads.append(("prefixed plaintext", Data(frame.payload.dropFirst())))
            }
        }

        for decoded in decodedPayloads {
            // These are session acknowledgements; their small status bodies are not
            // consistently encoded as a complete TLV list across firmware versions.
            if command == 0x0022 || command == 0x0027 {
                return AnkerSessionUpdate(
                    diagnostics: ["AES-GCM session acknowledgement 0x\(Self.hex4(command))"]
                )
            }

            var variants: [(dialect: String, fields: [UInt8: Data])] = []
            if let fields = try? AnkerTLV.parse(decoded.data) {
                variants.append(("standard", fields))
            }
            if let fields = try? AnkerTLV.parseTyped(decoded.data) {
                variants.append(("typed", fields))
            }

            for variant in variants {
                let fieldShape = variant.fields
                    .sorted { $0.key < $1.key }
                    .map { "\(String(format: "%02X", $0.key)):\($0.value.count)" }
                    .joined(separator: ",")
                var update = AnkerSessionUpdate()
                var diagnostics: [String] = []

                if let telemetry = LegacyAnkerSession.parseTelemetry(variant.fields) {
                    lastSessionDecryptFailureAt = nil
                    diagnostics.append(
                        "Decoded \(decoded.source) \(variant.dialect) telemetry 0x\(Self.hex4(command)) TLVs [\(fieldShape)]"
                    )
                    if !didLogFieldSnapshot {
                        didLogFieldSnapshot = true
                        let snapshot = variant.fields
                            .sorted { $0.key < $1.key }
                            .map { "\(String(format: "%02X", $0.key))=\($0.value.hexString)" }
                            .joined(separator: ",")
                        diagnostics.append("Telemetry field snapshot [\(snapshot)]")
                    }
                    update.telemetry = telemetry
                }

                let settings = AnkerSession.parseSettings(variant.fields, command: command)
                if !settings.isEmpty {
                    lastSessionDecryptFailureAt = nil
                    diagnostics.append(
                        "Decoded \(decoded.source) \(variant.dialect) settings 0x\(Self.hex4(command))"
                    )
                    update.settings = settings
                }

                if command == 0x0307 || command == 0x0308,
                   let control = AnkerSession.parsePortControl(variant.fields) {
                    lastSessionDecryptFailureAt = nil
                    diagnostics.append(
                        "Decoded \(decoded.source) \(variant.dialect) port control 0x\(Self.hex4(command)) TLVs [\(fieldShape)]"
                    )
                    update.portControl = control
                }

                if command == 0x020C || command == 0x0A0C,
                   let history = AnkerSession.parsePortHistory(variant.fields) {
                    lastSessionDecryptFailureAt = nil
                    diagnostics.append(
                        "Decoded \(decoded.source) \(variant.dialect) port history 0x\(Self.hex4(command))"
                    )
                    update.portHistory = history
                }

                if update.telemetry != nil || update.settings != nil
                    || update.portControl != nil || update.portHistory != nil {
                    update.diagnostics = diagnostics
                    return update
                }
            }

            if let ack = Self.controlAcknowledgement(for: command) {
                return AnkerSessionUpdate(diagnostics: [ack])
            }
        }

        if command == 0x020A || command == 0x020C { return AnkerSessionUpdate() }
        let now = Date()
        if lastSessionDecryptFailureAt.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
            lastSessionDecryptFailureAt = now
            return AnkerSessionUpdate(
                diagnostics: ["Could not decode session frame pattern=\(frame.pattern.hexString) command=0x\(Self.hex4(command)) payload=\(frame.payload.count) bytes as authenticated or typed telemetry"]
            )
        }
        return AnkerSessionUpdate()
    }

    func makeStatusProbe(now: Date = Date()) throws -> Data {
        guard isReady else { throw AnkerProtocolError.sessionNotReady }
        return try makePacket(
            group: 0x0F,
            command: 0x0200,
            fields: [
                (0xA1, Data([0x21])),
                (0xFE, Self.epochTimestamp(now))
            ]
        )
    }

    func makeRealtimeProbe(now: Date = Date()) throws -> Data {
        guard isReady else { throw AnkerProtocolError.sessionNotReady }
        return try makePacket(
            group: 0x0F,
            command: 0x020A,
            fields: [
                (0xA1, Data([0x21])),
                (0xA2, Self.realtimeA2),
                (0xA3, Self.realtimeA3),
                (0xA5, Data([0x01, 0x01])),
                (0xFE, Self.epochTimestamp(now))
            ]
        )
    }

    func makePortOutput(portIndex: UInt8, isOn: Bool, now: Date = Date()) throws -> Data {
        guard isReady else { throw AnkerProtocolError.sessionNotReady }
        return try makePacket(
            group: 0x0F,
            command: 0x0207,
            fields: try AnkerSession.portOutputFields(portIndex: portIndex, isOn: isOn, now: now)
        )
    }

    func makePortShutdownTimer(portIndex: UInt8, seconds: UInt32, now: Date = Date()) throws -> Data {
        guard isReady else { throw AnkerProtocolError.sessionNotReady }
        return try makePacket(
            group: 0x0F,
            command: 0x0209,
            fields: try AnkerSession.portShutdownTimerFields(
                portIndex: portIndex,
                seconds: seconds,
                now: now
            )
        )
    }

    func makeChargingMode(_ mode: ChargerChargingMode, now: Date = Date()) throws -> [Data] {
        guard isReady else { throw AnkerProtocolError.sessionNotReady }
        var packets = [
            try makePacket(
                group: 0x0F,
                command: 0x0206,
                fields: AnkerSession.singleValueFields(mode.protocolValue, now: now)
            )
        ]
        if let allocation = mode.fixedAllocationValue {
            packets.append(try makePacket(
                group: 0x0F,
                command: 0x0205,
                fields: AnkerSession.singleValueFields(allocation, now: now)
            ))
        }
        return packets
    }

    func makeCustomChargeMode(_ split: CustomChargeSplit, now: Date = Date()) throws -> Data {
        guard isReady else { throw AnkerProtocolError.sessionNotReady }
        return try makePacket(
            group: 0x0F,
            command: 0x0206,
            fields: try AnkerSession.customChargeFields(split, now: now)
        )
    }

    func makeLanguage(_ language: ChargerLanguage, now: Date = Date()) throws -> Data {
        try makeSetting(command: 0x0202, value: language.rawValue, now: now)
    }

    func makeScreenTimeout(_ timeout: ChargerScreenTimeout, now: Date = Date()) throws -> Data {
        try makeSetting(command: 0x0203, value: timeout.rawValue, now: now)
    }

    func makeScreenBrightness(_ percent: UInt8, now: Date = Date()) throws -> Data {
        try makeSetting(command: 0x0204, value: min(100, max(25, percent)), now: now)
    }

    func makeScreenOrientation(_ orientation: ChargerOrientation, now: Date = Date()) throws -> Data {
        try makeSetting(command: 0x020B, value: orientation.rawValue, now: now)
    }

    func makeAutoRotate(_ enabled: Bool, now: Date = Date()) throws -> Data {
        try makeSetting(command: 0x020D, value: enabled ? 1 : 0, now: now)
    }

    func makePortHistoryProbe(now: Date = Date()) throws -> Data {
        guard isReady else { throw AnkerProtocolError.sessionNotReady }
        return try makePacket(
            group: 0x0F,
            command: 0x020C,
            fields: [
                (0xA1, Data([0x21])),
                (0xA2, Data([0x01, 0x00])),
                (0xFE, Self.epochTimestamp(now))
            ]
        )
    }

    private func makeSetting(command: UInt16, value: UInt8, now: Date) throws -> Data {
        guard isReady else { throw AnkerProtocolError.sessionNotReady }
        return try makePacket(
            group: 0x0F,
            command: command,
            fields: AnkerSession.singleValueFields(value, now: now)
        )
    }

    private static func controlAcknowledgement(for command: UInt16) -> String? {
        switch command {
        case 0x0202: return "Language setting acknowledged"
        case 0x0203: return "Screen timeout acknowledged"
        case 0x0204: return "Screen brightness acknowledged"
        case 0x0205: return "Fixed allocation acknowledged"
        case 0x0206: return "Charging mode acknowledged"
        case 0x0207: return "Port output switch acknowledged"
        case 0x0209: return "Port shutdown timer acknowledged"
        case 0x020B: return "Screen orientation acknowledged"
        case 0x020D: return "Auto-rotate setting acknowledged"
        default: return nil
        }
    }

    private func receiveHandshake(
        command: UInt16,
        plaintext: Data
    ) throws -> AnkerSessionUpdate {
        switch (stage, command) {
        case (.response0001, 0x0001):
            stage = .response0003
            return AnkerSessionUpdate(
                outboundPackets: [try makePacket(
                    group: 0x01,
                    command: 0x0003,
                    fields: [
                        (0xA1, handshakeTimestamp),
                        (0xA3, Data([0x20])),
                        (0xA4, Data([0x00, 0xF0]))
                    ]
                )],
                diagnostics: ["AES-GCM handshake 1/5 acknowledged"]
            )

        case (.response0003, 0x0003):
            stage = .response0029
            return AnkerSessionUpdate(
                outboundPackets: [try makePacket(
                    group: 0x01,
                    command: 0x0029,
                    fields: [(0xA1, handshakeTimestamp)]
                )],
                diagnostics: ["AES-GCM handshake 2/5 acknowledged"]
            )

        case (.response0029, 0x0029):
            stage = .response0005
            return AnkerSessionUpdate(
                outboundPackets: [try makePacket(
                    group: 0x01,
                    command: 0x0005,
                    fields: [
                        (0xA1, Self.epochTimestamp()),
                        (0xA3, Data([0x20])),
                        (0xA4, Data([0x29, 0x01])),
                        (0xA5, Data([0x44])),
                        (0xA6, Data([0x02]))
                    ]
                )],
                identity: try Self.parseIdentity(plaintext),
                diagnostics: ["AES-GCM handshake 3/5 acknowledged; charger identity received"]
            )

        case (.response0005, 0x0005):
            guard let publicKey = privateKey?.publicKey.x963Representation,
                  publicKey.count == 65 else {
                throw AnkerProtocolError.invalidKey
            }
            stage = .response0021
            return AnkerSessionUpdate(
                outboundPackets: [try makePacket(
                    group: 0x01,
                    command: 0x0021,
                    fields: [(0xA1, Data(publicKey.dropFirst()))]
                )],
                diagnostics: ["AES-GCM handshake 4/5 acknowledged; exchanging ephemeral key"]
            )

        case (.response0021, 0x0021):
            try installSessionKey(from: plaintext)
            stage = .complete
            isReady = true
            return AnkerSessionUpdate(
                outboundPackets: try makeSessionSetupPackets(),
                becameReady: true,
                diagnostics: ["AES-GCM handshake 5/5 complete; live session key derived"]
            )

        default:
            return AnkerSessionUpdate(
                diagnostics: ["Ignored out-of-order AES-GCM handshake response 0x\(Self.hex4(command))"]
            )
        }
    }

    private func installSessionKey(from payload: Data) throws {
        let fields = try AnkerTLV.parse(payload)
        guard let coordinates = fields[0xA1], coordinates.count == 64,
              let privateKey else {
            throw AnkerProtocolError.invalidKey
        }
        var publicRepresentation = Data([0x04])
        publicRepresentation.append(coordinates)
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: publicRepresentation)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let bytes = sharedSecret.withUnsafeBytes { Data($0) }
        guard bytes.count == 32 else { throw AnkerProtocolError.invalidKey }
        key = Data(bytes.prefix(16))
        nonce = Data(bytes.dropFirst(16).prefix(12))
    }

    private func makeSessionSetupPackets(now: Date = Date()) throws -> [Data] {
        [
            try makePacket(
                group: 0x01,
                command: 0x0022,
                fields: [
                    (0xA1, Self.epochTimestamp(now)),
                    (0xA3, Data([0x80, 0x8F, 0xFF, 0xFF])),
                    (0xA5, Data("CST-8".utf8))
                ]
            ),
            try makePacket(
                group: 0x01,
                command: 0x0027,
                fields: [
                    (0xA1, Self.epochTimestamp(now)),
                    (0xA2, Self.sessionToken)
                ]
            ),
            try makeStatusProbe(now: now),
            try makeRealtimeProbe(now: now)
        ]
    }

    private func makePacket(
        group: UInt8,
        command: UInt16,
        fields: [(UInt8, Data)]
    ) throws -> Data {
        guard let key, let nonce else { throw AnkerProtocolError.sessionNotReady }
        let plaintext = try AnkerTLV.build(fields)
        let encrypted = try AES128GCM.encrypt(
            plaintext,
            key: key,
            nonce: nonce,
            authenticatedData: Self.authenticatedData
        )
        return try AnkerFrame(
            pattern: Data([0x03, 0x00, group]),
            command: command | 0x4000,
            payload: encrypted
        ).encode()
    }

    private static func parseIdentity(_ payload: Data) throws -> ChargerIdentity {
        let fields = try AnkerTLV.parse(payload)
        func ascii(_ tag: UInt8) -> String? {
            guard let data = fields[tag], !data.isEmpty else { return nil }
            let text = String(data: data, encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces))
            return text?.isEmpty == false ? text : nil
        }

        var mac: String?
        if let value = fields[0xA5], value.count >= 6,
           !value.prefix(6).allSatisfy({ $0 == 0 }) {
            mac = value.prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
        }
        return ChargerIdentity(
            productName: ascii(0xA2),
            firmware: ascii(0xA3),
            serialNumber: ascii(0xA4),
            macAddress: mac
        )
    }

    private static func epochTimestamp(_ date: Date = Date()) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(max(0, date.timeIntervalSince1970)))
        return data
    }

    private static func hex4(_ value: UInt16) -> String {
        String(format: "%04X", value)
    }
}

final class AnkerSession {
    private let modern = ModernAnkerSession()
    private let legacy = LegacyAnkerSession()

    private(set) var transport: AnkerSessionTransport = .modernAESGCM

    var isReady: Bool {
        switch transport {
        case .modernAESGCM: return modern.isReady
        case .legacyAESCBC: return legacy.isReady
        }
    }

    func reset() {
        modern.reset()
        legacy.reset()
        transport = .modernAESGCM
    }

    func start(now: Date = Date()) throws -> Data {
        legacy.reset()
        transport = .modernAESGCM
        return try modern.start(now: now)
    }

    func startLegacy() -> Data {
        modern.reset()
        transport = .legacyAESCBC
        return legacy.start()
    }

    func receive(_ frame: AnkerFrame) throws -> AnkerSessionUpdate {
        switch transport {
        case .modernAESGCM: return try modern.receive(frame)
        case .legacyAESCBC: return try legacy.receive(frame)
        }
    }

    func makeStatusProbe(now: Date = Date()) throws -> Data {
        try modern.makeStatusProbe(now: now)
    }

    func makeRealtimeProbe(now: Date = Date()) throws -> Data {
        try modern.makeRealtimeProbe(now: now)
    }

    func makePortOutput(portIndex: UInt8, isOn: Bool, now: Date = Date()) throws -> Data {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makePortOutput(portIndex: portIndex, isOn: isOn, now: now)
    }

    func makePortShutdownTimer(portIndex: UInt8, seconds: UInt32, now: Date = Date()) throws -> Data {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makePortShutdownTimer(portIndex: portIndex, seconds: seconds, now: now)
    }

    func makeChargingMode(_ mode: ChargerChargingMode, now: Date = Date()) throws -> [Data] {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makeChargingMode(mode, now: now)
    }

    func makeCustomChargeMode(_ split: CustomChargeSplit, now: Date = Date()) throws -> Data {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makeCustomChargeMode(split, now: now)
    }

    func makeLanguage(_ language: ChargerLanguage, now: Date = Date()) throws -> Data {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makeLanguage(language, now: now)
    }

    func makeScreenTimeout(_ timeout: ChargerScreenTimeout, now: Date = Date()) throws -> Data {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makeScreenTimeout(timeout, now: now)
    }

    func makeScreenBrightness(_ percent: UInt8, now: Date = Date()) throws -> Data {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makeScreenBrightness(percent, now: now)
    }

    func makeScreenOrientation(_ orientation: ChargerOrientation, now: Date = Date()) throws -> Data {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makeScreenOrientation(orientation, now: now)
    }

    func makeAutoRotate(_ enabled: Bool, now: Date = Date()) throws -> Data {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makeAutoRotate(enabled, now: now)
    }

    func makePortHistoryProbe(now: Date = Date()) throws -> Data {
        guard transport == .modernAESGCM else { throw AnkerProtocolError.sessionNotReady }
        return try modern.makePortHistoryProbe(now: now)
    }

    func makeTelemetrySubscription(now: Date = Date()) throws -> Data {
        try legacy.makeTelemetrySubscription(now: now)
    }

    var supportsPortControl: Bool {
        transport == .modernAESGCM && isReady
    }

    static func singleValueFields(_ value: UInt8, now: Date = Date()) -> [(UInt8, Data)] {
        [
            (0xA1, Data([0x21])),
            (0xA2, Data([0x01, value])),
            (0xFE, epochBytes(now))
        ]
    }

    static func customChargeFields(_ split: CustomChargeSplit, now: Date = Date()) throws -> [(UInt8, Data)] {
        if let error = split.validationError {
            throw AnkerProtocolError.invalidTLV(error)
        }
        let powerArray = Data([
            split.profileNumber,
            split.autoExit ? 1 : 0,
            split.c1,
            split.c2,
            split.c3
        ])
        let protocolArray = Data([
            split.protocolMasks[safe: 0] ?? 0x3B, 0, 0,
            split.protocolMasks[safe: 1] ?? 0x3B, 0, 0,
            split.protocolMasks[safe: 2] ?? 0x3B, 0, 0
        ])
        return [
            (0xA1, Data([0x21])),
            (0xA2, Data([0x01, 0x04])),
            (0xA3, Data([0x04]) + powerArray),
            (0xA4, Data([0x04]) + protocolArray),
            (0xFE, epochBytes(now))
        ]
    }

    static func parseSettings(_ fields: [UInt8: Data], command: UInt16) -> ChargerSettingsUpdate {
        var update = ChargerSettingsUpdate()
        let a2 = typedControlUnsigned(fields[0xA2])

        switch command {
        case 0x0202, 0x030B:
            if let value = a2, let language = ChargerLanguage(rawValue: UInt8(truncatingIfNeeded: value)) {
                update.language = language
            }
        case 0x0203, 0x0304:
            if let value = a2, let timeout = ChargerScreenTimeout(rawValue: UInt8(truncatingIfNeeded: value)) {
                update.screenTimeout = timeout
            }
        case 0x0204:
            if let value = a2, (25...100).contains(Int(value)) {
                update.brightnessPercent = Int(value)
            }
        case 0x020B:
            if let value = a2, let orientation = ChargerOrientation(rawValue: UInt8(truncatingIfNeeded: value)) {
                update.orientation = orientation
            }
        case 0x020D:
            if let value = a2, value <= 1 {
                update.autoRotate = value == 1
            }
        case 0x0205:
            if let value = a2 {
                update.chargingMode = value == 0 ? .dualLaptop : .c1Priority
            }
        case 0x0206, 0x0303:
            if let value = a2 {
                switch value {
                case 0: update.chargingMode = .ai2
                case 1: update.chargingMode = typedControlUnsigned(fields[0xAF]) == 0 ? .dualLaptop : .c1Priority
                case 4: update.chargingMode = .custom
                default: break
                }
            }
            update.customSplit = parseCustomSplit(fields)
        case 0x0200, 0x0300, 0x020A:
            if let brightness = typedControlUnsigned(fields[0xA9]), (25...100).contains(Int(brightness)) {
                update.brightnessPercent = Int(brightness)
            }
            if let code = typedUInt8(fields[0xA8]) ?? typedUInt8(fields[0xAB]),
               (1...63).contains(code) {
                update.fault = ChargerFault.from(errorCode: code)
            }
            if let mode = parseTelemetry(fields)?.chargingMode {
                update.chargingMode = mode
            }
        case 0x0301:
            if let code = a2 ?? typedControlUnsigned(fields[0xA1]), code <= 63 {
                update.fault = ChargerFault.from(errorCode: code)
            }
        case 0x0302:
            if let value = a2, (25...100).contains(Int(value)) {
                update.brightnessPercent = Int(value)
            }
        default:
            break
        }

        return update
    }

    static func parseCustomSplit(_ fields: [UInt8: Data]) -> CustomChargeSplit? {
        guard let power = typedByteArray(fields[0xA3]), power.count >= 5 else { return nil }
        var split = CustomChargeSplit(
            profileNumber: power[0],
            autoExit: power[1] == 1,
            portWatts: [power[2], power[3], power[4]]
        )
        if let protocols = typedByteArray(fields[0xA4]), protocols.count >= 9 {
            split.protocolMasks = [protocols[0], protocols[3], protocols[6]]
        }
        return split
    }

    static func parsePortHistory(
        _ fields: [UInt8: Data],
        at date: Date = Date()
    ) -> ChargerPortHistory? {
        var arrays: [(UInt8, [UInt16])] = []
        for (tag, value) in fields.sorted(by: { $0.key < $1.key }) {
            let bytes: Data
            if let typed = typedByteArray(value) {
                bytes = typed
            } else if value.count >= 8 {
                bytes = value
            } else {
                continue
            }
            guard bytes.count.isMultiple(of: 2), bytes.count >= 8 else { continue }
            var samples: [UInt16] = []
            var index = 0
            while index + 1 < bytes.count {
                samples.append(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
                index += 2
            }
            let valid = samples.filter { $0 != 0xFFFF }
            guard valid.count >= 4 else { continue }
            arrays.append((tag, samples))
        }
        guard arrays.count >= 2 else { return nil }

        func median(_ samples: [UInt16]) -> Double {
            let valid = samples.filter { $0 != 0xFFFF }.sorted()
            guard !valid.isEmpty else { return 0 }
            return Double(valid[valid.count / 2])
        }

        let voltages = arrays.filter { (4_000...28_000).contains(median($0.1)) }
        let currents = arrays.filter { sample in
            let value = median(sample.1)
            return value <= 5_500 && !(4_000...28_000).contains(value)
        }
        let count = min(3, voltages.count, currents.count)
        guard count >= 1 else { return nil }

        func volts(_ samples: [UInt16]) -> [Double] {
            samples.map { $0 == 0xFFFF ? 0 : Double($0) / 1_000 }
        }
        func amps(_ samples: [UInt16]) -> [Double] {
            samples.map { $0 == 0xFFFF ? 0 : Double($0) / 1_000 }
        }

        let ports = (0..<count).map { offset in
            PortHistorySeries(
                index: offset + 1,
                voltages: volts(voltages[offset].1),
                currents: amps(currents[offset].1)
            )
        }
        return ChargerPortHistory(capturedAt: date, ports: ports)
    }

    static func portOutputFields(
        portIndex: UInt8,
        isOn: Bool,
        now: Date = Date()
    ) throws -> [(UInt8, Data)] {
        try validatePortIndex(portIndex)
        return [
            (0xA1, Data([0x21])),
            (0xA2, Data([0x01, portIndex])),
            (0xA3, Data([0x01, isOn ? 0x01 : 0x00])),
            (0xFE, epochBytes(now))
        ]
    }

    static func portShutdownTimerFields(
        portIndex: UInt8,
        seconds: UInt32,
        now: Date = Date()
    ) throws -> [(UInt8, Data)] {
        try validatePortIndex(portIndex)
        var timerValue = Data([0x04])
        timerValue.appendLittleEndian(seconds)
        return [
            (0xA1, Data([0x21])),
            (0xA2, Data([0x01, portIndex])),
            (0xA3, timerValue),
            (0xFE, epochBytes(now))
        ]
    }

    static func parseTelemetry(
        _ fields: [UInt8: Data],
        at date: Date = Date()
    ) -> ChargerTelemetry? {
        LegacyAnkerSession.parseTelemetry(fields, at: date)
    }

    static func parsePortControl(_ fields: [UInt8: Data]) -> PortControlUpdate? {
        guard let rawIndex = typedControlUnsigned(fields[0xA2]), rawIndex <= 2 else {
            return nil
        }
        var update = PortControlUpdate(portIndex: Int(rawIndex) + 1)
        if let enabled = typedControlUnsigned(fields[0xA4]), enabled <= 1,
           fields[0xA4]?.first == 0x01 {
            update.isOutputEnabled = enabled == 1
        }
        if let remaining = countdownSeconds(fields[0xA3]) {
            update.remainingSeconds = remaining
        }
        return update.isOutputEnabled != nil || update.remainingSeconds != nil ? update : nil
    }

    private static func typedByteArray(_ data: Data?) -> Data? {
        guard let data, data.first == 0x04, data.count > 1 else { return nil }
        return Data(data.dropFirst())
    }

    private static func typedUInt8(_ data: Data?) -> UInt32? {
        guard let data, data.first == 0x01, data.count >= 2 else { return nil }
        return UInt32(data[1])
    }

    private static func validatePortIndex(_ portIndex: UInt8) throws {
        guard portIndex <= 2 else {
            throw AnkerProtocolError.invalidFrame("port index must be 0...2")
        }
    }

    private static func epochBytes(_ date: Date) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(max(0, date.timeIntervalSince1970)))
        return data
    }

    private static func typedControlUnsigned(_ data: Data?) -> UInt32? {
        guard let data, let type = data.first else { return nil }
        switch type {
        case 0x01 where data.count >= 2:
            return UInt32(data[1])
        case 0x02 where data.count >= 3:
            return UInt32(data[1]) | (UInt32(data[2]) << 8)
        case 0x03 where data.count >= 5:
            return UInt32(data[1])
                | (UInt32(data[2]) << 8)
                | (UInt32(data[3]) << 16)
                | (UInt32(data[4]) << 24)
        case 0x04 where data.count >= 5:
            return UInt32(data[1])
                | (UInt32(data[2]) << 8)
                | (UInt32(data[3]) << 16)
                | (UInt32(data[4]) << 24)
        default:
            return nil
        }
    }

    private static func countdownSeconds(_ data: Data?) -> UInt32? {
        guard let data, let type = data.first else { return nil }
        switch type {
        case 0x02, 0x03, 0x04:
            return typedControlUnsigned(data)
        default:
            return nil
        }
    }
}
