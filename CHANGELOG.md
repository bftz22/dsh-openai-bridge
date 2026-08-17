# Changelog

本项目的变更记录。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- **Cherry Studio 官方支持**：README 客户端配置章节拆分为「Chatbox / Cherry Studio 二选一」（Cherry 已在 2.0.5 真实界面验证）；新增 `docs/Cherry-Studio配置说明.md`（零改动法 + OpenAI 添加法 + 常见问题）
- **诊断工具开源**：新增 `tools/` 目录——`check-env.bat` / `check-env.ps1`（一键环境体检：Git/Node/VC++/WebView2/代理，缺失项自动 winget 安装）、`check-bridge.bat` / `check-bridge.ps1`（三层自检：桥进程 → 模型列表 → 真实对话）、`repair-links.ps1`（修复 18 个运行时插件链接，解决对话 500 / 插件树加载失败）
- **部署手册全面升级**：`docs/部署手册-中文版.md` 新增施工地图、5 步完成标志、AI 施工进度卡机制（进度播报 + 桌面 `施工进度.md`）、Git 前置安装、常见报错对照表（git 缺失 / VC++ 运行库 / 插件链接 / 代理拦截 / 401）
- **长任务心跳机制**：`server.mjs` 流式响应新增心跳增量（长任务执行期间定时输出，客户端不再显示"无响应"）；同步补全请求超时自动恢复机制（运行时死亡请求永不挂起的根除方案）
- **新运维工具**：`tools/token-stats.ps1`（从 bridge.log 解析 token 用量统计：回合数 / 输入合计 / 会话 TOP / 费用估算）、`tools/verify-heartbeat.mjs`（心跳回归验证脚本，真实请求长任务并观测 SSE 心跳流）

### 文档

- README 新增「下载之后，你能体验到什么」章节：从用户视角描述安装后的完整体验（真实执行命令、工具过程可视化、跨会话记忆、图片接收、推理透传、安全防护），一句话总结为"能指挥、会动手、有记忆、有护栏的 AI 管家"
- README 故障排查表新增 Cherry Studio 相关条目（401 地址未改 / ERR_NETWORK_ACCESS_DENIED 代理拦截 / 构建 0xC0000005 缺 VC++）
- README 修复历史 merge 冲突残留的重复章节结构（原两遍内容合并为单遍，内容一致无丢失）
- README 新增「致谢与测试」名单（首台异地真机部署测试贡献者）

## [1.1.0] - 2026-08-15

### 新增

- **推理过程透传**：`DSH_BRIDGE_SHOW_REASONING=1` 时，dsh 的 `reasoning-delta`
  事件转为 OpenAI SSE 的 `delta.reasoning_content`（DeepSeek 官方 API 同款非标准
  字段），非流式响应同时附加 `message.reasoning_content`；默认关闭
- **会话存档治理**：`.sessions/` 目录只保留最新 `DSH_BRIDGE_MAX_SESSIONS`
  （默认 20）个会话存档（按修改时间），启动时、`/clear`/`/new` 时、每小时自动
  清理超出部分；目录可用 `DSH_BRIDGE_SESSION_DIR` 指定
- **开机自启**：新增 `autostart-bridge.bat`（登录时若 8787 未监听则自动启动桥），
  `install.ps1` 安装时自动注册到「启动」文件夹
- **Mac 版说明书**：`docs/使用说明书-Mac版.md`（macOS/Linux 小白手册）

### 改进

- 事件级调试日志全部归入 `DSH_BRIDGE_DEBUG=1`（默认静默），避免日志刷屏

## [1.0.1] - 2026-08-15

### 新增

- **安全防护（强烈建议开启）**：
  - `guard.cs` / `install-guard.ps1`：危险命令拦截闸。用 Windows 自带 csc.exe 编译为
    `guard.exe`，管家的每条 pwsh 命令先过闸：`taskkill`、`Stop-Process`、`shutdown`、
    `Restart-Computer`、`reg delete`、删除系统路径等危险命令直接拒绝（`[安全拦截]` 提示），
    其余原样转发给真实 PowerShell（pwsh 7 → PATH → 系统自带 5.1 兑底）
  - `watchdog.cmd` + `install-service.ps1`：桥改为开机自启后台服务（计划任务），
    node 被误杀/崩溃后 3 秒自动重启，日志写 `bridge.log`；配套 `service-status.ps1` /
    `uninstall-service.ps1`
  - `install.ps1` 自动部署安全组件并尽力编译 guard.exe（失败不影响安装，可稍后重跑
    `install-guard.ps1`）
  - README 新增「安全防护」章节；`cordis-windows.yml` 支持 `DSH_PWSH_GUARD`
    （未设置时自动回退正常探测）

## [1.0.0] - 2026-08-15

首个开源版本。项目源于一次"在 Chatbox 中使用 DeepSeek Harness"的实战调试，
沉淀为可一键安装、可复用的 OpenAI 兼容桥接服务。

### 新增

- **桥接服务 `server.mjs`**（零运行时依赖，仅 Node 内置模块）：
  - OpenAI 兼容端点：`GET /v1/models`、`POST /v1/chat/completions`（SSE 流式 + 非流式）
  - 路径容错：兼容 `/v1`、`/v1/chat/completions`、`/chat/completions` 等客户端写法
  - 消息格式兼容：`content` 支持字符串与内容块数组（兼容 Chatbox 工作模式）
  - 会话管理：`persistent` 长驻会话 / `per-request` 一次性会话；`X-DSH-Session` 请求头隔离；
    `/clear`、`/new`、`/help` 内置命令
  - **工具过程展示**：Agent 调用工具时实时输出 🔧/📥/✅/❌ 进度（可用 `DSH_BRIDGE_SHOW_TOOLS=0` 关闭）
  - 会话存档冲突免疫：会话 ID 带随机前缀 + 运行时代际号，重启/重建永不与磁盘旧存档冲突
  - 简易 `.env` 加载（无需 dotenv 依赖）
  - dsh SDK 双路径加载：npm 包优先，dsh 仓库根目录运行时自动回退到本地构建产物
- **一键安装脚本**：
  - `install.ps1`（Windows）：检查 Node.js → 安装 pnpm（含国内镜像与 npx 兜底）→
    克隆/构建 dsh 仓库 → 链接运行时插件 → 部署文件 → 生成 `.env` 与启动脚本 → 启动
  - `install.sh`（macOS/Linux）：对应功能
  - `uninstall.ps1` / `uninstall.sh`：清理部署文件（可选删除整个仓库）
- **运行时配置**：
  - `cordis.yml`：macOS/Linux 版（bash 执行器）
  - `cordis-windows.yml`：Windows 版（PowerShell 执行器 `dsh-pwsh-local` +
    `dsh-tool-pwsh` + `dsh-shell-env`，自动探测 PowerShell 7 / 5.1）
- **文档**：README（中英双语要点）、`docs/使用说明书-小白版.md`（零代码经验用户手册）、
  `.env.example`、`LICENSE`（MIT + DeepSeek Harness 署名）

### 修复（来自实战调试的教训）

- pnpm 不会把 workspace 包链接到仓库根 `node_modules`，导致运行时找不到
  `@deepseek-ai/dsh-*` 插件 —— 安装脚本改为显式 `pnpm add -w` 链接插件
- 每次请求都按请求 system 消息重建运行时，引发「session id collision」与空白回复
  —— 默认忽略请求级 system 消息（用 `.env` persona），会话 ID 引入随机前缀 + 代际号
- Chatbox 工作模式消息格式（`content` 为数组、路径拼写差异）导致 400/404
  —— 消息解析与路由全部容错
- Windows PowerShell 5.1 解析无 BOM 的 UTF-8 脚本会乱码 —— 安装脚本按 5.1 兼容加 BOM
- 流式模式下错误被吞掉、Chatbox 显示 `[object Object]` —— 错误改为文本 delta 输出

### 已知限制

- dsh 官方 SDK 暂不支持外部工具调度/审批流，因此 Chatbox「工作模式」的
  原生工具调用界面无法对接；本桥以「工具过程展示」作为替代方案
- bash 执行器仅支持 POSIX；Windows 上使用 PowerShell 执行器（官方对应实现）
- dsh 处于开发者预览期（v0.1.0-rc），接口可能变化，遇到问题请更新 dsh 后重试

## [1.1.4] - 2026-08-16

### 改进

- **工具过程展示四档可调，默认改为摘要模式（贴近 Chatbox 原生观感）**：
  `DSH_BRIDGE_SHOW_TOOLS=0` 完全关闭；`1` 摘要（默认）——工具过程完全不刷屏，
  回合结束只追加一行统计（如 `🔧 调用工具 3 次（pwsh×2、read），失败 1 次：…`）；
  `2` 紧凑（每步单行实时回显）；`3` 完整（参数 + 结果，调试用）。
  管家回复现在与原生对话几乎无差别，只在末尾保留一行透明统计。

## [1.1.3] - 2026-08-16

### 改进

- **工具过程展示三档可调**：`DSH_BRIDGE_SHOW_TOOLS` 现支持三档——
  `0` 关闭 / `1` 紧凑（默认，每个工具调用只回显单行 `🔧 正在调用：{name}` → `✅ {name} 完成`，
  错误只显示单行摘要）/ `2` 完整（旧版行为：参数 200 字 + 结果 300 字，调试用）。
  告别大段工具轨迹刷屏，管家工作过程更接近原生对话的干净观感。

## [1.1.2] - 2026-08-16

### 修复

- **Node 24 启动崩溃（`ERR_AMBIGUOUS_MODULE_SYNTAX`）**：server.mjs 中 `__dirname`
  与顶层 await 混用导致 Node 24 拒绝启动（曾引发重启风暴）；改用 ESM 标准写法
  `import.meta.dirname`
- **批处理编码问题**：`watchdog.cmd` / `start-watchdog*.bat/vbs` 的 UTF-8 中文注释
  在 cmd 的 ANSI(GBK) 解析下会吞掉换行、破坏语法；注释已全部 ASCII 化
- **install.ps1 生成模板**：`start-dsh-chatbox.bat` 模板注释改为 ASCII，避免复发

### 新增

- `github-sync-loop.vbs`：GitHub 自动同步循环（每 15 分钟静默 fetch/pull/push）
- `THIRD_PARTY_NOTICES.md`：第三方声明独立成文（LICENSE 保持纯 MIT 便于 GitHub 识别）

## [1.1.1] - 2026-08-16

### 更新

- sync: 更新 server.mjs（本机实际运行版）、watchdog.cmd（加固版）、cordis.yml（guard 接线）

### 新增

- `launch-dsh.cmd/vbs`（一键启动器）、`restart-bridge.cmd`、`status-bridge.cmd`、
  `start-watchdog*.bat/vbs`、预编译 `guard.exe`
