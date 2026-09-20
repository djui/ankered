import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    @State private var confirmOffPort: Int?
    @State private var customTimerPort: Int?
    @State private var customHours = 1
    @State private var customMinutes = 0

    private static let hourPresets: [(label: String, seconds: UInt32)] = [
        ("1 Hour", 3_600),
        ("2 Hours", 7_200),
        ("3 Hours", 10_800)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 13) {
                ForEach(model.telemetry.ports) { port in
                    portRow(port)
                }
            }

            Divider().padding(.vertical, 10)
            statusToolbar
        }
        .padding(14)
        .frame(width: 280)
        .confirmationDialog(
            "Confirm",
            isPresented: Binding(
                get: { confirmOffPort != nil },
                set: { if !$0 { confirmOffPort = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("OK") {
                if let index = confirmOffPort {
                    model.setPortOutput(index: index, enabled: false)
                }
                confirmOffPort = nil
            }
            Button("Cancel", role: .cancel) {
                confirmOffPort = nil
            }
        } message: {
            Text("Are you sure you want to turn off output on this port?")
        }
        .popover(isPresented: Binding(
            get: { customTimerPort != nil },
            set: { if !$0 { customTimerPort = nil } }
        ), arrowEdge: .leading) {
            customTimerPopover
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Label("Total output", systemImage: "bolt.fill")
                    .font(.headline)
                Spacer()
                Text(model.connectionState.isConnected ? model.totalPower.formatted(.number.precision(.fractionLength(0))) : "—")
                    .font(.system(size: 26, weight: .semibold))
                    .contentTransition(.numericText())
                Text("W")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if model.connectionState.isConnected, let mode = model.telemetry.chargingMode {
                Label(mode.label, systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func portRow(_ port: PortTelemetry) -> some View {
        let isLive = model.connectionState.isConnected
        let showOff = isLive && !port.isOutputOn

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("C\(port.index)")
                    .font(.headline)
                Spacer(minLength: 4)
                if isLive {
                    portControls(port)
                }
                Text(showOff
                     ? "Off"
                     : (isLive
                        ? "\(port.power.formatted(.number.precision(.fractionLength(port.isActive && port.power < 10 ? 1 : 0)))) W"
                        : "— W"))
                    .font(.headline)
                    .foregroundStyle(isLive && port.isActive && port.isOutputOn ? .primary : .tertiary)
                    .contentTransition(.numericText())
            }

            if isLive, port.isActive, port.isOutputOn {
                Text("\(port.voltage.formatted(.number.precision(.fractionLength(1)))) V · \(port.current.formatted(.number.precision(.fractionLength(2)))) A")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if isLive {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    remainingTimeLine(port, at: context.date)
                        .onChange(of: context.date) { _, date in
                            if port.shutdownEndsAt != nil, port.shutdownRemaining(at: date) == nil {
                                model.noteTimerExpired(portIndex: port.index)
                            }
                        }
                }
            }

            if isLive, let cableInfo = port.cableInfo {
                detailLine(cableInfo, systemImage: "cable.connector")
            }
            if isLive, let chargingInfo = port.chargingInfo {
                detailLine(chargingInfo, systemImage: "bolt.circle")
            }
            if isLive, let deviceInfo = port.deviceInfo {
                detailLine(deviceInfo, systemImage: "desktopcomputer")
            }
        }
    }

    @ViewBuilder
    private func remainingTimeLine(_ port: PortTelemetry, at date: Date) -> some View {
        if let remaining = port.shutdownRemaining(at: date) {
            detailLine("Off in \(Self.formatRemaining(remaining))", systemImage: "timer")
        }
    }

    private func portControls(_ port: PortTelemetry) -> some View {
        let controlsEnabled = model.canControlPorts && !model.isPortCommandInFlight(port.index)
        return HStack(spacing: 2) {
            Menu {
                Button {
                    model.setPortShutdownTimer(index: port.index, seconds: 0)
                } label: {
                    timerMenuLabel("Off", selected: !hasActiveTimer(port))
                }
                ForEach(Self.hourPresets, id: \.seconds) { preset in
                    Button {
                        model.setPortShutdownTimer(index: port.index, seconds: preset.seconds)
                    } label: {
                        timerMenuLabel(preset.label, selected: isSelectedPreset(port, seconds: preset.seconds))
                    }
                }
                Button {
                    let remaining = port.shutdownRemaining() ?? TimeInterval(port.shutdownDurationSeconds ?? 0)
                    customHours = min(23, max(0, Int(remaining) / 3_600))
                    customMinutes = min(59, max(0, (Int(remaining) % 3_600) / 60))
                    if customHours == 0, customMinutes == 0 {
                        customHours = 1
                    }
                    customTimerPort = port.index
                } label: {
                    timerMenuLabel("Customize", selected: isCustomTimer(port))
                }
            } label: {
                Image(systemName: hasActiveTimer(port) ? "timer.circle.fill" : "timer")
                    .font(.body)
            }
            .menuIndicator(.hidden)
            .help(model.canControlPorts ? "Shutdown timer" : "Port control is unavailable on this connection")

            Button {
                if port.isOutputOn {
                    confirmOffPort = port.index
                } else {
                    model.setPortOutput(index: port.index, enabled: true)
                }
            } label: {
                Image(systemName: port.isOutputOn ? "power.circle.fill" : "power.circle")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help(
                model.canControlPorts
                    ? (port.isOutputOn ? "Turn off C\(port.index) output" : "Turn on C\(port.index) output")
                    : "Port control is unavailable on this connection"
            )
        }
        .disabled(!controlsEnabled)
        .buttonStyle(.plain)
        .controlSize(.small)
    }

    @ViewBuilder
    private func timerMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var customTimerPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom shutdown timer")
                .font(.headline)
            Stepper(value: $customHours, in: 0...23) {
                Text("\(customHours) \(customHours == 1 ? "hour" : "hours")")
            }
            Stepper(value: $customMinutes, in: 0...59) {
                Text("\(customMinutes) \(customMinutes == 1 ? "minute" : "minutes")")
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    customTimerPort = nil
                }
                Button("Set") {
                    if let index = customTimerPort {
                        let seconds = UInt32(customHours * 3_600 + customMinutes * 60)
                        model.setPortShutdownTimer(index: index, seconds: min(seconds, 86_400))
                    }
                    customTimerPort = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(customHours == 0 && customMinutes == 0)
            }
        }
        .padding(14)
        .frame(width: 220)
    }

    private func hasActiveTimer(_ port: PortTelemetry) -> Bool {
        port.shutdownRemaining() != nil
    }

    private func isSelectedPreset(_ port: PortTelemetry, seconds: UInt32) -> Bool {
        hasActiveTimer(port) && port.shutdownDurationSeconds == seconds
    }

    private func isCustomTimer(_ port: PortTelemetry) -> Bool {
        guard hasActiveTimer(port), let duration = port.shutdownDurationSeconds else { return false }
        return !Self.hourPresets.contains(where: { $0.seconds == duration })
    }

    private func detailLine(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.connectionState.isConnected ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.connectionState.isConnected ? "Connected: \(model.identity.displayName)" : model.connectionState.label)
                    .font(.caption)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Button { model.reconnect() } label: {
                    Label("Reconnect", systemImage: "arrow.clockwise")
                }
                .help("Reconnect")
                Spacer(minLength: 0)
                Button { openAuxiliaryWindow(id: "diagnostics", title: "Connection Diagnostics") } label: {
                    Label("Diagnostics", systemImage: "waveform.path.ecg")
                }
                .help("Diagnostics")
                Spacer(minLength: 0)
                Button { openAuxiliaryWindow(id: "history", title: "Charging History") } label: {
                    Label("History", systemImage: "chart.xyaxis.line")
                }
                .help("Charging history")
                Spacer(minLength: 0)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("Quit", systemImage: "xmark.circle")
                }
                .help("Quit Anker Power")
            }
            .frame(maxWidth: .infinity)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func openAuxiliaryWindow(id: String, title: String) {
        openWindow(id: id)

        // Menu-bar-only apps do not always become active when SwiftUI creates a
        // secondary window. Activate and raise it after the scene has materialized.
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                guard let window = NSApplication.shared.windows.first(where: {
                    $0.identifier?.rawValue == id || $0.title == title
                }) else { return }
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    private static func formatRemaining(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(String(format: "%02d", seconds))s"
        }
        return "\(seconds)s"
    }
}
