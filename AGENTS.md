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
make setup    # one-time: download sherpa-onnx + llama.cpp xcframeworks into Frameworks/ (make build/run call it; needed once before raw swift build)
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
scripts/setup-llama-cpp.sh     Downloads/prepares llama.cpp xcframework (macOS slice only)
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
 -> TextCleanup OR LocalTextCleanup OR CloudTextCleanup
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
- `LocalTextCleanup.swift`: optional on-device cleanup running Superwhisper S1-mini through llama.cpp. Works on any Apple Silicon Mac, no Apple Intelligence required. Model/context handles live in a lock-guarded `LlamaHandles` so they can be freed synchronously at termination.
- `S1MiniModel.swift`: S1-mini metadata plus the exact prompt format (system prompt, control line, empty think block) and transcript chunking. No llama.cpp dependency, so it is fully unit-testable.
- `CleanupModelManager.swift`: S1-mini GGUF download, checksum validation, delete/status.
- `CloudTextCleanup.swift`: OpenAI chat completions or Anthropic messages cleanup; failures fall back to original text.
- `CloudProvider.swift`: cloud URL validation and ephemeral `URLSession`.
- `TextInserter.swift`: secure-input checks, target app strategy, CGEvent Unicode insertion or clipboard paste.
- `ModelManager.swift`: speech model download, checksum validation, extraction, delete/status.
- `OnboardingView.swift`: install/permissions/model/cloud/hotkey wizard.
- `SettingsView.swift`: provider/key/model/hotkey/cleanup/update/logging controls.
- `SystemSettingsHelper.swift`: microphone/post-event permission helpers and stable-code-identity behavior.
- `OnboardingResetHelper.swift`: UserDefaults keys and fresh onboarding reset state.
- `DebugLog.swift`: local diagnostic logging with transcript redaction and 1 MB truncation.
- `KeychainHelper.swift`: API key storage under service `com.holdtotalk.apikeys`, accounts `openai` and `anthropic`.

Tech notes: `swift-tools-version: 6.0` with `swiftLanguageMode(.v5)`. Local ASR is sherpa-onnx (`Frameworks/sherpa_onnx.xcframework`, static) running NVIDIA Parakeet TDT 0.6B v2 int8. Local cleanup is llama.cpp (`Frameworks/llama.xcframework`, **dynamic**) running Superwhisper S1-mini Q4_K_M. Both models download at runtime into Application Support. `llama.framework` is linked at build time, so every bundle-assembly path must embed and sign it or the app will not launch: `make build`, `make run`, and the App Store workflow's inline assembly all do. Sparkle ships in direct-distribution builds only; `APP_STORE=1` excludes it.

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
- Never rank microphones by transport type. The app mirrors the system's chosen input unless the user picks one in Settings; quietly preferring the built-in mic because a headset is "worse" disagrees with System Settings and overrides a deliberate choice. Surface what a Bluetooth choice costs instead — `bluetoothInputNotice` — and let the user decide.
- Never pre-warm the capture engine unconditionally. Touching `engine.inputNode` opens the input device, and macOS can only expose a Bluetooth headset as an input by switching it out of A2DP into the hands-free profile — playback drops to mono call quality (measurably: 48 kHz to 24 kHz on AirPods Max) for as long as the app runs. `AudioInputDevice.prewarmWouldDegradePlayback` gates it, `stop()` respects the same check, and a default-input-change listener releases the engine when a headset connects mid-session. The 140ms latency win is not worth the user's audio.
- The app has no default window scene — only the menu bar item plus explicitly-opened onboarding and settings windows. `applicationShouldHandleReopen` is what makes opening an already-running app from the Dock or Finder show anything; without it the app looks like it failed to launch.
- `TextInserter` intentionally blocks secure text fields — preserve.
- New UserDefaults keys go in `OnboardingResetHelper.swift` as top-level constants.
- Runtime paths: models in `~/Library/Application Support/HoldToTalk/models`, debug log at `~/Library/Application Support/HoldToTalk/debug.log`.
- Keep privacy/security tests updated when touching cloud providers, URL validation, key handling, logging, or text insertion.
- Never distribute an ad-hoc signed build. Ad-hoc signing makes the designated requirement a bare cdhash, so macOS pins the user's Accessibility/Input Monitoring grants to one exact binary and every later upgrade silently loses them while System Settings still shows the app enabled. `_check-distributable-signing` blocks `package-zip`/`package-dmg` unless `SIGNING_IDENTITY` is set (`ALLOW_ADHOC_PACKAGE=1` overrides for local-only artifacts). Verify with `codesign -d -r- <app>`: a release must read `identifier "com.holdtotalk.app" and anchor apple generic ... subject.OU = "<team>"`, never `cdhash H"..."`.
- `make install` without `SIGNING_IDENTITY` puts an ad-hoc build at the same bundle identifier as the notarized release, which invalidates that release's grants too. Use `SIGNING_IDENTITY="Developer ID Application: ..." make install` for permission testing.
- `onboardingLaunchPreparation` compares both path *and* version. An in-place Sparkle or drag update keeps the path, so version is the only signal that an upgrade happened — dropping it re-introduces the bug where a broken upgrade left the hotkey silently dead.
- When permissions read as missing right after a move or update, `permissionsStaleAfterUpdate` is set and the UI must show `StalePermissionRecoveryView` instead of the normal "enable it" guidance. Telling the user to switch on a toggle that already looks on is the wrong remedy; removing and re-adding the entry is the right one.
- llama.cpp's Metal backend aborts during static destruction if a context is still alive at exit. `applicationWillTerminate` calls `LocalTextCleanup.shutdownForTermination()` and an `atexit` handler backs it up — preserve both, or quitting becomes a crash report.
- S1-mini is English-only and garbles other languages rather than failing. `DictationLanguageMode` gates it: `CleanupProvider.resolved(storedRawValue:languageMode:)` clamps a stale selection, and `DictationEngine.cleanUp` re-checks before running. Keep both — the clamp is what a stored preference hits after the user switches language.
- Apple Intelligence stays available in multilingual mode on purpose. It is the only on-device multilingual cleanup, so hiding it would push those users to the cloud and break "local by default".
- The S1-mini licence is Apache 2.0 plus an additional term: the model must be identified as "S1-mini" by "Superwhisper" with that exact capitalization wherever it is used or integrated. `S1MiniModelInfo.attributedName` exists for user-facing surfaces; do not rebrand it.
- S1-mini's system prompt and `[Styling:] [Structure:] [Context:]` control line are the trained input format, not suggestions. Changing the wording, or sending values outside the trained sets, silently degrades output. `S1MiniModelTests` pins the exact shape.
- The S1-mini download URL is pinned to a Hugging Face commit revision so the SHA-256 in `S1MiniModelInfo` stays valid. Bump both together.

## Coding conventions

- Prefer existing SwiftUI/AppKit patterns over new abstractions; keep UI native and compact (utility app, not a marketing surface).
- `@MainActor` for UI and `DictationEngine` state. Keep recognition/download/extraction off the main actor.
- `Transcriber` is an `actor` — preserve isolation around recognizer/model access.
- `AudioRecorder` is `@unchecked Sendable` guarded by `NSLock` — keep tap callbacks nonblocking.
- Avoid force unwraps except hardcoded URL literals and the documented Application Support lookups already in the codebase.
- Model/provider failures: failable initialization and user-facing errors, not crashes.
- Resource access: app-bundle resource paths first, then `Bundle.module` fallback (`.app` layout differs from raw `swift run`).

## Testing and evaluation

`swift test` covers: install/copy/relaunch helpers, cloud URL validation and safe cloud error text, log redaction and secure-input errors, onboarding reset/resume, speech model metadata, phrase dedup/silence trimming/segmentation/normalization, compatibility and permission helpers, and the S1-mini prompt format/chunking.

`LocalTextCleanupTests` runs the real S1-mini weights end to end. It is skipped automatically wherever the model is absent (CI, fresh checkouts) — download it from Settings › Cleanup to enable it.

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
