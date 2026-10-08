import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    static let width: CGFloat = 720
    /// Four slots fill the right column's 306 pt row with 8 pt gaps.
    private static let thumbnailSize: CGFloat = 70

    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @ObservedObject private var screensaverStore: ScreensaverStore
    @Environment(\.isScreenshotExport) private var isScreenshotExport
    @Environment(\.openWindow) private var openWindow

    @State private var customC1: Int
    @State private var customC2: Int
    @State private var customC3: Int
    @State private var nicknameDrafts: [Int: String]
    @State private var confirmReplace = false

    init(model: AppModel) {
        self.model = model
        let preferences = model.preferences
        _preferences = ObservedObject(wrappedValue: preferences)
        _screensaverStore = ObservedObject(wrappedValue: model.screensaverStore)
        _customC1 = State(initialValue: Int(model.settings.customSplit?.c1 ?? 0))
        _customC2 = State(initialValue: Int(model.settings.customSplit?.c2 ?? 0))
        _customC3 = State(initialValue: Int(model.settings.customSplit?.c3 ?? 0))
        _nicknameDrafts = State(initialValue: [
            1: preferences.portNicknames[1] ?? "",
            2: preferences.portNicknames[2] ?? "",
            3: preferences.portNicknames[3] ?? ""
        ])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !model.canControlPorts {
                offlineBanner
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    displaySection
                    customSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 18) {
                    screensaverSection
                    portNamesSection
                    if !preferences.deviceNames.isEmpty {
                        deviceNamesSection
                    }
                    macSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: Self.width, alignment: .topLeading)
        // Report the full content height as the minimum, so the window (sized to its content)
        // cannot open shorter and squeeze thumbnails and wrapped subtitles.
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            customC1 = Int(model.settings.customSplit?.c1 ?? 0)
            customC2 = Int(model.settings.customSplit?.c2 ?? 0)
            customC3 = Int(model.settings.customSplit?.c3 ?? 0)
            for index in 1...3 {
                nicknameDrafts[index] = preferences.portNicknames[index] ?? ""
            }
        }
    }

    // MARK: Connection

    private var offlineBanner: some View {
        let status = model.connectionStatus
        // Connected but without control means the charger only answered the older AES-CBC session.
        let isLegacySession = model.connectionState.isConnected
        let action: ConnectionStatus.Action? = isLegacySession ? .reconnect : status.action
        return HStack(spacing: 10) {
            ConnectionBadge(status: status)
                .scaleEffect(0.8)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Charger settings are read-only right now")
                    .font(.headline)
                Text(isLegacySession
                     ? "The charger answered only its older Bluetooth session, which cannot change settings. Reconnect to try again."
                     : "\(status.title). Display, split, and screensaver changes need a live connection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action.title) {
                    model.perform(action)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .platter()
    }

    // MARK: Display

    private var displaySection: some View {
        SettingsSection(title: "Charger display") {
            SettingsRow(title: "Brightness") {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { Double(model.settings.brightnessPercent ?? 80) },
                            set: { model.setScreenBrightness(Int($0.rounded())) }
                        ),
                        in: 25...100,
                        step: 5
                    )
                    .frame(width: 130)
                    Text("\(model.settings.brightnessPercent ?? 80)%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .disabled(!model.canControlPorts)
            }
            SettingsRow(title: "Turn off after") {
                menuPicker(selection: Binding(
                    get: { model.settings.screenTimeout ?? .oneMinute },
                    set: { model.setScreenTimeout($0) }
                )) {
                    ForEach(ChargerScreenTimeout.allCases, id: \.self) { timeout in
                        Text(timeout.label).tag(timeout)
                    }
                }
            }
            SettingsRow(title: "Language") {
                menuPicker(selection: Binding(
                    get: { model.settings.language ?? .english },
                    set: { model.setLanguage($0) }
                )) {
                    ForEach(ChargerLanguage.allCases, id: \.self) { language in
                        Text(language.label).tag(language)
                    }
                }
            }
            SettingsRow(title: "Orientation") {
                menuPicker(selection: Binding(
                    get: { model.settings.orientation ?? .up },
                    set: { model.setScreenOrientation($0) }
                )) {
                    ForEach(ChargerOrientation.allCases, id: \.self) { orientation in
                        Text(orientation.label).tag(orientation)
                    }
                }
            }
            SettingsRow(title: "Rotate automatically", showsDivider: false) {
                settingsSwitch("Rotate automatically", isOn: Binding(
                    get: { model.settings.autoRotate ?? true },
                    set: { model.setAutoRotate($0) }
                ))
                .disabled(!model.canControlPorts)
            }
        }
    }

    // MARK: Custom split

    private var customSection: some View {
        let split = CustomChargeSplit(portWatts: [
            UInt8(customC1),
            UInt8(customC2),
            UInt8(customC3)
        ])
        return SettingsSection(
            title: "Custom split",
            footer: "Each port gets 0 W or 15–140 W, up to 160 W in total. Applying switches the charger to Custom mode."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                PowerShareBar(segments: [
                    .init(index: 1, watts: Double(customC1)),
                    .init(index: 2, watts: Double(customC2)),
                    .init(index: 3, watts: Double(customC3))
                ])
                HStack {
                    Text("Allocated")
                    Spacer()
                    Text("\(split.totalWatts) of \(Int(ChargerTelemetry.capacityWatts)) W")
                        .monospacedDigit()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            Divider().padding(.leading, 12)

            wattRow(1, value: $customC1)
            wattRow(2, value: $customC2)
            wattRow(3, value: $customC3)

            HStack(spacing: 8) {
                if let error = split.validationError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                } else if model.telemetry.chargingMode == .custom, model.settings.customSplit == split {
                    Label("Active on the charger", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Apply Split") {
                    model.setCustomChargeSplit(split)
                }
                .disabled(!model.canControlPorts || split.validationError != nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func wattRow(_ index: Int, value: Binding<Int>) -> some View {
        HStack(spacing: 8) {
            portDot(index)
            Text("C\(index)")
                .fontWeight(.medium)
            if let nickname = preferences.portNicknames[index] {
                Text(nickname)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(value.wrappedValue) W")
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            if !isScreenshotExport {
                Stepper("C\(index) watts", value: value, in: 0...140, step: 5)
                    .labelsHidden()
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        Divider().padding(.leading, 12)
    }

    // MARK: Screensaver

    private var screensaverSection: some View {
        SettingsSection(
            title: "Screensaver",
            footer: "The charger keeps four images. A square \(ScreensaverImage.pixelSize) × \(ScreensaverImage.pixelSize) picture looks sharpest."
        ) {
            HStack(spacing: 0) {
                ForEach(0..<ScreensaverStore.slotCount, id: \.self) { index in
                    if index > 0 {
                        Spacer(minLength: 6)
                    }
                    screensaverSlot(index)
                }
            }
            .padding(12)
            Divider().padding(.leading, 12)
            HStack(spacing: 8) {
                screensaverStatus
                Spacer(minLength: 8)
                Button(screensaverStore.isFull ? "Replace Oldest…" : "Add Image…") {
                    if screensaverStore.isFull {
                        confirmReplace = true
                    } else {
                        pickScreensaverImage()
                    }
                }
                .disabled(!model.canControlPorts || isScreensaverBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .confirmationDialog(
            "Replace the oldest screensaver?",
            isPresented: $confirmReplace
        ) {
            Button("Replace Oldest", role: .destructive) {
                pickScreensaverImage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The charger keeps four images. A new one overwrites the oldest on the device. This cannot be undone over Bluetooth.")
        }
    }

    @ViewBuilder
    private var screensaverStatus: some View {
        if let counts = model.screensaverProgress.uploadCounts {
            ProgressView(value: Double(counts.current), total: Double(counts.total))
                .frame(maxWidth: 160)
        } else if let label = model.screensaverProgress.label {
            Label(label, systemImage: screensaverFailed ? "exclamationmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.subheadline)
                .foregroundStyle(screensaverFailed ? .red : .secondary)
                .lineLimit(2)
        } else {
            Text("\(screensaverStore.slots.count) of \(ScreensaverStore.slotCount) stored")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var isScreensaverBusy: Bool {
        switch model.screensaverProgress {
        case .selecting, .uploading, .verifying: return true
        default: return false
        }
    }

    private var screensaverFailed: Bool {
        if case .failed = model.screensaverProgress { return true }
        return false
    }

    private var unknownOnCharger: UInt16? {
        let reported = model.settings.screensaverReportedID
        if let reported, screensaverStore.slot(reportedID: reported) == nil {
            return reported
        }
        return nil
    }

    private var firstEmptySlotIndex: Int? {
        (0..<ScreensaverStore.slotCount).first { screensaverStore.slots[safe: $0] == nil }
    }

    /// Square thumbnails: the charger shows a square picture, so the slot should too.
    private func screensaverSlot(_ index: Int) -> some View {
        let slot = screensaverStore.slots[safe: index]
        let showsUnknown = slot == nil && unknownOnCharger != nil && firstEmptySlotIndex == index
        let selected = (slot?.reportedID != nil && slot?.reportedID == model.settings.screensaverReportedID)
            || showsUnknown
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button {
            if let slot {
                model.selectScreensaver(slot)
            } else if !showsUnknown, model.canControlPorts, !isScreensaverBusy {
                pickScreensaverImage()
            }
        } label: {
            ZStack {
                shape.fill(Color.primary.opacity(0.05))
                if let slot, let image = NSImage(data: slot.jpeg) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else if showsUnknown {
                    Text("On charger")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(4)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    selected ? Color.accentColor : Color.primary.opacity(0.1),
                    lineWidth: selected ? 2.5 : 1
                )
            )
            .overlay(alignment: .bottomTrailing) {
                if selected, slot != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!model.canControlPorts || isScreensaverBusy || showsUnknown)
        .help(slot == nil ? "Add an image" : "Show this image on the charger")
    }

    private func pickScreensaverImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .webP]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a square image. \(ScreensaverImage.pixelSize)×\(ScreensaverImage.pixelSize) is ideal."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let image = NSImage(contentsOf: url)?.screensaverCGImage else { return }
        model.beginScreensaverCrop(image: image)
        openWindow(id: "screensaver-crop")
    }

    // MARK: Port names

    private var portNamesSection: some View {
        SettingsSection(
            title: "Port names",
            footer: "Shown in the menu, notifications, and Shortcuts."
        ) {
            ForEach(1...3, id: \.self) { index in
                HStack(spacing: 8) {
                    portDot(index)
                    Text("C\(index)")
                        .fontWeight(.medium)
                        .frame(width: 22, alignment: .leading)
                    nicknameField(index)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                if index < 3 {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    private var deviceNamesSection: some View {
        let entries = preferences.deviceNames.sorted {
            $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending
        }
        return SettingsSection(
            title: "Device names",
            footer: "Name a device from its line in the menu. Devices of the same model share a name."
        ) {
            ForEach(Array(entries.enumerated()), id: \.element.key) { offset, entry in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.value.name)
                            .fontWeight(.medium)
                        Text(entry.value.model ?? entry.key)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        preferences.setDeviceName("", forKey: entry.key, model: entry.value.model)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Forget this name")
                    .accessibilityLabel("Forget \(entry.value.name)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 36)
                if offset < entries.count - 1 {
                    Divider().padding(.leading, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func nicknameField(_ index: Int) -> some View {
        let name = nicknameDrafts[index] ?? ""
        if isScreenshotExport {
            Text(name.isEmpty ? "Optional" : name)
                .foregroundStyle(name.isEmpty ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Saved as you type; there is no separate Save step.
            TextField("Optional", text: Binding(
                get: { nicknameDrafts[index] ?? "" },
                set: { value in
                    nicknameDrafts[index] = value
                    preferences.setNickname(value, forPort: index)
                }
            ))
            .textFieldStyle(.plain)
        }
    }

    // MARK: This Mac

    private var macSection: some View {
        SettingsSection(title: "This Mac") {
            SettingsRow(title: "Open at login") {
                settingsSwitch("Open at login", isOn: Binding(
                    get: { preferences.launchesAtLogin },
                    set: { preferences.setLaunchesAtLogin($0) }
                ))
            }
            SettingsRow(
                title: "Idle port alert",
                subtitle: "Notify after 10 minutes at 0 W."
            ) {
                settingsSwitch("Idle port alert", isOn: Binding(
                    get: { preferences.idleNotificationsEnabled },
                    set: { preferences.setIdleNotificationsEnabled($0) }
                ))
            }
            SettingsRow(
                title: "Release Bluetooth during sleep",
                subtitle: "Charging history pauses until the Mac wakes."
            ) {
                settingsSwitch("Release Bluetooth during sleep", isOn: Binding(
                    get: { preferences.releaseBluetoothOnSleep },
                    set: { preferences.setReleaseBluetoothOnSleep($0) }
                ))
            }
            SettingsRow(
                title: "Connection diagnostics",
                subtitle: "Log, firmware, serial, and MAC.",
                showsDivider: false
            ) {
                Button("Open…") {
                    AuxiliaryWindow.open(.diagnostics, using: openWindow)
                }
            }
        }
    }

    // MARK: Building blocks

    private func portDot(_ index: Int) -> some View {
        Circle()
            .fill(PortPalette.color(index))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func settingsSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        if isScreenshotExport {
            ExportSwitch(isOn: isOn.wrappedValue)
        } else {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func menuPicker<Selection: Hashable, Content: View>(
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker("", selection: selection) {
            content()
        }
        .labelsHidden()
        .fixedSize()
        .disabled(!model.canControlPorts)
    }
}

/// ImageRenderer cannot draw NSSwitch, so screenshot export uses a stand-in with its footprint.
private struct ExportSwitch: View {
    let isOn: Bool

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.15)))
            .frame(width: 32, height: 18)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .padding(1.5)
            }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

#Preview("Settings") {
    SettingsView(model: PreviewSample.connectedModel())
}

#Preview("Settings, disconnected") {
    SettingsView(model: PreviewSample.pausedModel())
}
