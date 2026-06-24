# PadKey

PadKey is a native macOS voice workspace combining the complete PadKey sensor Studio with hold-to-talk dictation, local speech models, optional AI polish, Mac actions, and universal text insertion.

It is designed for the awkward part of voice typing on macOS: getting polished text back into the app you were already using, and keeping a saved transcript when insertion fails.

## What it does

- Holds recording while fn is pressed, with Option-Space as a toggle fallback.
- Shows a floating bottom Flow Bar with dictation, polish, Scratchpad, and Hub controls.
- Streams live local captions with `sherpa-onnx` when set up.
- Transcribes speech offline with local `whisper.cpp` when set up.
- Can run optional Mega-ASR through CrispASR/GGUF as a robust retry for suspicious transcripts.
- Falls back to Apple's Speech framework if the local Whisper binary/model is missing.
- Cleans common filler words and spoken punctuation.
- Inserts the final transcript into the text field that was active when recording started.
- Uses layered insertion: Accessibility selected text, Accessibility value range, current focus retry, System Events paste, global keyboard typing, targeted keyboard typing, then clipboard paste with pasteboard restoration.
- Logs the insertion strategy, target app, latency, ASR engine, polish provider, and fallback reason for each dictation.
- Stores the optional Gemini API key in macOS Keychain and shows masked API key usage details in Settings.
- Provides a local Mac Action agent for Notes, FaceTime preparation, browser tasks, and generic accessible fields and buttons.
- Requires confirmation before consequential actions such as beginning a FaceTime call.
- Embeds PadKey Studio as the default native workspace with USB, BLE, Wi-Fi, editing, transcription, training, and export.
- Uses a native CoreBluetooth and USB serial bridge so all three hardware sensors remain available inside the Mac app.

## Privacy model

- Dictation history is stored locally on your Mac.
- Local speech recognition works without sending audio to a cloud service after the local models are installed.
- Gemini polish is optional and only runs when you add an API key.
- Optional API keys are stored in the macOS Keychain, not in the repository.
- Generated app bundles, downloaded models, local diagnostics, and personal app data are ignored by git.

## Set up local speech

```bash
git clone https://github.com/StellarLyyd/PadKey.git
cd PadKey/macos/PadKey
./script/setup_sherpa.sh
./script/setup_whisper.sh
./script/build_and_run.sh
```

Sherpa-ONNX powers live local captions while you speak. Whisper powers the fast final transcript after you release the hotkey. The default Pipeline mode is **Auto Robust**: Sherpa + Whisper first, with Mega-ASR retry only when the transcript looks empty or low-confidence.

The Whisper setup script clones `whisper.cpp`, builds `whisper-cli`, and downloads the `large-v3-turbo` ggml model. You can choose another model:

```bash
./script/setup_whisper.sh tiny.en
./script/setup_whisper.sh small.en
```

The Sherpa setup script downloads the current macOS `sherpa-onnx` release plus the small English streaming Zipformer model. To use another streaming model:

```bash
SHERPA_MODEL_NAME=sherpa-onnx-streaming-zipformer-en-2023-06-26 ./script/setup_sherpa.sh
```

Mega-ASR is optional because the recommended GGUF model is large. Install it only if you want a stronger local fallback for noisy, whispered, or degraded audio:

```bash
./script/setup_mega_asr.sh
```

That script builds `CrispStrobe/CrispASR` and downloads `cstr/mega-asr-GGUF/mega-asr-1.7b-q4_k.gguf`. The app bundle includes Mega-ASR resources only when `Support/MegaASR` exists.

## Run it

```bash
cd PadKey/macos/PadKey
./script/build_and_run.sh
```

The run script builds, signs, installs, and launches PadKey from:

```text
~/Applications/PadKey.app
```

That stable app path matters. macOS Privacy permissions attach to the signed app bundle, so running from a changing build or `dist/` path can make universal insertion appear broken even when transcription works.

The app appears in the Dock and menu bar as `pad`. Hold fn, or press Option-Space, speak, then release fn or press Option-Space again to insert the text into the field that was active when recording started.

Use the Hub's Pipeline tab to inspect recent sessions. It shows the target app, recognition engine, insertion strategy, Mega retry usage, and insertion latency.

Open **Mac Control** in the sidebar or use Studio's **Advanced → Mac control** panel. The combined app exposes a loopback-only API at `http://127.0.0.1:8789`, leaving OwoFlow's standalone `8788` endpoint independent. Check `GET /health` and `GET /permissions`, submit `POST /command`, and complete approved actions with `POST /confirm`.

Open the Hub or Settings directly while developing:

```bash
./script/build_and_run.sh --hub
./script/build_and_run.sh --settings
./script/build_and_run.sh --insertion-self-test
```

The insertion self-test opens a small TextEdit file and writes a JSON result to `~/Library/Application Support/PadKey/insertion-self-test.json`. Use it when dictation captures speech but text is not landing in other apps.

## Development checks

Before opening a pull request, run:

```bash
swift test
swift build -c release --product padkey
bash -n script/build_and_run.sh script/setup_whisper.sh script/setup_sherpa.sh script/setup_mega_asr.sh
```

GitHub Actions runs the same SwiftPM test and release build on macOS.

## Permissions

PadKey needs:

- Microphone, for audio input.
- Speech Recognition, for transcription.
- Accessibility, to insert text into other apps.
- Input Monitoring, to detect the global fn/Globe shortcut.
- Bluetooth, to receive all three PadKey sensor channels wirelessly.
- Local Network, when connecting to PadKey over Wi-Fi.

Use the menu-bar item and choose `Request Permissions` or `Open Privacy Settings` if macOS does not prompt automatically.

Enable the exact app at `~/Applications/PadKey.app` in:

- System Settings > Privacy & Security > Accessibility.
- System Settings > Privacy & Security > Input Monitoring.

If PadKey appears more than once, remove or ignore stale entries that point to old build locations, then quit and reopen PadKey. The run script automatically prefers the local Apple Development identity when available because macOS privacy permissions can become stale when an app is rebuilt with changing ad-hoc signatures.

## Cross-app QA checklist

After insertion changes, verify at least:

- Codex input field: click the composer, hold fn, release, confirm text lands in the composer.
- Browser editors: Safari, Chrome, ChatGPT, Gmail, and common textareas.
- Native editors: Notes and TextEdit.
- Work apps: Slack or Discord.
- Code editors: Cursor or VS Code.
- Failure path: click outside an editable field, dictate, confirm the transcript is saved in Home with a clear saved-only status.

Check Pipeline after each run. A healthy run should show either direct AX insertion or clipboard fallback with the previous pasteboard restored.

## Notes

This build intentionally avoids copying GPL code from VoiceInk. It is an original Swift implementation of a system-wide dictation flow, with local Whisper powered by the MIT-licensed `whisper.cpp` project.

## License

PadKey is released under the MIT License. See [LICENSE](LICENSE).
