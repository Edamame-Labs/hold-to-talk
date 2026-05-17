# CLAUDE.md

## Project Overview

Hold To Talk is a macOS hold-to-talk dictation app with Dock presence and a menu bar status control. Hold a hotkey, speak, release, and transcribed text is inserted into the active app. Local by default with optional bring-your-own-key cloud transcription (OpenAI) and text cleanup (OpenAI, Anthropic).

## Tech Stack

- **Swift 6** (language mode v5), **SwiftUI**, **SwiftPM** (no Xcode project)
- **sherpa-onnx** (Next-gen Kaldi) for speech recognition, downloaded at build time into `Frameworks/`
- **NVIDIA Parakeet TDT 0.6B** (int8 quantized, ~640MB) downloaded at runtime
- **Silero VAD** for voice activity detection, bundled as `Resources/silero_vad.onnx`
- **Apple Intelligence** (Foundation Models, macOS 26+) for optional text cleanup
- **Sparkle** for auto-updates (excluded from `APP_STORE=1` builds)

## Commands

```bash
make setup                         # Download sherpa-onnx xcframework (auto-runs before build/run)
swift build                        # Debug build (requires setup first)
swift build -c release             # Release build
swift test                         # Run all tests

make build                         # Release build + assemble .app bundle
make run                           # Debug build + assemble .app + open
make install                       # Release build + install to /Applications
make release                       # Sign, notarize, package zip + dmg
make test-reset                    # Kill app, remove installs, delete all data, reset permissions (needs sudo for TCC)
make permissions-reset             # Reset TCC permissions only (needs sudo)
tccutil reset Microphone com.holdtotalk.app    # Reset single TCC permission without sudo
tccutil reset Accessibility com.holdtotalk.app
tccutil reset ListenEvent com.holdtotalk.app
```

### Debug flags (DEBUG builds only)

```bash
swift run HoldToTalk -- --reset-onboarding              # Wipe state, show onboarding
swift run HoldToTalk -- --onboarding-step 2              # Jump to model download step
swift run HoldToTalk -- --skip-permissions                # Pretend all permissions granted
```

`make run` produces a debug build, so the "Skip Permissions (Debug)" button is available in onboarding.

## Architecture

### Dictation Pipeline

```
HotkeyManager (global hotkey press/release)
  -> AudioRecorder (AVAudioEngine, 16kHz mono float buffer)
    -> Transcriber (local: Silero VAD + sherpa-onnx) OR CloudTranscriber (OpenAI API, BYO key)
      -> TextCleanup (Apple Intelligence) OR CloudTextCleanup (OpenAI/Anthropic, BYO key)
        -> TextInserter (CGEvent unicode or clipboard paste)
          -> active app
```

Orchestrated by `DictationEngine` with states: `idle` -> `recording` -> `transcribing` -> `idle`

### Text Cleanup (Apple Intelligence)

`TextCleanup.swift` provides optional post-transcription cleanup via Foundation Models:
- Guarded with `#if canImport(FoundationModels)` (compile-time) and `@available(macOS 26, *)` (runtime)
- Checks `SystemLanguageModel.default.availability` for device eligibility
- ON by default when Apple Intelligence is available; gracefully unavailable otherwise
- User-configurable system prompt (editable in Settings, stored in UserDefaults)
- 3-second timeout via task group race; returns original text on failure
- Strips leaked XML tags from model output as safety net

### Cloud Transcription and Cleanup (BYO Key)

`CloudTranscriber.swift` sends audio to an OpenAI-compatible `/audio/transcriptions` endpoint. `CloudTextCleanup.swift` sends text to OpenAI or Anthropic chat/messages APIs. Both use user-provided API keys stored in the macOS Keychain (`KeychainHelper.swift`). When using OpenAI for both transcription and cleanup, cleanup instructions are folded into the transcription prompt to reduce latency. Hold to Talk never proxies or stores API keys or data server-side.

### Text Insertion

`TextInserter` selects strategy by target app bundle ID:
- **Electron/browser apps** (VS Code, Slack, Chrome, etc.): clipboard paste (CGEvent causes doubled text)
- **Native apps**: direct CGEvent with UTF-16 (no clipboard pollution)

### Key Concurrency Patterns

- `@MainActor` on `DictationEngine` and all SwiftUI views
- `actor` on `Transcriber` for thread-safe model access
- `Sendable` with NSLock on `AudioRecorder` for cross-actor buffer access

## Build Variants

| Command | Build | Entitlements | Sparkle | Signing |
|---------|-------|-------------|---------|---------|
| `make run` | Debug | `.dev.entitlements` | Yes | Ad-hoc (`-`) |
| `make build` | Release | `.dev.entitlements` | Yes | Ad-hoc (`-`) |
| `SIGNING_IDENTITY="..." make build` | Release | `.direct.entitlements` | Yes | Developer ID |
| `APP_STORE=1 make build` | Release | `.entitlements` | No | App Store |

## Conventions

- No force unwraps except on hardcoded URL literals and `applicationSupportDirectory`
- Model init uses failable initializers (returns nil on corrupt model, no crash)
- Resources declared as `.copy()` in Package.swift, accessed via `Bundle.module`
- UserDefaults keys are top-level `let` constants in `OnboardingResetHelper.swift`
- Diagnostic logging redacts transcript text (shows char/word count only)

## Troubleshooting

- **Permissions not auto-detecting**: `CGPreflightPostEventAccess()` caches per-process. Ad-hoc builds get new code identity each rebuild. Use "Skip Permissions (Debug)" button in debug builds, or relaunch for release builds with stable signing. To manually reset permissions without sudo, run `tccutil reset <service> com.holdtotalk.app` (services: `Microphone`, `Accessibility`, `ListenEvent`).
- **Wrong app instance launches**: macOS may open `/Applications/Hold To Talk.app` instead of debug build. Run `make test-reset` first.
- **Sparkle framework not found**: Binary needs `@loader_path/../Frameworks` rpath. `make build`/`make run` handle this; manual `swift build` does not assemble the .app bundle.
- **Model download fails**: Recognizer init returns nil and shows error. Delete model via Settings and re-download.
