import AppKit

/// Keep the entire panel inside the usable area, including on displays with negative origins.
func overlayFrame(in visible: NSRect) -> NSRect {
    let width = min(340, max(0, visible.width))
    let height = min(66, max(0, visible.height))
    return NSRect(x: visible.midX - width / 2,
                  y: max(visible.minY, visible.maxY - height - 24),
                  width: width, height: height)
}

/// A non-activating status indicator. All methods and callbacks run on the main thread.
final class FloatingOverlayController: NSObject {
    /// Called with the response supplied to showSuccess when the indicator is clicked.
    var onOpenResponse: ((String) -> Void)?
    /// Invoked only for an explicit close, never for programmatic hiding.
    var onClose: (() -> Void)?
    var isShowingResponse: Bool { response != nil && expanded && panel.isVisible }
    var isVisible: Bool { panel.isVisible }
    /// Called when the microphone control is pressed.
    var onMicrophone: (() -> Void)?
    /// Called when the response expires, not on manual or programmatic close.
    var onAutoClose: (() -> Void)?
    /// The application supplies the existing typed-message submission handler.
    var onSendText: ((String) -> Bool)? {
        didSet { input.isEnabled = onSendText != nil; sendButton.isEnabled = onSendText != nil }
    }

    private let panel: NSPanel
    private let background: OverlayView
    private let icon: NSImageView
    private let label: NSTextField
    private let detail: NSTextField
    private let meter: LevelMeter
    private let closeButton: CloseButton
    private let responseScroll: NSScrollView
    private let responseText: ResponseTextView
    private let microphoneButton: NSButton
    private let countdown: NSTextField
    private let input: NSTextField
    private let sendButton: NSButton
    private var hasPosition = false
    private let dismissalInterval: TimeInterval
    private var dismissalTimer: Timer?
    private var deadline: Date?
    private var expanded = false
    private var responseConstraints: [NSLayoutConstraint] = []
    private var response: String?
    private var screenObserver: NSObjectProtocol?

    init(dismissalInterval: TimeInterval = 15) {
        self.dismissalInterval = max(0, dismissalInterval)
        panel = ChatPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 66),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        background = OverlayView(frame: panel.contentView!.bounds)
        background.appearance = NSAppearance(named: .darkAqua)
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(icon)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)

        detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11, weight: .medium)
        detail.textColor = NSColor.white.withAlphaComponent(0.65)
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(detail)

        meter = LevelMeter()
        meter.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(meter)
        closeButton = CloseButton()
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        background.addSubview(closeButton)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 17),
            icon.topAnchor.constraint(equalTo: background.topAnchor, constant: 21),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: meter.leadingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 15),
            detail.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            detail.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
            meter.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            meter.topAnchor.constraint(equalTo: background.topAnchor, constant: 18),
            meter.widthAnchor.constraint(equalToConstant: 44),
            meter.heightAnchor.constraint(equalToConstant: 30),
            closeButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            closeButton.topAnchor.constraint(equalTo: background.topAnchor, constant: 15),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        responseScroll = NSScrollView(frame: .zero)
        responseScroll.hasVerticalScroller = true
        responseScroll.autohidesScrollers = true
        responseScroll.drawsBackground = false
        responseScroll.isHidden = true
        responseScroll.translatesAutoresizingMaskIntoConstraints = false
        responseText = ResponseTextView(frame: .zero)
        responseText.isEditable = false
        responseText.isSelectable = true
        responseText.drawsBackground = true
        responseText.backgroundColor = .clear
        responseText.textColor = NSColor.white.withAlphaComponent(0.92)
        responseText.font = .systemFont(ofSize: 14)
        responseText.textContainerInset = NSSize(width: 4, height: 8)
        responseText.isVerticallyResizable = true
        responseText.isHorizontallyResizable = false
        responseText.autoresizingMask = [.width]
        responseText.textContainer?.widthTracksTextView = true
        responseScroll.documentView = responseText
        background.addSubview(responseScroll)
        microphoneButton = MicrophoneButton(title: "", target: nil, action: nil)
        microphoneButton.setAccessibilityLabel("Microphone")
        microphoneButton.isBordered = false
        microphoneButton.contentTintColor = .white
        microphoneButton.imagePosition = .imageOnly
        microphoneButton.imageScaling = .scaleNone
        microphoneButton.translatesAutoresizingMaskIntoConstraints = false
        microphoneButton.isHidden = true
        background.addSubview(microphoneButton)
        countdown = NSTextField(labelWithString: "")
        countdown.font = .systemFont(ofSize: 11)
        countdown.textColor = .lightGray
        countdown.translatesAutoresizingMaskIntoConstraints = false
        countdown.isHidden = true
        background.addSubview(countdown)
        input = ChatInput()
        input.placeholderAttributedString = NSAttributedString(string: "Type a message…", attributes: [.foregroundColor: NSColor(white: 0.65, alpha: 1)])
        input.font = .systemFont(ofSize: 13)
        input.textColor = .white
        input.isBezeled = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.setAccessibilityLabel("Message")
        input.isEnabled = false
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        input.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(input)
        sendButton = NSButton(title: "Send", target: nil, action: nil)
        sendButton.isBordered = false
        sendButton.font = .systemFont(ofSize: 12, weight: .semibold)
        sendButton.contentTintColor = .white
        sendButton.wantsLayer = true
        sendButton.layer?.cornerRadius = 12
        sendButton.layer?.backgroundColor = NSColor(white: 0.26, alpha: 1).cgColor
        sendButton.isEnabled = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(sendButton)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            input.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -12),
            input.centerYAnchor.constraint(equalTo: microphoneButton.centerYAnchor),
            sendButton.trailingAnchor.constraint(equalTo: microphoneButton.leadingAnchor, constant: -8),
            sendButton.centerYAnchor.constraint(equalTo: microphoneButton.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 54),
            sendButton.heightAnchor.constraint(equalToConstant: 32),
            microphoneButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            microphoneButton.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
            microphoneButton.widthAnchor.constraint(equalToConstant: 40),
            microphoneButton.heightAnchor.constraint(equalTo: microphoneButton.widthAnchor),
            countdown.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            countdown.topAnchor.constraint(equalTo: background.topAnchor, constant: 48)
        ])
        let responseBottom = responseScroll.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -68)
        responseBottom.priority = .defaultHigh
        responseConstraints = [
            responseScroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 17),
            responseScroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -17),
            responseScroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 76),
            responseBottom
        ]
        super.init()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.positionPanel()
        }
        closeButton.onClick = { [weak self] in
            guard let self else { return }
            self.onClose?()
            self.hide()
        }
        microphoneButton.target = self
        microphoneButton.action = #selector(microphonePressed)
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        input.target = self
        input.action = #selector(sendPressed)
        responseText.onInteraction = { [weak self] in self?.pauseDismissal() }
        background.onClick = { [weak self] in self?.openChat() }
        (input as? ChatInput)?.onInteraction = { [weak self] in self?.openChat() }
    }

    func resetConversation(_ history: String = "") {
        response = nil
        responseText.setConversation(history)
    }

    func showRecording() {
        resetConversation()
        update(title: "Recording", subtitle: "Listening to your voice", symbol: "mic.fill", color: .systemRed)
        appendConversation("You: 🎙 Voice message · Recording…")
        meter.isHidden = false
        meter.level = 0
        configureMicrophone(recording: true)
        microphoneButton.setAccessibilityLabel("Stop recording")
        microphoneButton.isHidden = false
        positionPanel()
    }

    /// Values outside 0...1 are clamped; non-finite values are treated as silence.
    func setLevel(_ level: Float) {
        dispatchPrecondition(condition: .onQueue(.main))
        meter.level = level.isFinite ? CGFloat(max(0, min(1, level))) : 0
    }

    func showThinking(text: String) {
        update(title: "Thinking", subtitle: "Waiting for Pi…", symbol: "sparkles", color: .systemPurple)
        appendConversation("You: \(text)\n\nAssistant: Thinking…")
    }

    func showTranscribing() {
        update(title: "Transcribing", subtitle: "Converting speech to text…", symbol: "waveform", color: .systemBlue)
        appendConversation("You: 🎙 Voice message · Transcribing…")
    }

    func showSuccess(text: String, response: String, history: String? = nil) {
        update(title: "Response ready", subtitle: "You: \(text)", symbol: "checkmark.circle.fill", color: .systemGreen)
        self.response = response
        // A missing or stale session file must not replace this turn with old chat.
        let currentHistory = history.flatMap { $0.contains(text) && $0.contains(response) && !response.isEmpty ? $0 : nil }
        responseText.setConversation(currentHistory ?? "You: \(text)\n\nAssistant: \(response.isEmpty ? "No response text." : response)")
        configureMicrophone(recording: false)
        microphoneButton.setAccessibilityLabel("Start recording")
        responseText.scrollToEndOfDocument(nil)
        microphoneButton.isHidden = false
        countdown.isHidden = false
        responseScroll.isHidden = false
        expanded = true
        positionPanel()
        startDismissal()
    }

    func showError(_ message: String) {
        update(title: "Error · Click for details", subtitle: message.replacingOccurrences(of: "\n", with: " "), symbol: "exclamationmark.triangle.fill", color: .systemOrange)
        response = message
        appendConversation("Assistant: Error: \(message)")
        closeButton.isHidden = false
    }

    func showHistory(_ history: String) {
        update(title: "Conversation", subtitle: "Selected session", symbol: "text.bubble", color: .systemBlue)
        responseText.setConversation(history)
        openChat()
    }

    /// Compatibility with callers that provide a plain status message.
    func show(_ message: String) {
        update(title: message, subtitle: "", symbol: "sparkles", color: .systemBlue)
    }

    /// Remove the indicator; safe to call repeatedly.
    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelDismissal()
        response = nil
        panel.orderOut(nil)
    }

    deinit {
        dismissalTimer?.invalidate()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    private func positionPanel() {
        let screen = (panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let visible = screen.visibleFrame
            var frame = overlayFrame(in: visible)
            if expanded {
                frame.size.width = min(480, max(0, visible.width))
                frame.size.height = min(360, max(0, visible.height))
                frame.origin.x = visible.midX - frame.width / 2
                frame.origin.y = max(visible.minY, visible.maxY - frame.height - 24)
            }
            if hasPosition {
                let previous = panel.frame
                frame.origin.x = min(max(previous.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(previous.maxY - frame.height, visible.minY), visible.maxY - frame.height)
            }
            panel.setFrame(frame, display: true)
            hasPosition = true
        }
    }

    private func configureMicrophone(recording: Bool) {
        let symbol = recording ? "stop.fill" : "mic.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(.init(paletteColors: [.white])))
        image?.size = NSSize(width: 16, height: 16)
        microphoneButton.image = image
        (microphoneButton as? MicrophoneButton)?.recording = recording
        microphoneButton.toolTip = recording ? "Stop recording" : "Start recording"
    }

    @objc private func microphonePressed() { pauseDismissal(); onMicrophone?() }

    @objc private func sendPressed() {
        let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let onSendText else { return }
        pauseDismissal()
        if onSendText(text) { input.stringValue = "" }
    }

    func openChat() {
        pauseDismissal()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func appendConversation(_ message: String) {
        let existing = responseText.string
        let base = existing.components(separatedBy: "\n\nYou: 🎙 Voice message ·").first ?? existing
        responseText.setConversation(base.isEmpty ? message : base + "\n\n" + message)
        responseText.scrollToEndOfDocument(nil)
    }

    private func startDismissal() {
        deadline = Date().addingTimeInterval(dismissalInterval)
        refreshCountdown()
        guard deadline != nil else { return }
        dismissalTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.refreshCountdown()
        }
    }

    private func refreshCountdown() {
        guard let deadline else { return }
        let remaining = max(0, deadline.timeIntervalSinceNow)
        countdown.stringValue = "Closing in \(Int(ceil(remaining)))s"
        if remaining <= 0 {
            hide()
            onAutoClose?()
        }
    }

    private func pauseDismissal() {
        guard deadline != nil else { return }
        cancelDismissal()
        countdown.stringValue = "Auto-close paused"
    }

    private func cancelDismissal() {
        dismissalTimer?.invalidate()
        dismissalTimer = nil
        deadline = nil
    }

    private func update(title: String, subtitle: String, symbol: String, color: NSColor) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancelDismissal()
        response = nil
        expanded = true
        NSLayoutConstraint.deactivate(responseConstraints)
        NSLayoutConstraint.activate(responseConstraints)
        responseScroll.isHidden = false
        microphoneButton.isHidden = false
        configureMicrophone(recording: false)
        microphoneButton.setAccessibilityLabel("Start recording")
        countdown.isHidden = true
        meter.isHidden = true
        closeButton.isHidden = false
        label.stringValue = title
        detail.stringValue = subtitle
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 19, weight: .regular))
        icon.contentTintColor = color
        positionPanel()
        panel.orderFrontRegardless()
    }
}

/// Draw independently of the NSButton cell and backing layer, which can have
/// different visual bounds during panel resizing. The hit target stays a button.
private final class MicrophoneButton: NSButton {
    // NSButton's default alignment rect excludes cell padding, so square
    // constraints otherwise produce a taller, visibly oval view frame.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    var recording = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(bounds.width, bounds.height) - 2
        guard diameter > 0 else { return }
        let circle = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                            width: diameter, height: diameter)
        let path = NSBezierPath(ovalIn: circle)
        let top = recording ? NSColor(calibratedRed: 1, green: 0.39, blue: 0.34, alpha: 1) : NSColor(calibratedRed: 0.18, green: 0.76, blue: 1, alpha: 1)
        let bottom = recording ? NSColor(calibratedRed: 0.78, green: 0.08, blue: 0.19, alpha: 1) : NSColor(calibratedRed: 0.02, green: 0.30, blue: 0.91, alpha: 1)
        NSGradient(starting: bottom, ending: top)?.draw(in: path, angle: 90)
        NSColor.white.withAlphaComponent(0.48).setStroke()
        path.lineWidth = 1
        path.stroke()
        NSGraphicsContext.saveGraphicsState()
        if isFlipped {
            let flip = NSAffineTransform()
            flip.translateX(by: 0, yBy: bounds.midY * 2)
            flip.scaleX(by: 1, yBy: -1)
            flip.concat()
        }
        NSColor.white.withAlphaComponent(isHighlighted ? 0.65 : 1).set()
        if recording {
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10), xRadius: 2, yRadius: 2).fill()
        } else {
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 3, y: bounds.midY - 2, width: 6, height: 13), xRadius: 3, yRadius: 3).fill()
            let stand = NSBezierPath()
            stand.lineWidth = 1.8
            stand.lineCapStyle = .round
            stand.move(to: NSPoint(x: bounds.midX - 6, y: bounds.midY + 1))
            stand.curve(to: NSPoint(x: bounds.midX + 6, y: bounds.midY + 1), controlPoint1: NSPoint(x: bounds.midX - 6, y: bounds.midY - 7), controlPoint2: NSPoint(x: bounds.midX + 6, y: bounds.midY - 7))
            stand.move(to: NSPoint(x: bounds.midX, y: bounds.midY - 5))
            stand.line(to: NSPoint(x: bounds.midX, y: bounds.midY - 9))
            stand.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class ChatInput: NSTextField {
    var onInteraction: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        super.mouseDown(with: event)
    }
}

private final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        // An opaque dark base guarantees contrast even against a bright desktop.
        layer?.backgroundColor = NSColor(white: 0.105, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The composer is drawn behind the controls so its entire surface remains draggable.
        let composer = NSRect(x: 17, y: 10, width: max(0, bounds.width - 34), height: 40)
        NSColor(white: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: composer, xRadius: 14, yRadius: 14).fill()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = NSEvent.mouseLocation
        var dragged = false
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { if !dragged { onClick?() }; break }
            if hypot(NSEvent.mouseLocation.x - start.x, NSEvent.mouseLocation.y - start.y) > 3 {
                dragged = true
                window.performDrag(with: event)
                break
            }
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        // Decorative children must not intercept clicks, but the close control must.
        let local = convert(point, from: superview)
        if let button = subviews.compactMap({ $0 as? CloseButton }).first(where: { !$0.isHidden && $0.frame.contains(local) }) { return button }
        if let button = subviews.compactMap({ $0 as? NSButton }).first(where: { !$0.isHidden && $0.frame.contains(local) }) { return button.hitTest(local) }
        if let field = subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && !$0.isHidden && $0.frame.contains(local) }) {
            window?.makeKeyAndOrderFront(nil)
            return field.hitTest(local)
        }
        if let scroll = subviews.compactMap({ $0 as? NSScrollView }).first(where: { !$0.isHidden && $0.frame.contains(local) }) {
            return scroll.hitTest(local)
        }
        return self
    }
}

private final class ResponseTextView: NSTextView {
    var onInteraction: (() -> Void)?
    private var bubbles: [(NSRange, Bool)] = []

    func setConversation(_ text: String) {
        let source = text as NSString
        let pattern = try! NSRegularExpression(pattern: "(?m)^(You|Assistant):(?=\\s|$)")
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        bubbles = matches.enumerated().map { index, match in
            let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
            return (NSRange(location: match.range.location, length: end - match.range.location),
                    source.substring(with: match.range(at: 1)) == "You")
        }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white.withAlphaComponent(0.94)
        ])
        for (range, isUser) in bubbles {
            let style = NSMutableParagraphStyle()
            style.headIndent = isUser ? 74 : 14
            style.firstLineHeadIndent = style.headIndent
            style.tailIndent = isUser ? -14 : -74
            style.paragraphSpacing = 8
            attributed.addAttribute(.paragraphStyle, value: style, range: range)
        }
        textStorage?.setAttributedString(attributed)
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if string.isEmpty {
            let text = "Your conversation will appear here."
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(white: 0.68, alpha: 1)]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: max(0, (bounds.width - size.width) / 2), y: max(0, (bounds.height - size.height) / 2)), withAttributes: attributes)
        }
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        for (range, isUser) in bubbles where range.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var bubble = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            bubble.origin.x = isUser ? 68 : 8
            bubble.size.width = max(0, textContainer.size.width - 76)
            bubble.origin.y += textContainerOrigin.y
            bubble.origin.x += textContainerOrigin.x
            bubble = bubble.insetBy(dx: -5, dy: -3)
            (isUser ? NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.58, alpha: 1) : NSColor(white: 0.20, alpha: 1)).setFill()
            NSBezierPath(roundedRect: bubble, xRadius: 12, yRadius: 12).fill()
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        super.mouseDown(with: event)
    }
}

private final class CloseButton: NSView {
    var onClick: (() -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Close")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        // Consume the entire click so it cannot open the error details.
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { onClick?() }
                break
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 5, dy: 5))
        NSColor.white.withAlphaComponent(0.10).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY - 4))
        path.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY + 4))
        path.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY + 4))
        path.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY - 4))
        path.stroke()
    }
}

private final class LevelMeter: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let heights: [CGFloat] = [0.45, 0.75, 1, 0.75, 0.45]
        NSColor.systemRed.setFill()
        for (index, scale) in heights.enumerated() {
            let height = 3 + level * 24 * scale
            let rect = NSRect(x: CGFloat(index) * 9, y: (bounds.height - height) / 2, width: 5, height: height)
            NSBezierPath(roundedRect: rect, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }
}
