#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/DSH/Assets"
SOURCE="$ASSETS/whale-source.png"
ICNS="$ASSETS/AppIcon.icns"
TOOL="$(mktemp -t dsh-make-icon)"

cleanup() {
  rm -f "$TOOL"
}
trap cleanup EXIT

if [[ ! -f "$SOURCE" ]]; then
  echo "missing whale source: $SOURCE" >&2
  exit 1
fi

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  TARGET="arm64-apple-macos13"
else
  TARGET="x86_64-apple-macos13"
fi

swiftc -parse-as-library \
  -O \
  -target "$TARGET" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit \
  -o "$TOOL" \
  "$ROOT/scripts/MakeIcon.swift"

"$TOOL" "$SOURCE" "$ICNS"
echo "wrote $ICNS"
