import Foundation

@main
struct ConversationLifecycleTests {
    nonisolated static func expectFailure(_ fragment: String, _ body: () throws -> String) {
        do { _ = try body(); fatalError("Unexpected success") }
        catch { precondition(error.localizedDescription.contains(fragment), error.localizedDescription) }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("work").path
        let output = root.appendingPathComponent("output")
        let storage = root.appendingPathComponent("sessions")
        let suite = "voice-session-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func catalog() -> ConversationCatalog { conversationCatalog(for: directory, defaults: defaults) }
        let initial = catalog().selected
        precondition(UUID(uuidString: initial.id) != nil && initial.isDraft == true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: URL(fileURLWithPath: directory))
        precondition(conversationCatalog(for: alias.path, defaults: defaults).selectedID == initial.id)
        precondition(conversationCatalog(for: root.path, defaults: defaults).selectedID != initial.id)
        let legacyID = UUID().uuidString.lowercased()
        let legacy = root.appendingPathComponent("legacy").path
        defaults.set([legacy: legacyID], forKey: "conversationSessions")
        precondition(conversationCatalog(for: legacy, defaults: defaults).selectedID == legacyID)

        let extensions = [root.appendingPathComponent("auto-session-title.ts"), root.appendingPathComponent("6.2-failover.ts")]
        let turn = PiTurn(executable: root.appendingPathComponent("fake-pi").path, directory: directory,
                          model: PiModel.defaultID, extensions: extensions, storage: storage)
        let first = voiceConversation(startNew: true, directory: directory, defaults: defaults)
        let second = voiceConversation(startNew: true, directory: directory, defaults: defaults)
        precondition(Set([initial.id, first.id, second.id]).count == 3)
        let args = turn.arguments(text: "-leading hyphen", sessionID: first.id)
        precondition(args.suffix(2).elementsEqual(["--", "-leading hyphen"]))
        for flag in ["--print", "--session-id", "--session-dir", "--no-extensions", "--no-mcp", "--no-prompt-templates", "--no-context-files", "--append-system-prompt"] {
            precondition(args.filter { $0 == flag }.count == 1)
        }
        precondition(!args.contains("--no-skills") && !args.contains("--no-tools"))
        precondition(args[args.firstIndex(of: "--model")! + 1] == PiModel.defaultID)
        precondition(args.indices.filter { args[$0] == "-e" }.map { args[$0 + 1] } == extensions.map(\.path))
        let piDefault = PiTurn(executable: turn.executable, directory: directory, model: "", extensions: [], storage: storage)
        precondition(!piDefault.arguments(text: "hi", sessionID: first.id).contains("--model"))

        func send(_ text: String, _ session: ConversationSession, using config: PiTurn? = nil, token: ProcessCancellation = ProcessCancellation()) throws -> String {
            try (config ?? turn).runMessage(text, session: session, outputDirectory: output, cancellation: token)
        }
        precondition(try! send("-create task", first) == first.id)
        let transcript = try loadSessionTranscript(sessionID: first.id, directory: directory, storage: storage)!
        precondition(transcript.title == "Weather Forecast Test")
        updateConversation(first.id, from: transcript, directory: directory, defaults: defaults)
        precondition(catalog().matching("forecast WEATHER").map(\.id) == [first.id])
        precondition(catalog().selectedID == second.id)
        selectConversationSession("missing", for: directory, defaults: defaults)
        precondition(catalog().selectedID == second.id)
        selectConversationSession(first.id, for: directory, defaults: defaults)
        let reopened = UserDefaults(suiteName: suite)!
        let followup = voiceConversation(startNew: false, directory: directory, defaults: reopened)
        precondition(followup.id == first.id && followup.isDraft == false)
        precondition(try! send("follow-up", followup) == first.id)
        precondition(try! send("typed", followup, using: piDefault) == first.id)
        precondition(try! send("next", second) == second.id)
        setConversationArchived(true, id: first.id, directory: directory, defaults: defaults)
        let persisted = conversationCatalog(for: directory, defaults: UserDefaults(suiteName: suite)!)
        precondition(persisted.selectedID == second.id)
        precondition(!persisted.matching("").contains { $0.id == first.id })
        precondition(persisted.matching("", showArchive: true).map(\.id) == [first.id])
        precondition(persisted.matching("forecast").map(\.id) == [first.id])
        precondition(try! send("archived session still has history", followup) == first.id)
        setConversationArchived(false, id: first.id, directory: directory, defaults: defaults)
        precondition(catalog().matching("", showArchive: true).isEmpty)
        try FileManager.default.removeItem(at: storage.appendingPathComponent("test_\(first.id).jsonl"))
        expectFailure("history is missing") { try send("must not reach Pi", followup) }
        precondition(!FileManager.default.fileExists(atPath: storage.appendingPathComponent("test_\(first.id).jsonl").path))
        expectFailure("empty") { try send("  ", second) }
        let invalidModel = PiTurn(executable: turn.executable, directory: directory, model: "router/unknown", extensions: [], storage: storage)
        expectFailure("not available") { try send("must not reach Pi", second, using: invalidModel) }
        let cancelled = ProcessCancellation()
        cancelled.cancel()
        expectFailure("cancelled") { try send("cancel", second, token: cancelled) }
        let noResponse = PiTurn(executable: "/usr/bin/true", directory: directory, model: "", extensions: [], storage: storage)
        expectFailure("no response") { try send("hello", second, using: noResponse) }

        let recognizer = try makeRecognizer(engine: "gigaam", whisper: "", model: "", python: root.appendingPathComponent("fake-recognizer").path,
                                            gigaamModel: "test-model", cache: root.path, script: "/test/script")
        precondition(try! recognizer.transcribe(output.appendingPathComponent("audio.wav")) == "hello")
        try FileManager.default.removeItem(at: output.appendingPathComponent("transcript.txt"))
        expectFailure("Unknown recognition engine") {
            _ = try makeRecognizer(engine: "unknown", whisper: "", model: "", python: "", gigaamModel: "", cache: "", script: "")
            return ""
        }
        let token = ProcessCancellation()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            expectFailure("cancelled") {
                try run(root.appendingPathComponent("fake-blocking").path, [], directory: root, outputDirectory: output, cancellation: token)
            }
        }
        let marker = root.appendingPathComponent("child-started")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        precondition(FileManager.default.fileExists(atPath: marker.path))
        token.cancel()
        precondition(done.wait(timeout: .now() + 5) == .success)
        Thread.sleep(forTimeInterval: 0.5)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("child-survived").path))
        precondition(try! FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        print("Conversation routing, arguments and process tests passed.")
    }
}
