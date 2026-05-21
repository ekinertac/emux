#!/usr/bin/env bash
#
# build-libghostty.sh — rebuild the vendored GhosttyKit.xcframework from a pinned Ghostty tag.
#
# Usage:
#   ./scripts/build-libghostty.sh                                  # uses defaults
#   GHOSTTY_TAG=v1.4.0 ./scripts/build-libghostty.sh               # override tag
#   ZIG=/path/to/zig-0.15.2 ./scripts/build-libghostty.sh          # override zig binary
#
# Requires:
#   - zig at the version Ghostty's build.zig.zon pins (currently 0.15.2 for v1.3.1).
#     If your default `zig` is a different version, set the ZIG env var to an explicit
#     binary path. zigup is convenient for multi-version management.
#   - git
#   - xcode-select-installed Apple toolchain
#
# Writes:
#   Frameworks/GhosttyKit.xcframework  (replaces any existing copy)
#   Frameworks/LIBGHOSTTY_VERSION      (records the tag built)
#
set -euo pipefail

GHOSTTY_TAG="${GHOSTTY_TAG:-v1.3.1}"
ZIG="${ZIG:-zig}"
WORKDIR="$(mktemp -d)"
EMUX_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Using zig: $ZIG"
"$ZIG" version

echo "==> Cloning ghostty-org/ghostty @ $GHOSTTY_TAG into $WORKDIR ..."
git clone --depth=1 --branch="$GHOSTTY_TAG" \
    https://github.com/ghostty-org/ghostty "$WORKDIR/ghostty"

echo "==> Building XCFramework (this can take 10-20 minutes) ..."
cd "$WORKDIR/ghostty"
"$ZIG" build -Demit-macos-app=false

echo "==> Vendoring xcframework into $EMUX_ROOT/Frameworks/ ..."
rm -rf "$EMUX_ROOT/Frameworks/GhosttyKit.xcframework"
cp -R macos/GhosttyKit.xcframework "$EMUX_ROOT/Frameworks/"
echo "$GHOSTTY_TAG" > "$EMUX_ROOT/Frameworks/LIBGHOSTTY_VERSION"

echo "==> Done. Pinned to $GHOSTTY_TAG."
echo "    Commit the changes in Frameworks/ to record the bump."
