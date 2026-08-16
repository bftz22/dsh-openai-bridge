# github-sync.ps1 — 自适应 GitHub 同步工具
# 作用：代理自动探测（VPN 开→走代理，关→直连）→ 连通检测 → fetch/push
# 用法：
#   手动查看/同步：  powershell -File github-sync.ps1
#   静默自动同步：   powershell -File github-sync.ps1 -Auto   （计划任务用，无操作时零输出）
# 兼容 PS 5.1 / 7
param(
  [switch]$Auto,
  [string]$Repo = 'C:\Users\Administrator\dsh-openai-bridge'
)

$ErrorActionPreference = 'Continue'
$repo = $Repo

function Log($m) { if (-not $Auto) { Write-Output $m } }

# ---------- 1) 探测本地代理（Clash/V2Ray 等常见端口） ----------
$proxy = $null
foreach ($port in 7897, 7890, 7891, 7897, 10809, 10808, 1080, 8889) {
  if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
    $proxy = "http://127.0.0.1:$port"
    break
  }
}
Log "代理: $(if ($proxy) { $proxy } else { '未开（将直连）' })"
if ($proxy) {
  $env:HTTP_PROXY  = $proxy
  $env:HTTPS_PROXY = $proxy
  $env:GIT_HTTP_PROXY  = $proxy
  $env:GIT_HTTPS_PROXY = $proxy
} else {
  Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:GIT_HTTP_PROXY, Env:GIT_HTTPS_PROXY -ErrorAction SilentlyContinue
}

# ---------- 2) 连通性检测（10 秒超时） ----------
$reachable = $false
try {
  $null = git -C $repo -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 ls-remote origin HEAD 2>$null
  $reachable = ($LASTEXITCODE -eq 0)
} catch { $reachable = $false }

if (-not $reachable) {
  if ($Auto) { exit 0 }
  Write-Output 'GitHub 不可达：可能未开 VPN。稍后重试，或开 VPN 后运行本脚本。'
  Write-Output '提示：离线期间仍可正常 git commit，联网后本脚本会自动补推送。'
  exit 0
}
Log 'GitHub 可达 ✓'

# ---------- 3) 同步 ----------
git -C $repo fetch origin 2>$null | Out-Null
$counts = git -C $repo rev-list --left-right --count origin/main...main 2>$null
if (-not $counts) { if ($Auto) { exit 0 }; Write-Output '无法比较分支状态'; exit 1 }
$parts = ($counts.Trim() -split '\s+')
$behind = [int]$parts[0]
$ahead  = [int]$parts[1]

if ($behind -gt 0) {
  Log "远程有 $behind 个新提交 → pull"
  git -C $repo pull origin main 2>&1 | Out-Null
}
if ($ahead -gt 0) {
  Log "本地有 $ahead 个未推送提交 → push"
  git -C $repo push origin main 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Log "推送成功 ✓" } else { Write-Output "推送失败（exit=$LASTEXITCODE）" }
} else {
  Log '已是最新，无需推送'
}
if ($Auto) { exit 0 }
