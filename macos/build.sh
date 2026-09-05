#!/bin/bash
set -euo pipefail

# --dist-only: build artifacts into dist/ without quitting running processes
# or replacing /Applications/DeepSeek Harness.app.
DIST_ONLY=0
if [[ "${1:-}" == "--dist-only" || "${DSH_DIST_ONLY:-0}" == "1" ]]; then
  DIST_ONLY=1
fi

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
"$ROOT/scripts/stage-runtime.sh" "$REPO"
"$ROOT/scripts/verify-runtime-auth.sh" "$REPO/dist/runtime/dsh"

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

ditto "$REPO/dist/runtime/dsh" "$RESOURCES/dsh"
ditto "$REPO/dist/runtime/node" "$RESOURCES/node"
cp "$REPO/dist/runtime/runtime.json" "$RESOURCES/runtime.json"
chmod 755 "$RESOURCES/node/bin/node"
"$ROOT/scripts/verify-runtime-auth.sh" "$RESOURCES/dsh"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP"
fi

if [ "$DIST_ONLY" = "1" ]; then
  echo "Built $APP (--dist-only: 未退出任何进程，未安装到 /Applications)"
  exit 0
fi

INSTALL_APP="/Applications/DeepSeek Harness.app"
if pgrep -xq DSH >/dev/null 2>&1; then
  echo "正在退出已运行的 DeepSeek Harness，以便安装到 /Applications…"
  osascript -e 'tell application "DeepSeek Harness" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    pgrep -xq DSH >/dev/null 2>&1 || break
    sleep 0.4
  done
  pkill -x DSH >/dev/null 2>&1 || true
fi
rm -rf "$INSTALL_APP"
ditto "$APP" "$INSTALL_APP"
xattr -cr "$INSTALL_APP" >/dev/null 2>&1 || true
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$INSTALL_APP"
fi

echo "Built $APP"
echo "Installed $INSTALL_APP"
echo "Run with: open \"$INSTALL_APP\""
