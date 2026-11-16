#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s Tests -p 'test_*.py'
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Exercise the production argument builder and process runner with a fake Pi.
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
s = Path('Sources/main.swift').read_text()
safety = s[s.index('private let safetyInstruction'):s.index('\nfinal class App')]
functions = s[s.index('enum VoiceStatus'):s.index('\nlet app = NSApplication.shared')]
harness = '''
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let suite = "voice-session-test-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let id = conversationSessionID(for: root.path, defaults: defaults)
precondition(UUID(uuidString: id) != nil)
precondition(id == conversationSessionID(for: root.path, defaults: UserDefaults(suiteName: suite)!))
precondition(id == conversationSessionID(for: root.appendingPathComponent(".").path, defaults: defaults))
let alias = root.appendingPathComponent("alias")
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
precondition(id == conversationSessionID(for: alias.path, defaults: defaults))
precondition(id != conversationSessionID(for: root.appendingPathComponent("work").path, defaults: defaults))
let other = createConversationSession("  Research  ", for: root.path, defaults: defaults)!
precondition(other != id && UUID(uuidString: other) != nil)
precondition(createConversationSession("  ", for: root.path, defaults: defaults) == nil)
let reopened = UserDefaults(suiteName: suite)!
precondition(conversationCatalog(for: root.path, defaults: reopened).sessions.map { $0.title } == ["Default", "Research"])
precondition(conversationSessionID(for: root.path, defaults: reopened) == other)
selectConversationSession(id, for: root.path, defaults: reopened)
selectConversationSession("invalid", for: root.path, defaults: reopened)
precondition(conversationSessionID(for: root.path, defaults: defaults) == id)
let legacyPath = root.appendingPathComponent("legacy").path
let legacyID = UUID().uuidString.lowercased()
defaults.set([legacyPath: legacyID], forKey: "conversationSessions")
precondition(conversationSessionID(for: legacyPath, defaults: defaults) == legacyID)
precondition(conversationCatalog(for: legacyPath, defaults: defaults).sessions.first?.title == "Default")
let args = piArguments("-create task", sessionID: id)
precondition(!args.contains("--no-tools") && !args.contains("--no-skills"))
for flag in ["--print", "--session-id", "--no-extensions", "--no-mcp", "--no-prompt-templates", "--no-context-files"] {
    precondition(args.filter { $0 == flag }.count == 1, "Missing or duplicated flag: \(flag)")
}
precondition(!args.contains("--no-session") && !args.contains("--continue"))
precondition(args[args.firstIndex(of: "--session-id")! + 1] == id)
precondition(args.suffix(2).elementsEqual(["--", "-create task"]))
precondition(args.contains(safetyInstruction))
let result = try run(root.appendingPathComponent("fake-pi").path, args, directory: root.appendingPathComponent("work"), outputDirectory: root.appendingPathComponent("output"))
precondition(result.trimmingCharacters(in: .whitespacesAndNewlines) == "ok")
let secondResult = try runPi(root.appendingPathComponent("fake-pi").path, text: "follow-up", sessionID: id, directory: root.appendingPathComponent("work"), outputDirectory: root.appendingPathComponent("output"), cancellation: ProcessCancellation())
precondition(secondResult == "ok")
let chatResult = try runChatTurn(pi: root.appendingPathComponent("fake-pi").path, text: "typed", sessionID: id, directory: root.appendingPathComponent("work").path, outputDirectory: root.appendingPathComponent("output"), cancellation: ProcessCancellation())
precondition(chatResult == "ok")
// Drive distinct physical shortcuts through recording start/stop, production selection,
// and the child process; its response is the session ID it actually received.
let voiceDir = root.appendingPathComponent("work").path
var lifecycle = ConversationLifecycle()
var router = HotkeyRouter(configuration: HotkeyConfiguration(keyCode: 49, modifiers: .maskControl, mode: .hold), newShortcut: DialogShortcut(keyCode: 45, modifiers: .maskControl), previousShortcut: DialogShortcut(keyCode: 8, modifiers: .maskControl))
func voice(_ code: Int64) throws -> String {
    guard case .start(let owner) = router.handle(type: .keyDown, keyCode: code, flags: .maskControl) else { fatalError("no recording start") }
    precondition(router.handle(type: .keyUp, keyCode: code, flags: .maskControl) == .stop(owner))
    let selected = sessionForVoiceTurn(owner, directory: voiceDir, defaults: defaults, lifecycle: &lifecycle)
    let received = try runChatTurn(pi: root.appendingPathComponent("fake-pi").path, text: "report-session", sessionID: selected, directory: voiceDir, outputDirectory: root.appendingPathComponent("output"), cancellation: ProcessCancellation())
    precondition(received == selected && conversationSessionID(for: voiceDir, defaults: defaults) == selected)
    return received
}
let a = try voice(49)
precondition(try! voice(49) == a)
let b = try voice(45)
precondition(b != a)
let c = try voice(45)
precondition(c != a && c != b)
precondition(try! voice(8) == b)
precondition(try! voice(8) == c)
lifecycle.finish()
precondition(try! voice(8) == b) // explicit previous overrides a pending new dialog
lifecycle.finish()
let d = try voice(49)
precondition(d != a && d != b && d != c)
precondition(try! voice(49) == d)
precondition(try! voice(8) == b)
defaults.set(true, forKey: "alwaysNewDialog")
let e = try voice(49)
precondition(e != b && e != d)
precondition(try! voice(8) == b)
let f = try voice(49)
precondition(f != b && f != e) // forced previous did not suppress always-new on the next turn
let catalogKey = URL(fileURLWithPath: voiceDir).standardizedFileURL.resolvingSymlinksInPath().path
var catalogs = defaults.dictionary(forKey: "conversationCatalogs") as! [String: Data]
var stale = conversationCatalog(for: voiceDir, defaults: defaults)
stale.previousID = "removed"
catalogs[catalogKey] = try JSONEncoder().encode(stale)
defaults.set(catalogs, forKey: "conversationCatalogs")
precondition(try! voice(8) == f) // stale previous falls back to current
let isolated = root.appendingPathComponent("sessions")
try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
let header = "{\\\"type\\\":\\\"session\\\",\\\"id\\\":\\\"\\(b)\\\",\\\"cwd\\\":\\\"\\(voiceDir)\\\"}\\n"
try Data(header.utf8).write(to: isolated.appendingPathComponent("test_\\(b).jsonl"))
precondition(try! loadTranscript(sessionID: f, directory: voiceDir, environment: ["PI_CODING_AGENT_SESSION_DIR": isolated.path]) == nil)
do {
    _ = try runChatTurn(pi: "/bin/echo", text: "  ", sessionID: id, directory: root.path, outputDirectory: root.appendingPathComponent("output"), cancellation: ProcessCancellation())
    fatalError("empty message accepted")
} catch { precondition(error.localizedDescription.contains("empty")) }
let chatCancelled = ProcessCancellation()
chatCancelled.cancel()
do {
    _ = try runChatTurn(pi: root.appendingPathComponent("fake-pi").path, text: "cancel", sessionID: id, directory: root.appendingPathComponent("work").path, outputDirectory: root.appendingPathComponent("output"), cancellation: chatCancelled)
    fatalError("cancelled chat ran")
} catch { precondition(error.localizedDescription.contains("cancelled")) }
precondition(conversationSessionID(for: root.path, defaults: defaults) == id)
do {
    _ = try runPi("/usr/bin/true", text: "hello", sessionID: id, directory: root, outputDirectory: root.appendingPathComponent("output"), cancellation: ProcessCancellation())
    fatalError("empty response accepted")
} catch { precondition(error.localizedDescription.contains("no response")) }
let audio = root.appendingPathComponent("output/audio.wav")
let recognizer = try makeRecognizer(engine: "gigaam", whisper: "", model: "", python: root.appendingPathComponent("fake-recognizer").path, gigaamModel: "test-model", cache: root.path, script: "/test/script")
let transcript = try recognizer.transcribe(audio)
precondition(transcript == "hello")
try FileManager.default.removeItem(at: root.appendingPathComponent("output/transcript.txt"))
do {
    _ = try makeRecognizer(engine: "unknown", whisper: "", model: "", python: "", gigaamModel: "", cache: "", script: "")
    fatalError("unknown engine accepted")
} catch {}
let cancelled = ProcessCancellation()
cancelled.cancel()
do {
    _ = try run("/bin/echo", ["unexpected"], directory: root, outputDirectory: root.appendingPathComponent("output"), cancellation: cancelled)
    fatalError("pre-cancelled command ran")
} catch { precondition(error.localizedDescription.contains("cancelled")) }
let token = ProcessCancellation()
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    defer { done.signal() }
    do {
        _ = try run(root.appendingPathComponent("fake-blocking").path, [], directory: root, outputDirectory: root.appendingPathComponent("output"), cancellation: token)
        fatalError("cancelled command succeeded")
    } catch { precondition(error.localizedDescription.contains("cancelled")) }
}
let marker = root.appendingPathComponent("child-started")
let deadline = Date().addingTimeInterval(5)
while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
precondition(FileManager.default.fileExists(atPath: marker.path))
token.cancel()
precondition(done.wait(timeout: .now() + 5) == .success)
Thread.sleep(forTimeInterval: 0.5)
precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("child-survived").path))
let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("output").path)
precondition(remaining.isEmpty)
'''
Path(sys.argv[1], 'main.swift').write_text('import Foundation\nimport CoreGraphics\n' + safety + '\n' + functions + '\n' + harness)
PY
mkdir "$tmp/work" "$tmp/output"
cat > "$tmp/fake-pi" <<'SH'
#!/bin/sh
[ "$(basename "$PWD")" = work ] || exit 1
[ -z "$(ls -A ../work)" ] || exit 2
# The session flag must reach the executable.
found=0
for arg in "$@"; do [ "$arg" != --session-id ] || found=1; done
[ "$found" = 1 ] || exit 4
# stdin must be closed, not an interactive confirmation channel.
if read -r line; then exit 3; fi
prev=
for arg in "$@"; do
    if [ "$prev" = --session-id ]; then session=$arg; fi
    prev=$arg
done
if [ "$prev" = report-session ]; then printf '%s\n' "$session"; else printf 'ok\n'; fi
SH
cat > "$tmp/fake-recognizer" <<'SH'
#!/bin/sh
[ "$1" = /test/script ] && [ "$2" = --model ] && [ "$3" = test-model ] || exit 1
[ "$4" = --audio ] && [ "$6" = --output ] && [ "$8" = --cache ] || exit 2
printf ' hello \n' > "$7"
SH
cat > "$tmp/fake-blocking" <<'SH'
#!/bin/sh
( touch child-started; sleep 0.3; touch child-survived ) &
wait
SH
chmod +x "$tmp/fake-pi" "$tmp/fake-recognizer" "$tmp/fake-blocking"
swiftc Sources/Hotkey.swift Sources/Transcript.swift "$tmp/main.swift" -o "$tmp/test"
"$tmp/test" "$tmp"
echo 'Process and argument tests passed.'
swiftc Sources/Hotkey.swift Tests/HotkeyTests.swift -o "$tmp/hotkey-tests"
"$tmp/hotkey-tests"
swiftc Sources/Hotkey.swift Sources/SettingsWindow.swift Tests/SettingsTests.swift -o "$tmp/settings-tests" -framework AppKit -framework Carbon
"$tmp/settings-tests"
swiftc Sources/FloatingOverlay.swift Tests/OverlayTests.swift -o "$tmp/overlay-tests" -framework AppKit
"$tmp/overlay-tests"

python3 - "$tmp/lifecycle.swift" <<'PY'
from pathlib import Path
import sys
s = Path('Sources/main.swift').read_text()
Path(sys.argv[1]).write_text('import Foundation\n' + s[s.index('struct ConversationLifecycle'):s.index('func piArguments')])
PY
swiftc Sources/Hotkey.swift "$tmp/lifecycle.swift" Tests/ConversationLifecycleTests.swift -o "$tmp/lifecycle-tests"
"$tmp/lifecycle-tests"
swiftc Sources/Transcript.swift Tests/TranscriptTests.swift -o "$tmp/transcript-tests"
"$tmp/transcript-tests"
