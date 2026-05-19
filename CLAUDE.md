# CLAUDE.md

This file is for AI/code agents working in this repository. Keep changes grounded in the current SwiftPM app structure; this is not an Xcode-project repo.

## Agent Behavior

These guidelines are adapted from the `multica-ai/andrej-karpathy-skills` CLAUDE.md and merged with this repo's project-specific instructions. They bias toward caution over speed; use judgment for trivial tasks.

### Think Before Coding

- Do not assume requirements that are not in the request or visible in the code.
- State assumptions when they affect implementation.
- If multiple interpretations are plausible, surface them instead of silently choosing a risky path.
- If a simpler approach solves the problem, say so and use it.
- If something is unclear enough to risk the wrong change, stop and ask a focused question.

### Simplicity First

- Write the minimum code that solves the requested problem.
- Do not add speculative features, configuration, flexibility, or abstractions.
- Do not add defensive handling for impossible states unless this repo already handles that class of failure.
- If a change is getting large, re-check whether a smaller fix would satisfy the goal.

### Surgical Changes

- Touch only the files and lines needed for the user's request.
- Do not refactor, reformat, or "improve" adjacent code unless it is required for the task.
- Match existing style even when another style would also be reasonable.
- Remove imports, variables, functions, and files made unused by your own change.
- Do not remove pre-existing dead code or unrelated artifacts unless explicitly asked; mention them instead.
- Every changed line should trace back to the user's request.

### Goal-Driven Execution

- Convert non-trivial tasks into verifiable success criteria before editing.
- For bug fixes, prefer a failing test or clear reproduction first, then make it pass.
- For validation or behavior changes, cover the important invalid and valid cases where practical.
- For refactors, verify behavior before and after with the relevant tests.
- Loop until the change is implemented and verified, or clearly report the blocker.

## Project Overview

Hold To Talk is a macOS hold-to-talk dictation app. The user holds a configured hotkey, speaks, releases, and the app transcribes the recording, optionally cleans up the text, then inserts it into the previously active app.

Core product constraints:

- macOS 15+ and Apple Silicon are required for the app experience.
- Local transcription is the default. Cloud features are opt-in and use the user's own provider keys.
- There are no Hold To Talk servers. Provider requests go directly from the app to OpenAI-compatible or Anthropic endpoints.
- Privacy-sensitive data must stay out of diagnostics. Transcript text is redacted in logs.

## Tech Stack

- SwiftPM package, no `.xcodeproj` or `.xcworkspace`.
- `swift-tools-version: 6.0` with target `swiftLanguageMode(.v5)`.
- SwiftUI/AppKit app target: `Sources/HoldToTalk`.
- CLI transcription harness target: `Sources/TranscribeCmd`.
- Tests: `Tests/HoldToTalkTests`, using both XCTest and Swift Testing.
- Local ASR: sherpa-onnx binary target from `Frameworks/sherpa_onnx.xcframework`.
- Speech model: NVIDIA Parakeet TDT 0.6B v2 int8, downloaded at runtime into Application Support.
- VAD: `Sources/HoldToTalk/Resources/silero_vad.onnx`, copied by SwiftPM via `Bundle.module`.
- Updates: Sparkle for direct-distribution builds only. `APP_STORE=1` excludes Sparkle.
- Demo video: Remotion project under `demo-video/` and generated media in `demo-video/out/` and `docs/`.

## Important Paths

```text
Package.swift                         SwiftPM targets, Sparkle conditional dependency
Makefile                              Local build, app assembly, signing, packaging, reset helpers
Sources/HoldToTalk/                   Main macOS app
Sources/HoldToTalk/Resources/         SwiftPM-copied runtime resources
Sources/TranscribeCmd/                CLI tool for transcription experiments/evaluation
Tests/HoldToTalkTests/                Unit tests for security, onboarding, compatibility, insertion, ASR helpers
Resources/                            App bundle resources, entitlements, Info.plist, icons, privacy manifest
scripts/setup-sherpa-onnx.sh          Downloads/prepares sherpa-onnx xcframework
scripts/reset-fresh-test.sh           Removes installs/state and resets permissions
scripts/package-dmg.sh                Direct-distribution DMG packaging
evaluation/                           Manual WER/evaluation helpers
docs/                                 GitHub Pages site, appcast, privacy page, enterprise docs
Casks/holdtotalk.rb                   Template used by release workflow for Homebrew tap
.github/workflows/                    CI, direct release, App Store upload
```

Generated or local-only paths are ignored by git: `.build/`, `Frameworks/`, `.claude/`, `demo-video/`, `dist/`, app bundles, `.DS_Store`.

## Commands

```bash
make setup                         # Download sherpa-onnx xcframework into Frameworks/
swift build                        # Debug SwiftPM build; setup must already have run
swift build -c release             # Release SwiftPM build
swift test                         # Run all tests

make build                         # Release build + assemble .build/Hold To Talk.app
make run                           # Debug build + assemble .app + open it
make install                       # Build and copy to /Applications
make verify                        # Build, codesign verify, and spctl if not ad-hoc signed
make package                       # Direct-distribution zip + dmg; requires APP_STORE != 1
make release                       # Sign, notarize app, package zip/dmg, notarize dmg
make clean                         # swift package clean + remove app/dist/staging artifacts

make test-reset                    # Kill app, remove installs/data, reset permissions
make reset-fresh-test              # Same script, configurable via ARGS
make permissions-reset             # Reset TCC permissions only
tccutil reset Microphone com.holdtotalk.app
tccutil reset Accessibility com.holdtotalk.app
tccutil reset ListenEvent com.holdtotalk.app
```

Debug-only launch flags:

```bash
swift run HoldToTalk -- --reset-onboarding
swift run HoldToTalk -- --onboarding-step 2
swift run HoldToTalk -- --skip-permissions
swift run HoldToTalk -- --reset-onboarding --onboarding-step 3 --skip-permissions
```

`make run` creates a debug app bundle, so debug onboarding controls such as Skip Permissions are available there.

## Architecture

The main dictation path is:

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

Responsibilities:

- `HoldToTalkApp.swift`: app scene, menu bar status, onboarding/settings windows, install prompt, launch-at-login migration, Sparkle wiring.
- `DictationEngine.swift`: main `@MainActor` pipeline state machine (`idle -> recording -> transcribing -> idle`), permission snapshots, hotkey lifecycle, transcriber warmup.
- `HotkeyManager.swift`: Carbon hotkeys for regular shortcuts and AppKit modifier monitoring for bare modifier keys.
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

## Build Variants

| Command | Build | Entitlements | Sparkle | Signing |
| --- | --- | --- | --- | --- |
| `make run` | Debug app bundle | `Resources/HoldToTalk.dev.entitlements` | Yes | Ad-hoc (`-`) |
| `make build` | Release app bundle | `Resources/HoldToTalk.dev.entitlements` | Yes | Ad-hoc (`-`) |
| `SIGNING_IDENTITY="..." make build` | Release app bundle | `Resources/HoldToTalk.direct.entitlements` | Yes | Developer ID |
| `APP_STORE=1 make build` | Release app bundle | `Resources/HoldToTalk.entitlements` | No | App Store-style bundle assembly |

Direct distribution uses Sparkle appcast metadata in `docs/appcast.xml`. App Store workflow strips Sparkle keys from `Info.plist`, embeds a provisioning profile, signs with App Store entitlements, packages a `.pkg`, and uploads with `xcrun altool`.

## State, Storage, And Privacy

- UserDefaults keys live as top-level constants in `OnboardingResetHelper.swift`. Add new keys there.
- API keys must remain in Keychain via `KeychainHelper`; do not store secrets in UserDefaults, logs, files, or crash text.
- Cloud base URLs must be validated with `normalizedCloudBaseURL` before credentials/audio/text are sent.
- Cloud traffic uses `cloudSession`, an ephemeral `URLSession` with cookies and disk cache disabled.
- Diagnostic logging is off by default. Use `debugLogSensitive(_:text:)` for transcript-like content.
- `AudioRecorder.stop()` zeroes captured buffers after resampling.
- Secure text fields are intentionally blocked by `TextInserter`; preserve that behavior.
- Runtime model data is under `~/Library/Application Support/HoldToTalk/models`.
- Debug log path is `~/Library/Application Support/HoldToTalk/debug.log`.

## Testing And Evaluation

Run `swift test` before handing off code changes unless the change is docs-only or the environment cannot build macOS targets.

Current test coverage includes:

- app install/copy/relaunch helpers
- cloud base URL validation and safe cloud error text
- diagnostic log redaction and secure-input user-facing errors
- onboarding reset/resume behavior
- speech model metadata
- repeated phrase deduplication, silence trimming, segmentation, normalization
- system compatibility and permission helper logic

Manual/local evaluation tools:

```bash
swift build --target TranscribeCmd
python3 evaluation/evaluate.py record -n 5
python3 evaluation/evaluate.py retest
python3 evaluation/evaluate.py report
python3 evaluation/test_accuracy.py
```

`evaluation/evaluate.py` records through `ffmpeg` and writes local `test_data/` artifacts. Do not commit those artifacts.

## CI And Release Workflow

- `.github/workflows/build.yml`: on push/PR to `main`, runs setup, `swift test`, `APP_STORE=1 make build`, and direct `make build`.
- `.github/workflows/release.yml`: tag/workflow direct release; tests, stamps version, imports Developer ID cert, `make release`, publishes GitHub Release artifacts, updates Homebrew tap, generates Sparkle appcast, commits release metadata back to `main`.
- `.github/workflows/release-appstore.yml`: manual App Store build/upload; tests, stamps version/build, signs with App Store certificate/profile, packages `.pkg`, uploads to App Store Connect.

Be careful editing release workflow paths and repository slugs. The public README and some templates historically use both `hold-to-talk` and `holdtotalk` forms; verify actual URLs before changing release automation.

## Coding Conventions

- Prefer existing SwiftUI/AppKit patterns over new abstractions.
- Keep app UI changes native and compact; this is a utility app, not a marketing surface.
- Use `@MainActor` for UI and `DictationEngine` state. Keep long recognition/download/extraction work off the main actor.
- `Transcriber` is an `actor`; preserve actor isolation around recognizer/model access.
- `AudioRecorder` is `@unchecked Sendable` guarded by `NSLock`; keep tap callbacks nonblocking.
- Avoid force unwraps except for hardcoded URL literals and documented Application Support directory lookups already following the project style.
- Prefer failable initialization and user-facing errors for model/provider failures over crashes.
- Access SwiftPM resources through app-bundle resource paths first when needed, then `Bundle.module` fallback; `.app` bundle layout differs from raw `swift run`.
- Keep privacy/security tests updated when touching cloud providers, URL validation, key handling, logging, or text insertion.
- Do not commit downloaded frameworks, local demo-video dependencies/output, test audio, `.build`, or `dist`.

## Troubleshooting

- Permissions may not auto-detect after ad-hoc rebuilds because macOS TCC associates grants with code identity. Use debug Skip Permissions for UI work, stable signing for permission testing, or `make test-reset`.
- `CGPreflightPostEventAccess()` can be stale in-process. `SystemSettingsHelper` intentionally combines preflight, Accessibility trust, and a test event.
- macOS may launch `/Applications/Hold To Talk.app` instead of the debug app. Run `make test-reset` or remove the installed app before debugging.
- Manual `swift build` does not assemble a full `.app` or copy/sign Sparkle. Use `make run`/`make build` when testing runtime bundle behavior.
- If Sparkle framework loading fails, check that `make build` copied it into `Contents/Frameworks` and added the `@executable_path/../Frameworks` rpath.
- If local model initialization fails, delete the downloaded model from Settings or remove `~/Library/Application Support/HoldToTalk/models` and re-download.
