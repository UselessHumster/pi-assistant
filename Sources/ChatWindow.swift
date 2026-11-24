import AppKit

final class ChatWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onSelect: ((String) -> Void)?
    var onCreate: (() -> Void)?
    var onSend: ((String) -> Bool)?
    var onVoice: (() -> Void)?

    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 870, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let transcript = NSTextView()
    private let input = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let heading = NSTextField(labelWithString: "")
    private lazy var create = NSButton(title: "+ New Chat", target: self, action: #selector(newChat))
    private lazy var send = NSButton(title: "Send", target: self, action: #selector(sendMessage))
    private lazy var voice = NSButton(title: "Record", target: self, action: #selector(voicePressed))
    private var catalog: ConversationCatalog?
    private var rows: [ConversationSession] = []
    private var drafts: [String: String] = [:]
    private var updatingSelection = false

    var isVisible: Bool { window.isVisible }

    override init() {
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Pi Voice Assistant — Conversations"
        window.minSize = NSSize(width: 620, height: 360)

        search.placeholderString = "Search conversations"
        search.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Title")))
        table.headerView = nil
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .sourceList
        table.rowHeight = 26
        table.delegate = self; table.dataSource = self
        let list = scrollView(for: table)
        let sidebar = NSStackView(views: [search, list, create])
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 8
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)

        transcript.isEditable = false; transcript.isSelectable = true
        transcript.font = .systemFont(ofSize: 14)
        transcript.textContainerInset = NSSize(width: 12, height: 10)
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        transcript.autoresizingMask = [.width]
        transcript.textContainer?.widthTracksTextView = true
        let history = scrollView(for: transcript)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 3
        input.placeholderString = "Type a message…"
        input.target = self; input.action = #selector(sendMessage)
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let composer = NSStackView(views: [input, send, voice]); composer.spacing = 8
        let chat = NSStackView(views: [heading, history, status, composer])
        chat.orientation = .vertical; chat.alignment = .leading; chat.spacing = 8
        chat.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let divider = NSBox(); divider.boxType = .separator
        let content = NSStackView(views: [sidebar, divider, chat]); content.spacing = 0
        content.alignment = .top
        window.contentView = content
        NSLayoutConstraint.activate([
            sidebar.widthAnchor.constraint(equalToConstant: 235),
            sidebar.heightAnchor.constraint(equalTo: content.heightAnchor),
            divider.heightAnchor.constraint(equalTo: content.heightAnchor),
            chat.heightAnchor.constraint(equalTo: content.heightAnchor),
            search.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -20),
            list.widthAnchor.constraint(equalTo: search.widthAnchor),
            history.widthAnchor.constraint(equalTo: chat.widthAnchor, constant: -28),
            heading.widthAnchor.constraint(equalTo: history.widthAnchor),
            status.widthAnchor.constraint(equalTo: history.widthAnchor),
            composer.widthAnchor.constraint(equalTo: history.widthAnchor)
        ])
        window.center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func render(catalog: ConversationCatalog, history: String, phase: String, busy: Bool, recording: Bool) {
        if self.catalog?.selectedID != catalog.selectedID {
            if let previous = self.catalog?.selectedID {
                drafts[previous] = input.stringValue.isEmpty ? nil : input.stringValue
            }
            input.stringValue = drafts.removeValue(forKey: catalog.selectedID) ?? ""
        }
        self.catalog = catalog
        heading.stringValue = catalog.selected.title
        if transcript.string != history {
            transcript.string = history
            transcript.scrollToEndOfDocument(nil)
        }
        status.stringValue = phase
        voice.title = recording ? "Stop" : (busy ? "Cancel" : "Record")
        input.isEnabled = !busy && !recording
        send.isEnabled = input.isEnabled
        create.isEnabled = input.isEnabled
        table.isEnabled = input.isEnabled
        refreshRows()
    }

    func controlTextDidChange(_ obj: Notification) { refreshRows() }

    private func refreshRows() {
        rows = catalog?.matching(search.stringValue) ?? []
        updatingSelection = true
        defer { updatingSelection = false }
        table.reloadData()
        if let row = rows.firstIndex(where: { $0.id == catalog?.selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title = NSTextField(labelWithString: rows[row].title)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = title.stringValue
        return title
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, rows.indices.contains(table.selectedRow) else { return }
        onSelect?(rows[table.selectedRow].id)
    }

    private func scrollView(for view: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = view
        return scroll
    }

    @objc private func newChat() {
        search.stringValue = ""
        onCreate?()
        window.makeFirstResponder(input)
    }

    @objc private func sendMessage() {
        if onSend?(input.stringValue) == true { input.stringValue = "" }
    }

    @objc private func voicePressed() { onVoice?() }
}
