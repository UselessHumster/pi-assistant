import CoreGraphics
import Foundation

@main
struct HotkeyTests {
    static func main() {
        let both: CGEventFlags = [.maskControl, .maskAlternate]
        var key = PushToTalkHotkey()
        precondition(key.handle(type: .keyDown, keyCode: 49, flags: .maskControl) == nil)
        precondition(key.handle(type: .keyUp, keyCode: 49, flags: .maskControl) == nil)
        precondition(key.handle(type: .flagsChanged, keyCode: 58, flags: both) == nil)
        precondition(key.handle(type: .keyDown, keyCode: 49, flags: both, isRepeat: true) == nil)
        precondition(key.handle(type: .keyDown, keyCode: 49, flags: both) == .start)
        precondition(key.handle(type: .keyDown, keyCode: 49, flags: both, isRepeat: true) == nil)
        precondition(key.handle(type: .keyUp, keyCode: 49, flags: both) == .stop)
        for remaining: CGEventFlags in [.maskControl, .maskAlternate] {
            precondition(key.handle(type: .keyDown, keyCode: 49, flags: both) == .start)
            precondition(key.handle(type: .flagsChanged, keyCode: 0, flags: remaining) == .stop)
            precondition(key.handle(type: .flagsChanged, keyCode: 0, flags: both) == nil)
            precondition(key.handle(type: .keyDown, keyCode: 49, flags: both, isRepeat: true) == nil)
            precondition(key.handle(type: .keyUp, keyCode: 49, flags: both) == nil)
        }
        precondition(key.handle(type: .keyDown, keyCode: 49, flags: both) == .start)
        precondition(key.reset() == .stop)
        precondition(key.reset() == nil)
        key.configuration = HotkeyConfiguration(keyCode: 12, modifiers: .maskCommand, mode: .toggle)
        precondition(key.handle(type: .keyDown, keyCode: 12, flags: [.maskCommand, .maskShift]) == nil)
        _ = key.handle(type: .keyUp, keyCode: 12, flags: .maskCommand)
        precondition(key.handle(type: .keyDown, keyCode: 12, flags: .maskCommand) == .start)
        precondition(key.handle(type: .keyDown, keyCode: 12, flags: .maskCommand, isRepeat: true) == nil)
        precondition(key.handle(type: .keyUp, keyCode: 12, flags: []) == nil)
        precondition(key.handle(type: .flagsChanged, keyCode: 55, flags: []) == nil)
        precondition(key.handle(type: .keyDown, keyCode: 12, flags: .maskCommand) == .stop)
        _ = key.handle(type: .keyUp, keyCode: 12, flags: .maskCommand)
        precondition(key.handle(type: .keyDown, keyCode: 12, flags: .maskCommand) == .start)
        precondition(key.reset() == .stop)
        let suite = "hotkey-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(12, forKey: "previousDialogShortcutCode")
        defaults.set(Int(CGEventFlags.maskCommand.rawValue), forKey: "previousDialogShortcutModifiers")
        defaults.set(1, forKey: "hotkeyCode") // S
        defaults.set(Int(CGEventFlags.maskControl.rawValue), forKey: "hotkeyModifiers")
        defaults.set("toggle", forKey: "hotkeyMode")
        var saved = PushToTalkHotkey()
        saved.configuration = .load(from: defaults)
        precondition(saved.handle(type: .keyDown, keyCode: 1, flags: .maskControl) == .start)
        precondition(saved.handle(type: .keyUp, keyCode: 1, flags: .maskControl) == nil)
        precondition(saved.handle(type: .keyDown, keyCode: 1, flags: .maskControl) == .stop)
        precondition(saved.handle(type: .keyDown, keyCode: 12, flags: .maskCommand) == nil)
        print("Hotkey tests passed.")
    }
}
