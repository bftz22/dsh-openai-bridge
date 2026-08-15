#requires -Version 5.1
<#
.SYNOPSIS
  dsh-openai-bridge 一键安装脚本（Windows / PowerShell）

.DESCRIPTION
  自动完成：
    1. 检查 Node.js（>= 22.19）
    2. 安装 pnpm（如缺失）
    3. 克隆 / 更新 deepseek-harness 仓库
    4. 安装依赖并构建（pnpm run build:lib）
    5. 部署桥接文件（server.mjs / cordis.yml）到仓库根目录
    6. 生成 .env 配置与启动脚本
    7. 注册开机自启（启动文件夹，可用 -NoAutostart 跳过）
    8. 启动桥接服务（可用 -NoStart 跳过）

.PARAMETER ApiKey
  DeepSeek API Key（platform.deepseek.com 创建）。缺省时交互式询问。

.PARAMETER SystemPrompt
  Agent 系统提示词。缺省时交互式询问；直接回车使用默认值。

.PARAMETER Workspace
  Agent 工作目录（bash / 文件系统的根）。可选。

.PARAMETER Port
  桥接服务端口，默认 8787。

.PARAMETER RepoDir
  deepseek-harness 仓库目录，默认 $HOME\deepseek-harness。

.PARAMETER NoStart
  只安装不启动。

.PARAMETER SkipBuild
  跳过构建（仓库已构建过时加快速度）。

.PARAMETER FullBuild
  执行完整构建 pnpm run build（默认只构建 lib，更快）。

.PARAMETER NoAutostart
  不注册开机自启（默认注册到当前用户「启动」文件夹）。

.EXAMPLE
  .\install.ps1 -ApiKey "sk-xxxx"
  .\install.ps1 -ApiKey "sk-xxxx" -SystemPrompt "你是资深编程助手" -Workspace "D:\code\myproj"
  .\install.ps1 -ApiKey "sk-xxxx" -NoStart
#>
param(
  [string]$ApiKey = "",
  [string]$SystemPrompt = "",
  [string]$Workspace = "",
  [int]$Port = 8787,
  [string]$RepoDir = (Join-Path $HOME "deepseek-harness"),
  [switch]$NoStart,
  [switch]$SkipBuild,
  [switch]$FullBuild,
  [switch]$NoAutostart
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = (Get-Location).Path }

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Green }
function Write-Info($msg)  { Write-Host "    $msg" }
function Write-Warn2($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Write-Fail($msg)  { Write-Host "  [X] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  dsh-openai-bridge 一键安装（Windows）" -ForegroundColor Cyan
Write-Host "  Chatbox ↔ DeepSeek Harness" -ForegroundColor Cyan
Write-Host "==============================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------- 0. 参数
if (-not $ApiKey) {
  $ApiKey = Read-Host "请输入 DeepSeek API Key（留空则稍后手动配置）"
}
if (-not $SystemPrompt) {
  $SystemPrompt = Read-Host "Agent 系统提示词（直接回车使用默认）"
}
if (-not $SystemPrompt) { $SystemPrompt = "You are a coding agent." }

# ---------------------------------------------------------------- 1. Node.js
Write-Step "1/7 检查 Node.js（要求 >= 22.19）"
$nodeExe = $null
$cmd = Get-Command node -ErrorAction SilentlyContinue
if ($cmd) { $nodeExe = $cmd.Source }
if (-not $nodeExe) {
  foreach ($p in @("$env:ProgramFiles\nodejs\node.exe", "$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
    if (Test-Path $p) { $nodeExe = $p; break }
  }
}
if (-not $nodeExe) {
  Write-Fail "未找到 Node.js。请先安装 Node.js LTS（>= 22.19）："
  Write-Fail "  winget install OpenJS.NodeJS.LTS   或   https://nodejs.org"
  exit 1
}
$verRaw = (& $nodeExe -v).Trim()
$parts = $verRaw.TrimStart('v').Split('.')
$major = [int]$parts[0]; $minor = [int]$parts[1]
$versionOk = ($major -gt 22) -or ($major -eq 22 -and $minor -ge 19)
if (-not $versionOk) {
  Write-Fail "Node.js 版本 $verRaw 过低，dsh 需要 ^22.19.0 或 >=24.0.0。请升级后重试。"
  exit 1
}
Write-Info "Node.js $verRaw ✓（$nodeExe）"

# ---------------------------------------------------------------- 2. pnpm（自动降级：全局安装 → 国内镜像重试 → npx 免安装）
Write-Step "2/7 检查 pnpm"
$npmExe = Join-Path (Split-Path $nodeExe) "npm.cmd"
if (-not (Test-Path $npmExe)) {
  $npmInPath = Get-Command npm -ErrorAction SilentlyContinue
  if ($npmInPath) { $npmExe = $npmInPath.Source }
}
if (-not (Test-Path $npmExe)) {
  Write-Fail "未找到 npm（Node.js 安装可能不完整）。请重装 Node.js LTS：https://nodejs.org"
  exit 1
}
$pnpmExec = @('pnpm')   # 默认：直接使用 pnpm 命令
$pnpmCmd = (Get-Command pnpm -ErrorAction SilentlyContinue).Source
if (-not $pnpmCmd) {
  Write-Info "未找到 pnpm，尝试全局安装 pnpm@11.7.0 …"
  & $npmExe install -g pnpm@11.7.0
  if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "全局安装失败（常见：官方源超时）。切换国内镜像重试 …"
    & $npmExe config set registry https://registry.npmmirror.com
    & $npmExe install -g pnpm@11.7.0
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Warn2 "仍失败。改用 npx 免安装方式（无需安装 pnpm）…"
    & $npmExe exec pnpm@11.7.0 -- -v
    if ($LASTEXITCODE -eq 0) {
      $pnpmExec = @($npmExe, 'exec', 'pnpm@11.7.0', '--')
    } else {
      Write-Fail "pnpm 不可用，无法继续。请检查网络后重试。"
      exit 1
    }
  } else {
    # 全局安装成功 → 刷新 PATH 后重新查找
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $pnpmCmd = (Get-Command pnpm -ErrorAction SilentlyContinue).Source
    if (-not $pnpmCmd) {
      Write-Warn2 "pnpm 已装好但当前窗口没刷新到，改用 npx 方式继续 …"
      $pnpmExec = @($npmExe, 'exec', 'pnpm@11.7.0', '--')
    }
  }
}
Write-Info "pnpm 就绪（方式：$($pnpmExec -join ' ')）"
# 顺带设置国内镜像，加速后续依赖下载（对国内网络友好）
& $npmExe config set registry https://registry.npmmirror.com 2>$null

# ---------------------------------------------------------------- 3. 仓库
Write-Step "3/7 准备 deepseek-harness 仓库（$RepoDir）"
if (-not (Test-Path $RepoDir)) {
  Write-Info "克隆仓库 …"
  git clone --depth 1 https://github.com/deepseek-ai/deepseek-harness.git $RepoDir
  if ($LASTEXITCODE -ne 0) {
    Write-Fail "git clone 失败。请确认已安装 git（winget install Git.Git）且网络可用。"
    exit 1
  }
} else {
  Write-Info "仓库已存在，尝试拉取更新 …"
  Push-Location $RepoDir
  git pull --ff-only 2>$null
  if ($LASTEXITCODE -ne 0) { Write-Warn2 "拉取更新失败（忽略，继续使用现有代码）" }
  Pop-Location
}
if (-not (Test-Path (Join-Path $RepoDir "pnpm-workspace.yaml"))) {
  Write-Fail "目录 $RepoDir 不是有效的 deepseek-harness 仓库，请换一个目录或用 -RepoDir 指定。"
  exit 1
}

# ---------------------------------------------------------------- 4. 依赖 + 构建
Write-Step "4/7 安装依赖并构建（首次约 5~15 分钟，请耐心等待）"
Push-Location $RepoDir
& $pnpmExec install
if ($LASTEXITCODE -ne 0) { Write-Fail "pnpm install 失败"; Pop-Location; exit 1 }
if (-not $SkipBuild) {
  Write-Info "构建中 …"
  if ($FullBuild) { & $pnpmExec run build } else { & $pnpmExec run build:lib }
  if ($LASTEXITCODE -ne 0) { Write-Fail "构建失败"; Pop-Location; exit 1 }
}
# 链接运行时插件：cordis 配置从仓库根解析 @deepseek-ai/dsh-* 插件，
# pnpm 默认不会把 workspace 包链接到根 node_modules，必须显式加到根依赖
Write-Info "链接运行时插件到仓库根 node_modules …"
$pluginList = @(
  '@deepseek-ai/dsh-sdk-jsonrpc-server', '@deepseek-ai/dsh-llm-deepseek',
  '@deepseek-ai/dsh-subprocess-local', '@deepseek-ai/dsh-pwsh-local',
  '@deepseek-ai/dsh-agent-spine-demo', '@deepseek-ai/dsh-session-persistence-jsonl',
  '@deepseek-ai/dsh-session-checkpoint-policy', '@deepseek-ai/dsh-subagent',
  '@deepseek-ai/dsh-subagent-spawn-in-process', '@deepseek-ai/dsh-tool-subagent',
  '@deepseek-ai/dsh-tool-todo', '@deepseek-ai/dsh-fs-local',
  '@deepseek-ai/dsh-fs-observation-policy', '@deepseek-ai/dsh-tool-fs',
  '@deepseek-ai/dsh-token-meter', '@deepseek-ai/dsh-compaction-basic',
  '@deepseek-ai/dsh-shell-env', '@deepseek-ai/dsh-tool-pwsh'
)
& $pnpmExec add -w $pluginList
if ($LASTEXITCODE -ne 0) {
  Write-Warn2 "插件链接未完全成功。可手动执行：cd $RepoDir; pnpm add -w <插件列表>（见 README）"
}
$sdkLib = Join-Path $RepoDir "packages\sdk\client\lib\index.js"
if (-not (Test-Path $sdkLib)) {
  Write-Warn2 "未找到 SDK 构建产物 packages/sdk/client/lib/index.js，请确认构建成功（或去掉 -SkipBuild）。"
}
Pop-Location

# ---------------------------------------------------------------- 5. 部署桥接文件
Write-Step "5/7 部署桥接文件到仓库根目录"
# Windows：使用 PowerShell 执行器版配置（bash 执行器不支持 Windows）
foreach ($f in @('server.mjs', 'cordis-windows.yml')) {
  $src = Join-Path $ScriptDir $f
  if (-not (Test-Path $src)) { Write-Fail "缺少 $f（应与本脚本同目录）"; exit 1 }
}
$dstServer = Join-Path $RepoDir "server.mjs"
$dstConfig = Join-Path $RepoDir "cordis.yml"
if (Test-Path $dstServer) { Copy-Item $dstServer "$dstServer.bak" -Force }
Copy-Item (Join-Path $ScriptDir "server.mjs") $dstServer -Force
if (Test-Path $dstConfig) { Copy-Item $dstConfig "$dstConfig.bak" -Force }
Copy-Item (Join-Path $ScriptDir "cordis-windows.yml") $dstConfig -Force
Write-Info "server.mjs / cordis.yml（Windows PowerShell 版）✓"

# ---------------------------------------------------------------- 6. .env + 启动脚本
Write-Step "6/7 生成 .env 与启动脚本"
$envLines = [System.Collections.Generic.List[string]]::new()
$envLines.Add("# dsh-openai-bridge 配置（由 install.ps1 生成）")
$envLines.Add("DEEPSEEK_API_KEY=$ApiKey")
$envLines.Add("DSH_BRIDGE_PORT=$Port")
$envLines.Add("DSH_BRIDGE_MODEL=deepseek-v4-flash")
$envLines.Add("DSH_RUNTIME_COMMAND=node")
$envLines.Add('DSH_RUNTIME_ARGS="./packages/examples/jsonrpc-demo/lib/bin.js ./cordis.yml"')
$envLines.Add("DSH_SYSTEM_PROMPT=$SystemPrompt")
if ($Workspace) { $envLines.Add("DSH_CWD=$Workspace") }
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines((Join-Path $RepoDir ".env"), $envLines, $utf8NoBom)

$batContent = "@echo off`r`nrem dsh-openai-bridge 启动脚本（由 install.ps1 生成）`r`ncd /d `"%~dp0`"`r`nnode server.mjs`r`n"
[System.IO.File]::WriteAllText((Join-Path $RepoDir "start-dsh-chatbox.bat"), $batContent, $utf8NoBom)
Write-Info ".env / start-dsh-chatbox.bat ✓"

# 开机自启：注册到当前用户「启动」文件夹（登录时若端口未监听则自动启动桥）
if (-not $NoAutostart) {
  $startupDir = [Environment]::GetFolderPath('Startup')
  if (-not $startupDir) { $startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup" }
  $autoBat = "@echo off`r`nrem dsh-openai-bridge autostart (Startup folder)`r`ncd /d `"$RepoDir`"`r`nnetstat -ano | findstr `":$Port`" | findstr `"LISTENING`" >nul`r`nif not errorlevel 1 (`r`n  exit /b 0`r`n)`r`nnode server.mjs`r`n"
  $startupBat = Join-Path $startupDir "dsh-openai-bridge.bat"
  [System.IO.File]::WriteAllText($startupBat, $autoBat, $utf8NoBom)
  Write-Info "开机自启已注册：$startupBat"
} else {
  Write-Info "已跳过开机自启注册（-NoAutostart）"
}

# ---------------------------------------------------------------- 7. 完成 / 启动
Write-Step "7/7 完成"
Write-Host ""
Write-Host "  桥接目录   : $RepoDir" -ForegroundColor Yellow
Write-Host "  API 端点   : http://127.0.0.1:$Port/v1" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Chatbox 配置：" -ForegroundColor Cyan
Write-Host "    设置 → 模型提供方 → 添加自定义 OpenAI 兼容" -ForegroundColor Cyan
Write-Host "    API 地址 : http://127.0.0.1:$Port/v1" -ForegroundColor Cyan
Write-Host "    API 密钥 : 任意非空值（如 dsh-bridge）" -ForegroundColor Cyan
Write-Host "    模型     : deepseek-v4-flash" -ForegroundColor Cyan
Write-Host ""

if (-not $NoStart) {
  Write-Info "启动桥接服务（Ctrl+C 停止；以后可双击 start-dsh-chatbox.bat）"
  Write-Host ""
  Push-Location $RepoDir
  & node server.mjs
  Pop-Location
} else {
  Write-Info "本次未启动。以后启动："
  Write-Info "  双击 $RepoDir\start-dsh-chatbox.bat"
  Write-Info "  或：cd $RepoDir; node server.mjs"
}
