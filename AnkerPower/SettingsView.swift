import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
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
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                displaySection
                Divider()
                customSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 16) {
                screensaverSection
                Divider()
                macSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 680, alignment: .topLeading)
        .onAppear {
            customC1 = Int(model.settings.customSplit?.c1 ?? 0)
            customC2 = Int(model.settings.customSplit?.c2 ?? 0)
            customC3 = Int(model.settings.customSplit?.c3 ?? 0)
            for index in 1...3 {
                nicknameDrafts[index] = preferences.portNicknames[index] ?? ""
            }
        }
    }

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Display")
            HStack {
                Text("Brightness")
                Spacer()
                Text("\(model.settings.brightnessPercent ?? 80)%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(model.settings.brightnessPercent ?? 80) },
                    set: { model.setScreenBrightness(Int($0.rounded())) }
                ),
                in: 25...100,
                step: 5
            )
            .disabled(!model.canControlPorts)

            labeledPicker("Timeout", selection: Binding(
                get: { model.settings.screenTimeout ?? .oneMinute },
                set: { model.setScreenTimeout($0) }
            )) {
                ForEach(ChargerScreenTimeout.allCases, id: \.self) { timeout in
                    Text(timeout.label).tag(timeout)
                }
            }

            labeledPicker("Language", selection: Binding(
                get: { model.settings.language ?? .english },
                set: { model.setLanguage($0) }
            )) {
                ForEach(ChargerLanguage.allCases, id: \.self) { language in
                    Text(language.label).tag(language)
                }
            }

            labeledPicker("Orientation", selection: Binding(
                get: { model.settings.orientation ?? .up },
                set: { model.setScreenOrientation($0) }
            )) {
                ForEach(ChargerOrientation.allCases, id: \.self) { orientation in
                    Text(orientation.label).tag(orientation)
                }
            }

            Toggle(
                "Auto-rotate",
                isOn: Binding(
                    get: { model.settings.autoRotate ?? true },
                    set: { model.setAutoRotate($0) }
                )
            )
            .disabled(!model.canControlPorts)
        }
    }

    private var screensaverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Screensaver")
            Text("Square \(ScreensaverImage.pixelSize)×\(ScreensaverImage.pixelSize) looks sharpest.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(0..<ScreensaverStore.slotCount, id: \.self) { index in
                    screensaverSlot(index)
                }
            }
            HStack {
                Button(screensaverStore.isFull ? "Replace oldest…" : "Add image…") {
                    if screensaverStore.isFull {
                        confirmReplace = true
                    } else {
                        pickScreensaverImage()
                    }
                }
                .disabled(!model.canControlPorts || isScreensaverBusy)
                Spacer()
            }
            if let counts = model.screensaverProgress.uploadCounts {
                ProgressView(value: Double(counts.current), total: Double(counts.total))
            }
            if let label = model.screensaverProgress.label {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(screensaverFailed ? .red : .secondary)
            }
        }
        .confirmationDialog(
            "Replace oldest screensaver?",
            isPresented: $confirmReplace
        ) {
            Button("Replace oldest", role: .destructive) {
                pickScreensaverImage()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The charger keeps four images. A new one overwrites the oldest on the device. This cannot be undone over Bluetooth.")
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

    private func screensaverSlot(_ index: Int) -> some View {
        let slot = screensaverStore.slots[safe: index]
        let showsUnknown = slot == nil && unknownOnCharger != nil && firstEmptySlotIndex == index
        let selected = (slot?.reportedID != nil && slot?.reportedID == model.settings.screensaverReportedID)
            || showsUnknown
        return Button {
            if let slot {
                model.selectScreensaver(slot)
            } else if !showsUnknown, model.canControlPorts, !isScreensaverBusy {
                pickScreensaverImage()
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
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
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.canControlPorts || isScreensaverBusy || showsUnknown)
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

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Custom split")
            Text("Each port 0 or 15–140 W, 160 W total.")
                .font(.caption)
                .foregroundStyle(.secondary)
            wattRow("C1", value: $customC1)
            wattRow("C2", value: $customC2)
            wattRow("C3", value: $customC3)
            let split = CustomChargeSplit(portWatts: [
                UInt8(customC1),
                UInt8(customC2),
                UInt8(customC3)
            ])
            HStack {
                Text("\(split.totalWatts) W")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply custom") {
                    model.setCustomChargeSplit(split)
                }
                .disabled(!model.canControlPorts || split.validationError != nil)
            }
            if let error = split.validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var macSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("This Mac")
            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { preferences.launchesAtLogin },
                    set: { preferences.setLaunchesAtLogin($0) }
                )
            )
            Toggle(
                "Notify when a port idles 10 min",
                isOn: Binding(
                    get: { preferences.idleNotificationsEnabled },
                    set: { preferences.setIdleNotificationsEnabled($0) }
                )
            )
            ForEach(1...3, id: \.self) { index in
                HStack {
                    Text("C\(index) name")
                    nicknameField(index)
                }
            }
            Button("Save port names") {
                for index in 1...3 {
                    preferences.setNickname(nicknameDrafts[index] ?? "", forPort: index)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
    }

    @ViewBuilder
    private func nicknameField(_ index: Int) -> some View {
        let name = nicknameDrafts[index] ?? ""
        if isScreenshotExport {
            Text(name.isEmpty ? "Optional" : name)
                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
                )
        } else {
            TextField("Optional", text: Binding(
                get: { nicknameDrafts[index] ?? "" },
                set: { nicknameDrafts[index] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                preferences.setNickname(nicknameDrafts[index] ?? "", forPort: index)
            }
        }
    }

    @ViewBuilder
    private func wattRow(_ title: String, value: Binding<Int>) -> some View {
        if isScreenshotExport {
            Text("\(title)  \(value.wrappedValue) W")
        } else {
            Stepper(value: value, in: 0...140, step: 5) {
                Text("\(title)  \(value.wrappedValue) W")
            }
        }
    }

    private func labeledPicker<Selection: Hashable, Content: View>(
        _ title: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker(title, selection: selection) {
            content()
        }
        .disabled(!model.canControlPorts)
    }
}

#Preview("Settings") {
    SettingsView(model: PreviewSample.connectedModel())
        .frame(width: 680)
}
