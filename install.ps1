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
    7. 启动桥接服务（可用 -NoStart 跳过）

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
  [switch]$FullBuild
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
  # 直连 GitHub 优先；国内网络失败时自动降级到 ghproxy 镜像（2026-08-17 实测可达）
  $cloneUrls = @(
    "https://github.com/deepseek-ai/deepseek-harness.git",
    "https://ghproxy.net/https://github.com/deepseek-ai/deepseek-harness.git",
    "https://gh-proxy.com/https://github.com/deepseek-ai/deepseek-harness.git"
  )
  $cloned = $false
  foreach ($cu in $cloneUrls) {
    Write-Info "  尝试源: $cu"
    git clone --depth 1 $cu $RepoDir 2>$null
    if ($LASTEXITCODE -eq 0) { $cloned = $true; break }
    if (Test-Path $RepoDir) { Remove-Item $RepoDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Warn2 "  该源失败，尝试下一个 …"
  }
  if (-not $cloned) {
    Write-Fail "git clone 全部失败（直连 + 镜像）。请确认已安装 git（winget install Git.Git）、网络可用，或开启代理后重试。"
    exit 1
  }
} else {
  # 已存在：判断是否为 git 仓库——zip 解压安装（小白交付包）得到的目录不是 git 仓库，
  # 此时跳过 git pull 直接使用现有文件；git clone 安装的目录则拉取更新
  $isGitRepo = $false
  try {
    # 临时降级错误处理：PS 5.1 下 $ErrorActionPreference='Stop' 时外部命令写 stderr 会抛错，
    # 非 git 目录的 git 探测/拉取必须被当作"忽略"而不是中断安装
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      Push-Location $RepoDir
      $null = git rev-parse --is-inside-work-tree 2>$null
      if ($LASTEXITCODE -eq 0) { $isGitRepo = $true }
      Pop-Location
    } catch { try { Pop-Location } catch {} }
    if ($isGitRepo) {
      Write-Info "仓库已存在，尝试拉取更新 …"
      try {
        Push-Location $RepoDir
        git pull --ff-only 2>$null
        Pop-Location
      } catch { try { Pop-Location } catch {}; Write-Warn2 "拉取更新失败（忽略，继续使用现有代码）" }
    } else {
      Write-Info "目录已存在（非 git 仓库，跳过更新，直接使用现有文件）…"
    }
    $ErrorActionPreference = $oldEAP
  } catch {
    try { Pop-Location } catch {}
    $ErrorActionPreference = 'Continue'
    Write-Warn2 "检测仓库状态异常（忽略，继续使用现有文件）"
  }
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
  # 新版 harness 已内置构建产物（packages/*/lib），且 package.json 可能没有 build 脚本；
  # 仅当存在可用构建脚本时才构建，否则跳过（避免 ERR_PNPM_NO_SCRIPT 误报失败）
  $buildScript = $null
  try {
    $pkg = Get-Content (Join-Path $RepoDir 'package.json') -Raw | ConvertFrom-Json
    if ($pkg.scripts.'build:lib') { $buildScript = 'build:lib' }
    elseif ($pkg.scripts.build) { $buildScript = 'build' }
  } catch {}
  if ($buildScript) {
    Write-Info "构建中（$buildScript）…"
    if ($FullBuild) { & $pnpmExec run build } else { & $pnpmExec run $buildScript }
    if ($LASTEXITCODE -ne 0) { Write-Fail "构建失败"; Pop-Location; exit 1 }
  } else {
    Write-Info "package.json 无 build 脚本（新版 harness 内置构建产物），跳过构建"
  }
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
# 插件链接必须成功：失败会导致 dsh 启动报 ERR_MODULE_NOT_FOUND（网络抖动时重试最多 3 次）
$pluginsLinked = $false
$probe = Join-Path $RepoDir 'node_modules\@deepseek-ai\dsh-llm-deepseek'
for ($attempt = 1; $attempt -le 3; $attempt++) {
  Write-Info "链接运行时插件（第 $attempt/3 次尝试）…"
  & $pnpmExec add -w $pluginList
  if ($LASTEXITCODE -eq 0) {
    # 验证关键插件已出现在根 node_modules
    if (Test-Path $probe) { $pluginsLinked = $true; break }
    Write-Warn2 "插件目录未出现，重试 …"
  } else {
    # pnpm add 失败时：插件可能已被上一步 pnpm install 以 workspace 方式链接，
    # 此时直接视为成功（pnpm add 仅用于固化根依赖声明）
    if (Test-Path $probe) {
      Write-Warn2 "pnpm add 退出码 $LASTEXITCODE，但插件已存在于 node_modules（pnpm install 已链接），继续"
      $pluginsLinked = $true
      break
    }
    Write-Warn2 "pnpm add 退出码 $LASTEXITCODE，重试 …"
  }
  Start-Sleep -Seconds 3
}
if (-not $pluginsLinked) {
  Write-Fail "运行时插件链接失败（3 次重试均未成功）。请检查网络后重新运行本脚本，或手动执行："
  Write-Fail "  cd $RepoDir; pnpm add -w $($pluginList -join ' ')"
  Pop-Location
  exit 1
}
Write-Info "运行时插件链接完成（18 个）✓"
$sdkLib = Join-Path $RepoDir "packages\sdk\client\lib\index.js"
if (-not (Test-Path $sdkLib)) {
  Write-Warn2 "未找到 SDK 构建产物 packages/sdk/client/lib/index.js，请确认构建成功（或去掉 -SkipBuild）。"
}
Pop-Location

# ---------------------------------------------------------------- 5. 部署桥接文件
Write-Step "5/7 部署桥接文件到仓库根目录"
# Windows：使用 PowerShell 执行器版配置（bash 执行器不支持 Windows）
foreach ($f in @('server.mjs', 'cordis-windows.yml', 'guard.cs', 'watchdog.cmd', 'install-guard.ps1', 'install-service.ps1', 'uninstall-service.ps1', 'service-status.ps1')) {
  $src = Join-Path $ScriptDir $f
  if (-not (Test-Path $src)) { Write-Warn2 "缺少 $f（跳过）" }
}
$dstServer = Join-Path $RepoDir "server.mjs"
$dstConfig = Join-Path $RepoDir "cordis.yml"
if (Test-Path $dstServer) { Copy-Item $dstServer "$dstServer.bak" -Force }
Copy-Item (Join-Path $ScriptDir "server.mjs") $dstServer -Force
if (Test-Path $dstConfig) { Copy-Item $dstConfig "$dstConfig.bak" -Force }
Copy-Item (Join-Path $ScriptDir "cordis-windows.yml") $dstConfig -Force
Write-Info "server.mjs / cordis.yml（Windows PowerShell 版）✓"

# 附带部署安全组件（看门狗、安全闸源码、服务脚本）
foreach ($f in @('guard.cs', 'watchdog.cmd', 'install-guard.ps1', 'install-service.ps1', 'uninstall-service.ps1', 'service-status.ps1')) {
  $src = Join-Path $ScriptDir $f
  if (Test-Path $src) { Copy-Item $src (Join-Path $RepoDir $f) -Force }
}
Write-Info "安全组件（guard.cs / watchdog.cmd / 服务脚本）✓"

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

# NOTE: keep this template ASCII-only. UTF-8 Chinese comments in .bat/.cmd break
# under cmd's ANSI(GBK) parsing (byte at line end swallows the newline).
$batContent = "@echo off`r`nrem dsh-openai-bridge launcher (generated by install.ps1)`r`ncd /d `"%~dp0`"`r`nnode server.mjs`r`n"
[System.IO.File]::WriteAllText((Join-Path $RepoDir "start-dsh-chatbox.bat"), $batContent, $utf8NoBom)
Write-Info ".env / start-dsh-chatbox.bat ✓"

# 尽力编译安全闸 guard.exe（失败不影响安装，可稍后运行 install-guard.ps1）
$csc = @(
  "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
  "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($csc) {
  $guardSrc = Join-Path $RepoDir "guard.cs"
  $guardExe = Join-Path $RepoDir "guard.exe"
  & $csc /nologo /target:exe /out:$guardExe $guardSrc 2>$null
  if (Test-Path $guardExe) {
    Write-Info "安全闸 guard.exe 编译成功 ✓"
    $envFile = Join-Path $RepoDir ".env"
    $envContent = @()
    if (Test-Path $envFile) { $envContent = @(Get-Content $envFile) }
    $envContent = @($envContent | Where-Object { $_ -notmatch '^DSH_PWSH_GUARD=' })
    $envContent += "DSH_PWSH_GUARD=$guardExe"
    [System.IO.File]::WriteAllLines($envFile, [string[]]$envContent, $utf8NoBom)
  } else {
    Write-Warn2 "guard.exe 编译失败（可稍后运行 install-guard.ps1 重试）"
  }
} else {
  Write-Warn2 "未找到 csc.exe，跳过安全闸（可稍后运行 install-guard.ps1）"
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
