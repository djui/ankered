import AppKit
import SwiftUI

enum AppAbout {
    private static let homepageURL = URL(string: "https://djui.github.io/ankered/")!

    static func show() {
        let credits = NSMutableAttributedString(
            string: "Homepage",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.linkColor,
                .link: homepageURL
            ]
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Anker Power",
            .credits: credits
        ])
    }
}

enum AuxiliaryWindow {
    case history
    case diagnostics
    case settings

    var id: String {
        switch self {
        case .history: "history"
        case .diagnostics: "diagnostics"
        case .settings: "settings"
        }
    }

    var title: String {
        switch self {
        case .history: "Charging History"
        case .diagnostics: "Connection Diagnostics"
        case .settings: "Settings"
        }
    }

    var presentsAsDialog: Bool {
        self == .settings
    }

    static func open(_ window: AuxiliaryWindow, using openWindow: OpenWindowAction) {
        openWindow(id: window.id)
        raise(window)
    }

    static func raise(_ window: AuxiliaryWindow) {
        let id = window.id
        let title = window.title
        // Menu-bar-only apps do not always become active when SwiftUI creates a
        // secondary window. Activate and raise it after the scene has materialized.
        for delay in [0.0, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                guard let nsWindow = NSApplication.shared.windows.first(where: {
                    $0.identifier?.rawValue == id || $0.title == title
                }) else { return }
                if nsWindow.isMiniaturized {
                    nsWindow.deminiaturize(nil)
                }
                if window.presentsAsDialog {
                    nsWindow.styleMask.remove([.resizable, .miniaturizable])
                    nsWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
                    nsWindow.standardWindowButton(.zoomButton)?.isHidden = true
                    nsWindow.center()
                }
                nsWindow.makeKeyAndOrderFront(nil)
                nsWindow.orderFrontRegardless()
            }
        }
    }
}

@MainActor
final class StatusItemContextMenu: NSObject {
    static let shared = StatusItemContextMenu()

    private var monitor: Any?
    private var model: AppModel?
    private var openWindow: OpenWindowAction?

    func install(model: AppModel, openWindow: OpenWindowAction) {
        self.model = model
        self.openWindow = openWindow
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .rightMouseUp, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.isStatusItemEvent(event) else { return event }

            switch event.type {
            case .rightMouseDown:
                self.show(event)
                return nil
            case .rightMouseUp:
                return nil
            case .leftMouseDown where event.modifierFlags.contains(.control):
                self.show(event)
                return nil
            case .leftMouseUp where event.modifierFlags.contains(.control):
                return nil
            default:
                return event
            }
        }
    }

    private func isStatusItemEvent(_ event: NSEvent) -> Bool {
        event.window?.className.contains("StatusBarWindow") == true
    }

    private func show(_ event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let isPaused = model?.isPaused == true
        let pauseItem = NSMenuItem(
            title: isPaused ? "Resume Connection" : "Pause Connection",
            action: isPaused ? #selector(resumeConnection) : #selector(pauseConnection),
            keyEquivalent: ""
        )
        pauseItem.target = self
        menu.addItem(pauseItem)

        let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnectAction), keyEquivalent: "")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        let historyItem = NSMenuItem(title: "Charging History", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: "About Anker Power", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        if let contentView = event.window?.contentView {
            menu.popUp(positioning: nil, at: event.locationInWindow, in: contentView)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func pauseConnection() {
        model?.pauseConnection()
    }

    @objc private func resumeConnection() {
        model?.resumeConnection()
    }

    @objc private func reconnectAction() {
        model?.reconnect()
    }

    @objc private func openSettings() {
        guard let openWindow else { return }
        AuxiliaryWindow.open(.settings, using: openWindow)
    }

    @objc private func openHistory() {
        guard let openWindow else { return }
        AuxiliaryWindow.open(.history, using: openWindow)
    }

    @objc private func showAbout() {
        AppAbout.show()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
