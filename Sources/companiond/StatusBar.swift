import AppKit
import CompanionShared

/// Menu-bar item: count of sessions waiting on you, the pairing code while one is active, paired phones.
final class StatusBar: NSObject {
    struct State {
        var waiting: [SessionInfo]
        var busy: Int
        var phones: [String]
        var pairingCode: String?
        var dnd: DNDState
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var onRevokeAll: (() -> Void)?

    override init() {
        super.init()
        update(State(waiting: [], busy: 0, phones: [], pairingCode: nil, dnd: DNDState()))
    }

    func update(_ s: State) {
        if let code = s.pairingCode {
            item.button?.title = "✳ \(code)"
        } else if !s.waiting.isEmpty {
            item.button?.title = "✳ \(s.waiting.count)"
        } else {
            item.button?.title = s.busy > 0 ? "✳ …" : "✳"
        }

        let menu = NSMenu()
        if let code = s.pairingCode {
            menu.addItem(disabled("Pairing code: \(code)"))
            menu.addItem(.separator())
        }
        if s.waiting.isEmpty {
            menu.addItem(disabled(s.busy > 0 ? "\(s.busy) working, none waiting" : "Nothing waiting"))
        } else {
            for session in s.waiting {
                let mi = NSMenuItem(title: "\(session.status.label): \(session.title)", action: #selector(open(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = session.id
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        menu.addItem(disabled(s.phones.isEmpty ? "No phone connected" : "Phone: \(s.phones.joined(separator: ", "))"))
        if s.dnd.mode != .off || s.dnd.night {
            menu.addItem(disabled(s.dnd.night ? "Phone: night mode" : "Phone: \(s.dnd.mode == .muted ? "muted" : "pinned sessions only")"))
        }
        let revoke = NSMenuItem(title: "Unpair all phones", action: #selector(revokeAll), keyEquivalent: "")
        revoke.target = self
        menu.addItem(revoke)
        menu.addItem(NSMenuItem(title: "Quit Claude Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    @objc private func open(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Actions.openSession(id) }
    }

    @objc private func revokeAll() { onRevokeAll?() }
}
