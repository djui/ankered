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
        Group {
            if let title = label.content.title {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.square.fill")
                    // Tabular digits keep the status item, and everything left of it, from
                    // shifting sideways each time the reading changes.
                    Text(title)
                        .monospacedDigit()
                }
            } else if label.content.isPaused {
                Image(systemName: "pause.rectangle")
            } else {
                Image(systemName: "bolt.square")
            }
        }
        .font(.system(.body, design: .default))
        .onAppear {
            StatusItemContextMenu.shared.install(model: model, openWindow: openWindow)
        }
    }
}
