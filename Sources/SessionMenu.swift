import AppKit

/// Menu adapter: the owner supplies sessions for the active working directory and
/// persists selection/creation. IDs are opaque to the UI.
struct SessionMenuEntry {
    let id: String
    let title: String
}

final class SessionMenuController: NSObject {
    var onSelect: ((String) -> Void)?
    var onCreate: ((String) -> Void)?

    func item(sessions: [SessionMenuEntry], selectedID: String?, enabled: Bool) -> NSMenuItem {
        let selected = sessions.first { $0.id == selectedID }
        let parent = NSMenuItem(title: "Session: \(selected?.title ?? "None")", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        let create = NSMenuItem(title: "New Session…", action: #selector(createSession), keyEquivalent: "")
        create.target = self
        create.isEnabled = enabled
        menu.addItem(create)
        if !sessions.isEmpty { menu.addItem(.separator()) }
        for session in sessions {
            let item = NSMenuItem(title: session.title, action: #selector(selectSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            item.state = session.id == selectedID ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }
        menu.autoenablesItems = false
        parent.submenu = menu
        return parent
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelect?(id)
    }

    @objc private func createSession() {
        let alert = NSAlert()
        alert.messageText = "New Session"
        alert.informativeText = "Name this conversation so you can return to it later."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Session name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        onCreate?(title)
    }
}
