import SwiftUI

@main
struct AnkerPowerApp: App {
    @StateObject private var model: AppModel

    init() {
        if ScreenshotExporter.isRequested {
            _model = StateObject(wrappedValue: PreviewSample.connectedModel())
            DispatchQueue.main.async {
                ScreenshotExporter.exportIfRequested()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--demo") {
            // Sample data and no Bluetooth, for UI work without a charger.
            _model = StateObject(wrappedValue: PreviewSample.connectedModel())
        } else {
            _model = StateObject(wrappedValue: AppModel())
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
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.connectionState.isConnected {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.square.fill")
                    // Tabular digits keep the status item, and everything left of it, from
                    // shifting sideways each time the reading changes.
                    Text(model.menuBarTitle)
                        .monospacedDigit()
                }
                .font(.system(.body, design: .default))
            } else if model.isPaused {
                Image(systemName: "pause.rectangle")
                    .font(.system(.body, design: .default))
            } else {
                Image(systemName: "bolt.square")
                    .font(.system(.body, design: .default))
            }
        }
        .onAppear {
            StatusItemContextMenu.shared.install(model: model, openWindow: openWindow)
        }
    }
}
