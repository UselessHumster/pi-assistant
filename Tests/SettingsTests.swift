import AppKit
import ApplicationServices

@main
struct SettingsTests {
    static func main() {
        precondition(ShortcutSettingsView.validKeyCode(0))
        precondition(ShortcutSettingsView.validKeyCode(49))
        precondition(ShortcutSettingsView.validKeyCode(126))
        for code in [-1, 52, 55, 56, 63, 127, 128] { precondition(!ShortcutSettingsView.validKeyCode(code)) }
        _ = NSApplication.shared
        let view = ShortcutSettingsView(configuration: HotkeyConfiguration(keyCode: 49, modifiers: [.maskControl, .maskAlternate], mode: .toggle))
        precondition(view.keyCode == 49 && view.modifiers == [.maskControl, .maskAlternate])
        precondition(view.mode.indexOfSelectedItem == 1 && !view.isRecording)
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("/path/to/whisper.bin", forKey: "model")
        precondition(PiModel.load(from: defaults) == "router/6.2-sol-failover")
        precondition(PiModel.preference(" llm3/cx/gpt-6.2-sol ") == "llm3/cx/gpt-6.2-sol")
        precondition(PiModel.preference("llm3/cx//model") == nil)
        precondition(PiModel.preference("unqualified") == nil)
        defaults.set(PiModel.preference(PiModel.usePiDefault), forKey: PiModel.key)
        precondition(PiModel.load(from: defaults).isEmpty)
        print("Settings tests passed.")
    }
}
