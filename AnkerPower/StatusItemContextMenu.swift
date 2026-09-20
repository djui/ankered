import AppKit
import SwiftUI

enum AuxiliaryWindow {
    case history
    case diagnostics

    var id: String {
        switch self {
        case .history: "history"
        case .diagnostics: "diagnostics"
        }
    }

    var title: String {
        switch self {
        case .history: "Charging History"
        case .diagnostics: "Connection Diagnostics"
        }
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

        let reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnectAction), keyEquivalent: "")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        let historyItem = NSMenuItem(title: "Charging History", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: #selector(openDiagnostics), keyEquivalent: "")
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        if let contentView = event.window?.contentView {
            menu.popUp(positioning: nil, at: event.locationInWindow, in: contentView)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func reconnectAction() {
        model?.reconnect()
    }

    @objc private func openHistory() {
        guard let openWindow else { return }
        AuxiliaryWindow.open(.history, using: openWindow)
    }

    @objc private func openDiagnostics() {
        guard let openWindow else { return }
        AuxiliaryWindow.open(.diagnostics, using: openWindow)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
