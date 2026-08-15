#!/usr/bin/env bash
#
# 卸载 dsh-openai-bridge 的部署痕迹（不删除 deepseek-harness 仓库本身）。
#
# 用法:
#   ./uninstall.sh [--repo-dir DIR] [--remove-repo] [--keep-sessions]
#
set -euo pipefail

REPO_DIR="${HOME}/deepseek-harness"
REMOVE_REPO=0
KEEP_SESSIONS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir)    REPO_DIR="$2"; shift 2 ;;
    --remove-repo) REMOVE_REPO=1; shift ;;
    --keep-sessions) KEEP_SESSIONS=1; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

echo "==> 卸载 dsh-openai-bridge 部署文件（$REPO_DIR）"
[[ -d "$REPO_DIR" ]] || { echo "  仓库目录不存在，无需卸载。"; exit 0; }

for f in server.mjs cordis.yml .env start-dsh-chatbox.bat start-dsh-chatbox.sh; do
  if [[ -e "$REPO_DIR/$f" ]]; then
    rm -rf "$REPO_DIR/$f"
    echo "  已删除 $REPO_DIR/$f"
  fi
done

if [[ "$KEEP_SESSIONS" -ne 1 ]] && [[ -d "$REPO_DIR/.sessions" ]]; then
  rm -rf "$REPO_DIR/.sessions"
  echo "  已删除 $REPO_DIR/.sessions"
fi

if [[ "$REMOVE_REPO" -eq 1 ]]; then
  rm -rf "$REPO_DIR"
  echo "  已删除仓库 $REPO_DIR"
fi

echo "完成。"
