# 📖 dsh-openai-bridge 使用说明书（小白版 · macOS / Linux）

让 **Chatbox** 用上 **DeepSeek Harness（dsh）智能体**：你在 Chatbox 里正常聊天，
管家（dsh Agent）就在你的 Mac/Linux 电脑上真实执行 bash 命令、读写文件、
调用子代理，工具过程实时显示（🔧📥✅❌）。本文按「零基础」流程写，照着做就行。

> 说明：本项目以 Windows + PowerShell 为主要支持平台；macOS/Linux 版使用官方
> bash 执行器（`cordis.yml`）。安装脚本与配置已就绪，其中 macOS 路径未经实机验证，
> 遇到问题欢迎到 GitHub 提 Issue。

---

## 一、你需要准备什么

| 东西 | 怎么得到 |
|---|---|
| 一台 macOS（或 Linux）电脑 | 你已经有了 😄 |
| Node.js ≥ 22.19 | macOS：`brew install node`；Linux：https://nodejs.org |
| git | macOS 自带；Linux 用系统包管理器安装 |
| DeepSeek API 密钥 | https://platform.deepseek.com → API Keys → 创建，复制 `sk-` 开头的字符串 |
| Chatbox | https://chatboxai.app 下载对应版本 |

## 二、安装（大约 5~15 分钟，主要是构建 dsh）

打开「终端」，依次执行：

```bash
# 1. 下载项目
git clone https://github.com/bftz22/dsh-openai-bridge.git
cd dsh-openai-bridge

# 2. 一键安装（可直接带参数，也可不带参数交互式输入）
chmod +x install.sh
./install.sh --api-key "sk-你的密钥"
```

脚本会自动完成：检查 Node.js → 安装 pnpm → 克隆并构建 DeepSeek Harness →
链接运行时插件 → 部署桥接文件 → 生成 `.env` 与启动脚本 → 启动服务。

**常用参数**：

| 参数 | 说明 |
|---|---|
| `--api-key "sk-…"` | DeepSeek API Key（不带则交互式输入） |
| `--system-prompt "…"` | Agent 系统提示词（默认 `You are a coding agent.`） |
| `--workspace /path` | Agent 工作目录（命令/文件工具的根目录） |
| `--port 8787` | 端口 |
| `--repo-dir ~/deepseek-harness` | dsh 仓库目录 |
| `-n` / `--no-start` | 只安装不启动 |
| `--skip-build` | 跳过构建（已构建过时加速） |

> 💡 国内网络：脚本会自动把 npm/pnpm 源切到 npmmirror 镜像加速。
> 不想切镜像可用 `DSH_BRIDGE_NO_MIRROR=1` 环境变量跳过。

## 三、启动

如果安装时用了 `-n`，或之后想重新启动：

```bash
cd ~/deepseek-harness
node server.mjs
```

看到 `dsh-openai-bridge 已启动` 就成功了（**这个终端窗口别关**）。

> 开机自启（macOS launchd / Linux systemd）：目前未提供一键注册，可按需自行配置。
> Windows 版 install.ps1 已内置开机自启注册，可作参考。

## 四、配置 Chatbox

1. Chatbox → 设置 ⚙️ → 模型提供方 → 添加自定义提供方（OpenAI 兼容）
2. 填写：
   - **API 地址**：`http://127.0.0.1:8787/v1`
   - **API 密钥**：任意非空值，如 `dsh-bridge`（桥不校验）
   - **模型**：`deepseek-v4-flash`（或与 `.env` 的 `DSH_BRIDGE_MODEL` 一致）
3. 保存，新建对话，开聊！

> ⏳ 第一条消息会慢几秒到几十秒：运行时子进程是惰性启动的（首次请求才拉起 dsh）。

## 五、能干什么

- 🗣️ 普通聊天
- 💻 执行 bash 命令：「列出当前目录文件」「查看磁盘剩余空间」「找出最大的 5 个文件」
- 📁 读写文件：「把 README.md 里 xxx 改成 yyy」「统计这个文件夹里有多少个 .py 文件」
- 🧠 多轮上下文记忆：它会记住之前的对话和操作结果
- 🔄 重置会话：发 `/clear`（或 `/new`）；发 `/help` 查看命令

## 六、自检（有问题时先跑这个）

```bash
cd ~/deepseek-harness
node smoke-test.mjs
```

会依次测试健康检查、模型列表、流式/非流式对话、工具调用、多轮记忆。
**6 项全过 = 一切正常。**

## 七、常见问题

| 问题 | 解决 |
|---|---|
| Chatbox 显示 Failed to fetch | 终端里桥进程没在运行，重新 `node server.mjs` |
| 报错 `Cannot find package @deepseek-ai/dsh-*` | 在 dsh 仓库目录执行 `pnpm add -w <插件名>`（见 README 手动安装） |
| bash 工具不可用 | 确认用的是 `cordis.yml`（bash 版，install.sh 已自动部署） |
| 想换模型 / 改性格 | 编辑 `~/deepseek-harness/.env` 的 `DSH_BRIDGE_MODEL` / `DSH_SYSTEM_PROMPT`，重启桥 |
| 结果空白但桥有日志 | 在 `.env` 设 `DSH_BRIDGE_DEBUG=1` → 重启桥 → 复现 → 把 `[bridge]` 日志贴进 Issue |

## 八、卸载

```bash
cd dsh-openai-bridge
./uninstall.sh          # 停止桥、删除部署文件；--remove-repo 可连 dsh 仓库一起删
rm -rf dsh-openai-bridge
```

---

有问题先跑 `node smoke-test.mjs`，把输出贴给开发者，能省一大半排查时间。
