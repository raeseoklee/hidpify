#!/bin/bash
# hidpify installer — build from source and install the CLI/daemon.
#
# One-liner (works once the repo is public):
#   curl -fsSL https://raw.githubusercontent.com/raeseoklee/hidpify/main/install.sh | bash
#
# Or from a local clone:
#   ./install.sh
#
# Environment overrides:
#   PREFIX=/usr/local/bin   install location (default: ~/.local/bin)
#   HIDPIFY_SRC=~/path       where to clone/build the source (default: ~/.hidpify/src)
#   HIDPIFY_REF=main         git ref to build (default: main)
#   WITH_AGENT=1             also install the LaunchAgent (auto-run daemon at login)
#
# Builds from source (no prebuilt binary), so there is no Gatekeeper/quarantine
# issue. Requires the Swift toolchain (Xcode Command Line Tools).
set -euo pipefail

REPO_HTTPS="https://github.com/raeseoklee/hidpify.git"
SRC="${HIDPIFY_SRC:-$HOME/.hidpify/src}"
REF="${HIDPIFY_REF:-main}"
PREFIX="${PREFIX:-$HOME/.local/bin}"

info() { printf '==> %s\n' "$1"; }
die()  { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only."
command -v swift >/dev/null 2>&1 || die "Swift toolchain not found. Install it with: xcode-select --install"
command -v git   >/dev/null 2>&1 || die "git not found."

# Fetch or update the source. If this script is already running inside a clone,
# build that; otherwise clone into $SRC.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/Package.swift" ]; then
    SRC="$SCRIPT_DIR"
    info "building from local checkout: $SRC"
elif [ -d "$SRC/.git" ]; then
    info "updating source in $SRC"
    git -C "$SRC" fetch --depth 1 origin "$REF"
    git -C "$SRC" checkout -q FETCH_HEAD
else
    info "cloning into $SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch "$REF" "$REPO_HTTPS" "$SRC"
fi

cd "$SRC"
info "swift build -c release"
swift build -c release

# Install the binary, re-signing after the copy (SPM's linker signature is
# invalidated on copy and launchd would reject the daemon — see install-cli.sh).
mkdir -p "$PREFIX"
rm -f "$PREFIX/hidpify"
cp .build/release/hidpify "$PREFIX/hidpify"
codesign --force -s - "$PREFIX/hidpify"
info "installed $PREFIX/hidpify"

case ":$PATH:" in
    *":$PREFIX:"*) ;;
    *) printf '    note: %s is not on your PATH — add it to your shell profile.\n' "$PREFIX" ;;
esac

if [ "${WITH_AGENT:-}" = "1" ]; then
    info "installing LaunchAgent"
    "$PREFIX/hidpify" install-agent
fi

echo
info "done. Try:  hidpify list"
