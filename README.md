# dsh-openai-bridge

让 **Chatbox**（以及任何 OpenAI 兼容客户端）直接使用 **DeepSeek Harness（dsh）** 构建的
Agent：不止聊天，而是能**执行命令、读写文件、拆解任务、带上下文和持久化记忆**的完整智能体。

```
┌──────────────┐   OpenAI 兼容 API    ┌──────────────────┐   stdio JSON-RPC    ┌─────────────────────────┐
│   Chatbox    │ ───────────────────► │ dsh-openai-bridge │ ──────────────────► │ dsh 运行时 (jsonrpc-agent)│
│  (任意客户端) │   /v1/chat/completions │  (server.mjs)      │   官方 SDK 子进程    │  + cordis.yml           │
└──────────────┘                      └──────────────────┘                     │  模型+工具+会话持久化      │
                                                                               └─────────────────────────┘
```

Chatbox 里发消息 → 桥接服务转换为 dsh 的 `session/prompt` 调用 → Agent 自主调用
bash（macOS/Linux）/ PowerShell（Windows）/ 文件系统 / 子代理 / todo 等工具 →
**工具调用过程实时回显**（🔧📥✅❌）→ 最终结果以 OpenAI SSE 流式格式显示在 Chatbox。

> **平台说明**：dsh 的 bash 执行器仅支持 POSIX（官方声明）。Windows 上安装脚本会自动
> 部署 `cordis-windows.yml`（官方 PowerShell 执行器 `dsh-pwsh-local` + `dsh-tool-pwsh`，
> 自动探测 PowerShell 7，找不到则回退到系统自带的 PowerShell 5.1），
> 管家在 Windows 上调用的工具是 `pwsh`。macOS/Linux 使用 `cordis.yml`（bash）。

## ✨ 特性

- **零依赖桥接**：`server.mjs` 仅用 Node 内置模块（http/crypto/fs），无任何第三方运行时依赖
- **流式输出**：SSE 打字机效果，工具进度实时可见
- **会话管理**：长驻会话（persistent）/ 一次性会话（per-request）、`X-DSH-Session` 多会话隔离、
  `/clear`、`/new`、`/help` 内置命令
- **工具过程展示**：Agent 每步调用（工具名 + 参数 + 结果/错误）都实时出现在回复里
- **推理过程透传**（可选）：`DSH_BRIDGE_SHOW_REASONING=1` 时输出
  `delta.reasoning_content`（DeepSeek 官方 API 同款非标准字段）
- **会话存档治理**：`.sessions/` 自动只保留最新 N 个（默认 20），不再无界增长
- **开机自启**（Windows）：install.ps1 自动注册「启动」文件夹，登录即自动运行
- **高容错**：路径容错（`/v1`、`/v1/chat/completions` 均可）、消息格式容错（字符串/内容块数组）、
  会话存档冲突免疫（随机前缀 + 代际号，重启永不撞车）
- **一键安装**：Windows / macOS / Linux 脚本自动完成全部部署（含国内镜像加速、npx 兜底）
- **配置简单**：同目录 `.env` 文件 + 常用环境变量

## 🚀 快速开始（一键安装）

### Windows

```powershell
# 若未安装 Node.js（>=22.19）：winget install OpenJS.NodeJS.LTS
# 解压本包后，在 dsh-openai-bridge 目录运行：
.\install.ps1 -ApiKey "sk-你的密钥"
```

### macOS / Linux

```bash
chmod +x install.sh
./install.sh --api-key "sk-你的密钥"
```

脚本自动完成：检查 Node.js → 安装 pnpm → 克隆并构建
[deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) →
链接运行时插件 → 部署桥接文件 → 生成 `.env` 与启动脚本 → 启动服务。
首次安装约 5~15 分钟（主要是构建 dsh）。

**常用参数**：

| 参数 | 说明 |
|---|---|
| `-ApiKey` / `--api-key` | DeepSeek API Key（也支持交互式输入） |
| `-SystemPrompt` / `--system-prompt` | Agent 系统提示词，默认 `You are a coding agent.` |
| `-Workspace` / `--workspace` | Agent 工作目录（命令/文件工具的根目录） |
| `-Port` / `--port` | 端口，默认 8787 |
| `-RepoDir` / `--repo-dir` | dsh 仓库目录，默认 `~/deepseek-harness` |
| `-NoStart` / `-n` | 只安装不启动 |
| `-SkipBuild` / `--skip-build` | 跳过构建（已构建过时加速） |

> 💡 **国内网络**：脚本会自动把 npm/pnpm 源切到 npmmirror 镜像加速。
> 若 Windows 提示「禁止运行脚本」，先在 PowerShell 执行
> `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`（输入 Y 确认）。

## 🔌 在 Chatbox 中配置

1. Chatbox → **设置（Settings）→ 模型提供方（Model Provider）**
2. 「**添加自定义提供方**」（Custom Provider / OpenAI API 兼容）
3. 填写：

   | 填写项 | 值 |
   |---|---|
   | API 地址 | `http://127.0.0.1:8787/v1`（若界面拆成「域名+路径」：域名填 `http://127.0.0.1:8787`，路径填 `/v1`） |
   | API 密钥 | 任意非空字符串（如 `dsh-bridge`，桥不校验） |
   | 模型 | `deepseek-v4-flash`（或与 `DSH_BRIDGE_MODEL` 一致即可） |

4. 保存，新建对话，发送第一条消息。

> ⏳ 第一条消息会慢几秒到几十秒：运行时子进程是惰性启动的（首次请求才拉起 dsh）。

## 📁 项目结构

| 文件 | 作用 |
|---|---|
| `server.mjs` | 桥接服务本体（OpenAI 兼容端点 + SSE 流式 + 会话管理 + 工具过程展示） |
| `cordis.yml` | dsh 运行时配置（macOS/Linux：bash 执行器） |
| `cordis-windows.yml` | dsh 运行时配置（Windows：PowerShell 执行器） |
| `install.ps1` / `install.sh` | 一键安装脚本（Windows / macOS·Linux） |
| `uninstall.ps1` / `uninstall.sh` | 卸载部署文件（`--remove-repo` 可连仓库一起删） |
| `autostart-bridge.bat` | 开机自启助手（install.ps1 自动注册到「启动」文件夹） |
| `.env.example` | 环境变量模板（复制为 `.env` 使用） |
| `guard.cs` / `guard.exe` | 危险命令拦截闸（Windows，见「安全防护」） |
| `watchdog.cmd` | 看门狗：node 退出后 3 秒自动重启（防误杀/崩溃） |
| `install-guard.ps1` | 编译并安装 guard.exe，写入 `.env` 的 `DSH_PWSH_GUARD` |
| `install-service.ps1` / `uninstall-service.ps1` / `service-status.ps1` | 后台服务（计划任务）安装/卸载/状态检查 |
| `docs/使用说明书-小白版.md` | 零代码经验用户手册（Windows） |
| `docs/使用说明书-Mac版.md` | 零代码经验用户手册（macOS/Linux） |
| `smoke-test.mjs` | 自检脚本：一键验证 healthz / 模型列表 / 流式补全 / 工具调用 / 多轮上下文（见「自检」） |
| `package.json` | 独立目录部署（方式 B）时的依赖声明 |

## 🔧 手动安装（可选，不依赖一键脚本）

### 前置条件

| 依赖 | 版本 | 说明 |
|---|---|---|
| Node.js | **>= 22.19**（dsh 要求） | `node -v` 查看 |
| pnpm | 11.x | `npm install -g pnpm@11.7.0` |
| DeepSeek API Key | — | [platform.deepseek.com](https://platform.deepseek.com/api_keys) 创建 |
| git | — | 克隆仓库用 |

### 方式 A：从 dsh 源码运行（推荐，最可靠）

```bash
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build:lib          # 只构建库即可；完整构建用 pnpm run build

# ⚠️ 关键：pnpm 不会把 workspace 插件链接到仓库根 node_modules，
# 必须显式把运行时插件加为根依赖，否则启动时报插件找不到：
pnpm add -w @deepseek-ai/dsh-sdk-jsonrpc-server @deepseek-ai/dsh-llm-deepseek \
  @deepseek-ai/dsh-subprocess-local @deepseek-ai/dsh-agent-spine-demo \
  @deepseek-ai/dsh-session-persistence-jsonl @deepseek-ai/dsh-session-checkpoint-policy \
  @deepseek-ai/dsh-subagent @deepseek-ai/dsh-subagent-spawn-in-process \
  @deepseek-ai/dsh-tool-subagent @deepseek-ai/dsh-tool-todo @deepseek-ai/dsh-fs-local \
  @deepseek-ai/dsh-fs-observation-policy @deepseek-ai/dsh-tool-fs \
  @deepseek-ai/dsh-token-meter @deepseek-ai/dsh-compaction-basic

# Linux/macOS 加：@deepseek-ai/dsh-bash-local
# Windows 加：  @deepseek-ai/dsh-pwsh-local @deepseek-ai/dsh-tool-pwsh @deepseek-ai/dsh-shell-env

# 复制桥接文件到仓库根目录（Windows 用 cordis-windows.yml → cordis.yml）
cp ../dsh-openai-bridge/server.mjs ../dsh-openai-bridge/cordis.yml .
```

### 方式 B：仅用 npm 包（实验性）

```bash
cd dsh-openai-bridge
npm install        # 安装 @deepseek-ai/dsh-sdk-client 等
```

> ⚠️ 方式 B 下 `cordis.yml` 引用的插件包需要能被运行时解析到。若启动报插件找不到，请回到方式 A。

### 启动

```bash
# 方式 A（在 dsh 仓库根目录）
export DEEPSEEK_API_KEY="sk-你的密钥"
export DSH_RUNTIME_COMMAND="node"
export DSH_RUNTIME_ARGS="./packages/examples/jsonrpc-demo/lib/bin.js ./cordis.yml"
node server.mjs

# 方式 B（独立目录）
export DEEPSEEK_API_KEY="sk-你的密钥"
node server.mjs
```

Windows PowerShell 对应：`$env:DEEPSEEK_API_KEY = "sk-…"` 后再 `node server.mjs`。

## ⚙️ 环境变量一览

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DEEPSEEK_API_KEY` | **必填** | DeepSeek API 密钥，传给运行时子进程 |
| `DSH_BRIDGE_PORT` | `8787` | 桥接服务监听端口（只监听 127.0.0.1） |
| `DSH_BRIDGE_MODEL` | `deepseek-v4-flash` | 默认模型名（经 JSON-RPC 按会话传给运行时） |
| `DSH_BRIDGE_PROVIDER` | `deepseek-official` | 模型路由 provider |
| `DSH_BRIDGE_MAX_TOKENS` | 无 | 每个会话的输出 token 上限 |
| `DSH_BRIDGE_SESSION_MODE` | `persistent` | `persistent`=跨请求保留上下文；`per-request`=每次新会话 |
| `DSH_BRIDGE_SHOW_TOOLS` | `1` | 工具过程展示开关（🔧 进度实时回显）；`0` 关闭 |
| `DSH_BRIDGE_SHOW_REASONING` | `0` | `1` 时透传推理过程（SSE `delta.reasoning_content`，非标准字段） |
| `DSH_BRIDGE_DEBUG` | `0` | `1` 时输出每条会话事件等详细日志（排查问题用） |
| `DSH_BRIDGE_USE_SYSTEM_PROMPT` | `0` | `1` 时采纳请求携带的 system 消息作为 persona（见下方说明） |
| `DSH_BRIDGE_SESSION_DIR` | `./.sessions` | 会话存档目录 |
| `DSH_BRIDGE_MAX_SESSIONS` | `20` | 会话存档保留数量（启动时/`/clear` 时/每小时自动清理超出部分） |
| `DSH_RUNTIME_COMMAND` | `dsh-jsonrpc-agent` | 运行时可执行文件（源码方式设为 `node`） |
| `DSH_RUNTIME_ARGS` | `cordis.yml` | 运行时参数，空格分隔 |
| `DSH_SYSTEM_PROMPT` | 空 | Agent 系统提示词（persona）；留空用 dsh 默认 |
| `DSH_CWD` | 当前目录 | Agent 的命令/文件工具工作根目录 |
| `DSH_PWSH_GUARD` | 空 | guard.exe 绝对路径（由 install-guard.ps1 写入；未设置时自动回退正常探测） |

配置来源优先级：**进程环境变量 > 同目录 `.env` 文件 > 默认值**。

> **关于请求级 system 消息**：Chatbox 工作模式每次请求都会携带一大段动态系统提示词。
> 若每次都据此重建运行时，会引发会话存档冲突（id collision）与空白回复。
> 因此桥**默认忽略请求级 system 消息**（persona 用 `.env` 的 `DSH_SYSTEM_PROMPT`）。
> 仅当你的客户端确实需要请求级 persona 时，才设置 `DSH_BRIDGE_USE_SYSTEM_PROMPT=1`。

## 🔒 安全防护（强烈建议开启）

管家的 pwsh 工具以**当前用户权限**执行命令，理论上可以杀掉桥进程、关系统、删文件。
本仓库提供两层防护，**建议都装**：

### 第一层：危险命令拦截闸 `guard.exe`（Windows）

管家每条 pwsh 命令都会先经过 guard 检查，命中危险特征即拒绝（如 `taskkill`、
`Stop-Process`、`shutdown`、`Restart-Computer`、`reg delete`、删除系统路径等），
其余命令原样转发给真实 PowerShell。

```powershell
# 安装（编译 guard.exe 并写入 .env 的 DSH_PWSH_GUARD；一键安装脚本已尽力自动完成）
.\install-guard.ps1
# 然后重启桥：关旧窗口 → 双击 start-dsh-chatbox.bat（或重启服务）
```

> 原理：`cordis-windows.yml` 中 pwsh 执行器的 `pwshPath` 指向 `guard.exe`；
> guard 用 Windows 自带的 .NET Framework 编译器（csc.exe）编译，无需任何额外依赖。
> 被拦截时管家会看到 `[安全拦截] 该命令被 dsh-openai-bridge 安全策略禁止…` 并退出码 1。

### 第二层：看门狗 + 后台服务（防误杀/防手滑关窗口/开机自启）

```powershell
# 安装为后台服务（登录后自动运行；node 被误杀后 3 秒自动重启；日志写 bridge.log）
.\install-service.ps1
# 查看状态 / 卸载
.\service-status.ps1
.\uninstall-service.ps1
```

> ⚠️ 服务模式与窗口模式（`start-dsh-chatbox.bat`）二选一，不要同时开（端口冲突）。
> 安装服务前先关掉手动开的桥窗口。

### 使用规则（与防护同等重要）

1. 不要把系统级任务交给管家：杀进程、关机重启、改注册表、删系统文件
2. 重要数据操作前，先让管家「只读」确认（如先列出清单再动手）
3. 管家与普通 LLM 一样可能“脑补”细节——关键结论要求展示工具原始输出

## 🛠 常用操作

| 操作 | 方法 |
|---|---|
| 验证服务 | `curl http://127.0.0.1:8787/healthz` |
| 查看模型列表 | `curl http://127.0.0.1:8787/v1/models` |
| 命令行测试 | `curl -N http://127.0.0.1:8787/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"列出当前目录文件"}],"stream":true}'` |
| 多会话隔离 | 请求头 `X-DSH-Session: <任意id>` 使用独立会话 |
| 重置上下文 | 对话中发送 `/clear` 或 `/new`；`/help` 查看命令 |
| 更新 dsh | `cd ~/deepseek-harness && git pull && pnpm install && pnpm run build:lib` |
| 清理会话存档 | 自动治理：只保留最新 `DSH_BRIDGE_MAX_SESSIONS`（默认 20）个；可调大或关桥后手动删除 `.sessions/` |

## 🐛 故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| 启动报「禁止运行脚本」 | Windows 执行策略 | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| 安装时 npm/pnpm 下载慢或失败 | 官方源慢 | 脚本已自动切 npmmirror；手动：`npm config set registry https://registry.npmmirror.com` |
| 运行时插件找不到（`Cannot find package '@deepseek-ai/dsh-*'`） | pnpm 未把 workspace 包链接到根 node_modules | 在仓库根执行 `pnpm add -w <插件列表>`（见手动安装） |
| 回复空白 / 会话存档冲突（id collision） | 旧会话存档与重启后的运行时不匹配 | 已内置随机前缀免疫；仍出现则删除 `.sessions/` 后重启 |
| Chatbox 报 `unknown route` | 地址填错/重复 | 域名填 `http://127.0.0.1:8787`，路径只填 `/v1` |
| 报 `no user message found` | 消息格式特殊 | 已兼容内容块数组；仍出现请开 `DSH_BRIDGE_DEBUG=1` 并反馈日志 |
| 第一条消息很慢 | 运行时惰性启动 | 正常，等 10~30 秒 |
| bash 工具报 spawn 失败（Windows） | bash 执行器仅支持 POSIX | 使用 Windows 版配置（PowerShell 执行器） |
| 结果空白但桥有日志 | Chatbox 工作模式显示问题 | 新建对话切回对话模式；或开 `DSH_BRIDGE_DEBUG=1` 反馈 |

排查通用姿势：`.env` 里设 `DSH_BRIDGE_DEBUG=1` → 重启桥 → 复现问题 → 把桥窗口
`[bridge]` 开头的日志连同报错一起贴进 issue。

## 🔍 自检（smoke-test.mjs）

一键验证桥服务全链路是否正常，适合安装后、升级后或排障时运行：

```bash
node smoke-test.mjs                    # 默认 http://127.0.0.1:8787
node smoke-test.mjs --port 9000        # 指定端口
node smoke-test.mjs --model deepseek-v4-flash   # 指定模型（默认读 DSH_BRIDGE_MODEL）
```

检查项：`/healthz`、`/v1/models`、非流式补全、流式补全（SSE + `[DONE]`）、
工具调用（真实执行 PowerShell 并回传输出）、多轮上下文（会话记忆）。
全部通过退出码为 0，任一失败退出码为 1。脚本使用独立会话（`smoke-*`），
结束后自动 `/clear`，不会干扰正在使用的 Chatbox 会话。

## 📸 实拍效果（截图待补充）

> 以下为**占位图**：请在 Chatbox 中实际使用后，把截图保存到 `docs/screenshots/`
> 目录（文件名见下方），替换后即可在 README 中展示。建议两张：
> ① Chatbox 对话界面（含流式回复）；② 工具调用轨迹（🔧📥✅ 过程展示）。

![Chatbox 对话界面（占位：docs/screenshots/chatbox-main.png）](docs/screenshots/chatbox-main.png)

![工具调用轨迹（占位：docs/screenshots/tool-traces.png）](docs/screenshots/tool-traces.png)

## 🤝 开源与贡献

- 本项目基于 **MIT License** 开源；`cordis*.yml` 改编自 DeepSeek Harness 官方示例
  （MIT，署名保留在文件头与 LICENSE 中）。
- 上游：DeepSeek Harness（dsh）https://github.com/deepseek-ai/deepseek-harness
- 欢迎提交 issue / PR：功能请求（如思考过程在 Chatbox 的原生展示）、
  Bug 报告（请附 `DSH_BRIDGE_DEBUG=1` 日志）、文档改进。

### 已知限制 / Roadmap

- dsh 官方 SDK 暂不支持外部工具调度/审批流，因此 Chatbox「工作模式」的原生工具调用界面
  无法对接；本桥以「工具过程展示」替代（等 dsh 开放审批流后即可原生支持）
- dsh 处于开发者预览期（v0.1.0-rc），接口可能变化
- 计划中：README 实拍截图（占位已就绪，待用户补图）、reasoning 内容在 Chatbox 的
  原生展示（当前仅透传数据）、macOS 开机自启一键注册（launchd）

## 📜 License

MIT © 2026 dsh-openai-bridge contributors。详见 [LICENSE](LICENSE)。
