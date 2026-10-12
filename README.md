# Whistle Flow

A [Wispr Flow](https://wisprflow.ai)-style dictation app for macOS that runs entirely on your Mac, using
[Whistle](https://cactuscompute.com/blog/whistle), Cactus Compute's 16.9 MB open speech model (Apache-2.0).

Hold **Fn**, speak, release. The text is cleaned up and pasted into whatever app has focus.
Audio never leaves the machine and there is no account or API key.

## Use it

| Action | What happens |
| --- | --- |
| Hold **Fn**, speak, release | Push-to-talk: transcribes and pastes on release |
| Hold **Fn**, tap **Space** | Hands-free: keep talking with the key released; press **Fn** again (or the pill's ■) to finish |
| **Esc** while recording | Cancel |
| Say "new line" / "new paragraph" | Line or paragraph break |
| Menu bar icon → Recent | Re-copy an earlier dictation |

You can change the key to right ⌥, right ⌘ or right ⌃ in Settings.

Settings also has:
- **Dictionary**: names and jargon, passed to Whistle as keyword biasing so it prefers your spellings.
- **Snippets**: say a trigger phrase ("my calendar link") and the expansion is typed instead.
- **Microphone**: "Automatic" uses the built-in mic when the system default is a Bluetooth headset. Bluetooth mics
  take a second or two to switch on each time recording starts, which loses short dictations, and they drop your
  audio to call quality while recording.
- **Language**: English by default. Whistle also does German, French, Spanish, Italian, Dutch and Polish, or auto-detect.
- **Formatting**: filler-word removal (um, uh, erm…), voice commands, and smart spacing when you continue a sentence.
- **History**: stored locally in `~/Library/Application Support/WhistleFlow/history.json`.

## Build

Requires Apple silicon and Xcode command line tools.

```sh
./build.sh          # build/WhistleFlow.app
./build.sh run      # build and launch
./build.sh install  # copy to /Applications and launch
```

The first build downloads the model (`whistle.cact`) and the static engine (`libneedle.a`, `needle.h`) from
Hugging Face into `vendor/`. They're linked statically, so the app is one ~2 MB binary plus the model.

### First launch

1. Allow **Microphone** access.
2. Allow **Accessibility** (System Settings → Privacy & Security). The app needs it to see the dictation key and paste.
3. If you use Fn, set **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**. Otherwise Fn also opens
   the emoji picker or switches the input source.

The build is ad-hoc signed, so macOS treats every rebuild as a new app. An old Accessibility toggle can stay
"on" in System Settings without applying to the new build, so `build.sh` resets it and the app asks again on
launch. The menu bar icon has a slash through it until the permission is in effect. To keep permissions across
rebuilds, build with a real signing identity: `SIGN_IDENTITY="Apple Development: …" ./build.sh`.

## How it works

```
Fn down ─► AVCaptureSession ─► 16 kHz mono ─┬─► Whistle stream, 1 s chunks ─► live preview (and transcript if > 30 s)
                                         └─► buffer
Fn up ──► ≤ 30 s: one Whistle pass over the whole clip (≈50–150 ms) ─► cleanup ─► paste (⌘V) ─► restore clipboard
```

| File | Role |
| --- | --- |
| `Sources/WhistleEngine.swift` | Swift wrapper over the Needle C API (`needle_transcribe`, `needle_stream_transcribe_*`) |
| `Sources/DictationController.swift` | Press → record → transcribe → paste state machine |
| `Sources/HotkeyMonitor.swift` | CGEvent tap for Fn / right-modifier, Space (hands-free) and Esc |
| `Sources/AudioRecorder.swift` | Microphone capture (AVCaptureSession) as 16 kHz mono |
| `Sources/AudioDevices.swift` | Input device list, and the built-in-over-Bluetooth choice |
| `Sources/TextCleaner.swift` | Filler removal, voice commands, snippets |
| `Sources/Paster.swift` | Paste via ⌘V, clipboard restore, Accessibility caret lookup for smart spacing |
| `Sources/Overlay.swift` | Floating pill with waveform and live transcript |
| `Sources/SettingsView.swift` | Settings window (SwiftUI) |

On an M-series Mac, Whistle transcribes an 8.5 s clip in about 50 ms. A 37 s dictation was ready about
120 ms after the key was released.

### Testing without a microphone

```sh
B=build/WhistleFlow.app/Contents/MacOS/WhistleFlow
$B --transcribe clip.wav                # engine timings: one-shot and streaming
$B --clean "Um, so, uh, new paragraph"  # cleanup rules only
$B --list-mics                          # input devices, and which one "Automatic" picks
$B --mic-check auto --seconds 4         # record from a mic, print levels and what Whistle heard
open build/WhistleFlow.app --args --simulate clip.wav   # whole app, file played as if spoken
```

The app writes a log to `~/Library/Logs/WhistleFlow.log`, including which mic each dictation used and how
loud it was. A peak below about -50 dBFS means the mic heard nothing.

## Not included (yet)

Wispr Flow's LLM features (tone rewriting, "command mode", context-aware formatting) need a language model.
Whistle is speech-to-text only.
