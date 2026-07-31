#!/bin/bash
# Builds the universal (arm64 + x86_64) `hidpify` binary that the Homebrew
# formula installs, ad-hoc signs it, and packages it as the release tarball.
#
# The formula deliberately ships this prebuilt binary instead of building from
# source: `swift build` needs an up-to-date Xcode Command Line Tools install,
# and an outdated/missing one fails `brew install` outright. Signing here (not
# at install time) means installing needs no toolchain at all — an ad-hoc
# signature stays valid across Homebrew's copy.
#
# Usage: Scripts/make-prebuilt.sh   → dist/hidpify-<version>-macos-universal.tar.gz
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION="$(sed -n 's/.*version = "\([^"]*\)".*/\1/p' Sources/HidpifyCore/Version.swift | head -1)"
VERSION="${VERSION:-0.0.0}"

echo "==> swift build -c release --arch arm64 --arch x86_64"
swift build -c release --arch arm64 --arch x86_64

BINARY=".build/apple/Products/Release/hidpify"
[[ -x "${BINARY}" ]] || { echo "error: ${BINARY} not found" >&2; exit 1; }

# The universal (lipo'd) output comes out unsigned, so sign it here — launchd
# rejects an unsigned/invalid daemon binary at launch.
echo "==> codesign (ad-hoc)"
codesign --force -s - "${BINARY}"
codesign --verify --verbose=2 "${BINARY}"

mkdir -p dist
STAGE="$(mktemp -d)"
cp "${BINARY}" "${STAGE}/hidpify"
TARBALL="dist/hidpify-${VERSION}-macos-universal.tar.gz"
rm -f "${TARBALL}"
tar -czf "${TARBALL}" -C "${STAGE}" hidpify
rm -rf "${STAGE}"

echo "==> done: ${TARBALL}"
echo "architectures: $(lipo -info "${BINARY}" | sed 's/.*are: //')"
echo "sha256:        $(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
echo
echo "Next: gh release upload v${VERSION} ${TARBALL} --clobber"
echo "      then update url/sha256/version in homebrew-tap/Formula/hidpify.rb"
