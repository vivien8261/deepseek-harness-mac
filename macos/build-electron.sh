#!/bin/bash
#
# build-electron.sh — build the Chromium (Electron) shell of DeepSeek Harness.
#
# The AppKit shell embeds WKWebView; the harness frontend's assistant-stream
# handling hits a WebKit-specific object-semantics bug ("Assistant stream raw
# chunk must be a lossless JSON object"; blank transcript) that Chrome never
# exhibits. Electron shares Chrome's engine, so this shell is the reliable one.
#
# Usage: build-electron.sh <--dist-only>
#   --dist-only  build into dist/ only; do not quit processes or install to
#                /Applications.
#
# Writes:
#   dist/DeepSeek Harness.app   Electron-based app (same name; drag to replace)
set -euo pipefail

DIST_ONLY=0
if [[ "${1:-}" == "--dist-only" || "${DSH_DIST_ONLY:-0}" == "1" ]]; then
  DIST_ONLY=1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
DIST="$REPO/dist"
APP="$DIST/DeepSeek Harness.app"
ELECTRON_VERSION="${ELECTRON_VERSION:-v44.2.0}"
ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" ]] && EL_ARCH="arm64" || EL_ARCH="x64"

log() { echo "[electron-build] $*"; }
fail() { echo "[electron-build] ERROR: $*" >&2; exit 1; }

# --- shared dsh runtime (same staging as the AppKit shell) -------------------
"$ROOT/scripts/build-dsh.sh" "$REPO"
"$ROOT/scripts/stage-runtime.sh" "$REPO"
"$ROOT/scripts/verify-runtime-auth.sh" "$REPO/dist/runtime/dsh"

# --- Electron binary (cached) ----------------------------------------------------
if (echo > /dev/tcp/127.0.0.1/7890) 2>/dev/null; then
  export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"
  export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"
  export ALL_PROXY="${ALL_PROXY:-http://127.0.0.1:7890}"
  log "检测到本地代理 127.0.0.1:7890"
fi

CACHE_DIR="$REPO/.cache/electron"
ZIP_NAME="electron-${ELECTRON_VERSION}-darwin-${EL_ARCH}.zip"
ZIP="$CACHE_DIR/$ZIP_NAME"
URL="https://github.com/electron/electron/releases/download/${ELECTRON_VERSION}/${ZIP_NAME}"

if [ ! -f "$ZIP" ]; then
  log "下载 Electron ${ELECTRON_VERSION} darwin-${EL_ARCH}…"
  mkdir -p "$CACHE_DIR"
  if ! curl -L --fail --retry 3 --retry-delay 2 -o "$ZIP.partial" "$URL"; then
    rm -f "$ZIP.partial"
    fail "下载失败: $URL（可设 ELECTRON_VERSION 指定其他版本）"
  fi
  mv "$ZIP.partial" "$ZIP"
else
  log "复用已缓存的 Electron zip: $ZIP"
fi

# --- assemble the app -------------------------------------------------------------
rm -rf "$APP"
EXTRACT="$(mktemp -d)"
trap 'rm -rf "$EXTRACT"' EXIT
log "解压 Electron…"
unzip -q "$ZIP" -d "$EXTRACT"
[ -d "$EXTRACT/Electron.app" ] || fail "zip 中未找到 Electron.app"

mv "$EXTRACT/Electron.app" "$APP"
mv "$APP/Contents/MacOS/Electron" "$APP/Contents/MacOS/DSH"
rm -rf "$APP/Contents/Resources/default_app.asar"

# --- identity: same bundle id/name as the AppKit shell -------------------------
python3 - "$APP/Contents/Info.plist" <<'EOF'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
info['CFBundleExecutable'] = 'DSH'
info['CFBundleIdentifier'] = 'ai.deepseek.dsh.macos'
info['CFBundleName'] = 'DeepSeek Harness'
info['CFBundleDisplayName'] = 'DeepSeek Harness'
info['CFBundleShortVersionString'] = '1.0.0'
info['CFBundleVersion'] = '1'
info['CFBundleIconFile'] = 'AppIcon'
with open(path, 'wb') as f:
    plistlib.dump(info, f)
EOF

# --- app code --------------------------------------------------------------------
mkdir -p "$APP/Contents/Resources/app"
cp -R "$ROOT/shell-electron/." "$APP/Contents/Resources/app/"

# --- runtime + icon ---------------------------------------------------------------
ditto "$REPO/dist/runtime/dsh" "$APP/Contents/Resources/dsh"
ditto "$REPO/dist/runtime/node" "$APP/Contents/Resources/node"
cp "$REPO/dist/runtime/runtime.json" "$APP/Contents/Resources/runtime.json"
chmod 755 "$APP/Contents/Resources/node/bin/node"
cp "$ROOT/DSH/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
"$ROOT/scripts/verify-runtime-auth.sh" "$APP/Contents/Resources/dsh"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

log "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "$DIST_ONLY" = "1" ]; then
  echo "Built $APP (--dist-only: 未退出任何进程，未安装到 /Applications)"
  exit 0
fi

INSTALL_APP="/Applications/DeepSeek Harness.app"
q() { osascript -e 'tell application "DeepSeek Harness" to quit' >/dev/null 2>&1 || true; }
q
for _ in 1 2 3 4 5; do
  pgrep -xq DSH >/dev/null 2>&1 || break
  sleep 0.4
done
pkill -x DSH >/dev/null 2>&1 || true
# Electron keeps helper processes (GPU/renderer) alive after the main process
# dies; they hold the .app bundle and break `rm -rf` below. Match the bundle
# path so other Electron apps are never touched.
pkill -9 -f "$INSTALL_APP/Contents/Frameworks/Electron" >/dev/null 2>&1 || true
sleep 1
rm -rf "$INSTALL_APP"
ditto "$APP" "$INSTALL_APP"
xattr -cr "$INSTALL_APP" >/dev/null 2>&1 || true
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$INSTALL_APP" >/dev/null 2>&1 || true
fi

echo "Installed $INSTALL_APP"
echo "Run with: open \"$INSTALL_APP\""
