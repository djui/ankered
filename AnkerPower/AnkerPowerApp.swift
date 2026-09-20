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
        .defaultSize(width: 760, height: 460)

        Window("Connection Diagnostics", id: "diagnostics") {
            DiagnosticsView(model: model)
        }
        .defaultSize(width: 860, height: 520)
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
                    Text(model.menuBarTitle)
                }
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
