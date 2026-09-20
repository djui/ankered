import AppKit
import SwiftUI

private struct ScreenshotExportKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isScreenshotExport: Bool {
        get { self[ScreenshotExportKey.self] }
        set { self[ScreenshotExportKey.self] = newValue }
    }
}

@MainActor
enum PreviewSample {
    static func connectedModel() -> AppModel {
        AppModel(
            previewState: .connected,
            identity: ChargerIdentity(productName: "Anker Prime 160W", firmware: "1.5.1.2"),
            telemetry: telemetry,
            historySamples: historySamples(),
            diagnosticEntries: diagnosticEntries(),
            canControlPorts: true,
            settings: ChargerSettings(
                brightnessPercent: 80,
                screenTimeout: .oneMinute,
                orientation: .up,
                autoRotate: true,
                language: .english,
                customSplit: CustomChargeSplit(portWatts: [80, 60, 20])
            ),
            chargerHistory: chargerHistory(),
            preferences: AppPreferences(
                previewNicknames: [1: "MacBook", 2: "iPhone"],
                idleNotificationsEnabled: true
            )
        )
    }

    static var telemetry: ChargerTelemetry {
        ChargerTelemetry(
            ports: [
                PortTelemetry(
                    index: 1,
                    isActive: true,
                    voltage: 20.0,
                    current: 3.21,
                    power: 64,
                    cableInfo: "E-Marker 240W",
                    chargingInfo: "PD 3.1",
                    deviceInfo: "MacBook Pro",
                    isOutputEnabled: true
                ),
                PortTelemetry(
                    index: 2,
                    isActive: true,
                    voltage: 9.0,
                    current: 2.22,
                    power: 20,
                    chargingInfo: "PD",
                    isOutputEnabled: true,
                    shutdownDurationSeconds: 3_600,
                    shutdownEndsAt: Date().addingTimeInterval(2_760)
                ),
                PortTelemetry(
                    index: 3,
                    isActive: false,
                    voltage: 0,
                    current: 0,
                    power: 0,
                    isOutputEnabled: true
                )
            ],
            receivedAt: Date(),
            chargingMode: .ai2
        )
    }

    static func chargerHistory(now: Date = Date()) -> ChargerPortHistory {
        let count = 48
        return ChargerPortHistory(
            capturedAt: now.addingTimeInterval(-TimeInterval(count)),
            ports: (1...3).map { index in
                PortHistorySeries(
                    index: index,
                    voltages: Array(repeating: index == 3 ? 5.0 : index == 2 ? 9.0 : 20.0, count: count),
                    currents: (0..<count).map { step in
                        let wave = 0.35 * sin(Double(step) / 6 + Double(index))
                        switch index {
                        case 1: return max(0, 3.1 + wave)
                        case 2: return max(0, 2.1 + wave)
                        default: return max(0, 0.4 + wave * 0.4)
                        }
                    }
                )
            }
        )
    }

    static func historySamples(now: Date = Date()) -> [PowerHistorySample] {
        (0..<90).map { step in
            let progress = Double(step) / 89
            let totalWave = 55 + 28 * sin(progress * .pi * 2.1)
            let port1 = max(0, totalWave * 0.72)
            let port2 = max(0, totalWave * 0.24)
            let port3 = max(0, totalWave * 0.04)
            return PowerHistorySample(
                timestamp: now.addingTimeInterval(TimeInterval(step - 89) * 40),
                ports: [
                    PortTelemetry(index: 1, isActive: port1 > 1, voltage: 20, current: port1 / 20, power: port1),
                    PortTelemetry(index: 2, isActive: port2 > 1, voltage: 9, current: port2 / 9, power: port2),
                    PortTelemetry(index: 3, isActive: port3 > 1, voltage: 5, current: port3 / 5, power: port3)
                ]
            )
        }
    }

    static func diagnosticEntries(now: Date = Date()) -> [DiagnosticEntry] {
        let lines: [(secondsAgo: TimeInterval, level: DiagnosticEntry.Level, category: String, message: String)] = [
            (12.4, .info, "App", "Starting Bluetooth controller"),
            (11.8, .info, "Bluetooth", "Central powered on, scanning for FF09"),
            (10.9, .success, "Bluetooth", "Found Anker Prime 160W"),
            (10.2, .info, "Bluetooth", "Connecting"),
            (9.1, .success, "GATT", "Discovered write and notify characteristics"),
            (8.4, .info, "Session", "Starting AES-GCM handshake"),
            (7.6, .success, "Session", "Session established"),
            (7.1, .info, "Telemetry", "Polling 0x020A / 0x0200"),
            (6.4, .success, "Telemetry", "Receiving per-port power"),
            (2.0, .info, "Control", "Setting C2 shutdown timer to 3600s")
        ]
        return lines.map { line in
            DiagnosticEntry(
                timestamp: now.addingTimeInterval(-line.secondsAgo),
                level: line.level,
                category: line.category,
                message: line.message
            )
        }
    }
}

@MainActor
enum ScreenshotExporter {
    private static var didExport = false

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--export-screenshots")
    }

    static func destinationDirectory() -> URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--export-screenshots"),
              args.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: args[index + 1], isDirectory: true)
    }

    @MainActor
    static func exportIfRequested() {
        guard isRequested, !didExport else { return }
        guard let directory = destinationDirectory() else {
            fputs("usage: AnkerPower --export-screenshots <directory>\n", stderr)
            exit(1)
        }
        didExport = true

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let model = PreviewSample.connectedModel()
            try write(
                MenuContentView(model: model)
                    .frame(width: 280)
                    .padding(2),
                to: directory.appendingPathComponent("menu.png"),
                scale: 2
            )
            try write(
                HistoryView(model: model)
                    .frame(width: 760, height: 460),
                to: directory.appendingPathComponent("history.png"),
                scale: 2
            )
            try write(
                DiagnosticsView(model: model)
                    .frame(width: 860, height: 520),
                to: directory.appendingPathComponent("diagnostics.png"),
                scale: 2
            )
            try write(
                SettingsView(model: model)
                    .frame(width: 280)
                    .padding(2),
                to: directory.appendingPathComponent("settings.png"),
                scale: 2
            )
        } catch {
            fputs("screenshot export failed: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    @MainActor
    private static func write<V: View>(_ view: V, to url: URL, scale: CGFloat) throws {
        let rendered = view
            .environment(\.isScreenshotExport, true)
            .preferredColorScheme(.light)
            .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: rendered)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: nil, height: nil)
        guard let image = renderer.nsImage else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
