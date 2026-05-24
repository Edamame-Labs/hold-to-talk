# Privacy And Security

## Invariants

- Local transcription is the default.
- Cloud features are opt-in and use the user's provider keys.
- There are no Hold to Talk servers. Provider requests go directly from the app to OpenAI-compatible or Anthropic endpoints.
- Transcript-like content must stay out of diagnostics.

## Secrets

- Store API keys only in Keychain via `KeychainHelper`.
- Do not store provider keys in UserDefaults, logs, files, crash text, or diagnostics.
- Keychain service: `com.holdtotalk.apikeys`.
- Allowed accounts: `openai`, `anthropic`.

## Cloud

- Validate base URLs with `normalizedCloudBaseURL` before sending credentials, audio, or text.
- Require HTTPS.
- Reject embedded credentials, queries, and fragments.
- Use `cloudSession`, an ephemeral `URLSession` with cookies and disk cache disabled.
- Provider error response bodies must not be surfaced or logged because they can contain request details.

## Logging

- Diagnostic logging is off by default.
- Use `debugLogSensitive(_:text:)` for transcript-like content.
- Debug log path: `~/Library/Application Support/HoldToTalk/debug.log`.

## Audio And Text Insertion

- `AudioRecorder.stop()` zeroes captured audio buffers after resampling.
- Preserve secure-input blocking in `TextInserter`.
- Clipboard insertion must restore user clipboard contents when safe.

## Models And Supply Chain

- Runtime model data lives under `~/Library/Application Support/HoldToTalk/models`.
- Keep model archive checksum verification.
- Keep archive extraction path and entry-type validation.
- Do not commit downloaded `Frameworks/` or model artifacts.

## Permissions

- The app requests Microphone and PostEvent/Keyboard Access.
- It does not explicitly request Input Monitoring.
- Regular shortcuts use Carbon hotkey registration.
- Modifier-only shortcuts use Accessibility-trusted modifier-state events.
