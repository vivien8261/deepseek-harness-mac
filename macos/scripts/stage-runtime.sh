#!/bin/bash
#
# stage-runtime.sh — pack a standalone dsh + Node 24 tree for the macOS app.
#
# Usage: stage-runtime.sh <repo-root>
#
# Writes:
#   <repo>/dist/runtime/dsh/          production deploy of @deepseek-ai/dsh
#   <repo>/dist/runtime/node/bin/node official Node 24 binary
#   <repo>/dist/runtime/runtime.json  versions for the Swift shell
#
# Caching: runtime.json records submodule HEAD and node version. When those
# match and the staged bin + node exist, deploy is skipped.
set -euo pipefail

REPO="${1:?usage: stage-runtime.sh <repo-root>}"
DSH_DIR="$REPO/deepseek-harness"
RUNTIME="$REPO/dist/runtime"
STAGING="$RUNTIME/dsh"
NODE_DIR="$RUNTIME/node"
MARKER="$RUNTIME/runtime.json"
BIN_REL="lib/bin.js"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RECIPE="5"

log() { echo "[runtime] $*"; }
fail() { echo "[runtime] ERROR: $*" >&2; exit 1; }

[ -e "${DSH_DIR}/.git" ] || fail "submodule 不存在或未初始化: ${DSH_DIR}"
[ -f "$DSH_DIR/apps/cli/lib/bin.js" ] || fail "请先运行 macos/scripts/build-dsh.sh（缺少 apps/cli/lib/bin.js）"

# --- pick the same node/pnpm as build-dsh.sh --------------------------------
for cand in /opt/homebrew/opt/node@24/bin /usr/local/opt/node@24/bin; do
  if [ -x "$cand/node" ]; then
    export PATH="$cand:$PATH"
    break
  fi
done

COMMIT="$(git -C "$DSH_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
NODE_V="$(node -v 2>/dev/null || echo missing)"
VERSION="$(node -p "require('$DSH_DIR/apps/cli/package.json').version" 2>/dev/null || echo unknown)"
ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
  NODE_ARCH="arm64"
else
  NODE_ARCH="x64"
fi
export NODE_ARCH

PM_SPEC="$(node -p "require('$DSH_DIR/package.json').packageManager" 2>/dev/null || echo '')"
PM_NAME="${PM_SPEC%%@*}"
PM_VER="${PM_SPEC##*@}"
SHIM_DIR="$REPO/.cache/bin"
if [ "$PM_NAME" = "pnpm" ] && [ -n "$PM_VER" ] && [ -f "$HOME/.cache/node/corepack/v1/pnpm/$PM_VER/dist/pnpm.mjs" ]; then
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/pnpm" <<EOF
#!/bin/sh
exec node "$HOME/.cache/node/corepack/v1/pnpm/$PM_VER/dist/pnpm.mjs" "\$@"
EOF
  chmod +x "$SHIM_DIR/pnpm"
  export PATH="$SHIM_DIR:$PATH"
  PNPM="pnpm"
elif command -v corepack >/dev/null 2>&1; then
  PNPM="corepack pnpm"
else
  PNPM="pnpm"
fi

if (echo > /dev/tcp/127.0.0.1/7890) 2>/dev/null; then
  export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"
  export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"
  export ALL_PROXY="${ALL_PROXY:-http://127.0.0.1:7890}"
  log "检测到本地代理 127.0.0.1:7890"
fi

cache_hit=0
if [ -f "$MARKER" ] && [ -f "$STAGING/$BIN_REL" ] && [ -x "$NODE_DIR/bin/node" ]; then
  M_COMMIT="$(node -p "require('$MARKER').commit" 2>/dev/null || true)"
  M_NODE="$(node -p "require('$MARKER').node" 2>/dev/null || true)"
  if [ "$M_COMMIT" = "$COMMIT" ] && [ "$M_NODE" = "$NODE_V" ]; then
    cache_hit=1
  fi
fi

if [ "$cache_hit" = "1" ]; then
  log "缓存命中：commit=${COMMIT} node=${NODE_V}，跳过 deploy（删除 ${MARKER} 可强制重建）"
  node "$SCRIPT_DIR/patch-wkwebview-auth.mjs" "$STAGING"
  # Idempotent pipeline steps may change without invalidating the cached tree;
  # record the current recipe and patch outcome so the shell can verify the
  # deployed runtime before use.
  node -e "
const fs = require('fs');
const marker = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
marker.recipe = process.argv[2];
marker.authPatch = process.argv[3];
marker.stagedAt = new Date().toISOString();
fs.writeFileSync(process.argv[1], JSON.stringify(marker, null, 2) + '\n');
" "$MARKER" "$RECIPE" "applied"
  exit 0
fi

log "开始打包独立运行时 commit=${COMMIT} version=${VERSION} node=${NODE_V} arch=${NODE_ARCH}"

# --- Node 24 official binary -------------------------------------------------
stage_node() {
  local ver="$1"
  local tarball="node-${ver}-darwin-${NODE_ARCH}.tar.gz"
  local cache_dir="$REPO/.cache/node-dist"
  local cache="$cache_dir/$tarball"
  local url="https://nodejs.org/dist/${ver}/${tarball}"
  mkdir -p "$cache_dir"
  if [ ! -f "$cache" ]; then
    log "下载官方 Node ${ver} darwin-${NODE_ARCH}…"
    if ! curl -L --fail --retry 3 --retry-delay 2 -o "$cache.partial" "$url"; then
      rm -f "$cache.partial"
      return 1
    fi
    mv "$cache.partial" "$cache"
  else
    log "复用已缓存的 Node tarball: $cache"
  fi
  local tmp
  tmp="$(mktemp -d)"
  if ! tar -xzf "$cache" -C "$tmp"; then
    rm -rf "$tmp"
    return 1
  fi
  local extracted
  extracted="$(echo "$tmp"/node-"$ver"-darwin-"$NODE_ARCH")"
  if [ ! -x "$extracted/bin/node" ]; then
    rm -rf "$tmp"
    return 1
  fi
  mkdir -p "$NODE_DIR/bin"
  cp "$extracted/bin/node" "$NODE_DIR/bin/node"
  chmod 755 "$NODE_DIR/bin/node"
  if [ -f "$extracted/LICENSE" ]; then
    cp "$extracted/LICENSE" "$NODE_DIR/LICENSE"
  fi
  rm -rf "$tmp"
  log "已写入 $NODE_DIR/bin/node"
}

stage_node_from_brew() {
  local src=""
  for cand in /opt/homebrew/opt/node@24/bin/node /usr/local/opt/node@24/bin/node; do
    if [ -x "$cand" ]; then
      src="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$cand")"
      break
    fi
  done
  [ -n "$src" ] || fail "无法下载官方 Node，且本机没有 node@24"
  log "警告：官方 tarball 不可用，回退拷贝 ${src}（运行机可能仍依赖 Homebrew 库）"
  mkdir -p "$NODE_DIR/bin"
  cp "$src" "$NODE_DIR/bin/node"
  chmod 755 "$NODE_DIR/bin/node"
}

rm -rf "$NODE_DIR"
if ! stage_node "$NODE_V"; then
  stage_node_from_brew
fi

# --- pnpm deploy production closure ------------------------------------------
rm -rf "$STAGING"
log "pnpm deploy @deepseek-ai/dsh --prod（可能需要几分钟）…"
export CI=true
START="$(date +%s)"
(
  cd "$DSH_DIR"
  $PNPM --filter @deepseek-ai/dsh deploy \
    --legacy \
    --prod \
    --config.node-linker=hoisted \
    --config.auto-install-peers=false \
    --config.link-workspace-packages=true \
    "$STAGING"
)
DURATION="$(( $(date +%s) - START ))"
log "pnpm deploy 完成，耗时 ${DURATION}s"

[ -f "$STAGING/$BIN_REL" ] || fail "deploy 完成但未找到 $STAGING/$BIN_REL"

log "解开 symlink、裁剪构建文件、chmod native helpers…"
node "$SCRIPT_DIR/materialize-runtime.mjs" "$STAGING" "$DSH_DIR"

[ -f "$STAGING/$BIN_REL" ] || fail "materialize 后丢失 $BIN_REL"

node "$SCRIPT_DIR/patch-wkwebview-auth.mjs" "$STAGING"

mkdir -p "$RUNTIME"
node -e "
const fs = require('fs');
const marker = {
  commit: process.argv[1],
  node: process.argv[2],
  version: process.argv[3],
  arch: process.argv[4],
  bin: process.argv[5],
  recipe: process.argv[6],
  authPatch: process.argv[7],
  stagedAt: new Date().toISOString(),
};
fs.writeFileSync(process.argv[8], JSON.stringify(marker, null, 2) + '\n');
" "$COMMIT" "$NODE_V" "$VERSION" "$NODE_ARCH" "$BIN_REL" "$RECIPE" "applied" "$MARKER"

SIZE="$(du -sh "$RUNTIME" | cut -f1)"
log "独立运行时已就绪：${RUNTIME} (${SIZE})"
log "dsh ${VERSION} / node ${NODE_V} / commit ${COMMIT}"
