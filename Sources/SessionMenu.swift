import AppKit

final class SessionMenuController: NSObject {
    var onSelect: ((String) -> Void)?
    var onCreate: (() -> Void)?

    func item(catalog: ConversationCatalog, enabled: Bool) -> NSMenuItem {
        let parent = NSMenuItem(title: "Conversations", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let create = NSMenuItem(title: "New Chat", action: #selector(createChat), keyEquivalent: "")
        create.target = self; create.isEnabled = enabled
        menu.addItem(create)
        menu.addItem(.separator())
        for session in catalog.matching("") {
            let item = NSMenuItem(title: session.title, action: #selector(selectChat(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = session.id; item.isEnabled = enabled
            item.state = session.id == catalog.selectedID ? .on : .off
            menu.addItem(item)
        }
        parent.submenu = menu
        return parent
    }

    @objc private func selectChat(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onSelect?(id) }
    }

    @objc private func createChat() { onCreate?() }
}
