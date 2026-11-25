# Pi Voice Assistant

A macOS menu-bar push-to-talk assistant. Hold **Ctrl+Option+Space**, speak, and release Space, Ctrl, or Option to start a **new** conversation. A floating indicator shows recording, transcription and Pi status. Choose **Open Chat** on the indicator or in the menu bar to view the full response and continue. The chat window stays open until you close it.

## Requirements

- macOS 12 or later, Xcode command-line tools (`xcode-select --install`), Swift and `codesign`.
- A local recognition engine: either [whisper.cpp](https://github.com/ggml-org/whisper.cpp) `whisper-cli` and a compatible model, or [GigaAM](https://github.com/salute-developers/GigaAM) and its Python dependencies (see below).
- [Pi](https://github.com/earendil-works/pi) CLI 1.6.0 or compatible, configured and authenticated for your model. The default is `router/6.2-sol-failover`, registered by `~/.pi/agent/extensions/6.2-failover.ts` (or under `PI_CODING_AGENT_DIR`). That extension and its backing models/credentials are local Pi configuration, not bundled. In **Configure… → Pi model**, choose Sol or Astra failover, enter another `provider/model` ID, or choose **Use Pi/session default**. Provider use may incur costs.

## Build and run

```sh
./scripts/build.sh
open "build/Pi Voice Assistant.app"
```

The build is ad-hoc signed, not notarized. Keep the app at a stable path; rebuilding or moving it may require re-granting permissions. Click the microphone menu icon → **Configure…**, and enter absolute paths to `whisper-cli`, the model file, `pi`, and an existing Pi working directory. For example, locate executables with `command -v whisper-cli` and `command -v pi`. The default pi path is `/opt/homebrew/bin/pi` (change it for Intel or other installations). The working directory defaults to your home directory; choose a trusted project directory if appropriate. Existing saved settings are preserved. Pi uses this directory for project resource discovery; configured global user skills can also be discovered. Project-local resources may depend on Pi's trust settings. Settings are stored in macOS user defaults. Save validates the selected engine's required files, executable permissions, and the Pi working directory; inactive engine settings are retained.

In **Configure…**, click the shortcut button and press the desired key combination, then select hold or toggle mode. Press Escape to cancel recording (Escape itself cannot be recorded); modifier keys alone are not accepted. Modifiers must match exactly; the shortcut still passes through to other apps. Settings persist across launches and can be changed between turns. A shortcut without modifiers can interfere with normal typing.

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

Audio is recorded as 16 kHz mono WAV in a randomly named, owner-only temporary directory and transcribed locally by the selected engine (GigaAM may download weights on first use). The transcript is sent to the configured pi provider, which may be remote; review that provider's privacy policy. The app invokes pi directly (not through a shell) in the configured working directory, with Pi's default tool selection and discovered/configured skills enabled. Defaults normally include read, bash, edit and write, but Pi settings can change them. Pi can read and modify files, run commands, access the network and credentials available to the user, and use configured skill scripts. Automatic extension discovery, MCP, prompt templates and context files are disabled. The app only loads its bundled title extension and the local `6.2-failover.ts` if installed. The title extension makes a separate model request using excerpts of recent user messages from unnamed conversations. Transcripts are passed as process arguments and may be visible to other processes running as your user. Temporary audio, transcript and captured process output are removed on normal completion on a best-effort basis; an app crash, forced termination or cleanup failure can leave `pi-voice-*` directories in the system temporary directory. Pi session history is separate and persists; see [Persistent session privacy](SESSION_PRIVACY.md). The last response remains in memory until replaced or the app exits. Do not use for secrets or sensitive speech without accepting these limitations.

A system-prompt instruction asks Pi to ask before potentially harmful actions outside the clear request and to treat external content as untrusted. **This is not a security boundary**: the model can ignore it or be misled by prompt injection in skill instructions, files, web content, or tool output. Tools are not sandboxed or gated by an approval dialog. Review and trust the working directory, discovered skills and Pi configuration, and run with only the account permissions you accept. A clearly requested external action may be performed immediately.

The global shortcut always starts a new conversation after speech is recognized. To continue one, open **Open Chat**, search the left sidebar by title or first-message preview, then type a message or use **Record**. In the chat window, **⌘F** focuses search, **⌘N** opens a new chat, and **⌘Return** sends a message. Return inserts a newline. **+ New Chat** opens a fresh conversation without the global shortcut. The menu bar's **Conversations** submenu shows the same titles and lets you select a conversation.

Pi runs each turn in one-shot print mode with stdin closed. After a successful turn in an unnamed conversation, the title extension tries to save a name of up to three words. Existing names are preserved; a naming failure leaves the placeholder and can be retried on the next turn. The catalog and selected session persist across restarts per working directory. History shows only user and assistant text from the active branch, omitting tool calls, tool results and thinking. Closing the chat does not cancel a turn; use **Cancel** while a turn runs, or close the in-flight voice indicator.

The app trusts the configured executables and model; only use paths you trust. Click × at any stage to cancel recording, transcription, or Pi processing. Cancellation cannot undo actions Pi has already performed, and processes that leave their process group may survive; check for remaining children if needed. Requests have no automatic timeout. No automatic speech playback, streaming, or concurrency is included.

## Troubleshooting

Choose **Open Chat** for error details, or click × to dismiss the voice indicator. For GigaAM, verify the configured Python environment has the dependencies above, the model name is supported, FFmpeg is installed and the cache is writable. Downloads use normal TLS verification; fix certificate or network problems rather than disabling verification. Verify model compatibility and permissions, test `whisper-cli -m /path/to/model -f /path/to/audio.wav -otxt -of /tmp/test`, and verify pi authentication in Terminal. GUI apps may have a different environment from your shell; pi must be able to find its runtime and credentials without shell initialization. The child PATH includes Homebrew and standard system locations. Ctrl+Option+Space can conflict with another shortcut. Re-enable permissions after rebuilding if the event tap cannot start.
