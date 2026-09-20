import CryptoKit
import XCTest
@testable import AnkerPower

final class AnkerProtocolTests: XCTestCase {
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
