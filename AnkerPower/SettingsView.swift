import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences

    @State private var customC1: Int = 0
    @State private var customC2: Int = 0
    @State private var customC3: Int = 0
    @State private var nicknameDrafts: [Int: String] = [1: "", 2: "", 3: ""]

    init(model: AppModel) {
        self.model = model
        _preferences = ObservedObject(wrappedValue: model.preferences)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            displaySection
            Divider()
            customSection
            Divider()
            macSection
        }
        .padding(14)
        .frame(width: 280)
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
            Text("Display")
                .font(.subheadline.weight(.semibold))
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

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom split")
                .font(.subheadline.weight(.semibold))
            Text("Each port 0 or 15–140 W, 160 W total.")
                .font(.caption)
                .foregroundStyle(.secondary)
            wattStepper("C1", value: $customC1)
            wattStepper("C2", value: $customC2)
            wattStepper("C3", value: $customC3)
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
            Text("This Mac")
                .font(.subheadline.weight(.semibold))
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
            Button("Save port names") {
                for index in 1...3 {
                    preferences.setNickname(nicknameDrafts[index] ?? "", forPort: index)
                }
            }
        }
    }

    private func wattStepper(_ title: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 0...140, step: 5) {
            Text("\(title)  \(value.wrappedValue) W")
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
