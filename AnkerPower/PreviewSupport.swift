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
                customSplit: CustomChargeSplit(portWatts: [80, 60, 20]),
                screensaverReportedID: screensaverSlots().first.map(\.reportedID)
            ),
            chargerHistory: chargerHistory(),
            preferences: AppPreferences(
                previewNicknames: [1: "MacBook", 2: "iPhone"],
                idleNotificationsEnabled: true
            ),
            screensaverSlots: screensaverSlots()
        )
    }

    static func pausedModel() -> AppModel {
        disconnectedModel(.idle, isPaused: true)
    }

    static func disconnectedModel(_ state: ChargerConnectionState, isPaused: Bool = false) -> AppModel {
        AppModel(
            previewState: state,
            identity: ChargerIdentity(productName: "Anker Prime 160W", firmware: "1.5.1.2"),
            telemetry: .empty,
            isPaused: isPaused
        )
    }

    /// Connected, with an over-temperature report and C3 switched off.
    static func faultModel() -> AppModel {
        var sample = telemetry
        sample.ports[2].isOutputEnabled = false
        return AppModel(
            previewState: .connected,
            identity: ChargerIdentity(productName: "Anker Prime 160W", firmware: "1.5.1.2"),
            telemetry: sample,
            settings: ChargerSettings(fault: .overTemperature),
            preferences: AppPreferences(previewNicknames: [1: "MacBook", 2: "iPhone"])
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
            capturedAt: now,
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

    static func screensaverPreviewImage() -> NSImage {
        let size = NSSize(width: 320, height: 240)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(x: 80, y: 40, width: 160, height: 160)).fill()
        image.unlockFocus()
        return image
    }

    static func screensaverSlots() -> [ScreensaverSlot] {
        let colors: [CGColor] = [
            CGColor(red: 0.15, green: 0.45, blue: 0.75, alpha: 1),
            CGColor(red: 0.75, green: 0.28, blue: 0.22, alpha: 1),
            CGColor(red: 0.20, green: 0.62, blue: 0.38, alpha: 1)
        ]
        return colors.enumerated().compactMap { index, color in
            guard let image = ScreensaverImage.solidImage(color: color),
                  let plan = try? ScreensaverImage.encode(image: image, vignette: index == 0) else {
                return nil
            }
            return ScreensaverSlot(
                pictureID: plan.pictureID,
                hash: plan.hash,
                jpeg: plan.jpeg,
                createdAt: Date().addingTimeInterval(TimeInterval(-60 * (3 - index)))
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
            fputs("usage: AnkerPower --export-screenshots <directory> [--all-states]\n", stderr)
            exit(1)
        }
        didExport = true

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try exportDocumentationSet(to: directory)
            if ProcessInfo.processInfo.arguments.contains("--all-states") {
                try exportStateVariants(to: directory)
            }
        } catch {
            fputs("screenshot export failed: \(error)\n", stderr)
            exit(1)
        }
        exit(0)
    }

    /// The images README.md and the landing page use, in light (`menu.png`) and dark (`menu-dark.png`).
    private static func exportDocumentationSet(to directory: URL) throws {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "-dark" : ""
            func url(_ name: String) -> URL {
                directory.appendingPathComponent("\(name)\(suffix).png")
            }
            let model = PreviewSample.connectedModel()
            try write(MenuContentView(model: model).padding(2), to: url("menu"), colorScheme: scheme)
            try write(
                HistoryView(model: model).frame(width: 760, height: 520),
                to: url("history"),
                colorScheme: scheme
            )
            try write(
                DiagnosticsView(model: model).frame(width: 860, height: 440),
                to: url("diagnostics"),
                colorScheme: scheme
            )
            try write(SettingsView(model: model).padding(2), to: url("settings"), colorScheme: scheme)
            if let image = PreviewSample.screensaverPreviewImage().screensaverCGImage {
                model.beginScreensaverCrop(image: image)
            }
            try write(
                ScreensaverCropView(model: model).frame(width: 420),
                to: url("screensaver"),
                colorScheme: scheme
            )
        }
    }

    /// Every popover state in light and dark, for design review. Not used by the docs.
    private static func exportStateVariants(to directory: URL) throws {
        let menus: [(name: String, model: () -> AppModel)] = [
            ("connected", PreviewSample.connectedModel),
            ("fault", PreviewSample.faultModel),
            ("paused", PreviewSample.pausedModel),
            ("searching", { PreviewSample.disconnectedModel(.scanning) }),
            ("failed", { PreviewSample.disconnectedModel(.failed("Charger disconnected")) }),
            ("bluetooth-off", { PreviewSample.disconnectedModel(.bluetoothUnavailable(.poweredOff)) })
        ]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for menu in menus {
                try write(
                    MenuContentView(model: menu.model()).padding(2),
                    to: directory.appendingPathComponent("menu-\(menu.name)-\(suffix).png"),
                    colorScheme: scheme
                )
            }
        }
        try write(
            SettingsView(model: PreviewSample.pausedModel()).padding(2),
            to: directory.appendingPathComponent("settings-disconnected-light.png")
        )
    }

    @MainActor
    private static func write<V: View>(
        _ view: V,
        to url: URL,
        colorScheme: ColorScheme = .light,
        scale: CGFloat = 2
    ) throws {
        // ImageRenderer resolves AppKit catalog colors against the system appearance, so pin
        // the window background to the requested scheme before handing it to SwiftUI.
        var background = NSColor.windowBackgroundColor
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? background
        }
        // The flexible frame keeps the background under the whole canvas even when a view's
        // measured height and drawn height differ slightly (wrapping text in two columns).
        let rendered = view
            .environment(\.isScreenshotExport, true)
            .environment(\.colorScheme, colorScheme)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: background))
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
