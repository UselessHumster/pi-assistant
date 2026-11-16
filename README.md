# Pi Voice Assistant

A macOS menu-bar push-to-talk assistant. Hold **Ctrl+Option+Space**, speak, and release Space, Ctrl, or Option to stop. A non-activating floating overlay shows the live microphone level, transcription and thinking status, recognized speech, and a response preview. Click a completed response to open the full selectable transcript and response; the success overlay disappears after five seconds, and **Show Last Response** in the menu remains available. Errors stay visible; click them for details. The shortcut is passed through to other apps. Only one request runs at a time.

## Requirements

- macOS 12 or later, Xcode command-line tools (`xcode-select --install`), Swift and `codesign`.
- A local recognition engine: either [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `whisper-cli` and a compatible model, or [GigaAM](https://github.com/salute-developers/GigaAM) and its Python dependencies (see below).
- [pi](https://github.com/earendil-works/pi) CLI installed and already configured/authenticated for a model. Test `pi --print --no-session -- "Hello"` in a terminal first. Provider use may incur costs. Configure any optional skills and their credentials separately; this app does not set them up.

## Build and run

```sh
./scripts/build.sh
open "build/Pi Voice Assistant.app"
```

The build is ad-hoc signed, not notarized. Keep the app at a stable path; rebuilding or moving it may require re-granting permissions. Click the microphone menu icon → **Configure…**, and enter absolute paths to `whisper-cli`, the model file, `pi`, and an existing Pi working directory. For example, locate executables with `command -v whisper-cli` and `command -v pi`. The default pi path is `/opt/homebrew/bin/pi` (change it for Intel or other installations). The working directory defaults to your home directory; choose a trusted project directory if appropriate. Existing saved settings are preserved. Pi uses this directory for project resource discovery; configured global user skills can also be discovered. Project-local resources may depend on Pi's trust settings. Settings are stored in macOS user defaults. Save validates the selected engine's required files, executable permissions, and the Pi working directory; inactive engine settings are retained.

In **Configure…**, click the shortcut button and press the desired key combination, then select hold or toggle mode. Press Escape to cancel recording (Escape itself cannot be recorded); modifier keys alone are not accepted. Modifiers must match exactly; the shortcut still passes through to other apps. Settings persist across launches. Changing settings while recording stops and submits the recording. A shortcut without modifiers can interfere with normal typing.

Grant Accessibility when prompted for the global hotkey. After enabling it in System Settings → Privacy & Security → Accessibility, the app automatically retries; **Retry Hotkey Permission** also retries manually. Depending on macOS, Input Monitoring permission may also be required; relaunch if needed. On first hold, grant microphone access in the system prompt, then hold Ctrl+Option+Space again. If denied, enable Microphone in Privacy & Security. The app does not have a Dock icon; quit from its menu.

## Local GigaAM recognition

Install GigaAM into a dedicated Python environment following the [upstream installation instructions](https://github.com/salute-developers/GigaAM). For example, on Apple Silicon with Python 3.11:

```sh
brew install ffmpeg
python3.11 -m venv ~/.venvs/pi-gigaam
~/.venvs/pi-gigaam/bin/pip install 'torch==2.11.0' 'torchaudio==2.11.0'
~/.venvs/pi-gigaam/bin/pip install 'git+https://github.com/salute-developers/GigaAM.git' 'transformers==4.57.1' 'pyannote.audio==4.0.7'
~/.venvs/pi-gigaam/bin/pip check
```

Use compatible Python and PyTorch versions for your platform; model and dependency downloads require network access and can be large. The upstream package does not itself install PyTorch. The pinned Hugging Face model code imports `pyannote.audio` even for short audio; its dependencies and platform requirements are substantial. The above combination was tested with Python 3.11 on Apple Silicon.

In **Configure…**, set the recognition engine to `gigaam`, Python to the absolute path of the venv's `bin/python`, and the model name to an upstream-supported short-audio model (default `v3_e2e_rnnt`). The default uses the official [ai-sage/GigaAM-v3](https://huggingface.co/ai-sage/GigaAM-v3) Hugging Face model, pinned to commit `7655ad717f8122257385bb4b2f373db3697e8680` (the `e2e_rnnt` revision). It requires `transformers` and executes the repository's Python code (`trust_remote_code=True`): pinning prevents silent upstream changes but does not sandbox that code or make model weights safe. Trust the publisher and protect the local cache. Other model names continue through GigaAM's upstream loader and download source; there is no automatic fallback if the default fails.

Optionally set an absolute model cache directory: it is passed as the Hugging Face cache directory for the default, or as GigaAM's download root for other models. Without it, the respective library's default cache is used. Hugging Face may also use its default cache for auxiliary files and remote code. On first use model files may be downloaded; later recognition runs locally with cached files. Each recording starts a new Python process and loads the model, so startup can be slow. Select `whisper` to retain the existing whisper.cpp configuration. The engine interface in `Sources/main.swift` allows other implementations to be added.

Recordings up to 24 seconds use `transcribe` directly. Longer 16-bit mono PCM WAV recordings are split locally into at most 24-second chunks, choosing the quietest 100 ms window in the last four seconds of each chunk. Chunks are transcribed sequentially and their text joined; temporary chunk files are removed on normal completion or errors. This requires no gated VAD model or `HF_TOKEN` (the pinned model still imports the pyannote package). A crash or forced termination can leave `pi-voice-chunks-*` temporary directories.

This energy heuristic is not speech detection: noise or continuous speech can cause cuts inside words, silence may produce hallucinated text, and independent chunks lose context and may degrade accuracy. There is no overlap or deduplication, timestamps or speaker identification. Long recordings increase latency; inference errors are reported rather than silently falling back.

## Privacy and safety

Audio is recorded as 16 kHz mono WAV in a randomly named, owner-only temporary directory and transcribed locally by the selected engine (GigaAM may download weights on first use). The transcript is sent to the configured pi provider, which may be remote; review that provider's privacy policy. The app invokes pi directly (not through a shell) in the configured working directory, with Pi's default tool selection and discovered/configured skills enabled. Defaults normally include read, bash, edit and write, but Pi settings can change them. Pi can read and modify files, run commands, access the network and credentials available to the user, and use configured skill scripts. Extensions, MCP, prompt templates and context files are disabled; provider configuration and persistent Pi sessions still apply. Transcripts are passed as process arguments and may be visible to other processes running as your user. Temporary audio, transcript and captured process output are removed on normal completion on a best-effort basis; an app crash, forced termination or cleanup failure can leave `pi-voice-*` directories in the system temporary directory. Pi session history is separate and persists; see [Persistent session privacy](SESSION_PRIVACY.md). The last response remains in memory until replaced or the app exits. Do not use for secrets or sensitive speech without accepting these limitations.

A system-prompt instruction asks Pi to ask before potentially harmful actions outside the clear request and to treat external content as untrusted. **This is not a security boundary**: the model can ignore it or be misled by prompt injection in skill instructions, files, web content, or tool output. Tools are not sandboxed or gated by an approval dialog. Review and trust the working directory, discovered skills and Pi configuration, and run with only the account permissions you accept. A clearly requested external action may be performed immediately.

The normal shortcut continues the selected dialog while it is active; closing or automatically dismissing a response marks the next normal turn as a new dialog. The optional new-dialog shortcut always creates a fresh session. The optional previous-dialog shortcut switches to the immediately preceding selected session (repeating it switches back); if no preceding selection is known, it continues the current session. Selection history is per working directory and is recorded from this version onward; old catalogs have no preceding selection until another session is selected. Optional shortcuts are disabled by default. The built-in normal default is Ctrl+Option+Space in hold mode; saved settings override it.

Pi runs each recording in one-shot print mode with stdin closed, so it cannot receive an interactive answer while that invocation is running. If it asks a question, the response preview and response window show it; answer in a later recording to continue the selected persistent session. The menu's **Session** submenu lets you create a named session or select an existing one for the configured working directory. The selection and session IDs persist across app restarts; changing working directory selects that directory's separate session catalog. Starting or selecting another session does not delete earlier history. **Show Conversation History** displays user and assistant text for the selected session's active branch; tool output, tool calls and thinking are omitted. The history itself can contain sensitive information: it is shown on screen without redaction. **Send Typed Follow-up…** sends text to the same selected session; close the floating overlay to abort an in-flight request. Typed text, like speech transcripts, is passed in process arguments. Follow-ups depend on Pi successfully resuming the selected session and may need repeated context if it cannot. History is read on demand and does not automatically refresh; reopen it after a response.

The app trusts the configured executables and model; only use paths you trust. Click × at any stage to cancel recording, transcription, or Pi processing. Cancellation cannot undo actions Pi has already performed, and processes that leave their process group may survive; check for remaining children if needed. Requests have no automatic timeout. No automatic speech playback, streaming, or concurrency is included.

## Troubleshooting

Errors remain in the floating overlay; click it or choose **Show Last Response** for details, or click × to dismiss the overlay. For GigaAM, verify the configured Python environment has the dependencies above, the model name is supported, FFmpeg is installed and the cache is writable. Downloads use normal TLS verification; fix certificate or network problems rather than disabling verification. Verify model compatibility and permissions, test `whisper-cli -m /path/to/model -f /path/to/audio.wav -otxt -of /tmp/test`, and verify pi authentication in Terminal. GUI apps may have a different environment from your shell; pi must be able to find its runtime and credentials without shell initialization. The child PATH includes Homebrew and standard system locations. Ctrl+Option+Space can conflict with another shortcut. Re-enable permissions after rebuilding if the event tap cannot start.
