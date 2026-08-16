# collect-diag.ps1 - collect diagnostic info for remote troubleshooting
# run: powershell -ExecutionPolicy Bypass -File collect-diag.ps1
# output: 诊断信息-<timestamp>.txt in current directory (NO secrets included)
#encoding: utf-8 with BOM (required by PS 5.1)

$ErrorActionPreference = "Continue"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$out = Join-Path (Get-Location) "诊断信息-$stamp.txt"
$lines = New-Object System.Collections.Generic.List[string]

function Add-Line($s) { $lines.Add($s) }

Add-Line "==== dsh-openai-bridge 诊断信息 ===="
Add-Line "生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line ""

Add-Line "==== 1. 系统信息 ===="
try {
  $os = Get-CimInstance Win32_OperatingSystem
  Add-Line "系统: $($os.Caption) $($os.Version) 架构=$($os.OSArchitecture)"
  Add-Line "内存: $([math]::Round($os.TotalVisibleMemorySize/1MB,1)) GB"
} catch { Add-Line "系统信息获取失败: $($_.Exception.Message)" }
Get-PSDrive -PSProvider FileSystem | ForEach-Object {
  Add-Line ("磁盘 {0}: 剩余 {1:N1} GB / 共 {2:N1} GB" -f $_.Name, ($_.Free/1GB), (($_.Used + $_.Free)/1GB))
}
Add-Line ""

Add-Line "==== 2. 工具版本 ===="
foreach ($cmd in @("node","npm","git","winget","pnpm")) {
  $v = & $cmd --version 2>&1 | Select-Object -First 1
  Add-Line "$cmd : $v"
}
Add-Line ""

Add-Line "==== 3. 网络连通性（HTTP 状态码）===="
foreach ($u in @("https://github.com","https://ghproxy.net","https://registry.npmmirror.com","https://platform.deepseek.com")) {
  $code = & curl.exe -sS -o NUL -w "%{http_code}" --connect-timeout 8 --max-time 15 $u 2>$null
  Add-Line "$u : $code"
}
Add-Line ""

Add-Line "==== 4. 桥目录状态 ===="
$here = Get-Location
Add-Line "当前目录: $here"
Add-Line "install.ps1 存在: $(Test-Path (Join-Path $here 'install.ps1'))"
Add-Line "server.mjs 存在: $(Test-Path (Join-Path $here 'server.mjs'))"
Add-Line ".env 存在: $(Test-Path (Join-Path $here '.env'))"
Add-Line ".env.example 存在: $(Test-Path (Join-Path $here '.env.example'))"
Add-Line "watchdog.cmd 存在: $(Test-Path (Join-Path $here 'watchdog.cmd'))"
Add-Line "npm registry 配置: $(& npm config get registry 2>$null)"
Add-Line ""

Add-Line "==== 5. harness 运行时目录 ===="
$hr = Join-Path $HOME "deepseek-harness"
Add-Line "目录: $hr 存在: $(Test-Path $hr)"
if (Test-Path $hr) {
  Add-Line "pnpm-workspace.yaml: $(Test-Path (Join-Path $hr 'pnpm-workspace.yaml'))"
  Add-Line "node_modules: $(Test-Path (Join-Path $hr 'node_modules'))"
  Add-Line "bridge.log 尾部 30 行:"
  $lg = Join-Path $hr "bridge.log"
  if (Test-Path $lg) {
    Get-Content $lg -Tail 30 -Encoding UTF8 | ForEach-Object { Add-Line "  $_" }
  } else {
    Add-Line "  (无 bridge.log)"
  }
  # skills
  Add-Line "skills 目录: $(Test-Path (Join-Path $hr 'skills'))"
}
Add-Line ""

Add-Line "==== 6. .env 键名（仅键名，不显示任何值）===="
$envFile = Join-Path $here ".env"
if (Test-Path $envFile) {
  Get-Content $envFile -Encoding UTF8 | ForEach-Object {
    if ($_ -match "^\s*([A-Za-z0-9_]+)\s*=") { Add-Line "  $($matches[1])" }
  }
} else { Add-Line "  (无 .env)" }
Add-Line ""

Add-Line "==== 7. 服务进程 ===="
Add-Line "node 进程数: $((Get-Process -Name node -ErrorAction SilentlyContinue).Count)"
$listen = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue
Add-Line "端口 8787 监听: $([bool]$listen) (PID: $($listen.OwningProcess -join ','))"
Add-Line ""

Add-Line "==== 8. 近 5 条 PowerShell 安装记录（若有 install log）===="
Get-ChildItem $here -Filter "*.log" -ErrorAction SilentlyContinue | Select-Object -First 3 | ForEach-Object {
  Add-Line "  -- $($_.Name) 尾部 20 行 --"
  Get-Content $_.FullName -Tail 20 -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object { Add-Line "  $_" }
}
Add-Line ""
Add-Line "==== 结束 ===="
Add-Line "请把本文件原样发给部署指导者。文件不含任何密钥/密码。"

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllLines($out, $lines, $utf8Bom)
Write-Host ""
Write-Host "诊断信息已生成: $out"
Write-Host "请把这个文件发给部署指导者（不含任何密钥）。"
