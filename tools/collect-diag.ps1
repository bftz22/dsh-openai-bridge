# collect-diag.ps1 - collect diagnostic info for remote troubleshooting
# run: powershell -ExecutionPolicy Bypass -File collect-diag.ps1 [-EmailTo 收件邮箱]
# -EmailTo: 生成后自动通过发件人邮箱（QQ/163 SMTP）把诊断文件发到收件邮箱
# output: 诊断信息-<timestamp>.txt in current directory (NO secrets included)
#encoding: utf-8 with BOM (required by PS 5.1)

param(
  [string]$EmailTo = ""
)

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

# ---------------------------------------------------------------- 邮箱直发（-EmailTo）
if ($EmailTo -ne "") {
  Write-Host ""
  Write-Host "检测到 -EmailTo，将通过 SMTP 把诊断文件发送到: $EmailTo"
  $smtpUser = Read-Host "发件邮箱（QQ 或 163，需已开启 SMTP 服务）"
  $smtpPass = Read-Host "发件邮箱授权码（输入时不可见，不落盘）" -AsSecureString
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($smtpPass)
  $passPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringUnicode($bstr)
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  $smtpHost = ""
  if ($smtpUser -match "@qq\.com$") { $smtpHost = "smtp.qq.com" }
  elseif ($smtpUser -match "@163\.com$") { $smtpHost = "smtp.163.com" }
  else {
    $smtpHost = Read-Host "未能识别邮箱服务商，请输入 SMTP 服务器地址（如 smtp.qq.com）"
  }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    $sent = $false
    # 优先 587 STARTTLS（实测稳定），465 隐式 SSL 兜底
    foreach ($port in @(587, 465)) {
      try {
        $smtp = New-Object Net.Mail.SmtpClient($smtpHost, $port)
        $smtp.EnableSsl = $true
        $smtp.Timeout = 30000
        $smtp.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $passPlain)
        $msg = New-Object Net.Mail.MailMessage($smtpUser, $EmailTo)
        $msg.Subject = "AI 管家部署诊断信息 $stamp"
        $msg.Body = "部署诊断信息见附件。由 collect-diag.ps1 自动生成，不含任何密钥。"
        $att = New-Object Net.Mail.Attachment($out)
        $msg.Attachments.Add($att)
        $smtp.Send($msg)
        $msg.Dispose(); $att.Dispose()
        $sent = $true
        Write-Host "[OK] 邮件已通过 $smtpHost`:$port 发送到 $EmailTo"
        break
      } catch {
        Write-Host "  端口 $port 发送失败，尝试下一个 ..."
      }
    }
    if (-not $sent) { throw "全部端口发送失败" }
  } catch {
    Write-Host "[FAIL] 邮件发送失败: $($_.Exception.Message)"
    Write-Host "请手动把 $out 通过任意方式（微信/网页邮箱附件）发给部署指导者。"
  }
}
Write-Host "完成。"
