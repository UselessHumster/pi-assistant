import AppKit

@main
struct ChatWindowTests {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let chat = ChatWindowController()
        let a = ConversationSession(id: "a", title: "Первый чат")
        let b = ConversationSession(id: "b", title: "Café notes")
        var catalog = ConversationCatalog(sessions: [a, b], selectedID: a.id)
        func render(_ text: String) { chat.render(catalog: catalog, history: text, phase: "Ready", busy: false, recording: false) }
        render("first transcript")
        chat.show()
        let window = NSApp.windows.first { $0.title.hasSuffix("Conversations") }!
        let content = window.contentView!
        content.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let views = descendants(content)
        let table = views.compactMap { $0 as? NSTableView }.first!
        let search = views.compactMap { $0 as? NSSearchField }.first!
        let historyScroll = views.compactMap { $0 as? NSScrollView }.first { $0.documentView is NSTextView }!
        let history = historyScroll.documentView as! NSTextView
        let input = views.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Type a message…" }!
        input.stringValue = "unsent draft"
        precondition(table.numberOfRows == 2 && table.selectedRow == 1)
        precondition(table.enclosingScrollView!.frame.height > 200 && historyScroll.frame.height > 200)
        precondition(history.string == "first transcript")
        var selectionChanges = 0
        chat.onSelect = { id in selectionChanges += 1; catalog.selectedID = id; render("second transcript") }
        search.stringValue = "CAFE"
        chat.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        precondition(table.numberOfRows == 1 && table.selectedRow == -1 && selectionChanges == 0)
        precondition(history.string == "first transcript")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        precondition(selectionChanges == 1 && catalog.selectedID == b.id && history.string == "second transcript")
        let send = views.compactMap { $0 as? NSButton }.first { $0.title == "Send" }!
        precondition(input.stringValue.isEmpty)
        catalog.selectedID = a.id; render("first transcript")
        precondition(input.stringValue == "unsent draft")
        catalog.selectedID = b.id; render("second transcript")
        chat.onSend = { $0 == "next" }
        input.stringValue = "next"
        send.performClick(nil)
        precondition(input.stringValue.isEmpty)
        RunLoop.main.run(until: Date().addingTimeInterval(16))
        precondition(chat.isVisible && catalog.selectedID == b.id)
        window.close()
        precondition(!chat.isVisible)
        chat.show()
        precondition(chat.isVisible && history.string == "second transcript" && table.selectedRow == 0)
        print("Chat window tests passed.")
    }
}
