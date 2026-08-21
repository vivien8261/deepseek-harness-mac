#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
DIST="$REPO/dist"
APP="$DIST/DeepSeek Harness.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  TARGET="arm64-apple-macos13"
else
  TARGET="x86_64-apple-macos13"
fi

# --- build deepseek-harness from the submodule (cached; see build-dsh.sh) ----
if [ ! -e "$REPO/deepseek-harness/.git" ]; then
  echo "Initializing deepseek-harness submodule…"
  git -C "$REPO" submodule update --init --depth 1
fi
"$ROOT/scripts/build-dsh.sh" "$REPO"

"$ROOT/scripts/make-icon.sh"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES"

swiftc -parse-as-library \
  -O \
  -target "$TARGET" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -framework AppKit \
  -framework WebKit \
  -o "$MACOS_DIR/DSH" \
  "$ROOT/DSH/"*.swift

cp "$ROOT/DSH/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/DSH/Assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"
echo "Run with: open \"$APP\""
