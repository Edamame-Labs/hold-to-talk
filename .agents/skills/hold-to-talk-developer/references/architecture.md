# Architecture

Hold to Talk is a SwiftPM macOS app. There is no Xcode project.

## Important Paths

- `Package.swift`: SwiftPM targets and Sparkle conditional dependency.
- `Makefile`: build, install, package, release, and reset shortcuts.
- `Sources/HoldToTalk/`: app target.
- `Sources/TranscribeCmd/`: CLI transcription/evaluation harness.
- `Tests/HoldToTalkTests/`: XCTest and Swift Testing coverage.
- `Resources/`: Info.plist, entitlements, icons, privacy manifest, release resources.
- `docs/`: GitHub Pages site and Sparkle appcast.
- `Casks/holdtotalk.rb`: template consumed by the release workflow for Homebrew tap updates.
- `.github/workflows/`: CI, direct release, and App Store release workflows.

## Main Pipeline

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

## Component Ownership

- `HoldToTalkApp.swift`: app scene, menu bar status, onboarding/settings windows, install prompt, launch-at-login migration, Sparkle wiring.
- `DictationEngine.swift`: main `@MainActor` state machine, permission snapshots, hotkey lifecycle, transcriber warmup.
- `HotkeyManager.swift`: Carbon hotkeys for regular shortcuts, AppKit modifier monitoring for bare modifiers.
- `AudioRecorder.swift`: AVAudioEngine capture, level callback, resampling, buffer zeroing.
- `Transcriber.swift`: sherpa-onnx recognizer, VAD segmentation, silence trimming, normalization, deduplication, hotwords.
- `CloudTranscriber.swift`: OpenAI-compatible `/audio/transcriptions` calls.
- `TextCleanup.swift`: Apple Intelligence cleanup guarded by availability.
- `CloudTextCleanup.swift`: OpenAI/Anthropic cleanup with fallback to raw text.
- `CloudProvider.swift`: cloud URL validation and ephemeral `URLSession`.
- `TextInserter.swift`: secure-input checks, target app focus, CGEvent insertion, clipboard paste.
- `ModelManager.swift`: model download, checksum validation, extraction, delete/status.
- `OnboardingView.swift`: install, permission, model/cloud, cleanup, and hotkey wizard.
- `SettingsView.swift`: provider/key/model/hotkey/cleanup/update/logging controls.
- `SystemSettingsHelper.swift`: microphone/PostEvent helpers and stable-code-identity behavior.
- `OnboardingResetHelper.swift`: UserDefaults keys and onboarding reset/resume state.
- `DebugLog.swift`: local diagnostic logging with transcript redaction.
- `KeychainHelper.swift`: API key storage under service `com.holdtotalk.apikeys`.
