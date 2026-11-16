import CoreGraphics
import Foundation

struct HotkeyConfiguration {
    enum Mode: String { case hold, toggle }
    var keyCode: Int64 = 49
    var modifiers: CGEventFlags = [.maskControl, .maskAlternate]
    var mode: Mode = .hold

    static func load(from defaults: UserDefaults) -> Self {
        let code = defaults.object(forKey: "hotkeyCode") as? Int ?? 49
        let modifiers = defaults.object(forKey: "hotkeyModifiers") as? Int ?? Int(CGEventFlags([.maskControl, .maskAlternate]).rawValue)
        return Self(keyCode: Int64((0...127).contains(code) ? code : 49), modifiers: CGEventFlags(rawValue: UInt64(max(0, modifiers))).intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]), mode: Mode(rawValue: defaults.string(forKey: "hotkeyMode") ?? "hold") ?? .hold)
    }
}

// Optional dialog activation shortcuts use the same key code/modifier representation as
// push-to-talk. Missing or malformed preferences leave the shortcut disabled.
struct DialogShortcut {
    let keyCode: Int64
    let modifiers: CGEventFlags
    static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    static func load(prefix: String, from defaults: UserDefaults) -> Self? {
        guard let code = defaults.object(forKey: prefix + "Code") as? Int,
              (0...127).contains(code),
              let flags = defaults.object(forKey: prefix + "Modifiers") as? Int,
              flags >= 0 else { return nil }
        let modifiers = CGEventFlags(rawValue: UInt64(flags))
        guard modifiers == modifiers.intersection(relevant), !modifiers.isEmpty else { return nil }
        return Self(keyCode: Int64(code), modifiers: modifiers)
    }

    func matches(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        type == .keyDown && !isRepeat && self.keyCode == keyCode && flags.intersection(Self.relevant) == modifiers
    }
}

// Routes recording actions to the shortcut that initiated them. Reconfigure by
// resetting the old router and constructing a new one.
struct HotkeyRouter {
    enum Shortcut { case normal, new, previous }
    enum Action: Equatable { case start(Shortcut), stop(Shortcut) }

    let configuration: HotkeyConfiguration
    let newShortcut: DialogShortcut?
    let previousShortcut: DialogShortcut?
    private(set) var activeShortcut: Shortcut?
    private var activeHotkey = PushToTalkHotkey()
    private var keysDown: Set<Int64> = []

    init(configuration: HotkeyConfiguration = HotkeyConfiguration(), newShortcut: DialogShortcut? = nil, previousShortcut: DialogShortcut? = nil) {
        self.configuration = configuration
        self.newShortcut = newShortcut
        self.previousShortcut = previousShortcut
    }

    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool = false) -> Action? {
        let wasDown = keysDown.contains(keyCode)
        if type == .keyUp { keysDown.remove(keyCode) }
        if type == .keyDown && !isRepeat { keysDown.insert(keyCode) }

        if let owner = activeShortcut {
            // Only the owner can stop a toggle; other shortcuts are ignored.
            if type == .keyDown && wasDown { return nil }
            if activeHotkey.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat) == .stop {
                activeShortcut = nil
                return .stop(owner)
            }
            return nil
        }

        guard type == .keyDown, !isRepeat, !wasDown else { return nil }
        let relevant = DialogShortcut.relevant
        let owner: Shortcut
        let shortcut: DialogShortcut
        if keyCode == configuration.keyCode && flags.intersection(relevant) == configuration.modifiers {
            owner = .normal
            shortcut = DialogShortcut(keyCode: configuration.keyCode, modifiers: configuration.modifiers)
        } else if let candidate = newShortcut, candidate.matches(type: type, keyCode: keyCode, flags: flags, isRepeat: false) {
            owner = .new
            shortcut = candidate
        } else if let candidate = previousShortcut, candidate.matches(type: type, keyCode: keyCode, flags: flags, isRepeat: false) {
            owner = .previous
            shortcut = candidate
        } else { return nil }

        activeHotkey = PushToTalkHotkey()
        activeHotkey.configuration = HotkeyConfiguration(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, mode: configuration.mode)
        guard activeHotkey.handle(type: type, keyCode: keyCode, flags: flags) == .start else { return nil }
        activeShortcut = owner
        return .start(owner)
    }

    mutating func reset() -> Action? {
        keysDown.removeAll()
        _ = activeHotkey.reset()
        guard let owner = activeShortcut else { return nil }
        activeShortcut = nil
        return .stop(owner)
    }
}

struct PushToTalkHotkey {
    enum Action { case start, stop }
    var configuration = HotkeyConfiguration()
    private(set) var held = false
    private var keyIsDown = false
    private static let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool = false) -> Action? {
        let matches = flags.intersection(Self.relevant) == configuration.modifiers
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
