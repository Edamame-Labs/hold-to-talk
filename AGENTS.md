# AGENTS.md

Instructions for AI/code agents working in this repository.

## What this is

Hold To Talk: a macOS hold-to-talk dictation app. Hold a hotkey, speak, release — the recording is transcribed, optionally cleaned up, and inserted into the previously active app.

Hard constraints:

- **SwiftPM package. No `.xcodeproj` or `.xcworkspace` — never add one.**
- macOS 15+ and Apple Silicon only.
- Local transcription is the default. Cloud is opt-in with the user's own provider keys; requests go directly from the app to OpenAI-compatible or Anthropic endpoints. There are no Hold To Talk servers.
- Privacy-sensitive data stays out of diagnostics: transcript text is redacted in logs, API keys live only in Keychain.

## Setup and daily commands

```bash
make setup    # one-time: download sherpa-onnx xcframework into Frameworks/ (make build/run call it; needed once before raw swift build)
swift build   # debug build
swift test    # full test suite — run before handing off any non-docs change
make run      # debug .app bundle + launch; enables debug onboarding controls (e.g. Skip Permissions)
make build    # release build + assemble .build/Hold To Talk.app
```

Less common: `make install` (copy to `/Applications`), `make verify` (codesign/spctl check), `make package` (direct-distribution zip+dmg), `make release` (sign, notarize, package), `make clean`.

Debug-only launch flags (combinable):

```bash
swift run HoldToTalk -- --reset-onboarding --onboarding-step 3 --skip-permissions
```

## Repo map

```text
Package.swift                  SwiftPM targets, Sparkle conditional dependency
Makefile                       Build, app assembly, signing, packaging, reset helpers
Sources/HoldToTalk/            Main macOS app (SwiftUI/AppKit)
Sources/HoldToTalk/Resources/  SwiftPM-copied runtime resources (silero_vad.onnx)
Sources/TranscribeCmd/         CLI tool for transcription experiments/evaluation
Tests/HoldToTalkTests/         Unit tests (XCTest + Swift Testing)
Resources/                     App bundle resources, entitlements, Info.plist, icons, privacy manifest
scripts/setup-sherpa-onnx.sh   Downloads/prepares sherpa-onnx xcframework
scripts/reset-fresh-test.sh    Removes installs/state and resets permissions
scripts/package-dmg.sh         Direct-distribution DMG packaging
evaluation/                    Manual WER/evaluation helpers
docs/                          GitHub Pages site (holdtotalk.ai), appcast, privacy page, enterprise docs
Casks/holdtotalk.rb            Template used by release workflow for Homebrew tap
.github/workflows/             CI, direct release, App Store upload
```

Never commit: `.build/`, `Frameworks/`, `dist/`, app bundles, `demo-video/` dependencies/output, `evaluation/test_data/` artifacts, `.DS_Store`.

## Architecture

Main dictation path:

```text
HotkeyManager
 -> DictationEngine.beginRecording()
 -> AudioRecorder.start()
 -> DictationEngine.endRecording()
 -> AudioRecorder.stop() -> 16 kHz mono Float audio
 -> Transcriber OR CloudTranscriber
 -> TextCleanup OR CloudTextCleanup
 -> TextInserter
 -> target app
```

File responsibilities:

- `HoldToTalkApp.swift`: app scene, menu bar status, onboarding/settings windows, install prompt, launch-at-login migration, Sparkle wiring.
- `DictationEngine.swift`: main `@MainActor` pipeline state machine (`idle -> recording -> transcribing -> idle`), permission snapshots, hotkey lifecycle, transcriber warmup.
- `HotkeyManager.swift`: Carbon hotkeys for regular shortcuts; AppKit modifier monitoring for bare modifier keys.
- `AudioRecorder.swift`: AVAudioEngine capture, level callback, resampling to 16 kHz mono, buffer zeroing after use.
- `Transcriber.swift`: local sherpa-onnx recognizer, Silero VAD segmentation, silence trimming, normalization, repeated-phrase cleanup, profile selection, hotwords.
- `CloudTranscriber.swift`: OpenAI-compatible `/audio/transcriptions` request using user key and configurable HTTPS base URL.
- `TextCleanup.swift`: optional Apple Intelligence cleanup guarded by `canImport(FoundationModels)` and macOS availability; returns original text on failure/timeout.
- `CloudTextCleanup.swift`: OpenAI chat completions or Anthropic messages cleanup; failures fall back to original text.
- `CloudProvider.swift`: cloud URL validation and ephemeral `URLSession`.
- `TextInserter.swift`: secure-input checks, target app strategy, CGEvent Unicode insertion or clipboard paste.
- `ModelManager.swift`: model download, checksum validation, extraction, delete/status.
- `OnboardingView.swift`: install/permissions/model/cloud/hotkey wizard.
- `SettingsView.swift`: provider/key/model/hotkey/cleanup/update/logging controls.
- `SystemSettingsHelper.swift`: microphone/post-event permission helpers and stable-code-identity behavior.
- `OnboardingResetHelper.swift`: UserDefaults keys and fresh onboarding reset state.
- `DebugLog.swift`: local diagnostic logging with transcript redaction and 1 MB truncation.
- `KeychainHelper.swift`: API key storage under service `com.holdtotalk.apikeys`, accounts `openai` and `anthropic`.

Tech notes: `swift-tools-version: 6.0` with `swiftLanguageMode(.v5)`. Local ASR is sherpa-onnx (`Frameworks/sherpa_onnx.xcframework`) running NVIDIA Parakeet TDT 0.6B v2 int8, downloaded at runtime into Application Support. Sparkle ships in direct-distribution builds only; `APP_STORE=1` excludes it.

## Build variants

| Command | Entitlements | Sparkle | Signing |
| --- | --- | --- | --- |
| `make run` / `make build` | `Resources/HoldToTalk.dev.entitlements` | Yes | Ad-hoc (`-`) |
| `SIGNING_IDENTITY="..." make build` | `Resources/HoldToTalk.direct.entitlements` | Yes | Developer ID |
| `APP_STORE=1 make build` | `Resources/HoldToTalk.entitlements` | No | App Store-style assembly |

Direct distribution uses Sparkle appcast metadata in `docs/appcast.xml`. The App Store workflow strips Sparkle keys from `Info.plist`, embeds a provisioning profile, signs with App Store entitlements, packages a `.pkg`, and uploads with `xcrun altool`.

## Guardrails — do not break these

- API keys only via `KeychainHelper`. Never UserDefaults, logs, files, or crash text.
- Cloud base URLs must be validated with `normalizedCloudBaseURL` before credentials, audio, or text are sent.
- Cloud traffic uses `cloudSession` (ephemeral `URLSession`, cookies and disk cache disabled) — no shared session.
- Diagnostic logging is off by default. Transcript-like content goes through `debugLogSensitive(_:text:)` only.
- `AudioRecorder.stop()` zeroes captured buffers after resampling — preserve.
- `TextInserter` intentionally blocks secure text fields — preserve.
- New UserDefaults keys go in `OnboardingResetHelper.swift` as top-level constants.
- Runtime paths: models in `~/Library/Application Support/HoldToTalk/models`, debug log at `~/Library/Application Support/HoldToTalk/debug.log`.
- Keep privacy/security tests updated when touching cloud providers, URL validation, key handling, logging, or text insertion.

## Coding conventions

- Prefer existing SwiftUI/AppKit patterns over new abstractions; keep UI native and compact (utility app, not a marketing surface).
- `@MainActor` for UI and `DictationEngine` state. Keep recognition/download/extraction off the main actor.
- `Transcriber` is an `actor` — preserve isolation around recognizer/model access.
- `AudioRecorder` is `@unchecked Sendable` guarded by `NSLock` — keep tap callbacks nonblocking.
- Avoid force unwraps except hardcoded URL literals and the documented Application Support lookups already in the codebase.
- Model/provider failures: failable initialization and user-facing errors, not crashes.
- Resource access: app-bundle resource paths first, then `Bundle.module` fallback (`.app` layout differs from raw `swift run`).

## Testing and evaluation

`swift test` covers: install/copy/relaunch helpers, cloud URL validation and safe cloud error text, log redaction and secure-input errors, onboarding reset/resume, speech model metadata, phrase dedup/silence trimming/segmentation/normalization, compatibility and permission helpers.

Manual WER evaluation (records via `ffmpeg`, writes git-ignored `evaluation/test_data/`):

```bash
swift build --target TranscribeCmd
python3 evaluation/evaluate.py record -n 5
python3 evaluation/evaluate.py retest
python3 evaluation/evaluate.py report
```

## CI and release

- `.github/workflows/build.yml`: push/PR to `main` — setup, `swift test`, `APP_STORE=1 make build`, direct `make build`.
- `.github/workflows/release.yml`: tag/workflow direct release — tests, version stamp, Developer ID cert import, `make release`, GitHub Release artifacts, Homebrew tap update, Sparkle appcast, release metadata committed back to `main`.
- `.github/workflows/release-appstore.yml`: manual — App Store signing/profile, `.pkg`, upload via `xcrun altool`.

Caution: the repo slug appears as both `hold-to-talk` and `holdtotalk` in README/templates. Verify actual URLs before editing release automation.

## Troubleshooting (symptom → fix)

- Permissions not detected after ad-hoc rebuilds → macOS TCC ties grants to code identity. Use debug Skip Permissions for UI work, stable signing for permission testing, or `make test-reset`.
- `CGPreflightPostEventAccess()` stale in-process → expected; `SystemSettingsHelper` combines preflight, Accessibility trust, and a test event.
- macOS launches `/Applications/Hold To Talk.app` instead of the debug app → `make test-reset` or remove the installed app.
- `swift build` alone doesn't assemble a `.app` or copy/sign Sparkle → use `make run`/`make build` for runtime bundle behavior.
- Sparkle framework fails to load → check `make build` copied it into `Contents/Frameworks` and added the `@executable_path/../Frameworks` rpath.
- Local model init fails → delete the model in Settings or remove `~/Library/Application Support/HoldToTalk/models` and re-download.
- Reset TCC manually: `tccutil reset Microphone|Accessibility|ListenEvent com.holdtotalk.app`.
