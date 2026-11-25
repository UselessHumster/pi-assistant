import Foundation

struct ConversationSession: Codable {
    let id: String
    var title: String
    // Missing for older catalogs, whose sessions may already have history.
    var isDraft: Bool? = nil
    var archived: Bool? = nil
    var isArchived: Bool { archived == true }
    var needsDisplayTitle: Bool { title == "Default" || title == "Conversation" }

    func displayTitle(preview: String?) -> String {
        guard needsDisplayTitle else { return title }
        return preview ?? (isDraft == true ? "New Chat" : "Untitled conversation")
    }
}

struct ConversationCatalog: Codable {
    var sessions: [ConversationSession]
    var selectedID: String

    var selected: ConversationSession { sessions.first { $0.id == selectedID }! }

    func matching(_ query: String, previews: [String: String] = [:], showArchive: Bool = false) -> [ConversationSession] {
        let words = query.split(whereSeparator: \.isWhitespace)
        return sessions.reversed().filter { session in
            if words.isEmpty { return session.isArchived == showArchive }
            let title = session.displayTitle(preview: previews[session.id])
            return words.allSatisfy { title.localizedStandardContains(String($0)) }
        }
    }
}

private func conversationKey(_ directory: String) -> String {
    URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
}

private func saveConversationCatalog(_ catalog: ConversationCatalog, key: String, defaults: UserDefaults) {
    var catalogs = defaults.dictionary(forKey: "conversationCatalogs") as? [String: Data] ?? [:]
    catalogs[key] = try! JSONEncoder().encode(catalog)
    defaults.set(catalogs, forKey: "conversationCatalogs")
}

func conversationCatalog(for directory: String, defaults: UserDefaults) -> ConversationCatalog {
    let key = conversationKey(directory)
    let catalogs = defaults.dictionary(forKey: "conversationCatalogs") as? [String: Data] ?? [:]
    if let data = catalogs[key], let catalog = try? JSONDecoder().decode(ConversationCatalog.self, from: data),
       catalog.sessions.contains(where: { $0.id == catalog.selectedID }) { return catalog }
    let legacy = (defaults.dictionary(forKey: "conversationSessions") as? [String: String])?[key]
    let session = ConversationSession(id: legacy ?? UUID().uuidString.lowercased(), title: "Default", isDraft: legacy == nil ? true : nil)
    let catalog = ConversationCatalog(sessions: [session], selectedID: session.id)
    saveConversationCatalog(catalog, key: key, defaults: defaults)
    return catalog
}

func createConversationSession(_ input: String = "Conversation", for directory: String, defaults: UserDefaults) -> ConversationSession {
    let title = input.trimmingCharacters(in: .whitespacesAndNewlines)
    var catalog = conversationCatalog(for: directory, defaults: defaults)
    let session = ConversationSession(id: UUID().uuidString.lowercased(), title: title.isEmpty ? "Conversation" : title, isDraft: true)
    catalog.sessions.append(session)
    catalog.selectedID = session.id
    saveConversationCatalog(catalog, key: conversationKey(directory), defaults: defaults)
    return session
}

func selectConversationSession(_ id: String, for directory: String, defaults: UserDefaults) {
    var catalog = conversationCatalog(for: directory, defaults: defaults)
    guard id != catalog.selectedID, catalog.sessions.contains(where: { $0.id == id }) else { return }
    catalog.selectedID = id
    saveConversationCatalog(catalog, key: conversationKey(directory), defaults: defaults)
}

func setConversationArchived(_ archived: Bool, id: String, directory: String, defaults: UserDefaults) {
    var catalog = conversationCatalog(for: directory, defaults: defaults)
    guard let index = catalog.sessions.firstIndex(where: { $0.id == id }),
          catalog.sessions[index].isArchived != archived else { return }
    catalog.sessions[index].archived = archived ? true : nil
    if archived, catalog.selectedID == id,
       let next = catalog.sessions.last(where: { !$0.isArchived }) { catalog.selectedID = next.id }
    saveConversationCatalog(catalog, key: conversationKey(directory), defaults: defaults)
}

func voiceConversation(startNew: Bool, directory: String, defaults: UserDefaults) -> ConversationSession {
    if startNew { return createConversationSession(for: directory, defaults: defaults) }
    return conversationCatalog(for: directory, defaults: defaults).selected
}

func updateConversation(_ id: String, from transcript: SessionTranscript, directory: String, defaults: UserDefaults) {
    var catalog = conversationCatalog(for: directory, defaults: defaults)
    guard let index = catalog.sessions.firstIndex(where: { $0.id == id }) else { return }
    catalog.sessions[index].isDraft = false
    if let title = transcript.title,
       catalog.sessions[index].needsDisplayTitle {
        catalog.sessions[index].title = title
    }
    saveConversationCatalog(catalog, key: conversationKey(directory), defaults: defaults)
}
