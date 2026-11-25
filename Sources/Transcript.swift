import Foundation

struct ChatMessage: Equatable {
    enum Role { case user, assistant }
    let role: Role
    let text: String
    var speaker: String { role == .user ? "You" : "Pi" }
}

struct SessionTranscript {
    let messages: [ChatMessage]
    let title: String?

    var text: String { messages.map { "\($0.role == .user ? "You" : "Assistant"):\n\($0.text)" }.joined(separator: "\n\n") }
    var previewTitle: String? {
        if let title { return title }
        guard let first = messages.first(where: { $0.role == .user }) else { return nil }
        let excerpt = first.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return excerpt.count > 48 ? String(excerpt.prefix(48)) + "…" : excerpt
    }
}

func transcriptText(_ data: Data, sessionID: String, directory: String) throws -> String {
    try parseTranscript(data, sessionID: sessionID, directory: directory).text
}

private func validateSessionHeader(_ data: Data, sessionID: String, directory: String) throws {
    let line = data.prefix { $0 != 0x0a }
    guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          obj["type"] as? String == "session", obj["id"] as? String == sessionID,
          let cwd = obj["cwd"] as? String, cwd.hasPrefix("/"),
          URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path else { throw TranscriptError.invalid }
}

// Only display conversational text, never tool calls/results or thinking.
private func parseTranscript(_ data: Data, sessionID: String, directory: String) throws -> SessionTranscript {
    try validateSessionHeader(data, sessionID: sessionID, directory: directory)
    guard let source = String(data: data, encoding: .utf8) else { throw TranscriptError.invalid }
    var entries: [String: (String?, ChatMessage?)] = [:]
    var leaf: String?
    var title: String?
    for line in source.split(separator: "\n").dropFirst() {
        guard let bytes = String(line).data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { continue }
        if obj["type"] as? String == "session_info", let name = obj["name"] as? String {
            title = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard let id = obj["id"] as? String, !id.isEmpty else { continue }
        var turn: ChatMessage?
        if obj["type"] as? String == "message", let message = obj["message"] as? [String: Any], let role = message["role"] as? String, role == "user" || role == "assistant" {
            var pieces: [String] = []
            if let value = message["content"] as? String { pieces = [value] }
            if let blocks = message["content"] as? [[String: Any]] { pieces = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil } }
            let content = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { turn = ChatMessage(role: role == "user" ? .user : .assistant, text: content) }
        }
        entries[id] = (obj["parentId"] as? String, turn); leaf = id
    }
    var result: [ChatMessage] = []; var visited = Set<String>()
    while let id = leaf {
        guard visited.insert(id).inserted, let entry = entries[id] else { throw TranscriptError.invalid }
        if let text = entry.1 { result.append(text) }
        leaf = entry.0
    }
    return SessionTranscript(messages: result.reversed(), title: title.flatMap { $0.isEmpty ? nil : $0 })
}

enum TranscriptError: Error { case invalid, ambiguous, tooLarge }

func piAgentDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    guard let path = environment["PI_CODING_AGENT_DIR"], !path.isEmpty else { return home.appendingPathComponent(".pi/agent") }
    return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
}

func piSessionDirectory(for directory: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    let cwd = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let agent = piAgentDirectory(environment: environment)
    func sessionSetting(in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("settings.json")),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return settings["sessionDir"] as? String
    }
    let paths = [environment["PI_CODING_AGENT_SESSION_DIR"], sessionSetting(in: cwd.appendingPathComponent(".pi")), sessionSetting(in: agent)]
    if let path = paths.compactMap({ $0 }).first(where: { !$0.isEmpty }) {
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true, relativeTo: cwd).standardizedFileURL
    }
    let encoded = "--" + String(cwd.path.drop(while: { $0 == "/" })).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "--"
    return agent.appendingPathComponent("sessions").appendingPathComponent(encoded)
}

func loadTranscript(sessionID: String, directory: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String? {
    try loadSessionTranscript(sessionID: sessionID, directory: directory, storage: piSessionDirectory(for: directory, environment: environment))?.text
}

func loadSessionTranscript(sessionID: String, directory: String, storage: URL) throws -> SessionTranscript? {
    guard let file = try sessionFile(id: sessionID, storage: storage) else { return nil }
    return try readTranscriptFile(file, id: sessionID, directory: directory)
}

private func readTranscriptFile(_ file: URL, id: String, directory: String) throws -> SessionTranscript {
    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TranscriptError.invalid }
    guard (values.fileSize ?? Int.max) <= 20_000_000 else { throw TranscriptError.tooLarge }
    return try parseTranscript(Data(contentsOf: file), sessionID: id, directory: directory)
}

// Read one directory listing for the whole sidebar, not one per row or keystroke.
func conversationPreviews(ids: Set<String>, directory: String, storage: URL) -> [String: String] {
    guard let files = try? FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [:] }
    let indexed = Dictionary(grouping: files.filter { $0.pathExtension == "jsonl" }) {
        String($0.deletingPathExtension().lastPathComponent.split(separator: "_").last ?? "")
    }
    var previews: [String: String] = [:]
    for id in ids {
        guard let matches = indexed[id], matches.count == 1 else { continue }
        previews[id] = (try? readTranscriptFile(matches[0], id: id, directory: directory))?.previewTitle
    }
    return previews
}

func hasSessionFile(id: String, directory: String, storage: URL) throws -> Bool {
    guard let file = try sessionFile(id: id, storage: storage) else { return false }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    try validateSessionHeader(try handle.read(upToCount: 64_000) ?? Data(), sessionID: id, directory: directory)
    return true
}

private func sessionFile(id sessionID: String, storage dir: URL) throws -> URL? {
    let fm = FileManager.default
    let files: [URL]
    do { files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) }
    catch { if (error as NSError).code == NSFileReadNoSuchFileError { return nil }; throw error }
    // IDs originate from the catalog, not a path; match filenames exactly at the suffix.
    guard !sessionID.contains("/") && !sessionID.contains("\\") else { throw TranscriptError.invalid }
    let candidates = files.filter { $0.lastPathComponent.hasSuffix("_\(sessionID).jsonl") }
    guard candidates.count <= 1 else { throw TranscriptError.ambiguous }
    guard let file = candidates.first else { return nil }
    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw TranscriptError.invalid }
    return file
}
