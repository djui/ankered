import AppKit
import SwiftUI

struct MenuContentView: View {
    static let width: CGFloat = 300

    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.isScreenshotExport) private var isScreenshotExport

    @State private var confirmOffPort: Int?
    @State private var customTimerPort: Int?
    @State private var customHours = 1
    @State private var customMinutes = 0
    @State private var isShown = false
    @ObservedObject private var preferences: AppPreferences

    init(model: AppModel) {
        self.model = model
        _preferences = ObservedObject(wrappedValue: model.preferences)
    }

    private static let hourPresets: [(label: String, seconds: UInt32)] = [
        ("1 Hour", 3_600),
        ("2 Hours", 7_200),
        ("3 Hours", 10_800)
    ]

    var body: some View {
        let status = model.connectionStatus
        let isConnected = model.connectionState.isConnected

        VStack(alignment: .leading, spacing: 0) {
            header(status)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if isConnected {
                hero
                    .padding(.horizontal, 14)
                if let banner = model.settings.fault.banner {
                    faultBanner(banner)
                        .padding(.horizontal, 10)
                        .padding(.top, 12)
                }
                portList
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
            } else {
                notice(status)
                    .padding(.horizontal, 10)
            }

            Divider()
                .padding(.horizontal, 14)
                .padding(.top, 12)
            actions
        }
        .frame(width: Self.width)
        .animation(.snappy(duration: 0.25), value: isConnected)
        .overlay {
            confirmOverlay
        }
        .onAppear {
            StatusItemContextMenu.shared.install(model: model, openWindow: openWindow)
        }
        // MenuBarExtra keeps this window, and these views, alive after the popover closes.
        // Rolling digits there would keep redrawing (with a blur) for every reading nobody sees.
        // ImageRenderer draws AppKit views as a placeholder over the whole popover.
        .background {
            if !isScreenshotExport {
                WindowVisibilityReader(isVisible: $isShown)
            }
        }
        .transaction { transaction in
            if !isShown {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .popover(isPresented: Binding(
            get: { customTimerPort != nil },
            set: { if !$0 { customTimerPort = nil } }
        ), arrowEdge: .leading) {
            customTimerPopover
        }
    }

    // MARK: Header

    private func header(_ status: ConnectionStatus) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                ConnectionBadge(status: status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.identity.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(status.caption)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)
            connectionControls
        }
    }

    @ViewBuilder
    private var connectionControls: some View {
        if model.isSuspendedForSleep {
            EmptyView()
        } else if model.isPaused {
            Button {
                model.resumeConnection()
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(IconButtonStyle(emphasis: .prominent))
            .help("Resume the connection")
            .accessibilityLabel("Resume connection")
        } else {
            HStack(spacing: 2) {
                Button {
                    model.reconnect()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .help("Reconnect: drop the Bluetooth session and connect again")
                .accessibilityLabel("Reconnect")

                Button {
                    model.pauseConnection()
                } label: {
                    Image(systemName: "pause.fill")
                }
                .buttonStyle(IconButtonStyle())
                .help("Pause: release the charger so the Anker app can connect")
                .accessibilityLabel("Pause connection")
            }
        }
    }

    // MARK: Total output

    private var hero: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(AppModel.compactWatts(model.totalPower))
                    .font(.system(size: 40, weight: .semibold))
                    .contentTransition(.numericText(value: model.totalPower))
                Text("W")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                chargingModeControl
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Total output")
            .accessibilityValue("\(AppModel.compactWatts(model.totalPower)) watts")

            PowerShareBar(segments: model.telemetry.ports.map {
                PowerShareBar.Segment(index: $0.index, watts: $0.isOutputOn ? $0.power : 0)
            })
            .accessibilityHidden(true)

            HStack {
                Text("Total output")
                Spacer()
                Text("of \(Int(ChargerTelemetry.capacityWatts)) W")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .animation(.snappy(duration: 0.3), value: model.totalPower)
    }

    @ViewBuilder
    private var chargingModeControl: some View {
        if model.canControlPorts {
            Menu {
                ForEach(ChargerChargingMode.allCases, id: \.self) { mode in
                    Button {
                        model.setChargingMode(mode)
                    } label: {
                        if model.telemetry.chargingMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                Label(model.telemetry.chargingMode?.label ?? "Charging mode", systemImage: "slider.horizontal.3")
                    .font(.subheadline)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Charging mode: how the charger shares its 160 W between ports")
        } else if let mode = model.telemetry.chargingMode {
            Label(mode.label, systemImage: "slider.horizontal.3")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func faultBanner(_ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
    }

    // MARK: Ports

    private var portList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.telemetry.ports.enumerated()), id: \.element.id) { offset, port in
                if offset > 0 {
                    Divider().padding(.leading, 27)
                }
                portRow(port)
            }
        }
        .platter()
    }

    private func portRow(_ port: PortTelemetry) -> some View {
        let isDrawing = port.isActive && port.isOutputOn
        let name = preferences.displayName(forPort: port.index)

        return HStack(alignment: .top, spacing: 9) {
            portMarker(port.index, isDrawing: isDrawing)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(portStatus(port))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(isDrawing || !port.isOutputOn ? .secondary : .tertiary)
                    .contentTransition(.numericText())
                if port.shutdownEndsAt != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        shutdownCountdown(port, at: context.date)
                            .onChange(of: context.date) { _, date in
                                if port.shutdownRemaining(at: date) == nil {
                                    model.noteTimerExpired(portIndex: port.index)
                                }
                            }
                    }
                }
                portDetails(port)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(portWattsText(port))

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 5) {
                Text(portWattsText(port))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isDrawing ? .primary : .tertiary)
                    .contentTransition(.numericText(value: port.power))
                    .accessibilityHidden(true)
                portControls(port, name: name)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.3), value: port)
    }

    /// Filled dot while the port draws power, a ring otherwise; the color keys the bar above.
    private func portMarker(_ index: Int, isDrawing: Bool) -> some View {
        let color = PortPalette.color(index)
        return ZStack {
            Circle().strokeBorder(color, lineWidth: 1.5)
            if isDrawing {
                Circle().fill(color)
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }

    private func portStatus(_ port: PortTelemetry) -> String {
        if !port.isOutputOn {
            return "Output off"
        }
        if port.isActive {
            let volts = port.voltage.formatted(.number.precision(.fractionLength(1)))
            let amps = port.current.formatted(.number.precision(.fractionLength(2)))
            return "\(volts) V · \(amps) A"
        }
        return port.hasAttachedDevice ? "Not charging" : "Not in use"
    }

    private func portWattsText(_ port: PortTelemetry) -> String {
        if !port.isOutputOn {
            return "Off"
        }
        return "\(AppModel.compactWatts(port.isActive ? port.power : 0)) W"
    }

    @ViewBuilder
    private func shutdownCountdown(_ port: PortTelemetry, at date: Date) -> some View {
        if let remaining = port.shutdownRemaining(at: date) {
            detailLine("Turns off in \(Self.formatRemaining(remaining))", systemImage: "timer", emphasized: true)
        } else {
            // Keeps a view in place so the expiry check above keeps running until the port flips.
            Color.clear.frame(height: 0)
        }
    }

    @ViewBuilder
    private func portDetails(_ port: PortTelemetry) -> some View {
        if let chargingInfo = port.chargingInfo {
            detailLine(chargingInfo, systemImage: "bolt.circle")
        }
        if let deviceInfo = port.deviceInfo {
            detailLine(deviceInfo, systemImage: Self.deviceSymbol(for: deviceInfo))
        }
        if let cableInfo = port.cableInfo {
            detailLine(cableInfo, systemImage: "cable.connector")
        }
    }

    private func detailLine(_ text: String, systemImage: String, emphasized: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
                .foregroundStyle(emphasized ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                .frame(width: 13)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }

    private func portControls(_ port: PortTelemetry, name: String) -> some View {
        let controlsEnabled = model.canControlPorts && !model.isPortCommandInFlight(port.index)
        let unavailable = "Port control is unavailable on this connection"

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
                Divider()
                Button {
                    let remaining = port.shutdownRemaining() ?? TimeInterval(port.shutdownDurationSeconds ?? 0)
                    customHours = min(23, max(0, Int(remaining) / 3_600))
                    customMinutes = min(59, max(0, (Int(remaining) % 3_600) / 60))
                    if customHours == 0, customMinutes == 0 {
                        customHours = 1
                    }
                    customTimerPort = port.index
                } label: {
                    timerMenuLabel("Custom…", selected: isCustomTimer(port))
                }
            } label: {
                Image(systemName: "timer")
            }
            .menuStyle(.button)
            .buttonStyle(IconButtonStyle(emphasis: hasActiveTimer(port) ? .tinted : .plain))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.canControlPorts ? "Shutdown timer for \(name)" : unavailable)
            .accessibilityLabel("Shutdown timer for \(name)")

            Button {
                if port.isOutputOn {
                    confirmOffPort = port.index
                } else {
                    model.setPortOutput(index: port.index, enabled: true)
                }
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle(emphasis: port.isOutputOn ? .plain : .tinted))
            .help(
                model.canControlPorts
                    ? (port.isOutputOn ? "Turn off \(name)" : "Turn on \(name)")
                    : unavailable
            )
            .accessibilityLabel(port.isOutputOn ? "Turn off \(name)" : "Turn on \(name)")
        }
        .disabled(!controlsEnabled)
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
            Text("Turn off \(customTimerPort.map { preferences.displayName(forPort: $0) } ?? "port") after")
                .font(.headline)
            Stepper(value: $customHours, in: 0...23) {
                Text("\(customHours) \(customHours == 1 ? "hour" : "hours")")
                    .monospacedDigit()
            }
            Stepper(value: $customMinutes, in: 0...59) {
                Text("\(customMinutes) \(customMinutes == 1 ? "minute" : "minutes")")
                    .monospacedDigit()
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    customTimerPort = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Start Timer") {
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
        .frame(width: 240)
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

    // MARK: Not connected

    private func notice(_ status: ConnectionStatus) -> some View {
        VStack(spacing: 6) {
            Text(status.headline)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(status.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action = status.action {
                Button(action.title) {
                    model.perform(action)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .platter()
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 0) {
            MenuActionRow(title: "Charging History", systemImage: "chart.xyaxis.line") {
                AuxiliaryWindow.open(.history, using: openWindow)
            }
            MenuActionRow(
                title: "Settings…",
                systemImage: "gearshape",
                shortcut: KeyboardShortcut(",", modifiers: .command)
            ) {
                AuxiliaryWindow.open(.settings, using: openWindow)
            }
            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            MenuActionRow(title: "About Anker Power", systemImage: "info.circle") {
                AppAbout.show()
            }
            MenuActionRow(
                title: "Quit Anker Power",
                systemImage: "xmark",
                shortcut: KeyboardShortcut("q", modifiers: .command)
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Turn-off confirmation

    @ViewBuilder
    private var confirmOverlay: some View {
        if let portIndex = confirmOffPort {
            let name = preferences.displayName(forPort: portIndex)
            ZStack {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        confirmOffPort = nil
                    }

                VStack(spacing: 10) {
                    Image(systemName: "power")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Turn off \(name)?")
                        .font(.headline)
                    Text("The connected device stops charging until you turn the port back on.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Button {
                            confirmOffPort = nil
                        } label: {
                            Text("Cancel").frame(maxWidth: .infinity)
                        }
                        .keyboardShortcut(.cancelAction)

                        Button {
                            model.setPortOutput(index: portIndex, enabled: false)
                            confirmOffPort = nil
                        } label: {
                            Text("Turn Off").frame(maxWidth: .infinity)
                        }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                    .controlSize(.large)
                    .padding(.top, 4)
                }
                .padding(18)
                .frame(width: 250)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            }
        }
    }

    // MARK: Formatting

    static func deviceSymbol(for label: String) -> String {
        let lowered = label.lowercased()
        if lowered.contains("macbook") || lowered.contains("laptop") { return "laptopcomputer" }
        if lowered.contains("iphone") || lowered.contains("phone") { return "iphone" }
        if lowered.contains("ipad") || lowered.contains("tablet") { return "ipad" }
        if lowered.contains("watch") { return "applewatch" }
        if lowered.contains("power bank") { return "battery.100" }
        return "laptopcomputer.and.iphone"
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

/// Reports whether the hosting window is actually on screen.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { visible in
            if isVisible != visible { isVisible = visible }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            // Never write SwiftUI state from inside a view update.
            DispatchQueue.main.async { [weak self] in self?.onChange?(visible) }
        }
    }
}

#Preview("Menu") {
    MenuContentView(model: PreviewSample.connectedModel())
}

#Preview("Paused") {
    MenuContentView(model: PreviewSample.pausedModel())
}
