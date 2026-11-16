import Foundation

// Only display conversational text, never tool calls/results, thinking, or metadata.
func transcriptText(_ data: Data, sessionID: String, directory: String) throws -> String {
    guard let source = String(data: data, encoding: .utf8) else { throw TranscriptError.invalid }
    var header = false
    var entries: [String: (String?, String?)] = [:]
    var leaf: String?
    for line in source.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let bytes = String(line).data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { continue }
        if !header {
            guard obj["type"] as? String == "session", obj["id"] as? String == sessionID,
                  let cwd = obj["cwd"] as? String,
                  URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path else { throw TranscriptError.invalid }
            header = true; continue
        }
        guard let id = obj["id"] as? String, !id.isEmpty else { continue }
        var text: String?
        if obj["type"] as? String == "message", let message = obj["message"] as? [String: Any], let role = message["role"] as? String, role == "user" || role == "assistant" {
            var pieces: [String] = []
            if let value = message["content"] as? String { pieces = [value] }
            if let blocks = message["content"] as? [[String: Any]] { pieces = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } }
            let content = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { text = "\(role == "user" ? "You" : "Assistant"):\n\(content)" }
        }
        entries[id] = (obj["parentId"] as? String, text); leaf = id
    }
    guard header else { throw TranscriptError.invalid }
    var result: [String] = []; var visited = Set<String>()
    while let id = leaf {
        guard visited.insert(id).inserted, let entry = entries[id] else { throw TranscriptError.invalid }
        if let text = entry.1 { result.append(text) }
        leaf = entry.0
    }
    return result.reversed().joined(separator: "\n\n")
}

enum TranscriptError: Error { case invalid, ambiguous, tooLarge }

func loadTranscript(sessionID: String, directory: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
    let fm = FileManager.default
    let agent = environment["PI_CODING_AGENT_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent").path
    let cwd = URL(fileURLWithPath: directory).standardizedFileURL.path
    let encoded = "--" + String(cwd.drop(while: { $0 == "/" })).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "--"
    let dir = environment["PI_CODING_AGENT_SESSION_DIR"].flatMap { $0.isEmpty ? nil : $0 }.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: agent).appendingPathComponent("sessions").appendingPathComponent(encoded)
    let files: [URL]
    do { files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) }
    catch { if (error as NSError).code == NSFileReadNoSuchFileError { return nil }; throw error }
    // IDs originate from the catalog, not a path; match filenames exactly at the suffix.
    guard !sessionID.contains("/") && !sessionID.contains("\\") else { throw TranscriptError.invalid }
    let candidates = files.filter { $0.lastPathComponent.hasSuffix("_\(sessionID).jsonl") }
    guard candidates.count <= 1 else { throw TranscriptError.ambiguous }
    guard let file = candidates.first else { return nil }
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TranscriptError.invalid }
    guard (values.fileSize ?? Int.max) <= 20_000_000 else { throw TranscriptError.tooLarge }
    return try transcriptText(Data(contentsOf: file), sessionID: sessionID, directory: directory)
}
