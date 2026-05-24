# Commands

Run from the repo root.

## Build And Test

```bash
make setup
swift build
swift build -c release
swift test
make build
APP_STORE=1 make build
make verify
```

Use `make build` when runtime bundle layout matters. Plain `swift build` does not assemble a full `.app` or copy/sign Sparkle.

## Local Run And Install

```bash
make run
make install
```

`make run` creates a debug app bundle and opens it. Debug-only launch flags are available with `swift run HoldToTalk -- --reset-onboarding`, `--onboarding-step N`, and `--skip-permissions`.

## Reset And Permission Testing

```bash
make permissions-reset
make test-reset
make uninstall
make fresh-install
```

Use `make fresh-install` for the common local loop: uninstall, clear app state, reset TCC permissions, rebuild, and reinstall.

If `/Applications/Hold To Talk.app` is not writable by the current user, rerun the reset path with:

```bash
sudo APP_USER=$USER bash scripts/reset-fresh-test.sh --yes
```

The reset script covers:

- `/Applications/Hold To Talk.app`
- `~/Applications/Hold To Talk.app`
- app preferences, caches, logs, saved state
- sandbox container data
- downloaded speech models
- TCC Microphone, Accessibility, and PostEvent permissions

## Verification Scope

- Docs-only: usually `git diff --check`.
- Swift logic: `swift test`.
- Bundle/resources/Sparkle: `make build`.
- App Store conditional path: `APP_STORE=1 make build`.
- Release prep: run local tests/builds and then monitor GitHub Actions.
