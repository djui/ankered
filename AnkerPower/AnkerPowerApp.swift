import AppKit
import SwiftUI

@main
struct AnkerPowerApp: App {
    // Plain @State, not @StateObject: the scenes only pass the model along, and observing it
    // here would rebuild every scene on each reading. The views observe what they show.
    @State private var model: AppModel

    init() {
        if ScreenshotExporter.isRequested {
            _model = State(initialValue: PreviewSample.connectedModel())
            DispatchQueue.main.async {
                ScreenshotExporter.exportIfRequested()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--demo") {
            // Sample data and no Bluetooth, for UI work without a charger.
            _model = State(initialValue: PreviewSample.connectedModel())
        } else {
            _model = State(initialValue: AppModel())
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            MenuBarStatusView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Charging History", id: "history") {
            HistoryView(model: model)
        }
        .defaultSize(width: 780, height: 560)

        Window("Connection Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: model)
        }
        .defaultSize(width: 860, height: 520)

        Window("Settings", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 720, height: 680)
        .windowResizability(.contentSize)

        Window("Screensaver", id: "screensaver-crop") {
            ScreensaverCropView(model: model)
        }
        .defaultSize(width: 420, height: 560)
        .windowResizability(.contentSize)
    }
}

private struct MenuBarStatusView: View {
    let model: AppModel
    @ObservedObject private var label: MenuBarLabelState
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        _label = ObservedObject(wrappedValue: model.menuBar)
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarGlyphImage.image(for: label.content.glyph))
            if let title = label.content.title {
                // Tabular digits keep the status item, and everything left of it, from
                // shifting sideways each time the reading changes.
                Text(title)
                    .monospacedDigit()
            }
        }
        .font(.system(.body, design: .default))
        .onAppear {
            StatusItemContextMenu.shared.install(model: model, openWindow: openWindow)
        }
    }
}

/// Draws the status item glyph as a template image, so the menu bar tints it for light, dark,
/// and wallpaper-tinted bars: three 3 pt bars with 2 pt gaps, bottom-aligned in 13 × 16 pt.
private enum MenuBarGlyphImage {
    private static let size = NSSize(width: 13, height: 16)
    /// The status item ignores SwiftUI stack spacing, so the gap before the watts is part of the
    /// image; without it the low stubs read like a decimal point.
    private static let titleGap: CGFloat = 2
    private static let baseline: CGFloat = 15
    private static let fullHeight: CGFloat = 14
    /// Bar height for steps 1–4.
    private static let stepHeights: [CGFloat] = [5, 8, 11, 14]
    private static let stubHeight: CGFloat = 2
    private static let faint: CGFloat = 0.3

    /// Returning the same instance for an unchanged glyph keeps SwiftUI from resetting the image
    /// on every telemetry update. There are at most a few hundred glyphs.
    @MainActor private static var cache: [MenuBarGlyph: NSImage] = [:]

    @MainActor static func image(for glyph: MenuBarGlyph) -> NSImage {
        if let cached = cache[glyph] {
            return cached
        }
        var canvas = size
        if case .ports = glyph {
            canvas.width += titleGap
        }
        let image = NSImage(size: canvas, flipped: true) { _ in
            draw(glyph)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(for: glyph)
        cache[glyph] = image
        return image
    }

    private static func draw(_ glyph: MenuBarGlyph) {
        switch glyph {
        case .ports(let loads):
            for (slot, load) in loads.prefix(3).enumerated() {
                switch load {
                case .empty:
                    drawBar(slot, height: stubHeight, alpha: faint)
                case .idle:
                    drawBar(slot, height: stubHeight, alpha: 1)
                case .charging(let step):
                    drawBar(slot, height: stepHeights[min(max(step, 1), stepHeights.count) - 1], alpha: 1)
                }
            }
        case .noCharger:
            for slot in 0..<3 {
                drawBar(slot, height: fullHeight, alpha: faint)
            }
        case .unavailable:
            for slot in 0..<3 {
                drawBar(slot, height: fullHeight, alpha: faint)
            }
            drawSlash()
        }
    }

    private static func drawBar(_ slot: Int, height: CGFloat, alpha: CGFloat) {
        let rect = NSRect(x: CGFloat(slot) * 5, y: baseline - height, width: 3, height: height)
        NSColor.black.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 0.8, yRadius: 0.8).fill()
    }

    /// Clears a band under the slash first so it reads against the bars, like SF Symbols' slashes.
    private static func drawSlash() {
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 1, y: 1.5))
        slash.line(to: NSPoint(x: 12, y: 14.5))
        slash.lineCapStyle = .round

        let context = NSGraphicsContext.current
        context?.compositingOperation = .clear
        slash.lineWidth = 3.4
        slash.stroke()

        context?.compositingOperation = .sourceOver
        NSColor.black.setStroke()
        slash.lineWidth = 1.4
        slash.stroke()
    }

    private static func accessibilityDescription(for glyph: MenuBarGlyph) -> String {
        switch glyph {
        case .ports(let loads):
            return loads.enumerated().map { offset, load in
                switch load {
                case .empty: return "C\(offset + 1) empty"
                case .idle: return "C\(offset + 1) plugged in"
                case .charging: return "C\(offset + 1) charging"
                }
            }
            .joined(separator: ", ")
        case .noCharger:
            return "Charger not connected"
        case .unavailable:
            return "Charger unavailable"
        }
    }
}
