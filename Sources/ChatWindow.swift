import AppKit

final class ChatWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate {
    var onSelect: ((String) -> Void)?
    var onCreate: (() -> Void)?
    var onSend: ((String) -> Bool)?
    var onVoice: (() -> Void)?
    var onArchive: ((String, Bool) -> Void)?

    private let window = ChatWindow(contentRect: NSRect(x: 0, y: 0, width: 930, height: 630),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    private let search = NSSearchField()
    private let table = ConversationTable()
    private let transcript = NSTextView()
    private let input = MessageEditor()
    private let status = NSTextField(labelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let heading = NSTextField(labelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "Type a message or record one to get started.")
    private let noResults = NSTextField(labelWithString: "No matching conversations")
    private lazy var create = NSButton(title: "New Chat", target: self, action: #selector(newChat))
    private lazy var archive = NSButton(title: "", target: self, action: #selector(toggleArchive))
    private var showingArchive = false
    private lazy var send = NSButton(title: "Send", target: self, action: #selector(sendMessage))
    private lazy var voice = NSButton(title: "Record", target: self, action: #selector(voicePressed))
    private var catalog: ConversationCatalog?
    private var previews: [String: String] = [:]
    private var messages: [ChatMessage] = []
    private var rows: [ConversationSession] = []
    private var drafts: [String: String] = [:]
    private var updatingSelection = false

    var isVisible: Bool { window.isVisible }

    override init() {
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Pi Voice Assistant — Conversations"
        window.contentMinSize = NSSize(width: 620, height: 360)
        window.onFind = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.search)
        }
        window.onNew = { [weak self] in self?.newChat() }

        let content = ChatCanvas()
        window.contentView = content
        let sidebar = ChatCanvas()
        sidebar.isSidebar = true
        let divider = NSBox(); divider.boxType = .separator
        let detail = NSView()
        for view in [sidebar, divider, detail] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor), sidebar.widthAnchor.constraint(equalToConstant: 236),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), divider.widthAnchor.constraint(equalToConstant: 1),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor), detail.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ] + [sidebar, divider, detail].flatMap { [$0.topAnchor.constraint(equalTo: content.topAnchor), $0.bottomAnchor.constraint(equalTo: content.bottomAnchor)] })

        search.placeholderString = "Search all chats"; search.delegate = self
        search.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        archive.setButtonType(.toggle)
        archive.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Archive")
        archive.imagePosition = .imageOnly
        archive.setAccessibilityLabel("Archive")
        archive.toolTip = "Show archived conversations"
        let searchBar = NSStackView(views: [search, archive]); searchBar.spacing = 6; searchBar.alignment = .centerY
        search.toolTip = "Search conversations (⌘F)"
        create.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        create.imagePosition = .imageLeading
        create.toolTip = "New Chat (⌘N)"
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Title")))
        table.headerView = nil; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain; table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear; table.rowHeight = 32
        table.delegate = self; table.dataSource = self
        table.contextMenu = { [weak self] row in self?.archiveMenu(for: row) }
        let list = scrollView(for: table)
        noResults.textColor = .secondaryLabelColor; noResults.alignment = .center
        for view in [create, searchBar, list, noResults] { view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view) }
        NSLayoutConstraint.activate([
            create.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 14),
            searchBar.topAnchor.constraint(equalTo: create.bottomAnchor, constant: 10),
            archive.widthAnchor.constraint(equalToConstant: 30),
            list.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8), list.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),
            noResults.topAnchor.constraint(equalTo: list.topAnchor, constant: 18)
        ] + [create, searchBar, list, noResults].flatMap {
            [$0.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12), $0.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12)]
        })

        heading.font = .systemFont(ofSize: 19, weight: .semibold); heading.lineBreakMode = .byTruncatingTail
        transcript.isEditable = false; transcript.isSelectable = true
        transcript.textContainerInset = NSSize(width: 0, height: 12)
        let history = scrollView(for: transcript)
        empty.font = .systemFont(ofSize: 15); empty.textColor = .secondaryLabelColor; empty.alignment = .center
        status.font = .systemFont(ofSize: 11, weight: .medium); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        notice.font = .systemFont(ofSize: 12); notice.textColor = .systemOrange; notice.maximumNumberOfLines = 2
        notice.lineBreakMode = .byTruncatingTail

        input.font = .systemFont(ofSize: 14); input.textColor = .labelColor
        input.isRichText = false; input.isAutomaticQuoteSubstitutionEnabled = false
        input.textContainerInset = NSSize(width: 8, height: 6)
        input.delegate = self; input.setAccessibilityLabel("Message Pi")
        input.onSend = { [weak self] in self?.sendMessage() }
        let editor = scrollView(for: input)
        let editorFrame = NSBox()
        editorFrame.boxType = .custom; editorFrame.cornerRadius = 10; editorFrame.borderWidth = 1
        editorFrame.borderColor = .separatorColor; editorFrame.fillColor = .controlBackgroundColor
        editorFrame.contentViewMargins = NSSize(width: 5, height: 3)
        editorFrame.contentView = editor
        let placeholder = NSTextField(labelWithString: "Message Pi…")
        placeholder.font = .systemFont(ofSize: 14); placeholder.textColor = .placeholderTextColor
        input.placeholder = placeholder
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        input.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: input.leadingAnchor, constant: 13),
            placeholder.topAnchor.constraint(equalTo: input.topAnchor, constant: 7)
        ])
        voice.toolTip = "Record a message in this conversation"
        send.bezelStyle = .rounded; send.bezelColor = .controlAccentColor; send.controlSize = .large
        send.toolTip = "Send (⌘Return)"
        voice.setContentCompressionResistancePriority(.required, for: .horizontal)
        send.setContentCompressionResistancePriority(.required, for: .horizontal)
        let composer = NSStackView(views: [editorFrame, voice, send]); composer.spacing = 8; composer.alignment = .centerY
        editorFrame.heightAnchor.constraint(equalToConstant: 60).isActive = true
        editorFrame.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let footer = NSStackView(views: [notice, status, composer]); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 6
        let reading = NSLayoutGuide(); detail.addLayoutGuide(reading)
        let fill = reading.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -40); fill.priority = .defaultHigh
        for view in [heading, history, empty, footer] { view.translatesAutoresizingMaskIntoConstraints = false; detail.addSubview(view) }
        NSLayoutConstraint.activate([
            reading.centerXAnchor.constraint(equalTo: detail.centerXAnchor), reading.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            reading.widthAnchor.constraint(lessThanOrEqualTo: detail.widthAnchor, constant: -40), fill,
            heading.topAnchor.constraint(equalTo: detail.topAnchor, constant: 18),
            history.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            history.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            empty.centerYAnchor.constraint(equalTo: history.centerYAnchor),
            footer.bottomAnchor.constraint(equalTo: detail.bottomAnchor, constant: -16),
            composer.widthAnchor.constraint(equalTo: footer.widthAnchor),
            status.widthAnchor.constraint(equalTo: footer.widthAnchor), notice.widthAnchor.constraint(equalTo: footer.widthAnchor)
        ] + [heading, history, empty, footer].flatMap {
            [$0.leadingAnchor.constraint(equalTo: reading.leadingAnchor), $0.trailingAnchor.constraint(equalTo: reading.trailingAnchor)]
        })
        window.initialFirstResponder = input
        window.center()
    }

    func showNewConversation() {
        if showingArchive { toggleArchive() }
        search.stringValue = ""
        refreshRows()
        show()
        window.makeFirstResponder(input)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func render(catalog: ConversationCatalog, messages: [ChatMessage], phase: String, notice: String? = nil, busy: Bool, recording: Bool) {
        let switched = self.catalog?.selectedID != catalog.selectedID
        if switched {
            if let previous = self.catalog?.selectedID { drafts[previous] = input.string.isEmpty ? nil : input.string }
            input.string = drafts.removeValue(forKey: catalog.selectedID) ?? ""
        }
        self.catalog = catalog
        if switched || self.messages != messages {
            let clip = transcript.enclosingScrollView?.contentView
            let follow = switched || transcript.bounds.maxY - (clip?.bounds.maxY ?? 0) < 64
            self.messages = messages
            transcript.textStorage?.setAttributedString(styledTranscript(messages))
            if follow { transcript.scrollToEndOfDocument(nil) }
        }
        empty.isHidden = !messages.isEmpty || notice != nil || busy || recording
        let statusText = phase.isEmpty && catalog.selected.isArchived ? "Archived conversation" : phase
        status.stringValue = statusText; status.isHidden = statusText.isEmpty; status.toolTip = statusText
        self.notice.stringValue = notice ?? ""; self.notice.isHidden = notice == nil; self.notice.toolTip = notice
        voice.title = recording ? "Stop & Send" : (busy ? "Cancel" : "Record")
        input.isEditable = !busy && !recording
        create.isEnabled = input.isEditable; table.isEnabled = input.isEditable
        updateComposer()
        refreshRows()
    }

    func setPreviews(_ previews: [String: String]) {
        guard self.previews != previews else { return }
        self.previews = previews
        refreshRows()
    }

    func controlTextDidChange(_ obj: Notification) { refreshRows() }
    func textDidChange(_ notification: Notification) { updateComposer() }

    private func updateComposer() {
        input.placeholder?.isHidden = !input.string.isEmpty
        send.isEnabled = input.isEditable && !input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func title(for session: ConversationSession) -> String { session.displayTitle(preview: previews[session.id]) }

    private func refreshRows() {
        if let catalog { heading.stringValue = title(for: catalog.selected); heading.toolTip = heading.stringValue }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = catalog?.matching(query, previews: previews, showArchive: showingArchive) ?? []
        noResults.stringValue = query.isEmpty ? (showingArchive ? "Archive is empty" : "No active conversations") : "No matching conversations"
        updatingSelection = true
        defer { updatingSelection = false }
        rows = next
        table.reloadData()
        noResults.isHidden = !rows.isEmpty
        if let row = rows.firstIndex(where: { $0.id == catalog?.selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ConversationRow() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = rows[row]
        let label = NSTextField(labelWithString: title(for: session))
        label.font = .systemFont(ofSize: 13, weight: .medium); label.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView()
        cell.textField = label; cell.toolTip = label.stringValue
        var views: [NSView] = [label]
        if session.isArchived && !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let icon = NSImageView(image: NSImage(systemSymbolName: "archivebox", accessibilityDescription: "Archived")!)
            icon.contentTintColor = .secondaryLabelColor
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(icon)
        }
        let rowContent = NSStackView(views: views); rowContent.spacing = 5
        rowContent.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(rowContent)
        NSLayoutConstraint.activate([
            rowContent.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            rowContent.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            rowContent.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingSelection, rows.indices.contains(table.selectedRow) else { return }
        onSelect?(rows[table.selectedRow].id)
    }

    private func scrollView(for view: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        if let textView = view as? NSTextView {
            textView.drawsBackground = false
            textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
        }
        scroll.documentView = view
        return scroll
    }

    private func archiveMenu(for row: Int) -> NSMenu? {
        guard table.isEnabled, rows.indices.contains(row) else { return nil }
        let session = rows[row]
        let menu = NSMenu()
        let action = NSMenuItem(title: session.isArchived ? "Restore from Archive" : "Archive Chat",
                                action: #selector(changeArchive(_:)), keyEquivalent: "")
        action.target = self; action.representedObject = session.id
        menu.addItem(action)
        return menu
    }

    @objc private func changeArchive(_ sender: NSMenuItem) {
        guard table.isEnabled, let id = sender.representedObject as? String,
              let session = catalog?.sessions.first(where: { $0.id == id }) else { return }
        onArchive?(id, !session.isArchived)
    }

    @objc private func toggleArchive() {
        showingArchive.toggle()
        archive.state = showingArchive ? .on : .off
        archive.image = NSImage(systemSymbolName: showingArchive ? "archivebox.fill" : "archivebox", accessibilityDescription: "Archive")
        archive.toolTip = showingArchive ? "Back to active conversations" : "Show archived conversations"
        search.stringValue = ""
        refreshRows()
    }

    @objc private func newChat() {
        guard create.isEnabled else { return }
        onCreate?()
    }

    @objc private func sendMessage() {
        guard input.isEditable, !input.hasMarkedText(), !input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if onSend?(input.string) == true { input.string = ""; updateComposer() }
    }

    @objc private func voicePressed() { onVoice?() }
}

private func styledTranscript(_ messages: [ChatMessage]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for (index, message) in messages.enumerated() {
        let caption = NSMutableParagraphStyle(); caption.paragraphSpacing = 5
        let body = NSMutableParagraphStyle(); body.lineSpacing = 4; body.paragraphSpacing = 4
        result.append(NSAttributedString(string: message.speaker + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: message.role == .user ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            .paragraphStyle: caption
        ]))
        result.append(NSAttributedString(string: message.text + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor, .paragraphStyle: body
        ]))
        if index < messages.count - 1 { result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 10)])) }
    }
    return result
}

private final class ChatCanvas: NSView {
    var isSidebar = false
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSColor.windowBackgroundColor
        let fill = isSidebar ? base.blended(withFraction: 0.06, of: .labelColor) ?? base : base
        fill.setFill()
        dirtyRect.fill()
    }
}

private final class ConversationTable: NSTableView {
    var contextMenu: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

private final class ConversationRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }
}

private final class MessageEditor: NSTextView {
    weak var placeholder: NSTextField?
    var onSend: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let placeholder, hit === placeholder { return self }
        return hit
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock]) == .command,
           !hasMarkedText() { onSend?() }
        else { super.keyDown(with: event) }
    }
}

private final class ChatWindow: NSWindow {
    var onFind: (() -> Void)?
    var onNew: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command {
            switch event.characters(byApplyingModifiers: .command)?.lowercased() {
            case "a" where firstResponder is MessageEditor: firstResponder?.selectAll(nil); return true
            case "f": onFind?(); return true
            case "n": if !event.isARepeat { onNew?() }; return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
