#!/usr/bin/env bash
set -euo pipefail

APP_NAME="HoldToTalk"
APP_DISPLAY_NAME="Hold To Talk"
BUNDLE_ID="com.holdtotalk.app"
DEBUG_BUNDLE_ID="com.holdtotalk.debug"
APP_USER="${APP_USER:-${SUDO_USER:-$USER}}"
ASSUME_YES=0
FAILED_PATHS=()

usage() {
  cat <<'EOF'
Usage: scripts/reset-fresh-test.sh [--yes] [--permissions-only]

Preferred shortcut from the repo root:
  make permissions-reset   # reset macOS TCC permissions only
  make test-reset
  make uninstall

Removes Hold To Talk.app and app-specific local state so you can test from a clean slate:
- /Applications/Hold To Talk.app
- ~/Applications/Hold To Talk.app
- app preferences, caches, logs, saved state
- sandbox container data
- downloaded speech models
- TCC permissions for Microphone, Accessibility, and Keyboard Access

If /Applications/Hold To Talk.app exists and is not writable by your current user,
re-run with:

  sudo APP_USER=$USER bash scripts/reset-fresh-test.sh --yes

Environment:
  APP_USER   User whose HoldToTalk state should be removed.

Notes:
  On newer macOS versions, deleting ~/Library/Containers/<bundle id> may require
  Full Disk Access for Terminal/iTerm even if the files are owned by your user.

Use --permissions-only to skip uninstalling the app and clearing app state.
EOF
}

while (($# > 0)); do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --permissions-only)
      PERMISSIONS_ONLY=1
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

PERMISSIONS_ONLY="${PERMISSIONS_ONLY:-0}"

resolve_home() {
  local user="$1"
  local home=""
  home="$(dscl . -read "/Users/${user}" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')"
  if [[ -n "${home}" && -d "${home}" ]]; then
    printf '%s\n' "${home}"
    return
  fi

  if [[ "${user}" == "${USER:-}" && -n "${HOME:-}" && -d "${HOME}" ]]; then
    printf '%s\n' "${HOME}"
    return
  fi

  eval "home=~${user}"
  if [[ -n "${home}" && "${home}" != "~${user}" && -d "${home}" ]]; then
    printf '%s\n' "${home}"
    return
  fi

  return 1
}

USER_HOME="$(resolve_home "${APP_USER}")"
SYSTEM_APP="/Applications/${APP_DISPLAY_NAME}.app"
USER_APP="${USER_HOME}/Applications/${APP_DISPLAY_NAME}.app"

run_as_app_user() {
  if [[ "$(id -un)" == "${APP_USER}" ]]; then
    "$@"
  else
    sudo -u "${APP_USER}" "$@"
  fi
}

print_path() {
  printf '  %s\n' "$1"
}

remove_path() {
  local path="$1"
  local output
  if [[ -e "${path}" || -L "${path}" ]]; then
    if output="$(rm -rf "${path}" 2>&1)"; then
      printf 'removed %s\n' "${path}"
    else
      FAILED_PATHS+=("${path}")
      printf 'warning: could not remove %s\n' "${path}" >&2
      [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
    fi
  fi
}

remove_matches() {
  local dir="$1"
  local pattern="$2"
  local output
  [[ -d "${dir}" ]] || return 0
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    if output="$(rm -rf "${path}" 2>&1)"; then
      printf 'removed %s\n' "${path}"
    else
      FAILED_PATHS+=("${path}")
      printf 'warning: could not remove %s\n' "${path}" >&2
      [[ -n "${output}" ]] && printf '%s\n' "${output}" >&2
    fi
  done < <(find "${dir}" -maxdepth 1 -name "${pattern}" -print)
}

if [[ ! -d "${USER_HOME}" ]]; then
  echo "error: could not resolve home directory for ${APP_USER}" >&2
  exit 1
fi

LEGACY_SYSTEM_APP="/Applications/${APP_NAME}.app"
LEGACY_USER_APP="${USER_HOME}/Applications/${APP_NAME}.app"

for app_path in "${SYSTEM_APP}" "${LEGACY_SYSTEM_APP}"; do
  if [[ "${PERMISSIONS_ONLY}" -ne 1 && -e "${app_path}" && "${EUID}" -ne 0 && ! -w "${app_path}" ]]; then
    echo "error: ${app_path} exists and is not writable by $(id -un)." >&2
    echo "re-run with: sudo APP_USER=${APP_USER} bash scripts/reset-fresh-test.sh --yes" >&2
    exit 1
  fi
done

APP_PATHS=(
  "${SYSTEM_APP}"
  "${USER_APP}"
  "${LEGACY_SYSTEM_APP}"
  "${LEGACY_USER_APP}"
  "${USER_HOME}/Library/Application Support/HoldToTalk"
  "${USER_HOME}/Library/Application Support/${BUNDLE_ID}"
  "${USER_HOME}/Library/Caches/${BUNDLE_ID}"
  "${USER_HOME}/Library/HTTPStorages/${BUNDLE_ID}"
  "${USER_HOME}/Library/Logs/HoldToTalk"
  "${USER_HOME}/Library/Logs/${BUNDLE_ID}"
  "${USER_HOME}/Library/Preferences/${BUNDLE_ID}.plist"
  "${USER_HOME}/Library/Saved Application State/${BUNDLE_ID}.savedState"
  "${USER_HOME}/Library/WebKit/${BUNDLE_ID}"
  "${USER_HOME}/Library/Application Scripts/${BUNDLE_ID}"
  "${USER_HOME}/Library/Containers/${BUNDLE_ID}"
)

if [[ "${ASSUME_YES}" -ne 1 ]]; then
  if [[ "${PERMISSIONS_ONLY}" -eq 1 ]]; then
    cat <<EOF
This will reset Hold To Talk macOS permissions for user ${APP_USER} (${USER_HOME}):
EOF
    print_path "TCC: Microphone, Accessibility"
    print_path "App install and local app state will be preserved"
  else
    cat <<EOF
This will delete Hold To Talk state for user ${APP_USER} (${USER_HOME}):
EOF
    for path in "${APP_PATHS[@]}"; do
      print_path "${path}"
    done
    print_path "TCC: Microphone, Accessibility"
  fi
  printf 'Continue? [y/N] '
  read -r reply
  if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
    echo "aborted"
    exit 0
  fi
fi

if [[ "$(id -un)" == "${APP_USER}" ]]; then
  pkill -x "${APP_NAME}" >/dev/null 2>&1 || true
  pkill -x "Autoupdate" >/dev/null 2>&1 || true
else
  pkill -u "${APP_USER}" -x "${APP_NAME}" >/dev/null 2>&1 || true
  pkill -u "${APP_USER}" -x "Autoupdate" >/dev/null 2>&1 || true
fi

if [[ "${PERMISSIONS_ONLY}" -ne 1 ]]; then
  for path in "${APP_PATHS[@]}"; do
    remove_path "${path}"
  done

  remove_matches "${USER_HOME}/Library/Preferences/ByHost" "${BUNDLE_ID}*"
  remove_matches "${USER_HOME}/Library/Logs/DiagnosticReports" "${APP_NAME}*"

  run_as_app_user defaults delete "${BUNDLE_ID}" >/dev/null 2>&1 || true
  run_as_app_user defaults delete "${DEBUG_BUNDLE_ID}" >/dev/null 2>&1 || true
fi

for bid in "${BUNDLE_ID}" "${DEBUG_BUNDLE_ID}"; do
  run_as_app_user tccutil reset Microphone "${bid}" >/dev/null 2>&1 || true
  run_as_app_user tccutil reset Accessibility "${bid}" >/dev/null 2>&1 || true
  run_as_app_user tccutil reset PostEvent "${bid}" >/dev/null 2>&1 || true
done
run_as_app_user killall cfprefsd >/dev/null 2>&1 || true

if [[ "${PERMISSIONS_ONLY}" -ne 1 && "${#FAILED_PATHS[@]}" -gt 0 ]]; then
  cat >&2 <<EOF
warning: some paths could not be removed:
EOF
  for path in "${FAILED_PATHS[@]}"; do
    print_path "${path}" >&2
  done
  cat >&2 <<EOF

The most common cause is macOS protecting sandbox container metadata under
~/Library/Containers. If that remains, grant Full Disk Access to your terminal
app, then rerun this script. Everything else was still cleaned up.
EOF
fi

if [[ "${PERMISSIONS_ONLY}" -eq 1 ]]; then
  cat <<EOF
Hold to Talk permissions have been reset for ${APP_USER}.

This did not remove the app or local app state. For a clean first-run onboarding
test, use: make test-reset
EOF
else
  cat <<EOF
Hold To Talk has been removed for ${APP_USER}.

Fresh-start test sequence:
  1. Install Hold To Talk.app again
  2. Launch it from /Applications
  3. Onboarding, models, and permissions should behave like first run
EOF
fi
