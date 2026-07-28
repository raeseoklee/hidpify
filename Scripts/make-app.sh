#!/bin/bash
# Builds HidpifyApp (+ the hidpify CLI/daemon binary) in release mode and
# assembles them into dist/Hidpify.app. SPM cannot produce .app bundles
# directly (DESIGN.md §8.2), so this script does the bundling by hand: copy
# the executables, write Info.plist, ad-hoc sign.
#
# The `hidpify` CLI binary is copied into Contents/MacOS alongside HidpifyApp
# so that when the daemon (`hidpify daemon`, run via the LaunchAgent) executes
# from inside this bundle, macOS TCC (System Settings > Screen Recording) has
# a chance to attribute the grant to the Hidpify app's icon/name instead of
# showing a bare Mach-O "exec" entry. See LaunchAgentInstaller.swift for the
# path-resolution priority that makes the daemon prefer this bundled copy.
# NOTE: whether TCC actually attributes a Contents/MacOS helper binary to its
# parent bundle (rather than showing it standalone) can vary by macOS version
# and normally expects proper code signing — with the ad-hoc signing used here
# this is best-effort, not guaranteed. Verify visually in System Settings.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> swift build -c release"
swift build -c release

APP_NAME="Hidpify"
DIST_DIR="dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
BINARY_SRC=".build/release/HidpifyApp"
DAEMON_BINARY_SRC=".build/release/hidpify"

if [[ ! -x "${BINARY_SRC}" ]]; then
    echo "error: ${BINARY_SRC} not found (did the build fail?)" >&2
    exit 1
fi

if [[ ! -x "${DAEMON_BINARY_SRC}" ]]; then
    echo "error: ${DAEMON_BINARY_SRC} not found (did the build fail?)" >&2
    exit 1
fi

echo "==> assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}"

cp "${BINARY_SRC}" "${MACOS_DIR}/HidpifyApp"
chmod +x "${MACOS_DIR}/HidpifyApp"

cp "${DAEMON_BINARY_SRC}" "${MACOS_DIR}/hidpify"
chmod +x "${MACOS_DIR}/hidpify"

RESOURCES_DIR="${CONTENTS_DIR}/Resources"
mkdir -p "${RESOURCES_DIR}"
cp "Assets/hidpify.icns" "${RESOURCES_DIR}/hidpify.icns"

cat > "${CONTENTS_DIR}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.irae.hidpify.app</string>
    <key>CFBundleName</key>
    <string>Hidpify</string>
    <key>CFBundleDisplayName</key>
    <string>Hidpify</string>
    <key>CFBundleExecutable</key>
    <string>HidpifyApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>hidpify</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "==> codesign (ad-hoc)"
# Sign the inner hidpify daemon binary first (it's a secondary executable
# under Contents/MacOS that codesign's bundle-level sealing does not
# automatically re-sign), then sign the bundle as a whole — no --deep, same
# as before, so HidpifyApp's own bundle signature is unaffected.
codesign --force -s - "${MACOS_DIR}/hidpify"
codesign --force -s - "${APP_BUNDLE}"

echo "==> done: ${APP_BUNDLE}"
codesign -dv "${APP_BUNDLE}"
echo "==> inner hidpify binary signature:"
codesign -dv "${MACOS_DIR}/hidpify"
