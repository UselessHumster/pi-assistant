import Foundation

@main struct TranscriptTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["PI_CODING_AGENT_SESSION_DIR": root.path]
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        let agent = root.appendingPathComponent("agent")
        let project = root.appendingPathComponent(".pi")
        for folder in [agent, project] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var settingsEnv = ["PI_CODING_AGENT_DIR": agent.path]
        precondition(piSessionDirectory(for: root.path, environment: settingsEnv) == piSessionDirectory(for: alias.path, environment: settingsEnv))
        let physical = root.resolvingSymlinksInPath()
        try #"{"sessionDir":"global-store"}"#.write(to: agent.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        precondition(piSessionDirectory(for: alias.path, environment: settingsEnv).path == physical.appendingPathComponent("global-store").path)
        try #"{"sessionDir":"./project-store"}"#.write(to: project.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        precondition(piSessionDirectory(for: alias.path, environment: settingsEnv).path == physical.appendingPathComponent("project-store").path)
        settingsEnv["PI_CODING_AGENT_SESSION_DIR"] = "env-store"
        precondition(piSessionDirectory(for: alias.path, environment: settingsEnv).path == physical.appendingPathComponent("env-store").path)
        let missing = try loadTranscript(sessionID: "abc", directory: root.path, environment: env)
        precondition(missing == nil)
        let header = "{\"type\":\"session\",\"id\":\"abc\",\"cwd\":\"\(root.path)\"}"
        let body = """
        \(header)
        {"type":"message","id":"1","parentId":null,"message":{"role":"user","content":"hello"}}
        {"type":"message","id":"2","parentId":"1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"SECRET"},{"type":"text","text":"answer"},{"type":"toolCall","arguments":"SECRET"}]}}
        {"type":"message","id":"3","parentId":"2","message":{"role":"toolResult","content":"SECRET"}}
        broken json
        {"type":"message","id":"4","parentId":"3","message":{"role":"user","content":"next"}}
        """
        let file = root.appendingPathComponent("time_abc.jsonl")
        try body.write(to: file, atomically: true, encoding: .utf8)
        let text = try loadTranscript(sessionID: "abc", directory: root.path, environment: env)!
        precondition(text == "You:\nhello\n\nAssistant:\nanswer\n\nYou:\nnext")
        do { _ = try transcriptText(Data(body.utf8), sessionID: "other", directory: root.path); preconditionFailure() } catch {}
        do { _ = try transcriptText(Data("garbage".utf8), sessionID: "abc", directory: root.path); preconditionFailure() } catch {}
        let bigFile = root.appendingPathComponent("big_large.jsonl")
        try "{\"type\":\"session\",\"id\":\"large\",\"cwd\":\"\(root.path)\"}\n".write(to: bigFile, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: bigFile)
        try handle.truncate(atOffset: 20_000_001); try handle.close()
        precondition(try! hasSessionFile(id: "large", directory: alias.path, storage: root))
        do { _ = try loadSessionTranscript(sessionID: "large", directory: root.path, storage: root); preconditionFailure() } catch TranscriptError.tooLarge {}
        let duplicate = root.appendingPathComponent("duplicate_abc.jsonl")
        try FileManager.default.copyItem(at: file, to: duplicate)
        do { _ = try hasSessionFile(id: "abc", directory: root.path, storage: root); preconditionFailure() } catch TranscriptError.ambiguous {}
        print("Transcript tests passed")
    }
}
