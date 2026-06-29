#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-dmg.sh --app-bundle <path> --output <path> --volume-name <name>
EOF
}

APP_BUNDLE=""
OUTPUT_DMG=""
VOLUME_NAME=""

while (($# > 0)); do
  case "$1" in
    --app-bundle)
      APP_BUNDLE="$2"
      shift 2
      ;;
    --output)
      OUTPUT_DMG="$2"
      shift 2
      ;;
    --volume-name)
      VOLUME_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${APP_BUNDLE}" || -z "${OUTPUT_DMG}" || -z "${VOLUME_NAME}" ]]; then
  usage >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="$(basename "${APP_BUNDLE}")"
APP_ITEM_NAME="${APP_NAME}"
BACKGROUND_NAME="installer-background.png"
ICON_SOURCE="${REPO_ROOT}/Resources/HoldToTalk.icns"
BACKGROUND_TEXTURE="${REPO_ROOT}/Resources/images/dmg-background.jpeg"
MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null || echo "15.0")"
WINDOW_LEFT=140
WINDOW_TOP=120
WINDOW_WIDTH=720
WINDOW_HEIGHT=460
ICON_SIZE=112
APP_POS_X=188
APP_POS_Y=252
APPS_POS_X=532
APPS_POS_Y=252

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/holdtotalk-dmg.XXXXXX")"
STAGING_DIR="${WORK_DIR}/staging"
BACKGROUND_DIR="${STAGING_DIR}/.background"
BACKGROUND_PATH="${BACKGROUND_DIR}/${BACKGROUND_NAME}"
RW_DMG="${WORK_DIR}/temp.dmg"
MOUNT_DIR=""
APPLESCRIPT_FILE="${WORK_DIR}/style-dmg.applescript"
DMG_DEVICE=""

cleanup() {
  detach_dmg >/dev/null 2>&1 || true
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

detach_dmg() {
  [[ -n "${DMG_DEVICE}" ]] || return 0

  local attempt
  for attempt in 1 2 3 4 5; do
    if hdiutil detach "${DMG_DEVICE}" -quiet >/dev/null 2>&1; then
      DMG_DEVICE=""
      return 0
    fi
    sleep 1
  done

  hdiutil detach -force "${DMG_DEVICE}" -quiet >/dev/null
  DMG_DEVICE=""
}

ds_store_has_custom_layout() {
  local ds_store_path="$1"

  [[ -f "${ds_store_path}" ]] || return 1

  LC_ALL=C strings "${ds_store_path}" | grep -q 'backgroundImageAlias' || return 1
  LC_ALL=C strings "${ds_store_path}" | grep -q '\.background' || return 1
}

mkdir -p "${STAGING_DIR}" "${BACKGROUND_DIR}" "$(dirname "${OUTPUT_DMG}")"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"

CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/holdtotalk-clang-cache" \
SWIFT_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/holdtotalk-swift-cache" \
swift "${SCRIPT_DIR}/render-dmg-background.swift" \
  "${BACKGROUND_PATH}" \
  "${BACKGROUND_TEXTURE}" \
  "${MINIMUM_SYSTEM_VERSION}"

ln -s /Applications "${STAGING_DIR}/Applications"

STAGING_MB="$(du -sm "${STAGING_DIR}" | awk '{print $1}')"
DMG_SIZE_MB=$((STAGING_MB + 32))

rm -f "${OUTPUT_DMG}"
hdiutil create \
  -size "${DMG_SIZE_MB}m" \
  -fs HFS+ \
  -volname "${VOLUME_NAME}" \
  -type UDIF \
  -ov \
  "${RW_DMG}" >/dev/null

ATTACH_OUTPUT="$(
  hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    -nobrowse \
    -mountrandom /Volumes \
    "${RW_DMG}"
)"

DMG_DEVICE="$(printf '%s\n' "${ATTACH_OUTPUT}" | awk -F '\t' '/^\/dev\// {gsub(/[[:space:]]+$/, "", $1); print $1; exit}')"
MOUNT_DIR="$(printf '%s\n' "${ATTACH_OUTPUT}" | awk -F '\t' '/Apple_HFS|APFS/ {print $3; exit}')"

if [[ -z "${DMG_DEVICE}" || -z "${MOUNT_DIR}" ]]; then
  echo "error: failed to locate mounted DMG device or mount directory" >&2
  exit 1
fi

ditto "${STAGING_DIR}" "${MOUNT_DIR}"
if [[ -f "${ICON_SOURCE}" ]]; then
  cp "${ICON_SOURCE}" "${MOUNT_DIR}/.VolumeIcon.icns"
  SetFile -a C "${MOUNT_DIR}" >/dev/null 2>&1 || true
fi

cat > "${APPLESCRIPT_FILE}" <<EOF
on run argv
  set volumeName to item 1 of argv
  set appItemName to item 2 of argv
  set backgroundName to item 3 of argv
  set mountPath to item 4 of argv
  set dsStorePath to quoted form of (mountPath & "/.DS_Store")
  set theXOrigin to ${WINDOW_LEFT}
  set theYOrigin to ${WINDOW_TOP}
  set theWidth to ${WINDOW_WIDTH}
  set theHeight to ${WINDOW_HEIGHT}
  set theBottomRightX to (theXOrigin + theWidth)
  set theBottomRightY to (theYOrigin + theHeight)

  tell application "Finder"
    activate
    tell disk volumeName
      open
      repeat with _ from 1 to 15
        if (exists file appItemName of container window) and (exists folder ".background" of container window) and (exists file backgroundName of folder ".background" of container window) then
          exit repeat
        end if
        delay 1
      end repeat

      tell container window
        set current view to icon view
        try
          set toolbar visible to false
        end try
        try
          set statusbar visible to false
        end try
        set bounds to {theXOrigin, theYOrigin, theBottomRightX, theBottomRightY}
      end tell

      set opts to the icon view options of container window
      set bgPicture to (POSIX file (mountPath & "/.background/" & backgroundName)) as alias
      set arrangement of opts to not arranged
      set icon size of opts to ${ICON_SIZE}
      set text size of opts to 13
      set background picture of opts to bgPicture

      set position of item appItemName of container window to {${APP_POS_X}, ${APP_POS_Y}}
      set position of item "Applications" of container window to {${APPS_POS_X}, ${APPS_POS_Y}}
      try
        set position of item ".background" of container window to {5000, 5000}
      end try
      try
        set position of item ".VolumeIcon.icns" of container window to {5200, 5200}
      end try
      close
      open
      delay 1
      update without registering applications
      tell container window
        set bounds to {theXOrigin, theYOrigin, theBottomRightX - 10, theBottomRightY - 10}
      end tell
    end tell

    delay 1

    tell disk volumeName
      tell container window
        set bounds to {theXOrigin, theYOrigin, theBottomRightX, theBottomRightY}
      end tell
    end tell

    set waitTime to 0
    repeat while waitTime is less than 15
      delay 1
      if (do shell script "[ -f " & dsStorePath & " ] && echo yes || echo no") is "yes" then
        exit repeat
      end if
      set waitTime to waitTime + 1
    end repeat

    try
      tell disk volumeName to close container window
    end try
  end tell
end run
EOF

VOLUME_ID="$(basename "${MOUNT_DIR}")"

STYLE_OK=0
for attempt in 1 2 3; do
  if osascript "${APPLESCRIPT_FILE}" "${VOLUME_ID}" "${APP_ITEM_NAME}" "${BACKGROUND_NAME}" "${MOUNT_DIR}"; then
    if ds_store_has_custom_layout "${MOUNT_DIR}/.DS_Store"; then
      STYLE_OK=1
      break
    fi

    echo "warning: Finder styling attempt ${attempt} did not persist the custom background metadata." >&2
  else
    echo "warning: Finder styling attempt ${attempt} failed." >&2
  fi

  rm -f "${MOUNT_DIR}/.DS_Store"
  sleep 1
done

if [[ "${STYLE_OK}" -ne 1 ]]; then
  echo "error: Finder styling failed; refusing to package a DMG without the custom install layout." >&2
  exit 1
fi

if [[ -f "${ICON_SOURCE}" ]]; then
  SetFile -a V "${MOUNT_DIR}/.VolumeIcon.icns" >/dev/null 2>&1 || true
  chflags hidden "${MOUNT_DIR}/.VolumeIcon.icns" >/dev/null 2>&1 || true
fi
SetFile -a V "${MOUNT_DIR}/.background" >/dev/null 2>&1 || true
SetFile -a V "${MOUNT_DIR}/.background/${BACKGROUND_NAME}" >/dev/null 2>&1 || true
chflags hidden "${MOUNT_DIR}/.background" >/dev/null 2>&1 || true
chflags hidden "${MOUNT_DIR}/.background/${BACKGROUND_NAME}" >/dev/null 2>&1 || true

chmod -Rf go-w "${MOUNT_DIR}" >/dev/null 2>&1 || true
bless --folder "${MOUNT_DIR}" --openfolder "${MOUNT_DIR}" >/dev/null 2>&1 || true
sync

detach_dmg

hdiutil convert "${RW_DMG}" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "${OUTPUT_DMG}" >/dev/null

if [[ -f "${ICON_SOURCE}" ]]; then
  DMG_ICON="${WORK_DIR}/dmg-file-icon.icns"
  DMG_ICON_RSRC="${WORK_DIR}/dmg-file-icon.rsrc"
  cp "${ICON_SOURCE}" "${DMG_ICON}"
  sips -i "${DMG_ICON}" >/dev/null
  DeRez -only icns "${DMG_ICON}" > "${DMG_ICON_RSRC}"
  Rez -append "${DMG_ICON_RSRC}" -o "${OUTPUT_DMG}"
  SetFile -a C "${OUTPUT_DMG}" >/dev/null 2>&1 || true
fi

echo "Packaged ${OUTPUT_DMG}"
