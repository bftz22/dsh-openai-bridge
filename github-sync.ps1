# github-sync.ps1 - auto sync local bridge repo to GitHub
# usage: powershell -File github-sync.ps1 [-Auto]   (-Auto = silent, default = report)
# behavior: detect local proxy -> connectivity check -> fetch/push/pull (bridge repo only)
param([switch]$Auto)

$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\Administrator\dsh-openai-bridge'
$proxyPorts = 7897, 7890, 7891, 10809, 10808, 1080, 8889

function Log([string]$msg) { if (-not $Auto) { Write-Output $msg } }

# 1) detect local proxy (Clash Verge etc.)
$proxy = $null
foreach ($p in $proxyPorts) {
  $c = New-Object System.Net.Sockets.TcpClient
  try { $c.Connect('127.0.0.1', $p); $c.Close(); $proxy = "http://127.0.0.1:$p"; break } catch {}
}
if ($proxy) { $env:http_proxy = $proxy; $env:https_proxy = $proxy }

# 2) connectivity check (api.github.com is reachable even when github.com is blocked)
try {
  $r = Invoke-WebRequest -Uri 'https://api.github.com' -TimeoutSec 10 -Headers @{ 'User-Agent' = 'dsh-bridge' }
  if ($r.StatusCode -ne 200) { Log "GitHub API unreachable (HTTP $($r.StatusCode)), skip"; exit 0 }
} catch {
  Log "offline or unreachable, skip sync: $($_.Exception.Message)"
  exit 0
}

# 3) sync: fetch, then push local commits, then fast-forward pull
Log "syncing $repo (proxy=$proxy) ..."
git -C $repo fetch origin 2>&1 | Out-Null
$remote = 'origin/main'
$hasRemote = (git -C $repo rev-parse --verify $remote 2>$null) -ne $null
if (-not $hasRemote) { Log "no remote tracking branch, skip"; exit 0 }

$ahead = [int](git -C $repo rev-list --count "$remote..main" 2>$null)
$behind = [int](git -C $repo rev-list --count "main..$remote" 2>$null)

if ($ahead -gt 0) {
  git -C $repo push origin main --tags 2>&1 | Out-Null
  Log "pushed $ahead commit(s) + tags"
}
if ($behind -gt 0) {
  git -C $repo pull --ff-only origin main 2>&1 | Out-Null
  Log "fast-forwarded $behind commit(s) from origin"
}
if ($ahead -eq 0 -and $behind -eq 0) { Log "already in sync" }
Log "HEAD: $(git -C $repo log --oneline -1)"
