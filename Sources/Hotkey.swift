import CoreGraphics
import Foundation

struct HotkeyConfiguration {
    enum Mode: String { case hold, toggle }
    static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    var keyCode: Int64 = 49
    var modifiers: CGEventFlags = [.maskControl, .maskAlternate]
    var mode: Mode = .hold

    static func load(from defaults: UserDefaults) -> Self {
        let code = defaults.object(forKey: "hotkeyCode") as? Int ?? 49
        let modifiers = defaults.object(forKey: "hotkeyModifiers") as? Int ?? Int(Self().modifiers.rawValue)
        return Self(keyCode: Int64((0...127).contains(code) ? code : 49), modifiers: CGEventFlags(rawValue: UInt64(max(0, modifiers))).intersection(relevant), mode: Mode(rawValue: defaults.string(forKey: "hotkeyMode") ?? "hold") ?? .hold)
    }
}

struct PushToTalkHotkey {
    enum Action { case start, stop }
    var configuration = HotkeyConfiguration()
    private(set) var held = false
    private var keyIsDown = false

    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool = false) -> Action? {
        let matches = flags.intersection(HotkeyConfiguration.relevant) == configuration.modifiers
        if type == .keyUp && keyCode == configuration.keyCode { keyIsDown = false }
        if configuration.mode == .hold && held && ((type == .keyUp && keyCode == configuration.keyCode) || !matches) {
            held = false
            return .stop
        }
        if type == .keyDown && keyCode == configuration.keyCode && !isRepeat && !keyIsDown {
            keyIsDown = true
            guard matches else { return nil }
            if configuration.mode == .toggle {
                held.toggle()
                return held ? .start : .stop
            }
            if !held { held = true; return .start }
        }
        return nil
    }

    mutating func reset() -> Action? {
        keyIsDown = false
        guard held else { return nil }
        held = false
        return .stop
    }
}
