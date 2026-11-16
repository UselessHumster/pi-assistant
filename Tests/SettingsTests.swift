import AppKit
import ApplicationServices

@main
struct SettingsTests {
    static func main() {
        precondition(ShortcutSettingsView.validKeyCode(0))
        precondition(ShortcutSettingsView.validKeyCode(49))
        precondition(ShortcutSettingsView.validKeyCode(126))
        for code in [-1, 52, 55, 56, 63, 127, 128] {
            precondition(!ShortcutSettingsView.validKeyCode(code))
        }
        _ = NSApplication.shared
        let view = ShortcutSettingsView(configuration: HotkeyConfiguration(keyCode: 49, modifiers: [.maskControl, .maskAlternate], mode: .toggle))
        precondition(view.keyCode == 49 && view.modifiers == [.maskControl, .maskAlternate])
        precondition(view.mode.indexOfSelectedItem == 1 && !view.isRecording)
        view.stopRecording()
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let normal = DialogShortcut(keyCode: 49, modifiers: [.maskControl, .maskAlternate])
        let other = DialogShortcut(keyCode: 12, modifiers: .maskCommand)
        precondition(shortcutValidationError(normal: normal, optional: [nil, other]) == nil)
        precondition(shortcutValidationError(normal: normal, optional: [normal, nil]) != nil)
        precondition(shortcutValidationError(normal: normal, optional: [other, other]) != nil)
        precondition(shortcutValidationError(normal: normal, optional: [DialogShortcut(keyCode: 12, modifiers: []), nil]) != nil)
        for prefix in ["newDialogShortcut", "previousDialogShortcut"] {
            defaults.set(12, forKey: prefix + "Code"); defaults.set(Int(CGEventFlags.maskCommand.rawValue), forKey: prefix + "Modifiers")
            let optional = OptionalShortcutSettingsView(title: "Test", prefix: prefix, defaults: defaults)
            precondition(optional.value?.keyCode == 12 && optional.value?.modifiers == .maskCommand)
            optional.persist(to: defaults)
            precondition(DialogShortcut.load(prefix: prefix, from: defaults)?.keyCode == 12)
            optional.enabled.state = .off; optional.persist(to: defaults)
            precondition(defaults.object(forKey: prefix + "Code") == nil && defaults.object(forKey: prefix + "Modifiers") == nil)
        }
        print("Settings tests passed.")
    }
}
