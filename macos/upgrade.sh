#!/bin/bash
#
# upgrade.sh — 一键把 deepseek-harness submodule 升到最新（或指定）dsh-v* tag，并重建 App。
#
# Usage:
#   macos/upgrade.sh                 # 拉最新 dsh-v* tag → 更新 → 提交 → 构建（默认 Chromium/Electron 壳）
#   macos/upgrade.sh --check         # 只对比当前与最新，不改动
#   macos/upgrade.sh --list          # 列出上游 dsh-v* tag
#   macos/upgrade.sh --tag TAG       # 固定升到指定 tag（可降级）
#   macos/upgrade.sh --shell chromium   # 默认；构建 Electron（Chromium）壳（build-electron.sh）
#   macos/upgrade.sh --shell appkit     # 构建 WKWebView（AppKit）壳（build.sh）
#   macos/upgrade.sh --no-build      # 只更新 submodule，不构建
#   macos/upgrade.sh --no-commit     # 更新后不提交
#   macos/upgrade.sh --force         # 已是目标 tag 也强制重建
#
# 升级中途失败（如构建被打断）后，直接重跑本脚本即可自动续跑剩余步骤。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
DSH_DIR="$REPO/deepseek-harness"
TAG_PREFIX="dsh-v"

CHECK=0
LIST=0
NO_BUILD=0
NO_COMMIT=0
FORCE=0
REQUESTED_TAG=""
SHELL_KIND="chromium"

log() { echo "[upgrade] $*"; }
fail() { echo "[upgrade] ERROR: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
upgrade.sh — 一键把 deepseek-harness submodule 升到最新（或指定）dsh-v* tag，并重建 App。

Usage:
  macos/upgrade.sh                 # 拉最新 dsh-v* tag → 更新 → 提交 → 构建（默认 Chromium/Electron 壳）
  macos/upgrade.sh --check         # 只对比当前与最新，不改动
  macos/upgrade.sh --list          # 列出上游 dsh-v* tag
  macos/upgrade.sh --tag TAG       # 固定到指定 tag（可降级）
  macos/upgrade.sh --shell chromium   # 默认；构建 Electron（Chromium）壳（build-electron.sh）
  macos/upgrade.sh --shell appkit     # 构建 WKWebView（AppKit）壳（build.sh）
  macos/upgrade.sh --no-build      # 只更新 submodule，不构建
  macos/upgrade.sh --no-commit     # 更新后不提交
  macos/upgrade.sh --force         # 已是目标 tag 也强制重建

  升级中途失败后直接重跑本脚本，会自动续跑剩余步骤（无需 --force）。
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    --check) CHECK=1; shift ;;
    --list) LIST=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --no-commit) NO_COMMIT=1; shift ;;
    --force) FORCE=1; shift ;;
    --tag)
      [[ $# -ge 2 ]] || fail "--tag 需要参数"
      REQUESTED_TAG="$2"
      shift 2
      ;;
    --shell)
      [[ $# -ge 2 ]] || fail "--shell 需要参数"
      case "$2" in
        chromium|electron) SHELL_KIND="chromium" ;;
        appkit|webview|wkwebview) SHELL_KIND="appkit" ;;
        *) fail "--shell 仅支持 chromium|electron|appkit（默认 chromium）" ;;
      esac
      shift 2
      ;;
    *) fail "未知参数: $1（见 --help）" ;;
  esac
done

# --- optional local proxy (same detection as build-dsh.sh) -------------------
if (echo > /dev/tcp/127.0.0.1/7890) 2>/dev/null; then
  export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7890}"
  export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7890}"
  export ALL_PROXY="${ALL_PROXY:-http://127.0.0.1:7890}"
  export https_proxy="$HTTPS_PROXY"
  export http_proxy="$HTTP_PROXY"
  export all_proxy="$ALL_PROXY"
  log "检测到本地代理 127.0.0.1:7890，git 拉取将走代理"
fi

if [ ! -e "$DSH_DIR/.git" ]; then
  log "初始化 deepseek-harness submodule…"
  git -C "$REPO" submodule update --init --depth 1
fi
[ -e "$DSH_DIR/.git" ] || fail "submodule 不存在或未初始化: $DSH_DIR"

REMOTE="$(git -C "$DSH_DIR" remote get-url origin 2>/dev/null || true)"
[ -n "$REMOTE" ] || fail "submodule 没有 origin remote"

# --- list remote dsh-v* tags (newest last) -----------------------------------
# Only this prefix is a dsh release; vendor- / python- / landlock-run- tags are ignored.
list_remote_tags() {
  git -C "$DSH_DIR" ls-remote --tags origin \
    | awk '{print $2}' \
    | sed 's#^refs/tags/##' \
    | grep -v '\^{}$' \
    | grep -E "^${TAG_PREFIX}[0-9]" \
    | sort -V
}

log "查询上游 tag：$REMOTE"
REMOTE_TAGS="$(list_remote_tags || true)"
[ -n "$REMOTE_TAGS" ] || fail "上游没有 ${TAG_PREFIX}* 发布 tag"

if [ "$LIST" = "1" ]; then
  echo "$REMOTE_TAGS"
  exit 0
fi

LATEST_TAG="$(printf '%s\n' "$REMOTE_TAGS" | tail -1)"

current_tag() {
  git -C "$DSH_DIR" describe --tags --exact-match HEAD 2>/dev/null || true
}

CURRENT_TAG="$(current_tag)"
CURRENT_SHA="$(git -C "$DSH_DIR" rev-parse --short HEAD)"

if [ -n "$REQUESTED_TAG" ]; then
  TARGET_TAG="$REQUESTED_TAG"
  if ! printf '%s\n' "$REMOTE_TAGS" | grep -Fxq "$TARGET_TAG"; then
    fail "上游没有 tag：${TARGET_TAG}（可用 --list 查看）"
  fi
else
  TARGET_TAG="$LATEST_TAG"
fi

if [ -n "$CURRENT_TAG" ]; then
  log "当前: $CURRENT_TAG ($CURRENT_SHA)"
else
  log "当前: ${CURRENT_SHA}（未对准任何 tag）"
fi
log "目标: $TARGET_TAG"
log "最新: $LATEST_TAG"

if [ "$CHECK" = "1" ]; then
  if [ "$CURRENT_TAG" = "$LATEST_TAG" ]; then
    log "已是最新"
    exit 0
  fi
  log "有可用更新：$CURRENT_TAG → $LATEST_TAG"
  exit 2
fi

already_on_target=0
if [ "$CURRENT_TAG" = "$TARGET_TAG" ]; then
  already_on_target=1
fi

# 升级中断标记：动 submodule / 开始构建前写入，全部完成后删除。
# 中途失败后重跑本脚本会检测到它，直接续跑剩余步骤（构建会自动补上），
# 而不是因为"已在目标 tag"直接退出。
PENDING="$REPO/.git/upgrade-pending"
pending=0
if [ -f "$PENDING" ]; then
  pending_tag="$(head -n 1 "$PENDING" 2>/dev/null || true)"
  if [ "$pending_tag" = "$TARGET_TAG" ]; then
    pending=1
    log "检测到上次升级未完成（${TARGET_TAG}），继续完成剩余步骤"
  else
    rm -f "$PENDING"
    [ -z "$pending_tag" ] || log "已清理过期升级标记（${pending_tag}）"
  fi
fi

if [ "$already_on_target" = "1" ] && [ "$FORCE" != "1" ] && [ "$pending" != "1" ]; then
  log "已在目标 tag，无需更新（重建请加 --force）"
  exit 0
fi

# Auto mode never downgrades; --tag may pin an older release.
if [ -z "$REQUESTED_TAG" ] && [ -n "$CURRENT_TAG" ] && [ "$already_on_target" != "1" ]; then
  NEWER="$(printf '%s\n%s\n' "$CURRENT_TAG" "$TARGET_TAG" | sort -V | tail -1)"
  if [ "$NEWER" = "$CURRENT_TAG" ]; then
    log "当前 tag 新于上游最新，保持不动"
    exit 0
  fi
fi

if [ "$already_on_target" != "1" ]; then
  printf '%s\n' "$TARGET_TAG" > "$PENDING"
  log "拉取 ${TARGET_TAG}…"
  git -C "$DSH_DIR" fetch --depth 1 origin "tag" "$TARGET_TAG"
  git -C "$DSH_DIR" checkout --detach "$TARGET_TAG"
  NEW_SHA="$(git -C "$DSH_DIR" rev-parse --short HEAD)"
  log "已切换到 $TARGET_TAG ($NEW_SHA)"
else
  if [ "$FORCE" = "1" ]; then
    log "--force：保持 ${TARGET_TAG}，强制重建"
  else
    log "已在 ${TARGET_TAG}，续跑剩余步骤"
  fi
fi

# 提交 submodule 指针（幂等：上次升级已提交过则自动跳过；续跑时补上未提交的指针）
if [ "$already_on_target" != "1" ] || [ "$pending" = "1" ]; then
  git -C "$REPO" add "$DSH_DIR"
  if [ "$NO_COMMIT" = "1" ]; then
    log "已暂存 submodule 指针（--no-commit，未提交）"
  else
    if git -C "$REPO" diff --cached --quiet -- "$DSH_DIR"; then
      log "submodule 指针无变化，跳过提交"
    else
      if git -C "$REPO" commit -m "bump deepseek-harness to ${TARGET_TAG}"; then
        log "已提交：bump deepseek-harness to ${TARGET_TAG}"
      else
        log "提交失败（请检查 git user.name / user.email），submodule 已更新，继续构建"
      fi
    fi
  fi
fi

if [ "$NO_BUILD" = "1" ]; then
  rm -f "$PENDING"
  log "已更新，跳过构建（--no-build）"
  exit 0
fi

# 注意：变量必须用 ${} 括起来。系统自带的 bash 3.2 在 UTF-8 locale 下，
# 未加括号的 $VAR 紧跟全角字符时会把多字节字符吞进变量名，set -u 下直接报
# "unbound variable"（本脚本历史上就因此死在这一行）。
log "开始构建（SHELL_KIND=${SHELL_KIND}）…"
printf '%s\n' "$TARGET_TAG" > "$PENDING"
# 不用 exec：构建失败时标记保留，重跑可续；成功则删除标记，升级才算完成
if [ "$SHELL_KIND" = "chromium" ]; then
  "$ROOT/build-electron.sh"
else
  "$ROOT/build.sh"
fi
rm -f "$PENDING"
log "升级完成：${TARGET_TAG}"
