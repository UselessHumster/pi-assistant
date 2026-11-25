import AppKit
import AVFoundation
import ApplicationServices

final class App: NSObject, NSApplicationDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var tap: CFMachPort?
    private var permissionTimer: Timer?
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var hotkey = PushToTalkHotkey()
    private var recordingStartsNew = true
    private var settingsOpen = false
    private var operation: ProcessCancellation?
    private var busy: Bool { operation != nil }
    private var idlePhase = "Ready"
    private var activity: String?
    private var errorMessage: String?
    private var latestReply: (id: String, messages: [ChatMessage])?
    private var pendingMessage: (id: String, text: String)?
    private var previewDirectory: String?
    private var loadedPreviewIDs: Set<String> = []
    private var previews: [String: String] = [:]
    private let previewQueue = DispatchQueue(label: "chat-previews", qos: .utility)
    private var previewRequest = UUID()
    private let overlay = FloatingOverlayController()
    private var chat: ChatWindowController?
    private var meterTimer: Timer?
    private let defaults = UserDefaults.standard
    private let sessionMenu = SessionMenuController()
    private var workingDirectory: String { defaults.string(forKey: "workingDirectory") ?? FileManager.default.homeDirectoryForCurrentUser.path }

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkey.configuration = HotkeyConfiguration.load(from: defaults)
        overlay.onOpenChat = { [weak self] in self?.showChat() }
        overlay.onClose = { [weak self] in self?.cancelOperation() }
        sessionMenu.onSelect = { [weak self] id in
            self?.selectChat(id)
            self?.showChat()
        }
        sessionMenu.onCreate = { [weak self] in self?.createChat() }
        rebuildMenu()
        installTap(prompt: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        operation?.cancel()
        discardRecording()
        permissionTimer?.invalidate()
        if let tap { CFMachPortInvalidate(tap) }
    }

    private var canSwitchChat: Bool { !busy && recorder == nil && !settingsOpen }

    private func rebuildMenu() {
        item.button?.title = recorder != nil ? "🔴" : (busy ? "🎙…" : "🎙")
        let menu = NSMenu()
        let status = NSMenuItem(title: activity ?? (errorMessage == nil ? idlePhase : "Error — Open Chat"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let catalog = conversationCatalog(for: workingDirectory, defaults: defaults)
        menu.addItem(sessionMenu.item(catalog: catalog, enabled: canSwitchChat))
        menu.addItem(NSMenuItem(title: "Open Chat", action: #selector(showChat), keyEquivalent: ""))
        let settings = NSMenuItem(title: "Configure…", action: #selector(configure), keyEquivalent: ",")
        settings.isEnabled = canSwitchChat
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Retry Hotkey Permission", action: #selector(retryTap), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        if let chat, chat.isVisible { refreshChat(chat, catalog: catalog) }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func retryTap() { installTap(prompt: true) }

    private func installTap(prompt: Bool) {
        if hotkey.reset() != nil { keyUp() }
        if let tap { CFMachPortInvalidate(tap); self.tap = nil }
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            if permissionTimer == nil {
                let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self, AXIsProcessTrusted() else { return }
                    self.installTap(prompt: false)
                }
                permissionTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            idlePhase = "Enable Accessibility for the shortcut"
            rebuildMenu()
            return
        }
        permissionTimer?.invalidate(); permissionTimer = nil
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<App>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if app.hotkey.reset() != nil { app.keyUp() }
                if let tap = app.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else if !app.settingsOpen {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                switch app.hotkey.handle(type: type, keyCode: code, flags: event.flags, isRepeat: repeated) {
                case .start: app.keyDown(startNew: true)
                case .stop: app.keyUp()
                case nil: break
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            idlePhase = "Shortcut unavailable — check Input Monitoring and Accessibility"
            rebuildMenu()
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        idlePhase = "Ready — shortcut starts a new chat"
        rebuildMenu()
    }

    private func keyDown(startNew: Bool) {
        guard canSwitchChat else { _ = hotkey.reset(); return }
        errorMessage = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            recordingStartsNew = startNew
            startRecording()
        case .notDetermined:
            _ = hotkey.reset()
            finish(error: "Allow microphone access, then try again.", inOverlay: startNew)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        default:
            _ = hotkey.reset()
            finish(error: "Enable Pi Voice Assistant under System Settings → Privacy & Security → Microphone.", inOverlay: startNew)
        }
    }

    private func startRecording() {
        do {
            let dir = try temporaryDirectory()
            let url = dir.appendingPathComponent("audio.wav")
            do {
                let r = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
                r.isMeteringEnabled = true
                guard r.record() else { throw Failure.message("Could not start recording.") }
                recorder = r; recordingURL = url; activity = "Recording…"
                if recordingStartsNew {
                    overlay.showRecording()
                    let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak r] _ in
                        guard let r else { return }
                        r.updateMeters()
                        self?.overlay.setLevel((r.averagePower(forChannel: 0) + 60) / 60)
                    }
                    meterTimer = timer; RunLoop.main.add(timer, forMode: .common)
                }
                rebuildMenu()
            } catch { try? FileManager.default.removeItem(at: dir); throw error }
        } catch {
            _ = hotkey.reset()
            finish(error: error.localizedDescription, inOverlay: recordingStartsNew)
        }
    }

    private func stopRecording() -> URL? {
        meterTimer?.invalidate(); meterTimer = nil
        recorder?.stop(); recorder = nil
        defer { recordingURL = nil }
        return recordingURL
    }

    private func discardRecording() {
        if let url = stopRecording() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    private func cancelOperation() {
        operation?.cancel(); operation = nil
        discardRecording()
        _ = hotkey.reset()
        overlay.hide()
        activity = nil; pendingMessage = nil
        rebuildMenu()
    }

    private func keyUp() {
        guard let url = stopRecording() else { return }
        let startNew = recordingStartsNew
        let token = ProcessCancellation(); operation = token
        activity = "Transcribing…"
        if startNew { overlay.showTranscribing() }
        rebuildMenu()
        let dir = url.deletingLastPathComponent()
        let recognizer: RecognitionEngine
        do {
            recognizer = try makeRecognizer(engine: defaults.string(forKey: "recognitionEngine") ?? "whisper",
                whisper: defaults.string(forKey: "whisper") ?? "", model: defaults.string(forKey: "model") ?? "",
                python: defaults.string(forKey: "gigaamPython") ?? "", gigaamModel: defaults.string(forKey: "gigaamModel") ?? "v3_e2e_rnnt",
                cache: defaults.string(forKey: "gigaamCache") ?? "", script: Bundle.main.path(forResource: "gigaam_recognize", ofType: "py") ?? "")
        } catch {
            try? FileManager.default.removeItem(at: dir)
            finish(error: error.localizedDescription, inOverlay: startNew)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> String in
                let text = try recognizer.transcribe(url, cancellation: token)
                guard !text.isEmpty else { throw Failure.message("No speech was transcribed.") }
                return text
            }
            try? FileManager.default.removeItem(at: dir)
            DispatchQueue.main.async {
                guard self.operation === token else { return }
                switch result {
                case .success(let text):
                    let session = voiceConversation(startNew: startNew, directory: self.workingDirectory, defaults: self.defaults)
                    self.submit(text, to: session, token: token, inOverlay: startNew)
                case .failure(let error): self.finish(error: error.localizedDescription, inOverlay: startNew)
                }
            }
        }
    }

    private func submit(_ text: String, to session: ConversationSession, token: ProcessCancellation, inOverlay: Bool) {
        let directory = workingDirectory
        let failover = piAgentDirectory().appendingPathComponent("extensions/6.2-failover.ts")
        var extensions = [URL]()
        if let naming = Bundle.main.url(forResource: "auto-session-title", withExtension: "ts") { extensions.append(naming) }
        if FileManager.default.isReadableFile(atPath: failover.path) { extensions.append(failover) }
        let turn = PiTurn(executable: defaults.string(forKey: "pi") ?? "/opt/homebrew/bin/pi", directory: directory,
                          model: PiModel.load(from: defaults), extensions: extensions)
        operation = token; errorMessage = nil; activity = "Asking Pi…"
        pendingMessage = (session.id, text)
        if inOverlay { overlay.showThinking(text: text) }
        rebuildMenu()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> String in
                let temp = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: temp) }
                return try turn.runMessage(text, session: session, outputDirectory: temp, cancellation: token)
            }
            let history = try? loadSessionTranscript(sessionID: session.id, directory: directory, storage: turn.storage)
            DispatchQueue.main.async {
                guard self.operation === token else { return }
                if let history {
                    updateConversation(session.id, from: history, directory: directory, defaults: self.defaults)
                    if self.previewDirectory == directory, let preview = history.previewTitle { self.previews[session.id] = preview }
                }
                switch result {
                case .success(let response):
                    self.latestReply = (session.id, [.init(role: .user, text: text), .init(role: .assistant, text: response)])
                    if inOverlay && self.chat?.isVisible != true { self.overlay.showSuccess(response: response) }
                    else { self.overlay.hide() }
                    self.finish(error: nil, inOverlay: false)
                case .failure(let error): self.finish(error: error.localizedDescription, inOverlay: inOverlay)
                }
            }
        }
    }

    private func finish(error: String?, inOverlay: Bool) {
        operation = nil; activity = nil; pendingMessage = nil; errorMessage = error
        if inOverlay, let error { overlay.showError(error) }
        rebuildMenu()
    }

    private func selectChat(_ id: String) {
        guard canSwitchChat else { return }
        selectConversationSession(id, for: workingDirectory, defaults: defaults)
        errorMessage = nil
        overlay.hide()
        rebuildMenu()
    }

    private func createChat() {
        guard canSwitchChat else { return }
        _ = createConversationSession(for: workingDirectory, defaults: defaults)
        errorMessage = nil
        rebuildMenu()
        showChat()
    }

    @objc private func showChat() {
        if chat == nil {
            let window = ChatWindowController()
            window.onSelect = { [weak self] in self?.selectChat($0) }
            window.onCreate = { [weak self] in self?.createChat() }
            window.onSend = { [weak self] input in
                let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, self.canSwitchChat, !text.isEmpty else { return false }
                let session = conversationCatalog(for: self.workingDirectory, defaults: self.defaults).selected
                self.submit(text, to: session, token: ProcessCancellation(), inOverlay: false)
                return true
            }
            window.onVoice = { [weak self] in
                guard let self else { return }
                if self.recorder != nil { _ = self.hotkey.reset(); self.keyUp() }
                else if self.busy { self.cancelOperation() }
                else { self.keyDown(startNew: false) }
            }
            chat = window
        }
        let directory = workingDirectory
        if !busy && recorder == nil { overlay.hide() }
        if let chat {
            refreshChat(chat, catalog: conversationCatalog(for: directory, defaults: defaults))
            chat.show()
        }
    }

    private func refreshChat(_ chat: ChatWindowController, catalog: ConversationCatalog) {
        let id = catalog.selectedID
        let directory = workingDirectory
        let storage = piSessionDirectory(for: directory)
        if previewDirectory != directory {
            previewDirectory = directory; loadedPreviewIDs = []; previews = [:]; previewRequest = UUID()
        }
        var messages: [ChatMessage] = []
        var notice: String?
        do {
            if let transcript = try loadSessionTranscript(sessionID: id, directory: directory, storage: storage) {
                messages = transcript.messages
                if let preview = transcript.previewTitle { previews[id] = preview }
            } else if let latestReply, latestReply.id == id { messages = latestReply.messages }
            else if catalog.selected.isDraft != true { notice = "Conversation history is missing." }
        } catch { notice = "Could not read conversation history. The file may be invalid, inaccessible, or too large." }
        if let pendingMessage, pendingMessage.id == id,
           messages.last != ChatMessage(role: .user, text: pendingMessage.text) {
            messages.append(ChatMessage(role: .user, text: pendingMessage.text))
        }
        chat.setPreviews(previews)
        chat.render(catalog: catalog, messages: messages, phase: activity ?? (tap == nil ? idlePhase : ""),
                    notice: errorMessage ?? notice, busy: busy, recording: recorder != nil)
        let missing = Set(catalog.sessions.filter(\.needsDisplayTitle).map(\.id)).subtracting(loadedPreviewIDs)
        guard !missing.isEmpty else { return }
        loadedPreviewIDs.formUnion(missing)
        let request = previewRequest
        previewQueue.async { [weak self] in
            let result = conversationPreviews(ids: missing, directory: directory, storage: storage)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewRequest == request else { return }
                self.previews.merge(result) { current, _ in current }
                self.chat?.setPreviews(self.previews)
            }
        }
    }

    @objc private func configure() {
        guard canSwitchChat else { return }
        settingsOpen = true
        let oldDirectory = workingDirectory
        defer {
            settingsOpen = false
            if workingDirectory != oldDirectory { errorMessage = nil; overlay.hide() }
            rebuildMenu()
        }
        let settings = SettingsWindowController(defaults: defaults, configuration: hotkey.configuration) { [self] code, flags, mode in
            defaults.set(code, forKey: "hotkeyCode")
            defaults.set(Int(flags.rawValue), forKey: "hotkeyModifiers")
            defaults.set(mode, forKey: "hotkeyMode")
            _ = hotkey.reset()
            hotkey.configuration = HotkeyConfiguration.load(from: defaults)
        }
        settings.show()
    }
}

private func temporaryDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pi-voice-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return dir
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
