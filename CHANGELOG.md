# Changelog

本项目的变更记录。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

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
