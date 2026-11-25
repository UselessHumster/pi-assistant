import AppKit

@main
struct ChatWindowTests {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let chat = ChatWindowController()
        let a = ConversationSession(id: "a", title: "Conversation")
        let b = ConversationSession(id: "b", title: "Café notes")
        var catalog = ConversationCatalog(sessions: [a, b], selectedID: a.id)
        func render(_ text: String) {
            chat.render(catalog: catalog, messages: [.init(role: .user, text: "Как подготовить план на неделю?"), .init(role: .assistant, text: text)],
                        phase: "", busy: false, recording: false)
        }
        chat.setPreviews([a.id: "План на неделю"])
        render("Раздели задачи на три группы: встречи, работа без отвлечений и всё остальное. Затем выдели время для каждой группы и оставь запас между встречами.\n\nНачни с двух приоритетов на понедельник.")
        chat.show()
        let window = NSApp.windows.first { $0.title.hasSuffix("Conversations") }!
        let content = window.contentView!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(content)
        let table = views.compactMap { $0 as? NSTableView }.first!
        let search = views.compactMap { $0 as? NSSearchField }.first!
        let textViews = views.compactMap { $0 as? NSTextView }.filter { $0.enclosingScrollView != nil }
        let history = textViews.first { !$0.isEditable }!
        let input = textViews.first { $0.isEditable }!
        let send = views.compactMap { $0 as? NSButton }.first { $0.title == "Send" }!
        for size in [NSSize(width: 620, height: 360), NSSize(width: 930, height: 630), NSSize(width: 1230, height: 670)] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            let historyScroll = history.enclosingScrollView!
            let editor = input.enclosingScrollView!
            let expected = min(CGFloat(720), size.width - 237 - 40)
            precondition(abs(historyScroll.frame.width - expected) < 2, "History width: \(historyScroll.frame.width), expected \(expected)")
            precondition(abs(history.frame.width - historyScroll.contentSize.width) < 2, "Text width: \(history.frame.width), viewport: \(historyScroll.contentSize.width)")
            precondition(history.textContainer!.containerSize.width > expected - 30)
            precondition(editor.frame.width > expected - 160, "Editor width: \(editor.frame.width)")
            precondition(abs(input.frame.width - editor.contentSize.width) < 2)
            precondition(historyScroll.frame.height > 180)
        }
        window.setContentSize(NSSize(width: 930, height: 630))
        if let path = ProcessInfo.processInfo.environment["CHAT_SNAPSHOT"] {
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(path)-\(mode).png"))
            }
        }
        precondition(table.numberOfRows == 2 && table.selectedRow == 1 && !send.isEnabled)
        input.string = "unsent draft"
        var selectionChanges = 0
        chat.onSelect = { id in selectionChanges += 1; catalog.selectedID = id; render("Second transcript") }
        func searchFor(_ query: String) {
            search.stringValue = query
            chat.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        }
        searchFor("НЕДЕЛЮ")
        precondition(table.numberOfRows == 1 && table.selectedRow == 0 && selectionChanges == 0)
        searchFor("CAFE")
        precondition(table.numberOfRows == 1 && table.selectedRow == -1 && selectionChanges == 0)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        precondition(selectionChanges == 1 && catalog.selectedID == b.id && history.string.contains("Pi\nSecond transcript"))
        precondition(input.string.isEmpty)
        catalog.selectedID = a.id; render("First transcript")
        precondition(input.string == "unsent draft")
        catalog.selectedID = b.id; render("Second transcript")
        var sent: String?
        chat.onSend = { sent = $0; return true }
        input.string = "   \n"
        chat.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
        precondition(!send.isEnabled)
        input.string = "first line\nsecond line"
        chat.textDidChange(Notification(name: NSText.didChangeNotification, object: input))
        precondition(send.isEnabled)
        send.performClick(nil)
        precondition(sent == "first line\nsecond line" && input.string.isEmpty)
        func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        window.makeFirstResponder(input)
        input.string = "keyboard"
        input.setSelectedRange(NSRange(location: 8, length: 0))
        input.keyDown(with: key(36, "\r"))
        precondition(input.string == "keyboard\n")
        input.keyDown(with: key(36, "\r", flags: .command))
        precondition(sent == "keyboard\n" && input.string.isEmpty)
        window.sendEvent(key(3, "f", flags: .command))
        precondition(search.currentEditor() === window.firstResponder)
        RunLoop.main.run(until: Date().addingTimeInterval(16))
        precondition(chat.isVisible && catalog.selectedID == b.id)
        window.close()
        precondition(!chat.isVisible)
        chat.show()
        precondition(chat.isVisible && history.string.contains("Second transcript") && table.selectedRow == 0)
        print("Chat window tests passed.")
    }
}
