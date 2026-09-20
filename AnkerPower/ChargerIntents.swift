import AppIntents

struct SetAnkerPortOutputIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Anker Port Output"
    static var description = IntentDescription("Turn an Anker Prime 160W USB-C port on or off.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Port", description: "Port number 1, 2, or 3")
    var port: Int

    @Parameter(title: "On")
    var enabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn C\(\.$port) \(\.$enabled)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard (1...3).contains(port) else {
            throw IntentError.message("Choose C1, C2, or C3.")
        }
        guard let model = AppRuntime.model, model.canControlPorts else {
            throw IntentError.message("Anker Power is not connected to the charger.")
        }
        model.setPortOutput(index: port, enabled: enabled)
        let name = model.preferences.displayName(forPort: port)
        return .result(dialog: "\(name) is now \(enabled ? "on" : "off").")
    }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text):
            return "\(text)"
        }
    }
}

struct AnkerPowerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetAnkerPortOutputIntent(),
            phrases: [
                "Turn off an Anker port in \(.applicationName)",
                "Set Anker port output in \(.applicationName)"
            ],
            shortTitle: "Set Port Output",
            systemImageName: "bolt.horizontal.circle"
        )
    }
}
