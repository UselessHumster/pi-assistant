import Foundation

@main struct ConversationLifecycleTests {
    static func main() {
        var lifecycle = ConversationLifecycle()
        precondition(!lifecycle.consumeNewSession()) // Initial selected session.
        precondition(!lifecycle.consumeNewSession()) // Follow-up stays in it.
        lifecycle.finish()
        precondition(lifecycle.consumeNewSession())
        precondition(!lifecycle.consumeNewSession()) // Subsequent follow-up continues.
        lifecycle.finish()
        lifecycle.finish()
        lifecycle.select()
        precondition(!lifecycle.consumeNewSession()) // Explicit selection wins.
        lifecycle.finish()
        precondition(lifecycle.consumeNewSession())
        precondition(lifecycle.consumeNewSession(alwaysNew: true))
        lifecycle.select()
        precondition(!lifecycle.consumeNewSession(alwaysNew: true))
        precondition(lifecycle.consumeNewSession(alwaysNew: true))
        lifecycle.finish()
        precondition(lifecycle.consumeNewSession(alwaysNew: true))
        let suite = "dialog-shortcut-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = NSTemporaryDirectory()
        let first = conversationSessionID(for: directory, defaults: defaults)
        lifecycle.finish()
        let latest = sessionForVoiceTurn(.new, directory: directory, defaults: defaults, lifecycle: &lifecycle)
        precondition(first != latest && lifecycle.consumeNewSession(alwaysNew: true))
        selectConversationSession(first, for: directory, defaults: defaults)
        lifecycle.finish()
        precondition(sessionForVoiceTurn(.previous, directory: directory, defaults: defaults, lifecycle: &lifecycle) == latest)
        precondition(conversationSessionID(for: directory, defaults: defaults) == latest)
        precondition(lifecycle.consumeNewSession(alwaysNew: true))
        let next = sessionForVoiceTurn(.new, directory: directory, defaults: defaults, lifecycle: &lifecycle)
        precondition(next != latest && next != first)
        print("Conversation lifecycle tests passed")
    }
}
