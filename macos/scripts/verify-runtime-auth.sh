#!/bin/bash
#
# verify-runtime-auth.sh — fail loudly when a staged dsh runtime lacks the
# WKWebView WebSocket auth patch (0.1.3 browser-session auth).
#
# Usage: verify-runtime-auth.sh <dsh-dir>
#
# The patch (patch-wkwebview-auth.mjs) relaxes the session cookie to
# SameSite=Lax and accepts the process launch token on the /api/remote.mux
# upgrade. Without it the Mac shell loads the page but the live journal stream
# stays empty. This check exists so a stale or unpatched runtime can never be
# silently packaged into the app.
set -euo pipefail

DIR="${1:?usage: verify-runtime-auth.sh <dsh-dir>}"
TARGET="$DIR/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js"

[ -f "$TARGET" ] || { echo "[verify-auth] ERROR: missing $TARGET" >&2; exit 1; }

TOKEN_COUNT="$(grep -c 'hasLaunchToken(' "$TARGET" || true)"
LAX_COUNT="$(grep -c 'SameSite=Lax' "$TARGET" || true)"

if [ "$TOKEN_COUNT" -ge 1 ] && [ "$LAX_COUNT" -ge 1 ]; then
  echo "[verify-auth] PASS: WKWebView auth patch present (hasLaunchToken=${TOKEN_COUNT}, SameSite=Lax=${LAX_COUNT})"
  exit 0
fi

echo "[verify-auth] FAIL: WKWebView auth patch missing (hasLaunchToken=${TOKEN_COUNT}, SameSite=Lax=${LAX_COUNT})" >&2
echo "[verify-auth] 该运行时缺少 0.1.3 WebSocket 鉴权补丁，App 页面实时输出将不可用。" >&2
exit 1
