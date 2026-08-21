#!/usr/bin/env bash
# Download the official llama.cpp xcframework and keep only the macOS slice,
# repackaged for this project's SwiftPM layout.
#
# Used by the local (S1-mini) text cleanup provider.
#
# Usage: bash scripts/setup-llama-cpp.sh [--force]

set -euo pipefail

LLAMA_BUILD="b10507"
ARCHIVE_NAME="llama-${LLAMA_BUILD}-xcframework.zip"
DOWNLOAD_URL="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_BUILD}/${ARCHIVE_NAME}"
ARCHIVE_SHA256="22f453fcd2ec483bcb1163d95cc712d88d656679b9fd24d65714d8e64d7d12d0"

DEST_DIR="Frameworks/llama.xcframework"
SLICE_DIR="${DEST_DIR}/macos-arm64_x86_64"
FRAMEWORK_DIR="${SLICE_DIR}/llama.framework"

FORCE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE=true
fi

# Skip if already set up (unless --force)
if [[ -f "${FRAMEWORK_DIR}/Versions/A/llama" && "${FORCE}" == "false" ]]; then
    echo "llama.cpp xcframework already present. Use --force to re-download."
    exit 0
fi

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_WORK}"' EXIT

sha256_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d ' ' -f 1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        echo "Error: neither shasum nor sha256sum is available for integrity verification." >&2
        exit 1
    fi
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local label="$3"
    local actual
    actual="$(sha256_file "${file}")"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "Error: SHA-256 mismatch for ${label}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
    echo "Verified ${label} SHA-256: ${actual}"
}

echo "Downloading llama.cpp ${LLAMA_BUILD} xcframework..."
curl -fSL --progress-bar "${DOWNLOAD_URL}" -o "${TMPDIR_WORK}/${ARCHIVE_NAME}"
verify_sha256 "${TMPDIR_WORK}/${ARCHIVE_NAME}" "${ARCHIVE_SHA256}" "${ARCHIVE_NAME}"

echo "Extracting macOS slice..."
# The published archive carries iOS/tvOS/visionOS slices and ~150 MB of dSYMs
# that this macOS-only app never uses. Take just the macOS framework.
unzip -q "${TMPDIR_WORK}/${ARCHIVE_NAME}" \
    "build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework/*" \
    -d "${TMPDIR_WORK}/extracted"

SRC_FRAMEWORK="${TMPDIR_WORK}/extracted/build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework"
if [[ ! -f "${SRC_FRAMEWORK}/Versions/A/llama" ]]; then
    echo "Error: llama.framework binary not found in ${ARCHIVE_NAME}" >&2
    exit 1
fi

rm -rf "${DEST_DIR}"
mkdir -p "${SLICE_DIR}"
cp -R "${SRC_FRAMEWORK}" "${SLICE_DIR}/"

# Create a macOS-only xcframework Info.plist.
cat > "${DEST_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>llama.framework/Versions/A/llama</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>llama.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
EOF

FINAL_SIZE=$(du -sh "${DEST_DIR}" | cut -f1)
echo "Done. llama.cpp ${LLAMA_BUILD} xcframework installed at ${DEST_DIR} (${FINAL_SIZE})"
