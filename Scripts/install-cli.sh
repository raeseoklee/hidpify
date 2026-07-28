#!/bin/bash
# Builds the hidpify CLI/daemon binary and installs it to ~/.local/bin
# (override with PREFIX=/some/dir), RE-SIGNING after the copy.
#
# Why the re-sign matters: SPM emits a "linker-signed" ad-hoc signature that is
# valid in place but gets invalidated by copying. `codesign --verify` still
# passes, yet launchd/taskgated rejects the moved binary at spawn time with
# "Invalid Signature" and SIGKILLs it — so the LaunchAgent (KeepAlive) restarts
# it in a tight crash loop (the daemon "turns on and off"). A fresh ad-hoc
# `codesign --force -s -` after the copy produces a self-contained signature
# that survives, so the daemon launches cleanly. Always install via this script
# (or otherwise re-sign after copying) rather than a bare `cp`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "==> swift build -c release"
swift build -c release

PREFIX="${PREFIX:-$HOME/.local/bin}"
DEST="$PREFIX/hidpify"

mkdir -p "$PREFIX"
rm -f "$DEST"
cp .build/release/hidpify "$DEST"
codesign --force -s - "$DEST"

echo "==> installed $DEST (re-signed ad-hoc)"
codesign -dv "$DEST" 2>&1 | grep -i "signature\|flags" | head -1 || true
echo "==> if the daemon is running, reload it:  launchctl kickstart -k gui/\$(id -u)/dev.irae.hidpify"
