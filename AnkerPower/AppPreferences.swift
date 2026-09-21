import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private static let portLabelsKey = "portNicknames"
    private static let idleNotificationsKey = "idleNotificationsEnabled"
    private static let screensaverVignetteKey = "screensaverVignetteEnabled"
    private static let identityFileName = "charger-identity.json"

    @Published var portNicknames: [Int: String]
    @Published var idleNotificationsEnabled: Bool
    @Published var screensaverVignetteEnabled: Bool
    @Published private(set) var launchesAtLogin: Bool

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.portLabelsKey) as? [String: String] ?? [:]
        var nicknames: [Int: String] = [:]
        for (key, value) in stored {
            if let index = Int(key), (1...3).contains(index), !value.trimmingCharacters(in: .whitespaces).isEmpty {
                nicknames[index] = value
            }
        }
        self.portNicknames = nicknames
        self.idleNotificationsEnabled = UserDefaults.standard.bool(forKey: Self.idleNotificationsKey)
        if UserDefaults.standard.object(forKey: Self.screensaverVignetteKey) == nil {
            self.screensaverVignetteEnabled = true
        } else {
            self.screensaverVignetteEnabled = UserDefaults.standard.bool(forKey: Self.screensaverVignetteKey)
        }
        self.launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// In-memory preferences for SwiftUI previews and screenshot export.
    init(
        previewNicknames: [Int: String] = [:],
        idleNotificationsEnabled: Bool = false,
        launchesAtLogin: Bool = false,
        screensaverVignetteEnabled: Bool = true
    ) {
        self.portNicknames = previewNicknames
        self.idleNotificationsEnabled = idleNotificationsEnabled
        self.launchesAtLogin = launchesAtLogin
        self.screensaverVignetteEnabled = screensaverVignetteEnabled
    }

    func displayName(forPort index: Int) -> String {
        if let nickname = portNicknames[index]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nickname.isEmpty {
            return "C\(index) · \(nickname)"
        }
        return "C\(index)"
    }

    func setNickname(_ name: String, forPort index: Int) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            portNicknames[index] = nil
        } else {
            portNicknames[index] = trimmed
        }
        persistNicknames()
    }

    func setIdleNotificationsEnabled(_ enabled: Bool) {
        idleNotificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.idleNotificationsKey)
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func setScreensaverVignetteEnabled(_ enabled: Bool) {
        screensaverVignetteEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.screensaverVignetteKey)
    }

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    launchesAtLogin = true
                    return
                }
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func loadPersistedIdentity() -> ChargerIdentity? {
        guard let url = identityURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChargerIdentity.self, from: data)
    }

    func persistIdentity(_ identity: ChargerIdentity) {
        guard !identity.isEmpty, let url = identityURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(identity) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func persistNicknames() {
        var stored: [String: String] = [:]
        for (index, name) in portNicknames {
            stored[String(index)] = name
        }
        UserDefaults.standard.set(stored, forKey: Self.portLabelsKey)
    }

    private var identityURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("AnkerPower", isDirectory: true)
            .appendingPathComponent(Self.identityFileName)
    }
}

enum IdleChargeNotifier {
    static let idleInterval: TimeInterval = 10 * 60
    private static let category = "idle-port"

    static func notify(portIndex: Int, label: String) {
        let content = UNMutableNotificationContent()
        content.title = "Anker Power"
        content.body = "\(label) has been at 0 W for 10 minutes."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "\(category)-\(portIndex)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
