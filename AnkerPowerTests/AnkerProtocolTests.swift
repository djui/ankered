import CoreGraphics
import CryptoKit
import XCTest
@testable import AnkerPower

final class AnkerProtocolTests: XCTestCase {
    func testDiscoveryBackoffGrowsThenCaps() {
        XCTAssertEqual(BluetoothDiscoveryBackoff.scanWindow, 8)
        XCTAssertEqual(BluetoothDiscoveryBackoff.delay(afterFailureCount: 1), 5)
        XCTAssertEqual(BluetoothDiscoveryBackoff.delay(afterFailureCount: 2), 15)
        XCTAssertEqual(BluetoothDiscoveryBackoff.delay(afterFailureCount: 3), 30)
        XCTAssertEqual(BluetoothDiscoveryBackoff.delay(afterFailureCount: 4), 60)
        XCTAssertEqual(BluetoothDiscoveryBackoff.delay(afterFailureCount: 5), 120)
        XCTAssertEqual(BluetoothDiscoveryBackoff.delay(afterFailureCount: 9), 120)
    }

    func testFrameRoundTrip() throws {
        let frame = AnkerFrame(
            pattern: try Data(hex: "03000f"),
            command: 0x4200,
            payload: Data([0x01, 0x02, 0x03])
        )
        let encoded = try frame.encode()

        XCTAssertEqual(try AnkerFrame.decode(encoded), frame)
        XCTAssertEqual(encoded.reduce(0, ^), 0)
    }

    func testStreamDecoderReassemblesFragmentsAndMultipleFrames() throws {
        let first = try AnkerFrame(
            pattern: Data(hex: "030001"),
            command: 0x0801,
            payload: Data([0xA1, 0x01, 0x00])
        ).encode()
        let second = try AnkerFrame(
            pattern: Data(hex: "03010f"),
            command: 0x4300,
            payload: Data([0x10, 0x20])
        ).encode()

        var decoder = AnkerFrameStreamDecoder()
        XCTAssertTrue(decoder.append(Data(first.prefix(5))).isEmpty)
        let frames = decoder.append(Data(first.dropFirst(5)) + second)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].command, 0x0801)
        XCTAssertEqual(frames[1].command, 0x4300)
    }

    func testTelemetryParserDecodesA2687PortStructures() throws {
        let fields: [UInt8: Data] = [
            0xA5: Data([0x04, 0x01, 0x84, 0x4E, 0xCA, 0x0D, 0xBC, 0x1B]),
            0xA6: Data([0x04, 0x01, 0x8C, 0x23, 0xB4, 0x0A, 0xC4, 0x09]),
            0xA7: Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            0xAA: Data([0x01, 0x00]),
            0xAC: Data([0x04] + Array(repeating: 0x00, count: 10) + [0x00, 0x01]),
            0xAD: Data([0x04] + Array(repeating: 0x00, count: 10) + [0x00, 0x00]),
            0xAE: Data([0x04] + Array(repeating: 0x00, count: 10) + [0x01, 0x01]),
            0xAF: Data([0x01, 0x01]),
            0xB4: Data([0x04, 0x01, 0x00, 0x00, 0x00,
                       0x00, 0x00, 0x00, 0x00,
                       0x01, 0x00, 0x00, 0x00]),
            0xB5: Data([0x04, 0x11, 0x00, 0x00, 0x00,
                       0x00, 0x00, 0x00, 0x00,
                       0x22, 0x00, 0x00, 0x00])
        ]

        let telemetry = try XCTUnwrap(AnkerSession.parseTelemetry(fields))
        XCTAssertEqual(telemetry.ports[0].voltage, 20.1, accuracy: 0.001)
        XCTAssertEqual(telemetry.ports[0].current, 3.53, accuracy: 0.001)
        XCTAssertEqual(telemetry.ports[0].power, 71.0, accuracy: 0.001)
        XCTAssertEqual(telemetry.ports[1].voltage, 9.1, accuracy: 0.001)
        XCTAssertEqual(telemetry.ports[1].current, 2.74, accuracy: 0.001)
        XCTAssertEqual(telemetry.ports[1].power, 25.0, accuracy: 0.001)
        XCTAssertFalse(telemetry.ports[2].isActive)
        XCTAssertEqual(telemetry.totalPower, 96.0, accuracy: 0.001)
        XCTAssertEqual(telemetry.chargingMode, .ai2)
        XCTAssertEqual(telemetry.ports[0].cableInfo, "3A–60W Max")
        XCTAssertEqual(telemetry.ports[0].chargingInfo, "Apple PD Fast Charging")
        XCTAssertEqual(telemetry.ports[0].deviceInfo, "Apple Device")
        XCTAssertEqual(telemetry.ports[1].cableInfo, "3A–60W Max")
        XCTAssertNil(telemetry.ports[1].chargingInfo)
        XCTAssertEqual(telemetry.ports[2].cableInfo, "5A–100W Max")
        XCTAssertEqual(telemetry.ports[2].deviceInfo, "Apple Device")
    }

    func testTelemetryParserDecodesTypedScalarLayout() throws {
        let fields: [UInt8: Data] = [
            0xA2: Data([0x02, 0xC9, 0x00]), // 20.1 V in decivolts
            0xA3: Data([0x02, 0x5B, 0x00]), // 9.1 V in decivolts
            0xA4: Data([0x02, 0x00, 0x00]),
            0xA5: Data([0x02, 0x23, 0x00]), // 3.5 A in deciamps
            0xA6: Data([0x02, 0x1B, 0x00]), // 2.7 A in deciamps
            0xA7: Data([0x02, 0x00, 0x00]),
            0xB0: Data([0x02, 0x47, 0x00]), // 71 W
            0xB1: Data([0x02, 0x19, 0x00]), // 25 W
            0xB2: Data([0x02, 0x00, 0x00])
        ]

        let telemetry = try XCTUnwrap(AnkerSession.parseTelemetry(fields))
        XCTAssertEqual(telemetry.ports[0].voltage, 20.1, accuracy: 0.001)
        XCTAssertEqual(telemetry.ports[0].current, 3.5, accuracy: 0.001)
        XCTAssertEqual(telemetry.ports[0].power, 71, accuracy: 0.001)
        XCTAssertEqual(telemetry.ports[1].power, 25, accuracy: 0.001)
        XCTAssertFalse(telemetry.ports[2].isActive)
        XCTAssertEqual(telemetry.totalPower, 96, accuracy: 0.001)
    }

    func testTelemetryParserIgnoresPowerSentinelAndHistoryArrays() throws {
        let missingPower: [UInt8: Data] = [
            0xA5: Data([0x04, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        ]
        XCTAssertNil(AnkerSession.parseTelemetry(missingPower))

        let derivedFields: [UInt8: Data] = [
            0xA5: Data([0x04, 0x01, 0x84, 0x4E, 0xCA, 0x0D, 0xFF, 0xFF])
        ]
        let derived = try XCTUnwrap(AnkerSession.parseTelemetry(derivedFields))
        XCTAssertEqual(derived.ports[0].voltage, 20.1, accuracy: 0.001)
        XCTAssertEqual(derived.ports[0].current, 3.53, accuracy: 0.001)
        XCTAssertEqual(derived.ports[0].power, 20.1 * 3.53, accuracy: 0.001)
        XCTAssertNotEqual(derived.ports[0].power, 655.35, accuracy: 0.01)

        var history = Data([0x04])
        for sample: UInt16 in [20_000, 20_100, 19_900, 20_050, 0xFFFF] {
            history.append(UInt8(truncatingIfNeeded: sample))
            history.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        XCTAssertGreaterThan(history.count, 8)
        let historyFields: [UInt8: Data] = [0xA5: history]
        XCTAssertNil(AnkerSession.parseTelemetry(historyFields))
    }

    func testAESCBCRoundTrip() throws {
        let key = try Data(hex: "00112233445566778899aabbccddeeff")
        let iv = try Data(hex: "ffeeddccbbaa99887766554433221100")
        let plaintext = try Data(hex: "a10121fe050342ad8c69")

        let ciphertext = try AES128CBC.encrypt(plaintext, key: key, iv: iv)
        XCTAssertEqual(ciphertext.count % 16, 0)
        XCTAssertEqual(try AES128CBC.decrypt(ciphertext, key: key, iv: iv), plaintext)
    }

    func testAESGCMRoundTripWithProtocolAAD() throws {
        let key = try Data(hex: "b8ff7422955d4eb6d554a2c470280559")
        let nonce = try Data(hex: "6ba3e3f2f3a60f2971ce5d1f")
        let aad = try Data(hex: "3322110077665544bbaa9988ffeeddcc")
        let plaintext = try Data(hex: "a10401020304")

        let encrypted = try AES128GCM.encrypt(
            plaintext,
            key: key,
            nonce: nonce,
            authenticatedData: aad
        )

        XCTAssertEqual(encrypted.count, plaintext.count + 16)
        XCTAssertEqual(
            try AES128GCM.decrypt(
                encrypted,
                key: key,
                nonce: nonce,
                authenticatedData: aad
            ),
            plaintext
        )
    }

    func testModernHandshakeStartsWithEncrypted0001() throws {
        let packet = try AnkerSession().start(now: Date(timeIntervalSince1970: 1_700_000_000))
        let frame = try AnkerFrame.decode(packet)

        XCTAssertEqual(frame.pattern, Data([0x03, 0x00, 0x01]))
        XCTAssertEqual(frame.command, 0x4001)

        let plaintext = try AES128GCM.decrypt(
            frame.payload,
            key: Data(hex: "b8ff7422955d4eb6d554a2c470280559"),
            nonce: Data(hex: "6ba3e3f2f3a60f2971ce5d1f"),
            authenticatedData: Data(hex: "3322110077665544bbaa9988ffeeddcc")
        )
        XCTAssertEqual(try AnkerTLV.parse(plaintext)[0xA1], Data([0x00, 0xF1, 0x53, 0x65]))
    }

    func testModernHandshakeDerivesSessionAndDecodesTelemetry() throws {
        let initialKey = try Data(hex: "b8ff7422955d4eb6d554a2c470280559")
        let initialNonce = try Data(hex: "6ba3e3f2f3a60f2971ce5d1f")
        let aad = try Data(hex: "3322110077665544bbaa9988ffeeddcc")
        let session = AnkerSession()
        _ = try session.start(now: Date(timeIntervalSince1970: 1_700_000_000))

        var update = try session.receive(makeGCMResponse(
            command: 0x0001,
            plaintext: Data(),
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))
        XCTAssertEqual(try AnkerFrame.decode(XCTUnwrap(update.outboundPackets.first)).command, 0x4003)

        update = try session.receive(makeGCMResponse(
            command: 0x0003,
            plaintext: Data(),
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))
        XCTAssertEqual(try AnkerFrame.decode(XCTUnwrap(update.outboundPackets.first)).command, 0x4029)

        let identityPayload = try AnkerTLV.build([
            (0xA3, Data("1.2.3".utf8)),
            (0xA4, Data("SERIAL123456".utf8)),
            (0xA5, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
        ])
        update = try session.receive(makeGCMResponse(
            command: 0x0029,
            plaintext: identityPayload,
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))
        XCTAssertEqual(update.identity?.firmware, "1.2.3")
        XCTAssertEqual(update.identity?.serialNumber, "SERIAL123456")
        XCTAssertEqual(try AnkerFrame.decode(XCTUnwrap(update.outboundPackets.first)).command, 0x4005)

        update = try session.receive(makeGCMResponse(
            command: 0x0005,
            plaintext: Data(),
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))
        let keyExchangeFrame = try AnkerFrame.decode(XCTUnwrap(update.outboundPackets.first))
        let clientKeyPayload = try AES128GCM.decrypt(
            keyExchangeFrame.payload,
            key: initialKey,
            nonce: initialNonce,
            authenticatedData: aad
        )
        let clientCoordinates = try XCTUnwrap(AnkerTLV.parse(clientKeyPayload)[0xA1])
        XCTAssertEqual(clientCoordinates.count, 64)

        let devicePrivateKey = P256.KeyAgreement.PrivateKey()
        let deviceCoordinates = Data(devicePrivateKey.publicKey.x963Representation.dropFirst())
        update = try session.receive(makeGCMResponse(
            command: 0x0021,
            plaintext: AnkerTLV.build([(0xA1, deviceCoordinates)]),
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))

        XCTAssertTrue(update.becameReady)
        XCTAssertTrue(session.isReady)
        XCTAssertEqual(update.outboundPackets.count, 4)

        var clientPublicRepresentation = Data([0x04])
        clientPublicRepresentation.append(clientCoordinates)
        let clientPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: clientPublicRepresentation)
        let sharedSecret = try devicePrivateKey.sharedSecretFromKeyAgreement(with: clientPublicKey)
            .withUnsafeBytes { Data($0) }
        let sessionKey = Data(sharedSecret.prefix(16))
        let sessionNonce = Data(sharedSecret.dropFirst(16).prefix(12))
        let setupFrame = try AnkerFrame.decode(update.outboundPackets[0])
        XCTAssertEqual(setupFrame.command, 0x4022)
        XCTAssertNoThrow(try AES128GCM.decrypt(
            setupFrame.payload,
            key: sessionKey,
            nonce: sessionNonce,
            authenticatedData: aad
        ))

        let telemetryPayload = try AnkerTLV.build([
            (0xA5, Data([0x04, 0x01, 0x84, 0x4E, 0xCA, 0x0D, 0xBC, 0x1B])),
            (0xA6, Data([0x04, 0x01, 0x8C, 0x23, 0xB4, 0x0A, 0xC4, 0x09])),
            (0xA7, Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        ])
        let telemetryUpdate = try session.receive(makeGCMResponse(
            command: 0x0300,
            plaintext: telemetryPayload,
            key: sessionKey,
            nonce: sessionNonce,
            aad: aad,
            pattern: Data([0x03, 0x01, 0x11]),
            commandFlags: 0
        ))
        XCTAssertEqual(telemetryUpdate.telemetry?.totalPower ?? 0, 96, accuracy: 0.001)

        // Firmware v0.0.5.2 also emits 030111 session reports without the
        // command encryption flag, using a TLV length that excludes the type byte.
        var typedTelemetryPayload = Data()
        for (tag, value) in [
            (UInt8(0xA5), Data([0x04, 0x01, 0x84, 0x4E, 0xCA, 0x0D, 0xBC, 0x1B])),
            (UInt8(0xA6), Data([0x04, 0x01, 0x8C, 0x23, 0xB4, 0x0A, 0xC4, 0x09])),
            (UInt8(0xA7), Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        ] {
            typedTelemetryPayload.append(tag)
            typedTelemetryPayload.append(UInt8(value.count - 1))
            typedTelemetryPayload.append(value)
        }
        let typedTelemetryUpdate = try session.receive(AnkerFrame(
            pattern: Data([0x03, 0x01, 0x11]),
            command: 0x0300,
            payload: typedTelemetryPayload
        ))
        XCTAssertEqual(typedTelemetryUpdate.telemetry?.totalPower ?? 0, 96, accuracy: 0.001)
    }

    func testPortControlTLVLayout() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let offPayload = try AnkerTLV.build(
            try AnkerSession.portOutputFields(portIndex: 0, isOn: false, now: now)
        )
        let offFields = try AnkerTLV.parse(offPayload)
        XCTAssertEqual(offFields[0xA1], Data([0x21]))
        XCTAssertEqual(offFields[0xA2], Data([0x01, 0x00]))
        XCTAssertEqual(offFields[0xA3], Data([0x01, 0x00]))
        XCTAssertEqual(offFields[0xFE], Data([0x00, 0xF1, 0x53, 0x65]))

        let onPayload = try AnkerTLV.build(
            try AnkerSession.portOutputFields(portIndex: 2, isOn: true, now: now)
        )
        let onFields = try AnkerTLV.parse(onPayload)
        XCTAssertEqual(onFields[0xA2], Data([0x01, 0x02]))
        XCTAssertEqual(onFields[0xA3], Data([0x01, 0x01]))

        let cancelPayload = try AnkerTLV.build(
            try AnkerSession.portShutdownTimerFields(portIndex: 1, seconds: 0, now: now)
        )
        let cancelFields = try AnkerTLV.parse(cancelPayload)
        XCTAssertEqual(cancelFields[0xA2], Data([0x01, 0x01]))
        XCTAssertEqual(cancelFields[0xA3], Data([0x04, 0x00, 0x00, 0x00, 0x00]))

        let hourPayload = try AnkerTLV.build(
            try AnkerSession.portShutdownTimerFields(portIndex: 0, seconds: 3_600, now: now)
        )
        let hourFields = try AnkerTLV.parse(hourPayload)
        XCTAssertEqual(hourFields[0xA3], Data([0x04, 0x10, 0x0E, 0x00, 0x00]))

        XCTAssertThrowsError(try AnkerSession.portOutputFields(portIndex: 3, isOn: true))
        XCTAssertThrowsError(try AnkerSession.portShutdownTimerFields(portIndex: 4, seconds: 60))
    }

    func testParsePortControlCountdownReport() throws {
        let fields: [UInt8: Data] = [
            0xA2: Data([0x01, 0x01]),
            0xA3: Data([0x04, 0x10, 0x0E, 0x00, 0x00]),
            0xA4: Data([0x01, 0x01])
        ]
        let control = try XCTUnwrap(AnkerSession.parsePortControl(fields))
        XCTAssertEqual(control.portIndex, 2)
        XCTAssertEqual(control.remainingSeconds, 3_600)
        XCTAssertEqual(control.isOutputEnabled, true)
    }

    func testModernSessionEncodesPortControlPackets() throws {
        let ready = try completeModernHandshake()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let outputPacket = try ready.session.makePortOutput(portIndex: 0, isOn: false, now: now)
        let outputFrame = try AnkerFrame.decode(outputPacket)
        XCTAssertEqual(outputFrame.pattern, Data([0x03, 0x00, 0x0F]))
        XCTAssertEqual(outputFrame.command, 0x4207)
        let outputPlaintext = try AES128GCM.decrypt(
            outputFrame.payload,
            key: ready.key,
            nonce: ready.nonce,
            authenticatedData: ready.aad
        )
        XCTAssertEqual(try AnkerTLV.parse(outputPlaintext)[0xA2], Data([0x01, 0x00]))
        XCTAssertEqual(try AnkerTLV.parse(outputPlaintext)[0xA3], Data([0x01, 0x00]))

        let timerPacket = try ready.session.makePortShutdownTimer(portIndex: 2, seconds: 3_600, now: now)
        let timerFrame = try AnkerFrame.decode(timerPacket)
        XCTAssertEqual(timerFrame.command, 0x4209)
        let timerPlaintext = try AES128GCM.decrypt(
            timerFrame.payload,
            key: ready.key,
            nonce: ready.nonce,
            authenticatedData: ready.aad
        )
        XCTAssertEqual(try AnkerTLV.parse(timerPlaintext)[0xA2], Data([0x01, 0x02]))
        XCTAssertEqual(try AnkerTLV.parse(timerPlaintext)[0xA3], Data([0x04, 0x10, 0x0E, 0x00, 0x00]))

        let ack = try ready.session.receive(makeGCMResponse(
            command: 0x0207,
            plaintext: Data(),
            key: ready.key,
            nonce: ready.nonce,
            aad: ready.aad,
            pattern: Data([0x03, 0x00, 0x0F]),
            commandFlags: 0x0800
        ))
        XCTAssertNil(ack.telemetry)
        XCTAssertTrue(ack.diagnostics.contains(where: { $0.contains("Port output switch acknowledged") }))
    }

    func testLegacySessionRejectsPortControl() {
        let session = AnkerSession()
        _ = session.startLegacy()
        XCTAssertFalse(session.supportsPortControl)
        XCTAssertThrowsError(try session.makePortOutput(portIndex: 0, isOn: false))
        XCTAssertThrowsError(try session.makePortShutdownTimer(portIndex: 0, seconds: 60))
        XCTAssertThrowsError(try session.makeChargingMode(.ai2))
        XCTAssertThrowsError(try session.makeLanguage(.english))
        XCTAssertThrowsError(try session.makePortHistoryProbe())
        XCTAssertThrowsError(try session.makeScreensaverSelect(pictureID: 1, hash: 1))
        XCTAssertThrowsError(try session.makeScreensaverTransferStart(pictureID: 1, hash: 1, jpegByteCount: 10, chunkCount: 1))
        XCTAssertThrowsError(try session.makeScreensaverChunk(index: 0, of: 1, payload: Data(count: 156)))
    }

    func testChargingModeAndDisplayTLVLayouts() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let modeFields = try AnkerTLV.parse(try AnkerTLV.build(AnkerSession.singleValueFields(0, now: now)))
        XCTAssertEqual(modeFields[0xA1], Data([0x21]))
        XCTAssertEqual(modeFields[0xA2], Data([0x01, 0x00]))
        XCTAssertEqual(modeFields[0xFE], Data([0x00, 0xF1, 0x53, 0x65]))

        let allocation = try AnkerTLV.parse(try AnkerTLV.build(AnkerSession.singleValueFields(1, now: now)))
        XCTAssertEqual(allocation[0xA2], Data([0x01, 0x01]))

        let split = CustomChargeSplit(portWatts: [80, 60, 20])
        let customFields = try AnkerTLV.parse(try AnkerTLV.build(try AnkerSession.customChargeFields(split, now: now)))
        XCTAssertEqual(customFields[0xA2], Data([0x01, 0x04]))
        XCTAssertEqual(customFields[0xA3], Data([0x04, 0x00, 0x00, 80, 60, 20]))
        XCTAssertEqual(customFields[0xA4], Data([0x04, 0x3B, 0x00, 0x00, 0x3B, 0x00, 0x00, 0x3B, 0x00, 0x00]))

        XCTAssertThrowsError(try AnkerSession.customChargeFields(CustomChargeSplit(portWatts: [10, 0, 0])))
        XCTAssertThrowsError(try AnkerSession.customChargeFields(CustomChargeSplit(portWatts: [140, 20, 20])))
        XCTAssertEqual(ChargerChargingMode.ai2.protocolValue, 0)
        XCTAssertEqual(ChargerChargingMode.custom.protocolValue, 4)
        XCTAssertEqual(ChargerChargingMode.dualLaptop.fixedAllocationValue, 0)
        XCTAssertEqual(ChargerChargingMode.c1Priority.fixedAllocationValue, 1)
    }

    func testParseSettingsFaultsAndDisplayReports() {
        XCTAssertEqual(ChargerFault.from(errorCode: 0), .none)
        XCTAssertEqual(ChargerFault.from(errorCode: 1), .overTemperature)
        XCTAssertEqual(ChargerFault.from(errorCode: 2), .portAbnormality)
        XCTAssertEqual(ChargerFault.from(errorCode: 9), .other(9))
        XCTAssertEqual(ChargerFault.from(errorCode: 1).banner, "Over-temperature protection is active")

        let overTemp = AnkerSession.parseSettings([0xA2: Data([0x01, 0x01])], command: 0x0301)
        XCTAssertEqual(overTemp.fault, .overTemperature)

        let brightness = AnkerSession.parseSettings([0xA2: Data([0x01, 80])], command: 0x0204)
        XCTAssertEqual(brightness.brightnessPercent, 80)

        let timeout = AnkerSession.parseSettings([0xA2: Data([0x01, 0x02])], command: 0x0304)
        XCTAssertEqual(timeout.screenTimeout, .fiveMinutes)

        let language = AnkerSession.parseSettings([0xA2: Data([0x01, 0x00])], command: 0x030B)
        XCTAssertEqual(language.language, .english)

        let mode = AnkerSession.parseSettings([0xA2: Data([0x01, 0x04])], command: 0x0206)
        XCTAssertEqual(mode.chargingMode, .custom)

        let snapshot = AnkerSession.parseSettings(
            [0xA8: Data([0x01, 0x02]), 0xA9: Data([0x01, 90])],
            command: 0x0200
        )
        XCTAssertEqual(snapshot.fault, .portAbnormality)
        XCTAssertEqual(snapshot.brightnessPercent, 90)

        let ignoredWideFault = AnkerSession.parseSettings(
            [0xA8: Data([0x03, 0x02, 0x00, 0x00, 0x00])],
            command: 0x0200
        )
        XCTAssertNil(ignoredWideFault.fault)
    }

    func testScreensaverTLVLayoutsAndE1() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let select = try AnkerTLV.parse(try AnkerTLV.build(
            AnkerSession.screensaverSelectFields(pictureID: 0x0000_5FE7, hash: 0x1DA2_DDCA, now: now)
        ))
        XCTAssertEqual(try AnkerTLV.build(
            AnkerSession.screensaverSelectFields(pictureID: 0x0000_5FE7, hash: 0x1DA2_DDCA, now: now)
        ).count, 47)
        XCTAssertEqual(select[0xA1]?.hexString, "21")
        XCTAssertEqual(select[0xA3]?.hexString, "0103")
        XCTAssertEqual(select[0xA4]?.hexString, "04e75f0000")
        XCTAssertEqual(select[0xA5]?.hexString, "04cadda21d")
        XCTAssertEqual(select[0xFD]?.first, 0x00)
        XCTAssertEqual(String(data: select[0xFD]!.dropFirst(), encoding: .utf8), "SmallChargingUrl")
        XCTAssertEqual(select[0xFE]?.hexString, "0300f15365")
        let settingsEpoch = try AnkerTLV.parse(try AnkerTLV.build(AnkerSession.singleValueFields(80, now: now)))
        XCTAssertEqual(settingsEpoch[0xFE]?.hexString, "00f15365")

        let start = try AnkerTLV.build(try AnkerSession.screensaverTransferStartFields(
            pictureID: 1,
            hash: 2,
            jpegByteCount: 25_397,
            chunkCount: 163,
            now: now
        ))
        XCTAssertEqual(start.count, 49)
        let startFields = try AnkerTLV.parse(start)
        XCTAssertEqual(startFields[0xA6]?.hexString, "010a")
        XCTAssertEqual(startFields[0xA7]?.hexString, "029c00")
        XCTAssertEqual(startFields[0xA8]?.hexString, "02a300")
        XCTAssertEqual(startFields[0xA5]?.hexString, "0335630000")

        var chunkPayload = Data([0xFF, 0xD8])
        chunkPayload.append(Data(count: 154))
        let chunk = try AnkerTLV.build(try AnkerSession.screensaverChunkFields(
            index: 0,
            of: 163,
            payload: chunkPayload
        ))
        XCTAssertEqual(chunk.count, 167)

        XCTAssertFalse(AnkerSession.isScreensaverChunkAcknowledged(index: 8, of: 163))
        XCTAssertTrue(AnkerSession.isScreensaverChunkAcknowledged(index: 9, of: 163))
        XCTAssertTrue(AnkerSession.isScreensaverChunkAcknowledged(index: 162, of: 163))
        XCTAssertTrue(AnkerSession.isScreensaverChunkAcknowledged(index: 0, of: 1))

        let e1 = Data([0x04, 0x80, 0x03, 0xE7, 0x5F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(AnkerSession.parseScreensaverPictureID([0xE1: e1]), 0x5FE7)
        let e1Raw = Data([0x80, 0x03, 0xE7, 0x5F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(AnkerSession.parseScreensaverPictureID([0xE1: e1Raw]), 0x5FE7)
        let parsed = AnkerSession.parseSettings([0xE1: e1], command: 0x0300)
        XCTAssertEqual(parsed.screensaverReportedID, 0x5FE7)

        let selectAck = AnkerSession.parseScreensaverAck(
            command: 0x021F,
            plaintext: Data([0x00, 0xA1, 0x01, 0x31])
        )
        XCTAssertEqual(selectAck?.status, 0)
        XCTAssertNil(selectAck?.nextIndex)

        let ack = AnkerSession.parseScreensaverAck(
            command: 0x0221,
            plaintext: Data([0x00, 0xA1, 0x01, 0x31, 0xA2, 0x02, 0x0A, 0x00])
        )
        XCTAssertEqual(ack?.status, 0)
        XCTAssertEqual(ack?.nextIndex, 10)

        let missingPixels = AnkerControlAck(command: 0x021F, status: 0x11)
        XCTAssertFalse(missingPixels.acceptsScreensaverSelect(beforeUpload: false))
        XCTAssertTrue(missingPixels.acceptsScreensaverSelect(beforeUpload: true))
        let stored = AnkerControlAck(command: 0x021F, status: 0)
        XCTAssertTrue(stored.acceptsScreensaverSelect(beforeUpload: false))

        let storedImage = AnkerControlAck(command: 0x0221, status: 0x10, nextIndex: 83)
        XCTAssertTrue(storedImage.acceptsScreensaverChunk(isFinal: true))
        XCTAssertFalse(storedImage.acceptsScreensaverChunk(isFinal: false))
        let checkpoint = AnkerControlAck(command: 0x0221, status: 0, nextIndex: 10)
        XCTAssertTrue(checkpoint.acceptsScreensaverChunk(isFinal: false))
    }

    func testScreensaverCRCChunksAndVignette() throws {
        XCTAssertEqual(ScreensaverImage.crc32(Data("123456789".utf8)), 0xCBF4_3926)

        let jpeg = Data(repeating: 0xAB, count: 200)
        XCTAssertEqual(ScreensaverImage.chunkCount(forByteCount: jpeg.count), 2)
        let first = try XCTUnwrap(ScreensaverImage.chunk(jpeg, at: 0))
        let last = try XCTUnwrap(ScreensaverImage.chunk(jpeg, at: 1))
        XCTAssertEqual(first.count, 156)
        XCTAssertEqual(last.count, 156)
        XCTAssertEqual(Data(last[44..<156]), Data(count: 112))

        let white = try XCTUnwrap(ScreensaverImage.solidImage(color: CGColor(gray: 1, alpha: 1)))
        let plain = try XCTUnwrap(ScreensaverImage.render(image: white, crop: .identity, vignette: false))
        let faded = try XCTUnwrap(ScreensaverImage.render(image: white, crop: .identity, vignette: true))
        XCTAssertGreaterThan(luma(plain, x: 0, y: 0), 250)
        XCTAssertLessThan(luma(faded, x: 0, y: 0), 20)
        XCTAssertGreaterThan(luma(faded, x: 120, y: 120), 250)

        let plan = try ScreensaverImage.encode(image: white, vignette: false)
        XCTAssertEqual(plan.pictureID, plan.hash)
        XCTAssertGreaterThan(plan.chunkCount, 0)
        XCTAssertEqual(UInt16(truncatingIfNeeded: plan.pictureID), plan.reportedID)
    }

    private func luma(_ image: CGImage, x: Int, y: Int) -> Int {
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return -1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return -1 }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixel[0])
    }

    func testDeviceIdentityBrandVersusUsbVidPid() throws {
        let brandFields: [UInt8: Data] = [
            0xA5: Data([0x04, 0x01, 0x84, 0x4E, 0xCA, 0x0D, 0xBC, 0x1B]),
            0xA6: Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            0xA7: Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            0xAA: Data([0x01, 0x00]),
            0xAC: Data([0x04] + Array(repeating: 0x00, count: 10) + [0x03, 0x00]),
            0xB4: Data([0x04, 0x01, 0x00, 0x00, 0x00,
                       0x00, 0x00, 0x00, 0x00,
                       0x00, 0x00, 0x00, 0x00]),
            0xB5: Data([0x04, 0x11, 0x00, 0x00, 0x00,
                       0x00, 0x00, 0x00, 0x00,
                       0x00, 0x00, 0x00, 0x00])
        ]
        let brandTelemetry = try XCTUnwrap(AnkerSession.parseTelemetry(brandFields))
        XCTAssertEqual(brandTelemetry.ports[0].deviceInfo, "Apple Device")
        XCTAssertNil(brandTelemetry.ports[0].cableInfo)

        let usbFields: [UInt8: Data] = [
            0xA5: Data([0x04, 0x01, 0x84, 0x4E, 0xCA, 0x0D, 0xBC, 0x1B]),
            0xA6: Data([0x04, 0x01, 0x8C, 0x23, 0xB4, 0x0A, 0xC4, 0x09]),
            0xA7: Data([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]),
            0xAA: Data([0x01, 0x00]),
            0xB4: Data([
                0x04,
                0xAC, 0x05, 0x19, 0x75,
                0x1A, 0x29, 0x0A, 0x11,
                0xAC, 0x05, 0x17, 0x71
            ])
        ]
        let usbTelemetry = try XCTUnwrap(AnkerSession.parseTelemetry(usbFields))
        XCTAssertEqual(usbTelemetry.ports[0].deviceInfo, "iPhone 17")
        XCTAssertEqual(usbTelemetry.ports[1].deviceInfo, "Prime Power Bank 26K")
        XCTAssertEqual(usbTelemetry.ports[1].chargingInfo, "Anker Protocol")
        XCTAssertEqual(usbTelemetry.ports[2].deviceInfo, "iPad Pro")
        XCTAssertNil(DeviceCatalog.usbDeviceLabel(vid: 0x1234, pid: 0x0001))
        XCTAssertEqual(DeviceCatalog.usbDeviceLabel(vid: 0x05AC, pid: 0x9999), "Apple Device")
        XCTAssertNil(DeviceCatalog.ankerProtocolLabel(vid: 0x291A, pid: 0x110A, isAIMode: false))
    }

    func testParsePortHistoryUsesMillivoltMilliampArrays() throws {
        func packed(_ values: [UInt16]) -> Data {
            var data = Data([0x04])
            for value in values {
                data.append(UInt8(truncatingIfNeeded: value))
                data.append(UInt8(truncatingIfNeeded: value >> 8))
            }
            return data
        }
        let history = AnkerSession.parsePortHistory([
            0xA2: packed([20_000, 20_100, 19_900, 20_050, 0xFFFF]),
            0xA3: packed([9_000, 9_050, 8_950, 9_020, 0xFFFF]),
            0xA5: packed([3_200, 3_150, 3_180, 3_210, 0xFFFF]),
            0xA6: packed([2_200, 2_180, 2_210, 2_190, 0xFFFF])
        ], at: Date(timeIntervalSince1970: 1_700_000_000))
        let parsed = try XCTUnwrap(history)
        XCTAssertEqual(parsed.ports.count, 2)
        XCTAssertEqual(parsed.ports[0].voltages[0], 20.0, accuracy: 0.001)
        XCTAssertEqual(parsed.ports[0].currents[0], 3.2, accuracy: 0.001)
        XCTAssertEqual(parsed.ports[0].powers[0], 64.0, accuracy: 0.05)
        XCTAssertEqual(parsed.ports[0].voltages[4], 0)
        XCTAssertEqual(parsed.ports[0].currents[4], 0)
    }

    func testModernSessionEncodesModeDisplayAndHistoryPackets() throws {
        let ready = try completeModernHandshake()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let modePackets = try ready.session.makeChargingMode(.c1Priority, now: now)
        XCTAssertEqual(modePackets.count, 2)
        let modeFrame = try AnkerFrame.decode(modePackets[0])
        XCTAssertEqual(modeFrame.command, 0x4206)
        let allocationFrame = try AnkerFrame.decode(modePackets[1])
        XCTAssertEqual(allocationFrame.command, 0x4205)
        let allocationPlain = try AES128GCM.decrypt(
            allocationFrame.payload,
            key: ready.key,
            nonce: ready.nonce,
            authenticatedData: ready.aad
        )
        XCTAssertEqual(try AnkerTLV.parse(allocationPlain)[0xA2], Data([0x01, 0x01]))

        let brightnessPacket = try ready.session.makeScreenBrightness(75, now: now)
        let brightnessFrame = try AnkerFrame.decode(brightnessPacket)
        XCTAssertEqual(brightnessFrame.command, 0x4204)
        let brightnessPlain = try AES128GCM.decrypt(
            brightnessFrame.payload,
            key: ready.key,
            nonce: ready.nonce,
            authenticatedData: ready.aad
        )
        XCTAssertEqual(try AnkerTLV.parse(brightnessPlain)[0xA2], Data([0x01, 75]))

        let historyPacket = try ready.session.makePortHistoryProbe(now: now)
        let historyFrame = try AnkerFrame.decode(historyPacket)
        XCTAssertEqual(historyFrame.pattern, Data([0x03, 0x00, 0x0F]))
        XCTAssertEqual(historyFrame.command, 0x420C)
        let historyPlain = try AES128GCM.decrypt(
            historyFrame.payload,
            key: ready.key,
            nonce: ready.nonce,
            authenticatedData: ready.aad
        )
        XCTAssertEqual(try AnkerTLV.parse(historyPlain)[0xA2], Data([0x01, 0x00]))
    }

    private func completeModernHandshake() throws -> (
        session: AnkerSession,
        key: Data,
        nonce: Data,
        aad: Data
    ) {
        let initialKey = try Data(hex: "b8ff7422955d4eb6d554a2c470280559")
        let initialNonce = try Data(hex: "6ba3e3f2f3a60f2971ce5d1f")
        let aad = try Data(hex: "3322110077665544bbaa9988ffeeddcc")
        let session = AnkerSession()
        _ = try session.start(now: Date(timeIntervalSince1970: 1_700_000_000))

        _ = try session.receive(makeGCMResponse(
            command: 0x0001,
            plaintext: Data(),
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))
        _ = try session.receive(makeGCMResponse(
            command: 0x0003,
            plaintext: Data(),
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))
        _ = try session.receive(makeGCMResponse(
            command: 0x0029,
            plaintext: try AnkerTLV.build([
                (0xA3, Data("1.2.3".utf8)),
                (0xA4, Data("SERIAL123456".utf8))
            ]),
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))
        let keyExchange = try session.receive(makeGCMResponse(
            command: 0x0005,
            plaintext: Data(),
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))
        let keyExchangeFrame = try AnkerFrame.decode(XCTUnwrap(keyExchange.outboundPackets.first))
        let clientKeyPayload = try AES128GCM.decrypt(
            keyExchangeFrame.payload,
            key: initialKey,
            nonce: initialNonce,
            authenticatedData: aad
        )
        let clientCoordinates = try XCTUnwrap(AnkerTLV.parse(clientKeyPayload)[0xA1])
        let devicePrivateKey = P256.KeyAgreement.PrivateKey()
        let deviceCoordinates = Data(devicePrivateKey.publicKey.x963Representation.dropFirst())
        _ = try session.receive(makeGCMResponse(
            command: 0x0021,
            plaintext: AnkerTLV.build([(0xA1, deviceCoordinates)]),
            key: initialKey,
            nonce: initialNonce,
            aad: aad
        ))

        var clientPublicRepresentation = Data([0x04])
        clientPublicRepresentation.append(clientCoordinates)
        let clientPublicKey = try P256.KeyAgreement.PublicKey(
            x963Representation: clientPublicRepresentation
        )
        let sharedSecret = try devicePrivateKey.sharedSecretFromKeyAgreement(with: clientPublicKey)
            .withUnsafeBytes { Data($0) }
        return (
            session: session,
            key: Data(sharedSecret.prefix(16)),
            nonce: Data(sharedSecret.dropFirst(16).prefix(12)),
            aad: aad
        )
    }

    private func makeGCMResponse(
        command: UInt16,
        plaintext: Data,
        key: Data,
        nonce: Data,
        aad: Data,
        pattern: Data = Data([0x03, 0x00, 0x01]),
        commandFlags: UInt16 = 0x4800
    ) throws -> AnkerFrame {
        let encrypted = try AES128GCM.encrypt(
            plaintext,
            key: key,
            nonce: nonce,
            authenticatedData: aad
        )
        return AnkerFrame(
            pattern: pattern,
            command: command | commandFlags,
            payload: encrypted
        )
    }
}
