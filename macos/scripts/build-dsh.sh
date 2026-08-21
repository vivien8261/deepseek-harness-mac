#!/bin/bash
#
# build-dsh.sh — build the deepseek-harness submodule from source and cache the result.
#
# Usage: build-dsh.sh <repo-root>
#
# The submodule lives at <repo-root>/deepseek-harness. Building follows the
# upstream README ("Run from source"): pnpm install && pnpm run build.
#
# Caching: a marker file <repo-root>/dist/.dsh-build-state.json records the
# submodule HEAD commit, node/pnpm versions and the produced bin path. When the
# marker matches the current environment and the bin exists, the build is
# skipped entirely (fast startup). Any change to the commit, node or pnpm
# version, or a missing bin, triggers a full rebuild.
set -euo pipefail

REPO="${1:?usage: build-dsh.sh <repo-root>}"
DSH_DIR="$REPO/deepseek-harness"
MARKER="$REPO/dist/.dsh-build-state.json"
BIN_REL="apps/cli/lib/bin.js"

log() { echo "[dsh-build] $*"; }
fail() { echo "[dsh-build] ERROR: $*" >&2; exit 1; }

[ -e "${DSH_DIR}/.git" ] || fail "submodule 不存在或未初始化: ${DSH_DIR}（请先运行 git submodule update --init）"

cd "$DSH_DIR"

# --- pick node (24.x preferred; node 23 lacks import.meta.main, which the
#     upstream build scripts rely on: engines wants ^22.19.0 || >=24.0.0) ----
for cand in /opt/homebrew/opt/node@24/bin /usr/local/opt/node@24/bin; do
  if [ -x "$cand/node" ]; then
    export PATH="$cand:$PATH"
    break
  fi
done

# --- environment facts -------------------------------------------------------
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
NODE_V="$(node -v 2>/dev/null || echo missing)"
if ! node --input-type=module -e "if (!import.meta.main) process.exit(1)" 2>/dev/null; then
  fail "当前 node ${NODE_V} 不支持 import.meta.main（上游构建脚本依赖它，要求 node ^22.19.0 || >=24.0.0）。请安装 node@24：brew install node@24"
fi
log "submodule: $DSH_DIR"
log "commit:    $COMMIT"
log "node:      $NODE_V"

# --- pick pnpm (11.x via corepack; shim keeps subprocess pnpm in sync) ------
# pnpm >= 9 runs a "verify deps" step before `pnpm run` that spawns the `pnpm`
# found on PATH. If that resolves to an older pnpm, it can reject the lockfile
# (ERR_PNPM_LOCKFILE_CONFIG_MISMATCH). A shim pinned to the same corepack
# version placed first on PATH avoids that.
PM_SPEC="$(node -p "require('./package.json').packageManager" 2>/dev/null || echo '')"
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
  log "pnpm:      $PM_SPEC (corepack shim: $SHIM_DIR)"
elif command -v corepack >/dev/null 2>&1; then
  PNPM="corepack pnpm"
  log "pnpm:      corepack (packageManager: ${PM_SPEC:-unknown})（无 shim，子进程可能用 PATH 内其他 pnpm）"
else
  PNPM="pnpm"
  log "pnpm:      $(pnpm --version 2>/dev/null || echo missing) (corepack 不可用，请确保 pnpm >= 11)"
fi

CLIENT_PROFILE="official"
export DSH_BUILD_CLIENT_PROFILE="$CLIENT_PROFILE"

# --- cache hit check ----------------------------------------------------------
BIN="$DSH_DIR/$BIN_REL"
cache_hit=0
if [ -f "$MARKER" ]; then
  M_COMMIT="$(node -p "require('$MARKER').commit" 2>/dev/null || true)"
  M_NODE="$(node -p "require('$MARKER').node" 2>/dev/null || true)"
  M_PNPM="$(node -p "require('$MARKER').pnpm" 2>/dev/null || true)"
  M_PROFILE="$(node -p "require('$MARKER').clientProfile" 2>/dev/null || true)"
  if [ "$M_COMMIT" = "$COMMIT" ] && [ "$M_NODE" = "$NODE_V" ] && [ "$M_PNPM" = "$PNPM" ] && [ "$M_PROFILE" = "$CLIENT_PROFILE" ] && [ -f "$BIN" ]; then
    cache_hit=1
  fi
fi

if [ "$cache_hit" = "1" ]; then
  log "缓存命中：commit=$COMMIT node=$NODE_V 产物已就绪，跳过 install 与 build（如需强制重建请删除 ${MARKER}）"
  exit 0
fi

log "缓存未命中（commit/node/pnpm/产物任一变化），开始构建…"

# --- optional local proxy (common in CN networks), auto-detected -------------
if (echo > /dev/tcp/127.0.0.1/7890) 2>/dev/null; then
  export HTTPS_PROXY="http://127.0.0.1:7890"
  export HTTP_PROXY="http://127.0.0.1:7890"
  export ALL_PROXY="http://127.0.0.1:7890"
  log "检测到本地代理 127.0.0.1:7890，依赖下载将走代理"
fi

# --- install ---------------------------------------------------------------
# Reaching this point means the cache missed, so a fresh/complete install is
# required. `pnpm install` is idempotent: it finishes in seconds when
# node_modules is already complete, and resumes partial downloads otherwise.
log "安装依赖（pnpm install）…"
# Slow/flaky networks: raise fetch timeouts and retries, lower concurrency.
export npm_config_fetch_timeout=300000
export npm_config_fetch_retries=6
export npm_config_network_concurrency=8
# CI=true makes the root postinstall (install-lefthook.mjs) skip installing
# git hooks, which otherwise fails inside a submodule worktree. It also puts
# pnpm in frozen-lockfile mode, which matches the upstream lockfile.
export CI=true
START="$(date +%s)"
$PNPM install
DURATION="$(( $(date +%s) - START ))"
log "pnpm install 完成，耗时 ${DURATION}s"

# --- build -------------------------------------------------------------------
log "运行 pnpm run build（官方客户端品牌 DSH_BUILD_CLIENT_PROFILE=${CLIENT_PROFILE}）…"
START="$(date +%s)"
$PNPM run build
DURATION="$(( $(date +%s) - START ))"
log "pnpm run build 完成，耗时 ${DURATION}s"

[ -f "$BIN" ] || fail "构建完成但未找到产物 $BIN_REL"

# --- write marker ------------------------------------------------------------
mkdir -p "$(dirname "$MARKER")"
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('apps/cli/package.json', 'utf8'));
const marker = {
  commit: process.argv[1],
  node: process.argv[2],
  pnpm: process.argv[3],
  bin: process.argv[4],
  clientProfile: process.argv[5],
  version: pkg.version,
  builtAt: new Date().toISOString(),
  buildSeconds: Number(process.argv[6]),
};
fs.writeFileSync(process.argv[7], JSON.stringify(marker, null, 2) + '\n');
" "$COMMIT" "$NODE_V" "$PNPM" "$BIN_REL" "$CLIENT_PROFILE" "$DURATION" "$MARKER"

BIN_SIZE="$(du -h "$BIN" | cut -f1)"
log "构建产物: $BIN_REL ($BIN_SIZE)，版本 $(node -p "require('$DSH_DIR/apps/cli/package.json').version" 2>/dev/null || echo unknown)"
log "缓存标记已写入: ${MARKER}（下次启动将直接复用，不再构建）"
