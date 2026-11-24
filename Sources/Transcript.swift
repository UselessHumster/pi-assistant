import Foundation

struct SessionTranscript {
    let text: String
    let title: String?
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
    var entries: [String: (String?, String?)] = [:]
    var leaf: String?
    var title: String?
    for line in source.split(separator: "\n").dropFirst() {
        guard let bytes = String(line).data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { continue }
        if obj["type"] as? String == "session_info", let name = obj["name"] as? String {
            title = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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
    var result: [String] = []; var visited = Set<String>()
    while let id = leaf {
        guard visited.insert(id).inserted, let entry = entries[id] else { throw TranscriptError.invalid }
        if let text = entry.1 { result.append(text) }
        leaf = entry.0
    }
    return SessionTranscript(text: result.reversed().joined(separator: "\n\n"), title: title.flatMap { $0.isEmpty ? nil : $0 })
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
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
    guard (size ?? Int.max) <= 20_000_000 else { throw TranscriptError.tooLarge }
    return try parseTranscript(Data(contentsOf: file), sessionID: sessionID, directory: directory)
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
