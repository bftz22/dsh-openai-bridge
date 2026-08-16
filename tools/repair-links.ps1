# repair-links.ps1
# Rebuilds the 18 @deepseek-ai/dsh-* workspace junctions under
# %USERPROFILE%\deepseek-harness\node_modules\@deepseek-ai
# Fixes bridge error: "plugin tree failed to load ... loader entries failed to apply"
# and chat 500 responses caused by missing plugin links.
# Usage: powershell -ExecutionPolicy Bypass -File .\repair-links.ps1
# NOTE: ASCII-only on purpose (console-encoding safe on any locale).

$ErrorActionPreference = 'Stop'
$root = Join-Path $HOME 'deepseek-harness'
if (-not (Test-Path $root)) {
  Write-Host "[ERROR] deepseek-harness not found at $root"
  Write-Host "If your runtime repo lives elsewhere, edit the `$root line in this script."
  exit 1
}
$target = Join-Path $root 'node_modules\@deepseek-ai'

$map = [ordered]@{
  'dsh-agent-spine-demo'              = 'packages\examples\agent-spine-demo'
  'dsh-compaction-basic'              = 'packages\compaction\compaction-basic'
  'dsh-fs-local'                      = 'packages\fs\fs-local'
  'dsh-fs-observation-policy'         = 'packages\fs\fs-observation-policy'
  'dsh-llm-deepseek'                  = 'packages\llm\llm-deepseek'
  'dsh-pwsh-local'                    = 'packages\shell\pwsh-local'
  'dsh-sdk-jsonrpc-server'            = 'packages\sdk\server'
  'dsh-shell-env'                     = 'packages\shell\shell-env'
  'dsh-subagent'                      = 'packages\subagent\subagent'
  'dsh-subagent-spawn-in-process'     = 'packages\subagent\subagent-spawn-in-process'
  'dsh-subprocess-local'              = 'packages\subprocess\subprocess-local'
  'dsh-session-checkpoint-policy'     = 'packages\session\session-checkpoint-policy'
  'dsh-session-persistence-jsonl'     = 'packages\session\session-persistence-jsonl'
  'dsh-token-meter'                   = 'packages\llm\token-meter'
  'dsh-tool-fs'                       = 'packages\fs\tool-fs'
  'dsh-tool-pwsh'                     = 'packages\shell\tool-pwsh'
  'dsh-tool-subagent'                 = 'packages\subagent\tool-subagent'
  'dsh-tool-todo'                     = 'packages\todo\tool-todo'
}

if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target | Out-Null }

$fixed = 0; $ok = 0; $bad = 0
foreach ($pkg in $map.Keys) {
  $link = Join-Path $target $pkg
  $src  = Join-Path $root $map[$pkg]
  $valid = $false
  if (Test-Path $link) {
    try { $item = Get-Item $link -Force; $valid = (Test-Path $item.Target) } catch { $valid = $false }
  }
  if ($valid) { $ok++; continue }
  if (Test-Path $link) { Remove-Item $link -Force -Recurse -ErrorAction SilentlyContinue }
  if (-not (Test-Path $src)) { Write-Host "[MISSING-SRC] $pkg -> $($map[$pkg])"; $bad++; continue }
  New-Item -ItemType Junction -Path $link -Target $src | Out-Null
  Write-Host "[REBUILT] $pkg"
  $fixed++
}

Write-Host "----"
Write-Host "OK=$ok REBUILT=$fixed MISSING_SRC=$bad TOTAL=$($map.Count)"
if ($bad -gt 0) { Write-Host "WARNING: some package sources are missing - check the workspace." }
Write-Host "DONE. Now restart the bridge via start-dsh-chatbox.bat"
