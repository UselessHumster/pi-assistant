#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s Tests -p 'test_*.py'
node --test Tests/TitleExtensionTests.mjs
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/work" "$tmp/output"
cat > "$tmp/fake-pi" <<'SH'
#!/bin/sh
set -eu
[ "$(basename "$PWD")" = work ] && [ -z "$(ls -A ../work)" ] || exit 1
if read -r line; then exit 2; fi
session= dir= text=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --list-models) printf 'provider model context\nrouter 6.2-sol-failover 128K\n'; exit ;;
        --session-id) session=$2; shift ;;
        --session-dir) dir=$2; shift ;;
        --) text=$2; break ;;
    esac
    shift
done
[ -n "$session" ] && [ "$dir" = "$(dirname "$PWD")/sessions" ] && [ -n "$text" ] || exit 3
mkdir -p "$dir"
file="$dir/test_$session.jsonl"
if [ ! -f "$file" ]; then
    printf '{"type":"session","id":"%s","cwd":"%s"}\n' "$session" "$PWD" > "$file"
    printf '{"type":"session_info","id":"title","name":"Weather Forecast Test"}\n' >> "$file"
fi
printf '%s\n' "$session"
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
swiftc Sources/{PiTurn,PiModel,ProcessRunner,Recognition,Conversations,Transcript}.swift Tests/ConversationLifecycleTests.swift -o "$tmp/lifecycle-tests"
"$tmp/lifecycle-tests" "$tmp"
swiftc Sources/Hotkey.swift Tests/HotkeyTests.swift -o "$tmp/hotkey-tests"
"$tmp/hotkey-tests"
swiftc Sources/{Hotkey,PiModel,SettingsWindow}.swift Tests/SettingsTests.swift -o "$tmp/settings-tests" -framework AppKit -framework Carbon
"$tmp/settings-tests"
swiftc Sources/FloatingOverlay.swift Tests/OverlayTests.swift -o "$tmp/overlay-tests" -framework AppKit
"$tmp/overlay-tests"
swiftc Sources/{ChatWindow,Conversations,Transcript}.swift Tests/ChatWindowTests.swift -o "$tmp/chat-tests" -framework AppKit
"$tmp/chat-tests"
swiftc Sources/Transcript.swift Tests/TranscriptTests.swift -o "$tmp/transcript-tests"
"$tmp/transcript-tests"
