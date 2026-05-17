# Enterprise Deployment Guide

This guide covers how organizations can deploy Hold To Talk for their employees with centrally managed cloud transcription.

## Why Hold To Talk for enterprise

- **No vendor lock-in** -- open-source, Apache 2.0, self-buildable
- **Local-first by default** -- works fully on-device with no network calls for air-gapped or classified environments
- **Bring-your-own-key cloud** -- optional cloud transcription and cleanup via OpenAI or Anthropic, controlled by your infrastructure
- **No Hold to Talk servers** -- the app connects directly to the provider. We never see, proxy, or store your data
- **macOS native** -- Swift/SwiftUI, Keychain for secrets, MDM-compatible preferences

## Deployment models

### 1. Fully local (no cloud)

Best for: air-gapped networks, HIPAA, classified environments.

Employees use the on-device Parakeet TDT speech model. No API keys, no network calls after initial model download. Audio and transcriptions never leave the Mac.

### 2. Cloud via company proxy (recommended)

Best for: organizations that want cloud transcription quality with centralized control.

The company runs a thin proxy in front of the AI provider. Hold To Talk's custom base URL field points to the proxy instead of the provider directly.

```
Employee's Mac                    Company proxy                  AI Provider
Hold To Talk  ──── base URL ────>  proxy.corp.com  ──── real key ────>  api.openai.com
              (employee token)     - SSO auth (Okta, Entra ID)
                                   - Rate limits & quotas
                                   - Audit logging
                                   - Cost attribution
```

**Why a proxy instead of distributing the API key:**
- The real API key never touches employee Macs -- can't be extracted or misused
- Per-user authentication via your existing SSO (Okta, Entra ID, etc.)
- Instant revocation when employees leave -- disable their SSO account
- Rate limiting and cost caps per user, team, or department
- Audit trail: who dictated, when, duration (not content)
- Single key to rotate without touching any employee device

See [proxy-setup.md](proxy-setup.md) for implementation details.

### 3. Azure OpenAI (managed proxy)

Best for: organizations already on Azure / Microsoft 365.

Azure OpenAI is effectively a Microsoft-managed proxy. You get an Azure endpoint, Entra ID handles per-user auth, and the raw OpenAI key is never exposed.

- Set base URL to your Azure OpenAI endpoint
- Employee token is an Entra ID-scoped credential
- Per-user quotas and cost attribution built in
- Data stays in your Azure tenant

## MDM configuration

All Hold To Talk settings are stored in UserDefaults (`com.holdtotalk.app`) and can be pushed via managed preferences (MDM profile or `defaults write`).

### Key preferences

| Key | Type | Example | Description |
|-----|------|---------|-------------|
| `transcriptionProvider` | String | `"openai"` | `"local"` or `"openai"` |
| `openaiTranscriptionModel` | String | `"gpt-4o-mini-transcribe"` | OpenAI model name |
| `openaiBaseURL` | String | `"https://proxy.corp.com/v1"` | Custom base URL for proxy |
| `cleanupProvider` | String | `"openai"` | `"apple_intelligence"`, `"openai"`, or `"anthropic"` |
| `openaiCleanupModel` | String | `"gpt-4o-mini"` | Cleanup model name |
| `anthropicCleanupModel` | String | `"claude-haiku-3-5-20241022"` | Anthropic cleanup model |
| `anthropicBaseURL` | String | `"https://proxy.corp.com"` | Custom Anthropic base URL |
| `textCleanupEnabled` | Bool | `true` | Enable/disable text cleanup |
| `textCleanupPrompt` | String | `"..."` | Custom cleanup instructions |

### Provisioning the API token via Keychain

The app stores API keys in the macOS Keychain under service `com.holdtotalk.apikeys`. Push a token via script or MDM:

```bash
# Add the employee's proxy token to Keychain
security add-generic-password \
  -s "com.holdtotalk.apikeys" \
  -a "openai" \
  -w "employee-token-here" \
  -U
```

### Example MDM profile (plist)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>transcriptionProvider</key>
  <string>openai</string>
  <key>openaiTranscriptionModel</key>
  <string>gpt-4o-mini-transcribe</string>
  <key>openaiBaseURL</key>
  <string>https://proxy.corp.com/v1</string>
  <key>textCleanupEnabled</key>
  <true/>
  <key>cleanupProvider</key>
  <string>openai</string>
  <key>openaiCleanupModel</key>
  <string>gpt-4o-mini</string>
</dict>
</plist>
```

### Example: `defaults write`

```bash
defaults write com.holdtotalk.app transcriptionProvider -string "openai"
defaults write com.holdtotalk.app openaiTranscriptionModel -string "gpt-4o-mini-transcribe"
defaults write com.holdtotalk.app openaiBaseURL -string "https://proxy.corp.com/v1"
defaults write com.holdtotalk.app textCleanupEnabled -bool true
defaults write com.holdtotalk.app cleanupProvider -string "openai"
defaults write com.holdtotalk.app openaiCleanupModel -string "gpt-4o-mini"
```

## Distribution

| Method | Best for |
|--------|----------|
| Homebrew (`brew install jxucoder/tap/holdtotalk`) | Developer teams |
| DMG via internal file share or MDM | Managed fleets |
| Build from source | Security review, custom builds |

## Permissions

macOS will prompt each employee for two permissions on first launch:

- **Microphone** -- recording audio
- **Accessibility** -- inserting text into apps

Hold to Talk does not explicitly request Input Monitoring. Regular hold shortcuts are registered with macOS; modifier-only shortcuts use Accessibility-trusted modifier-state events.

These can be pre-approved via MDM PPPC (Privacy Preferences Policy Control) profiles using the app's bundle identifier `com.holdtotalk.app`.

## Security considerations

- **API keys** are stored in the macOS Keychain for this Mac only, not in UserDefaults, iCloud Keychain, or plain text files
- **Diagnostic logging** is off by default; when enabled, transcript text is redacted (only character/word counts are logged)
- **Secure text fields** (password inputs) are blocked -- the app will not transcribe into them
- **No telemetry** -- Hold to Talk includes no analytics, tracking, or phone-home behavior in the app
- The app is **open-source** -- your security team can audit the code and build from source
