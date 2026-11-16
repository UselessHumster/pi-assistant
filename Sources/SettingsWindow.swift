import AppKit
import ApplicationServices
import Carbon

// Capture locally so key equivalents such as Return and Escape do not activate the
// settings buttons while recording. The owner is responsible for suspending the
// global hotkey while the settings window is open.
final class ShortcutSettingsView: NSStackView {
    let mode = NSPopUpButton()
    private let recordButton = NSButton(title: "", target: nil, action: nil)
    private let hint = NSTextField(labelWithString: "Click to record a shortcut.")
    private(set) var keyCode: Int
    private(set) var modifiers: CGEventFlags
    private var monitor: Any?
    var isRecording: Bool { monitor != nil }
    var willStartRecording: (() -> Void)?

    // Known macOS virtual key codes; excludes modifier-only and unassigned codes.
    private static let validCodes: Set<Int> = Set(0...50).union([51, 53, 64, 65, 67, 69, 71, 72, 73, 74, 75, 76, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 109, 110, 111, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123, 124, 125, 126])
    static func validKeyCode(_ code: Int) -> Bool { validCodes.contains(code) }

    init(configuration: HotkeyConfiguration, title: String = "Shortcut", showsMode: Bool = true) {
        keyCode = Int(configuration.keyCode); modifiers = configuration.modifiers
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        addArrangedSubview(NSTextField(labelWithString: title))
        recordButton.target = self; recordButton.action = #selector(startRecording)
        addArrangedSubview(recordButton); addArrangedSubview(hint)
        mode.addItems(withTitles: ["Push to talk (hold)", "Toggle recording"])
        mode.selectItem(at: configuration.mode == .hold ? 0 : 1)
        if showsMode { addArrangedSubview(mode) }
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { stopRecording() }

    @objc private func startRecording() {
        guard monitor == nil else { stopRecording(); return }
        willStartRecording?()
        hint.stringValue = "Press a key combination. Escape cancels."
        recordButton.title = "Recording… (click to cancel)"
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, event.window === self.window else { return event }
            if event.type == .flagsChanged { return nil }
            if event.keyCode == 53 { self.stopRecording(); return nil }
            let code = Int(event.keyCode)
            guard Self.validKeyCode(code), !event.isARepeat else {
                self.hint.stringValue = "Press a non-modifier key (Escape cancels)."
                return nil
            }
            var flags: CGEventFlags = []
            if event.modifierFlags.contains(.control) { flags.insert(.maskControl) }
            if event.modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
            if event.modifierFlags.contains(.shift) { flags.insert(.maskShift) }
            if event.modifierFlags.contains(.command) { flags.insert(.maskCommand) }
            self.keyCode = code; self.modifiers = flags
            self.stopRecording()
            return nil
        }
    }
    func stopRecording() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        hint.stringValue = "Click to record a shortcut. Escape cancels recording."
        updateTitle()
    }
    private func updateTitle() {
        var parts: [String] = []
        if modifiers.contains(.maskControl) { parts.append("⌃") }
        if modifiers.contains(.maskAlternate) { parts.append("⌥") }
        if modifiers.contains(.maskShift) { parts.append("⇧") }
        if modifiers.contains(.maskCommand) { parts.append("⌘") }
        parts.append(Self.keyName(keyCode))
        recordButton.title = parts.joined(separator: " ")
    }
    private static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /", 76: "Keypad Enter", 78: "Keypad −", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let name = special[code] { return name }
        // Translate using the active keyboard layout, independently of modifiers.
        if (0...127).contains(code), let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var dead: UInt32 = 0; var length = 0; var chars = [UniChar](repeating: 0, count: 8)
                if UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars) == noErr, length > 0 {
                    let name = String(utf16CodeUnits: chars, count: length)
                    if name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { return name.uppercased() }
                }
            }
        }
        return "Key code \(code)"
    }
}

// Optional shortcuts are represented by both keys being present; removing either
// disables the shortcut. DialogShortcut.load defines the runtime format.
final class OptionalShortcutSettingsView: NSStackView {
    let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let recorder: ShortcutSettingsView
    let prefix: String

    init(title: String, prefix: String, defaults: UserDefaults) {
        self.prefix = prefix
        let saved = DialogShortcut.load(prefix: prefix, from: defaults)
        recorder = ShortcutSettingsView(configuration: HotkeyConfiguration(keyCode: saved?.keyCode ?? 49, modifiers: saved?.modifiers ?? [.maskControl, .maskAlternate], mode: .hold), title: title, showsMode: false)
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 4
        enabled.title = "Enable \(title.lowercased())"; enabled.state = saved == nil ? .off : .on
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        addArrangedSubview(enabled); addArrangedSubview(recorder)
        recorder.isHidden = saved == nil
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func toggleEnabled() {
        recorder.isHidden = enabled.state != .on
        if recorder.isHidden { recorder.stopRecording() }
    }
    var value: DialogShortcut? {
        guard enabled.state == .on else { return nil }
        return DialogShortcut(keyCode: Int64(recorder.keyCode), modifiers: recorder.modifiers)
    }
    func persist(to defaults: UserDefaults) {
        if let value = value {
            defaults.set(Int(value.keyCode), forKey: prefix + "Code")
            defaults.set(Int(value.modifiers.rawValue), forKey: prefix + "Modifiers")
        } else {
            defaults.removeObject(forKey: prefix + "Code")
            defaults.removeObject(forKey: prefix + "Modifiers")
        }
    }
}

func shortcutValidationError(normal: DialogShortcut, optional: [DialogShortcut?]) -> String? {
    var used = [normal]
    for case let shortcut? in optional {
        guard ShortcutSettingsView.validKeyCode(Int(shortcut.keyCode)), !shortcut.modifiers.isEmpty,
              shortcut.modifiers == shortcut.modifiers.intersection(DialogShortcut.relevant) else {
            return "Optional shortcuts need a valid key and at least one modifier."
        }
        if used.contains(where: { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers }) {
            return "Shortcuts must be different."
        }
        used.append(shortcut)
    }
    return nil
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let defaults: UserDefaults
    private let shortcut: ShortcutSettingsView
    private let newDialogShortcut: OptionalShortcutSettingsView
    private let previousDialogShortcut: OptionalShortcutSettingsView
    private let engine = NSPopUpButton()
    private var fields: [String: NSTextField] = [:]
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let onSave: (Int, CGEventFlags, String) -> Void

    init(defaults: UserDefaults, configuration: HotkeyConfiguration, onSave: @escaping (Int, CGEventFlags, String) -> Void) {
        self.defaults = defaults; self.onSave = onSave
        shortcut = ShortcutSettingsView(configuration: configuration)
        newDialogShortcut = OptionalShortcutSettingsView(title: "New dialog shortcut", prefix: "newDialogShortcut", defaults: defaults)
        previousDialogShortcut = OptionalShortcutSettingsView(title: "Previous/latest dialog shortcut", prefix: "previousDialogShortcut", defaults: defaults)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Settings"; window.minSize = NSSize(width: 480, height: 400); window.delegate = self
        let content = NSView(); window.contentView = content
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8; stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = stack
        let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Changes apply to the next recording. Use absolute paths."))
        stack.addArrangedSubview(NSTextField(labelWithString: "Recognition engine"))
        engine.addItems(withTitles: ["whisper", "gigaam"]); engine.selectItem(withTitle: defaults.string(forKey: "recognitionEngine")?.lowercased() ?? "whisper")
        stack.addArrangedSubview(engine)
        for (label, key, fallback) in [("whisper-cli", "whisper", ""), ("Whisper model", "model", ""), ("GigaAM Python executable", "gigaamPython", ""), ("GigaAM model name", "gigaamModel", "v3_e2e_rnnt"), ("GigaAM model cache directory (optional)", "gigaamCache", ""), ("pi", "pi", "/opt/homebrew/bin/pi"), ("Pi working directory", "workingDirectory", defaultDirectory)] {
            stack.addArrangedSubview(NSTextField(labelWithString: label))
            let field = NSTextField(string: defaults.string(forKey: key) ?? fallback)
            fields[key] = field; stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.addArrangedSubview(shortcut)
        stack.addArrangedSubview(newDialogShortcut); stack.addArrangedSubview(previousDialogShortcut)
        let recorders = [shortcut, newDialogShortcut.recorder, previousDialogShortcut.recorder]
        for recorder in recorders {
            recorder.willStartRecording = { [weak self, weak recorder] in
                guard let self = self else { return }
                for other in [self.shortcut, self.newDialogShortcut.recorder, self.previousDialogShortcut.recorder] where other !== recorder { other.stopRecording() }
            }
        }
        errorLabel.textColor = .systemRed; errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel); errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed)); cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(savePressed)); save.keyEquivalent = "\r"
        buttons.addArrangedSubview(cancel); buttons.addArrangedSubview(save); buttons.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        window.center()
    }
    func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); NSApp.runModal(for: window); window.orderOut(nil) }
    private func stopRecording() { shortcut.stopRecording(); newDialogShortcut.recorder.stopRecording(); previousDialogShortcut.recorder.stopRecording() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { stopRecording(); NSApp.stopModal(); return true }
    @objc private func cancelPressed() { stopRecording(); NSApp.stopModal() }
    @objc private func savePressed() {
        let values = fields.mapValues { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        func fail(_ message: String, _ field: NSView) { errorLabel.stringValue = message; errorLabel.isHidden = false; window.makeFirstResponder(field); field.scrollToVisible(field.bounds) }
        guard ![shortcut, newDialogShortcut.recorder, previousDialogShortcut.recorder].contains(where: { $0.isRecording }) else { fail("Finish or cancel shortcut recording before saving.", shortcut); return }
        let code = shortcut.keyCode
        guard ShortcutSettingsView.validKeyCode(code) else { fail("Record a valid non-modifier shortcut key.", shortcut); return }
        if let error = shortcutValidationError(normal: DialogShortcut(keyCode: Int64(code), modifiers: shortcut.modifiers), optional: [newDialogShortcut.value, previousDialogShortcut.value]) {
            fail(error, newDialogShortcut); return
        }
        let selected = engine.titleOfSelectedItem ?? "whisper"
        let keys = selected == "whisper" ? ["whisper", "model", "pi", "workingDirectory"] : ["gigaamPython", "pi", "workingDirectory"]
        for key in keys {
            let path = values[key] ?? ""
            guard path.hasPrefix("/") else { fail("Enter an absolute path for \(key).", fields[key]!); return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue == (key == "workingDirectory") else { fail("Select an existing \(key == "workingDirectory" ? "directory" : "file") for \(key).", fields[key]!); return }
            if ["whisper", "gigaamPython", "pi"].contains(key) && !FileManager.default.isExecutableFile(atPath: path) { fail("The \(key) file must be executable.", fields[key]!); return }
        }
        if selected == "gigaam" && (values["gigaamModel"] ?? "").isEmpty { fail("Enter a GigaAM model name.", fields["gigaamModel"]!); return }
        let cache = values["gigaamCache"] ?? ""
        if selected == "gigaam" && !cache.isEmpty && !cache.hasPrefix("/") { fail("GigaAM cache must be an absolute path.", fields["gigaamCache"]!); return }
        for (key, value) in values { defaults.set(value, forKey: key) }
        defaults.set(selected, forKey: "recognitionEngine")
        newDialogShortcut.persist(to: defaults); previousDialogShortcut.persist(to: defaults)
        onSave(code, shortcut.modifiers, shortcut.mode.indexOfSelectedItem == 0 ? "hold" : "toggle")
        NSApp.stopModal()
    }
}
