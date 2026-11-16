import Foundation

@main struct TranscriptTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let env = ["PI_CODING_AGENT_SESSION_DIR": root.path]
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
        print("Transcript tests passed")
    }
}
