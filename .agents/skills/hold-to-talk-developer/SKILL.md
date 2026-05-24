---
name: hold-to-talk-developer
description: Develop, test, package, reset, and release the Hold to Talk macOS SwiftPM app. Use when working in the hold-to-talk repository on app code, onboarding, permissions, local/cloud transcription, text cleanup, text insertion, model downloads, Sparkle updates, Homebrew cask metadata, GitHub release workflows, App Store builds, or fresh-install permission testing.
---

# Hold to Talk Developer

Use this skill to work on the Hold to Talk repo without re-discovering its SwiftPM app structure, privacy constraints, reset workflow, and release process.

## First Steps

1. Run `git status --short --branch` and preserve unrelated user changes.
2. Read the relevant source before editing. Prefer `rg` for searches.
3. Keep changes scoped. This repo is a SwiftPM macOS app, not an Xcode project.
4. Run the smallest meaningful checks, then broaden before release or handoff.

## Reference Selection

- For repo layout and main components, read `references/architecture.md`.
- For commands, local install/reset, and verification, read `references/commands.md`.
- For privacy, security, cloud, logging, keychain, and model-integrity rules, read `references/privacy-security.md`.
- For direct-distribution release and appcast/Homebrew checks, read `references/release.md`.

## Common Workflows

### Make A Code Change

1. Identify the owner file from `references/architecture.md`.
2. Add or update focused tests when touching shared behavior, state transitions, permissions, cloud providers, URL validation, key handling, logging, text insertion, model download/extraction, or onboarding resume.
3. Run `swift test`.
4. For bundle/runtime changes, run `make build`.
5. For Sparkle/App Store conditional behavior, also run `APP_STORE=1 make build`.

### Fresh Permission Install

Use `make fresh-install` for the recurring local loop: uninstall, clear state, reset permissions, rebuild, and reinstall. If working on an older branch without that target, use `make test-reset && make install`.

### Release

Release only when explicitly requested. Follow `references/release.md`; do not stop after tagging. Watch the GitHub release workflow, verify assets, verify Homebrew tap, pull the workflow's appcast metadata commit, and verify the served appcast URL.

## Guardrails

- Keep transcript-like content out of logs. Use redacted diagnostic helpers.
- Store provider keys only in Keychain via `KeychainHelper`.
- Validate cloud base URLs with `normalizedCloudBaseURL` before sending credentials, audio, or text.
- Preserve secure-input blocking in `TextInserter`.
- Preserve model archive checksum and extraction path validation.
- Do not commit `.build/`, `Frameworks/`, `demo-video/`, `dist/`, downloaded models, or test audio.
