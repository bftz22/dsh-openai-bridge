# check-env.ps1 - One-click environment check for dsh-openai-bridge (Chinese UI)
# Checks: Git / Node.js / VC++ runtime / WebView2 / execution policy / system proxy / mirror network
# Missing items are auto-installed via winget when possible, then re-checked.
# Usage: double-click check-env.bat in the same folder, or:
#   powershell -ExecutionPolicy Bypass -File .\check-env.ps1
# NOTE: must be saved as UTF-8 WITH BOM so Windows PowerShell 5.1 parses Chinese correctly.

$ErrorActionPreference = 'Continue'
Write-Host ""
Write-Host "========== AI Bridge Environment Check ==========" -ForegroundColor Cyan

$issues = @()

# ---- 1. Git ----
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
  $gv = (& git --version) 2>$null
  Write-Host "[OK] Git: $gv" -ForegroundColor Green
} else {
  Write-Host "[MISSING] Git 未安装，尝试自动安装（winget install Git.Git）..." -ForegroundColor Yellow
  winget install Git.Git --accept-package-agreements --accept-source-agreements 2>$null | Out-Null
  Start-Sleep -Seconds 2
  if (Get-Command git -ErrorAction SilentlyContinue) { Write-Host "[OK] Git 安装成功" -ForegroundColor Green }
  else { Write-Host "[FAIL] Git 自动安装失败。可手动：PowerShell 运行 winget install Git.Git" -ForegroundColor Red; $issues += 'Git' }
}

# ---- 2. Node.js ----
$node = Get-Command node -ErrorAction SilentlyContinue
if ($node) {
  $nv = (& node -v).Trim().TrimStart('v')
  $major = 0; try { $major = [int]($nv.Split('.')[0]) } catch {}
  if ($major -ge 22) { Write-Host "[OK] Node.js: v$nv" -ForegroundColor Green }
  else { Write-Host "[WARN] Node.js 版本 v$nv 偏低（需 >= 22.19），建议升级" -ForegroundColor Yellow; $issues += 'Node版本' }
} else {
  Write-Host "[MISSING] Node.js 未安装，尝试自动安装（winget install OpenJS.NodeJS.LTS）..." -ForegroundColor Yellow
  winget install OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements 2>$null | Out-Null
  Start-Sleep -Seconds 2
  if (Get-Command node -ErrorAction SilentlyContinue) { Write-Host "[OK] Node.js 安装成功" -ForegroundColor Green }
  else { Write-Host "[WARN] Node.js 可能已装好但需重开窗口生效（重开本窗口后复检）；或手动：winget install OpenJS.NodeJS.LTS" -ForegroundColor Yellow; $issues += 'Node' }
}

# ---- 3. VC++ runtime ----
if (Test-Path "$env:WINDIR\System32\vcruntime140.dll") {
  Write-Host "[OK] VC++ 运行库: 已安装" -ForegroundColor Green
} else {
  Write-Host "[MISSING] VC++ 运行库缺失（会导致桥构建崩溃）。请安装微软 VC++ 2015-2022 x64 运行库：https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor Yellow
  $issues += 'VC++'
}

# ---- 4. WebView2 ----
$wv = $null
try { $wv = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction Stop).pv } catch {}
if (-not $wv) { try { $wv = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction Stop).pv } catch {} }
if ($wv) { Write-Host "[OK] WebView2: $wv" -ForegroundColor Green }
else {
  Write-Host "[MISSING] WebView2 缺失（客户端会白屏）。请安装微软官方 WebView2 Runtime：https://go.microsoft.com/fwlink/p/?LinkId=2124703" -ForegroundColor Yellow
  $issues += 'WebView2'
}

# ---- 5. Execution policy ----
$ep = Get-ExecutionPolicy
if ($ep -in @('RemoteSigned','Unrestricted','Bypass')) { Write-Host "[OK] 执行策略: $ep" -ForegroundColor Green }
else { Write-Host "[WARN] 执行策略: $ep（本工具已自动绕过，不影响；如需手动跑 ps1 可执行 Set-ExecutionPolicy -Scope CurrentUser RemoteSigned）" -ForegroundColor Yellow }

# ---- 6. System proxy ----
$proxyEnable = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyEnable
if ($proxyEnable -eq 1) {
  Write-Host "[WARN] 系统代理已开启！若客户端连不上桥（ERR_NETWORK_ACCESS_DENIED），请关闭代理（设置→网络和Internet→代理）或把客户端加入白名单" -ForegroundColor Yellow
} else { Write-Host "[OK] 系统代理: 关闭" -ForegroundColor Green }

# ---- 7. Mirror network ----
try {
  $r = Invoke-WebRequest -Uri 'https://ghproxy.net/https://github.com' -Method Head -UseBasicParsing -TimeoutSec 10
  Write-Host "[OK] 镜像网络: ghproxy.net 可达" -ForegroundColor Green
} catch { Write-Host "[WARN] 镜像网络: ghproxy.net 不可达（仅提示，安装脚本会自行降级）" -ForegroundColor Yellow }

# ---- Summary ----
Write-Host ""
Write-Host "========== Result ==========" -ForegroundColor Cyan
if ($issues.Count -eq 0) {
  Write-Host "环境就绪！下一步见 README「快速开始」或 docs/部署手册-中文版.md" -ForegroundColor Green
} else {
  Write-Host "以下项目需处理：$($issues -join '、')" -ForegroundColor Yellow
  Write-Host "处理完后再运行本体检确认。" -ForegroundColor Yellow
}
Write-Host ""
Read-Host "按回车键关闭"
