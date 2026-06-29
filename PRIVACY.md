# Privacy Policy

**Effective date:** April 5, 2026

This privacy policy covers the Hold to Talk macOS app and the Hold to Talk website at `holdtotalk.ai`.

## Summary

- The **app** keeps all dictation data on your Mac by default. If you opt in to cloud transcription or cleanup, audio or text is sent directly to the provider you choose (OpenAI or Anthropic) using your own API key. Hold to Talk never proxies, stores, or has access to your data.
- The **website** uses Google Analytics to understand traffic.
- Hold to Talk does **not** sell personal data or use advertising trackers inside the app.

## Hold to Talk app

### How speech recognition works

By default, Hold to Talk uses two open-source projects for on-device speech recognition:

- **[NVIDIA Parakeet TDT 0.6B](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)** -- the speech model. Parakeet is an automatic speech recognition model developed by NVIDIA and released under the Apache 2.0 license. Hold to Talk downloads the int8-quantized version (~640 MB) on first launch. Once downloaded, the model runs entirely on your Mac with no network calls.

- **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)** -- the inference runtime. sherpa-onnx is developed by the [Next-gen Kaldi](https://github.com/k2-fsa) team (the research group behind the Kaldi speech recognition toolkit widely used in academia and industry). It runs ONNX models locally without requiring a GPU or cloud service. sherpa-onnx is open-source under the Apache 2.0 license.

Both projects are published by established research teams, hosted on GitHub and Hugging Face, and are independently auditable.

### Optional cloud transcription and cleanup (bring your own key)

You can optionally enable cloud-powered transcription (OpenAI) or text cleanup (OpenAI, Anthropic) by providing your own API key in Settings. When cloud features are enabled:

- Audio or transcription text is sent **directly from your Mac to the provider** (e.g., `api.openai.com` or `api.anthropic.com`). Hold to Talk does not operate any proxy or relay server.
- Your API key is stored in the **macOS Keychain**, not in plain text or in Hold to Talk preferences.
- Hold to Talk **never sees, collects, or stores** your API key, audio, or transcription text. The connection is between your Mac and the provider.
- The provider's own privacy policy and data retention rules apply. Consult their documentation for details.

Cloud features are **off by default**. If you do not add an API key, the app operates entirely on-device.

### Audio

- Microphone audio is captured only while you hold the dictation hotkey.
- When using on-device transcription (default), audio is processed locally in memory and is not sent over the network.
- When using cloud transcription, audio is sent directly to the provider you configured. It is not sent to Hold to Talk.
- Audio is not stored as recordings.

### Transcriptions

- Transcribed text is inserted into the app you are using.
- Hold to Talk does not keep a cloud transcription history.
- If optional Apple Intelligence cleanup is enabled (macOS 26+), cleanup runs on-device via macOS system features.
- If cloud text cleanup is enabled, transcription text is sent directly to the provider you configured. It is not sent to Hold to Talk.
- If you enable local diagnostic logging, transcript text is redacted in those logs by default.

### Local storage

Hold to Talk stores the following on your Mac:

- Preferences (hotkey, transcription profile, cleanup settings)
- The downloaded Parakeet TDT speech model
- Temporary app state for onboarding and operation
- Optional local diagnostic logs, only if you enable them

Hold to Talk does not store audio recordings or a server-side transcript history.

### Network activity

The app makes limited network requests:

| Request | Destination | Purpose |
|---|---|---|
| Model download | `github.com/k2-fsa/sherpa-onnx/releases` | One-time download of the Parakeet TDT speech model |
| Update check | Sparkle update feed | Checking for app updates (direct-download builds only, not App Store) |
| Cloud transcription | `api.openai.com` (or custom base URL) | Only if you enable cloud transcription with your own API key |
| Cloud text cleanup | `api.openai.com` or `api.anthropic.com` (or custom base URL) | Only if you enable cloud cleanup with your own API key |

Model and update requests download app or model files. Cloud transcription and cleanup requests are only made when you explicitly enable those features and provide your own API key. In all cases, data is sent directly to the provider -- never through Hold to Talk servers.

### App analytics and tracking

Hold to Talk does not include in-app advertising, third-party analytics SDKs, or telemetry that tracks what you dictate.

## Website

### Website analytics

The Hold to Talk website uses **Google Analytics** to measure site traffic. When you visit the website, Google Analytics may collect:

- Pages viewed
- Approximate geographic region
- Browser and device information
- Referral source

Website analytics do not include dictation audio or transcription text from the app.

### Website hosting

The website and release assets are served through GitHub Pages and GitHub Releases. Those services may receive technical information (IP address, user agent) as part of normal web delivery.

## Permissions

The app requests these macOS permissions:

- **Microphone** -- recording audio for transcription
- **Accessibility** (Keyboard Access) -- inserting transcribed text into apps
- **No explicit Input Monitoring request** -- regular shortcuts are registered with macOS; modifier-only shortcuts use Accessibility-trusted modifier-state events

These permissions are managed by macOS and can be revoked at any time in System Settings.

## Third parties

| Service | Role | Their privacy policy |
|---|---|---|
| GitHub | Source code, release hosting, model download | [github.com/site/privacy](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) |
| Google Analytics | Website traffic analytics | [policies.google.com/privacy](https://policies.google.com/privacy) |
| Sparkle | Direct-download update delivery | [sparkle-project.org](https://sparkle-project.org) |
| OpenAI | Cloud transcription and/or text cleanup (opt-in, BYO key) | [openai.com/privacy](https://openai.com/privacy) |
| Anthropic | Cloud text cleanup (opt-in, BYO key) | [anthropic.com/privacy](https://www.anthropic.com/privacy) |

## Children

Hold to Talk is not directed to children and does not knowingly collect personal information from children.

## Changes to this policy

If this policy changes, the updated version will be posted on the website and in this repository with a new effective date.

## Contact

If you have privacy questions, open an issue at:

`https://github.com/Edamame-Labs/hold-to-talk/issues`
