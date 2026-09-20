import AppKit
import SwiftUI

struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.isScreenshotExport) private var isScreenshotExport

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connection Diagnostics")
                        .font(.headline)
                    Text("Packet payloads and session keys are intentionally omitted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reconnect") { model.reconnect() }
                Button("Copy All") { copyAll() }
                    .disabled(model.diagnostics.entries.isEmpty)
                Button("Clear") { model.diagnostics.clear() }
            }
            .padding(12)

            Divider()

            if model.diagnostics.entries.isEmpty {
                ContentUnavailableView(
                    "No diagnostics yet",
                    systemImage: "wave.3.right",
                    description: Text("Bluetooth activity will appear here.")
                )
            } else if isScreenshotExport {
                diagnosticList
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        diagnosticList
                    }
                    .onChange(of: model.diagnostics.entries.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 440)
    }

    private var diagnosticList: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(model.diagnostics.entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.timestamp, format: .dateTime.hour().minute().second())
                        .foregroundStyle(.tertiary)
                    Text(entry.level.rawValue)
                        .foregroundStyle(color(for: entry.level))
                        .frame(width: 42, alignment: .leading)
                    Text("[\(entry.category)]")
                        .foregroundStyle(.secondary)
                    Text(entry.message)
                        .textSelection(.enabled)
                }
                .font(.system(.caption, design: .default))
                .id(entry.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.diagnostics.exportedText, forType: .string)
    }

    private func color(for level: DiagnosticEntry.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

#Preview("Diagnostics") {
    DiagnosticsView(model: PreviewSample.connectedModel())
        .frame(width: 860, height: 520)
}
