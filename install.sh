#!/usr/bin/env bash
#
# dsh-openai-bridge 一键安装脚本（macOS / Linux）
#
# 自动完成：
#   1. 检查 Node.js（>= 22.19）
#   2. 安装 pnpm（如缺失）
#   3. 克隆 / 更新 deepseek-harness 仓库
#   4. 安装依赖并构建（pnpm run build:lib）
#   5. 部署桥接文件（server.mjs / cordis.yml）到仓库根目录
#   6. 生成 .env 配置与启动脚本
#   7. 启动桥接服务（-n 跳过启动）
#
# 用法：
#   ./install.sh --api-key sk-xxxx [--system-prompt "..." ] [--workspace /path] [--port 8787] [-n]
#
set -euo pipefail

API_KEY=""
SYSTEM_PROMPT=""
WORKSPACE=""
PORT=8787
REPO_DIR="${HOME}/deepseek-harness"
NO_START=0
SKIP_BUILD=0
FULL_BUILD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)       API_KEY="$2"; shift 2 ;;
    --system-prompt) SYSTEM_PROMPT="$2"; shift 2 ;;
    --workspace)     WORKSPACE="$2"; shift 2 ;;
    --port)          PORT="$2"; shift 2 ;;
    --repo-dir)      REPO_DIR="$2"; shift 2 ;;
    -n|--no-start)   NO_START=1; shift ;;
    --skip-build)    SKIP_BUILD=1; shift ;;
    --full-build)    FULL_BUILD=1; shift ;;
    -h|--help)
      echo "用法: $0 [--api-key KEY] [--system-prompt TEXT] [--workspace DIR] [--port N] [--repo-dir DIR] [-n|--no-start] [--skip-build] [--full-build]"
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { echo "    $*"; }
step()  { echo ""; echo "==> $*"; }
warn()  { echo "  [!] $*"; }
fail()  { echo "  [X] $*"; exit 1; }

echo ""
echo "=============================================================="
echo "  dsh-openai-bridge 一键安装（macOS / Linux）"
echo "  Chatbox ↔ DeepSeek Harness"
echo "=============================================================="

# ---------------------------------------------------------------- 0. 参数
if [[ -z "$API_KEY" ]]; then
  read -r -p "请输入 DeepSeek API Key（留空则稍后手动配置）: " API_KEY || true
fi
if [[ -z "$SYSTEM_PROMPT" ]]; then
  read -r -p "Agent 系统提示词（直接回车使用默认）: " SYSTEM_PROMPT || true
fi
[[ -z "$SYSTEM_PROMPT" ]] && SYSTEM_PROMPT="You are a coding agent."

# ---------------------------------------------------------------- 1. Node.js
step "1/7 检查 Node.js（要求 >= 22.19）"
if ! command -v node >/dev/null 2>&1; then
  fail "未找到 Node.js。请先安装 Node.js LTS（>= 22.19）：https://nodejs.org（macOS 也可 brew install node）"
fi
NODE_VER="$(node -v | tr -d 'v')"
MAJOR="${NODE_VER%%.*}"
MINOR="$(echo "$NODE_VER" | cut -d. -f2)"
if [[ "$MAJOR" -lt 22 ]] || { [[ "$MAJOR" -eq 22 ]] && [[ "$MINOR" -lt 19 ]]; }; then
  fail "Node.js 版本 v$NODE_VER 过低，dsh 需要 ^22.19.0 或 >=24.0.0。请升级后重试。"
fi
info "Node.js v$NODE_VER ✓"

# ---------------------------------------------------------------- 2. pnpm
step "2/7 检查 pnpm"
if ! command -v pnpm >/dev/null 2>&1; then
  info "未找到 pnpm，通过 npm 安装 pnpm@11.7.0 …"
  npm install -g pnpm@11.7.0
  if ! command -v pnpm >/dev/null 2>&1; then
    fail "pnpm 安装完成但未出现在 PATH，请打开新终端后重新运行本脚本。"
  fi
fi
info "pnpm ✓（$(command -v pnpm)）"

# ---------------------------------------------------------------- 3. 仓库
step "3/7 准备 deepseek-harness 仓库（$REPO_DIR）"
if [[ ! -d "$REPO_DIR" ]]; then
  info "克隆仓库 …"
  git clone --depth 1 https://github.com/deepseek-ai/deepseek-harness.git "$REPO_DIR" \
    || fail "git clone 失败。请确认已安装 git 且网络可用。"
else
  info "仓库已存在，尝试拉取更新 …"
  (cd "$REPO_DIR" && git pull --ff-only >/dev/null 2>&1) || warn "拉取更新失败（忽略，继续使用现有代码）"
fi
[[ -f "$REPO_DIR/pnpm-workspace.yaml" ]] \
  || fail "目录 $REPO_DIR 不是有效的 deepseek-harness 仓库，请用 --repo-dir 指定。"

# ---------------------------------------------------------------- 4. 依赖 + 构建
step "4/7 安装依赖并构建（首次约 5~15 分钟，请耐心等待）"
(
  cd "$REPO_DIR"
  pnpm install || fail "pnpm install 失败"
  if [[ "$SKIP_BUILD" -ne 1 ]]; then
    info "构建中 …"
    if [[ "$FULL_BUILD" -eq 1 ]]; then pnpm run build; else pnpm run build:lib; fi \
      || fail "构建失败"
  fi
)
# 链接运行时插件：cordis 配置从仓库根解析 @deepseek-ai/dsh-* 插件，
# pnpm 默认不会把 workspace 包链接到根 node_modules，必须显式加到根依赖
(
  cd "$REPO_DIR"
  info "链接运行时插件到仓库根 node_modules …"
  pnpm add -w \
    '@deepseek-ai/dsh-sdk-jsonrpc-server' '@deepseek-ai/dsh-llm-deepseek' \
    '@deepseek-ai/dsh-subprocess-local' '@deepseek-ai/dsh-bash-local' \
    '@deepseek-ai/dsh-agent-spine-demo' '@deepseek-ai/dsh-session-persistence-jsonl' \
    '@deepseek-ai/dsh-session-checkpoint-policy' '@deepseek-ai/dsh-subagent' \
    '@deepseek-ai/dsh-subagent-spawn-in-process' '@deepseek-ai/dsh-tool-subagent' \
    '@deepseek-ai/dsh-tool-todo' '@deepseek-ai/dsh-fs-local' \
    '@deepseek-ai/dsh-fs-observation-policy' '@deepseek-ai/dsh-tool-fs' \
    '@deepseek-ai/dsh-token-meter' '@deepseek-ai/dsh-compaction-basic' \
    || warn "插件链接未完全成功。可手动执行：cd $REPO_DIR; pnpm add -w <插件列表>（见 README）"
)
[[ -f "$REPO_DIR/packages/sdk/client/lib/index.js" ]] \
  || warn "未找到 SDK 构建产物 packages/sdk/client/lib/index.js，请确认构建成功（或去掉 --skip-build）。"

# ---------------------------------------------------------------- 5. 部署桥接文件
step "5/7 部署桥接文件到仓库根目录"
for f in server.mjs cordis.yml; do
  src="$SCRIPT_DIR/$f"
  dst="$REPO_DIR/$f"
  [[ -f "$src" ]] || fail "缺少 $f（应与本脚本同目录）"
  if [[ -f "$dst" ]]; then cp "$dst" "$dst.bak"; info "已备份旧文件 → $f.bak"; fi
  cp "$src" "$dst"
done
info "server.mjs / cordis.yml ✓"

# ---------------------------------------------------------------- 6. .env + 启动脚本
step "6/7 生成 .env 与启动脚本"
{
  echo "# dsh-openai-bridge 配置（由 install.sh 生成）"
  echo "DEEPSEEK_API_KEY=$API_KEY"
  echo "DSH_BRIDGE_PORT=$PORT"
  echo "DSH_BRIDGE_MODEL=deepseek-v4-flash"
  echo "DSH_RUNTIME_COMMAND=node"
  echo 'DSH_RUNTIME_ARGS="./packages/examples/jsonrpc-demo/lib/bin.js ./cordis.yml"'
  echo "DSH_SYSTEM_PROMPT=$SYSTEM_PROMPT"
  [[ -n "$WORKSPACE" ]] && echo "DSH_CWD=$WORKSPACE"
} > "$REPO_DIR/.env"

cat > "$REPO_DIR/start-dsh-chatbox.sh" <<'EOF'
#!/usr/bin/env bash
cd "$(dirname "$0")"
exec node server.mjs
EOF
chmod +x "$REPO_DIR/start-dsh-chatbox.sh"
info ".env / start-dsh-chatbox.sh ✓"

# ---------------------------------------------------------------- 7. 完成 / 启动
step "7/7 完成"
echo ""
echo "  桥接目录   : $REPO_DIR"
echo "  API 端点   : http://127.0.0.1:$PORT/v1"
echo ""
echo "  Chatbox 配置："
echo "    设置 → 模型提供方 → 添加自定义 OpenAI 兼容"
echo "    API 地址 : http://127.0.0.1:$PORT/v1"
echo "    API 密钥 : 任意非空值（如 dsh-bridge）"
echo "    模型     : deepseek-v4-flash"
echo ""

if [[ "$NO_START" -ne 1 ]]; then
  info "启动桥接服务（Ctrl+C 停止；以后可运行 $REPO_DIR/start-dsh-chatbox.sh）"
  echo ""
  cd "$REPO_DIR"
  exec node server.mjs
else
  info "本次未启动。以后启动："
  info "  $REPO_DIR/start-dsh-chatbox.sh"
  info "  或：cd $REPO_DIR && node server.mjs"
fi
