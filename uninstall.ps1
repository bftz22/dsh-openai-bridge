#requires -Version 5.1
<#
.SYNOPSIS
  卸载 dsh-openai-bridge 的部署痕迹（不删除 deepseek-harness 仓库本身）。

.PARAMETER RepoDir
  deepseek-harness 仓库目录，默认 $HOME\deepseek-harness。

.PARAMETER RemoveRepo
  同时删除整个仓库目录。

.PARAMETER KeepSessions
  保留 .sessions 会话数据（默认删除）。
#>
param(
  [string]$RepoDir = (Join-Path $HOME "deepseek-harness"),
  [switch]$RemoveRepo,
  [switch]$KeepSessions
)

$ErrorActionPreference = 'Stop'

function Say($msg) { Write-Host "  $msg" }
function Warn2($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

Write-Host "==> 卸载 dsh-openai-bridge 部署文件（$RepoDir）"

if (-not (Test-Path $RepoDir)) {
  Write-Host "  仓库目录不存在，无需卸载。"
  exit 0
}

$targets = @(
  (Join-Path $RepoDir "server.mjs"),
  (Join-Path $RepoDir "cordis.yml"),
  (Join-Path $RepoDir ".env"),
  (Join-Path $RepoDir "start-dsh-chatbox.bat"),
  (Join-Path $RepoDir "start-dsh-chatbox.sh")
)
if (-not $KeepSessions) { $targets += (Join-Path $RepoDir ".sessions") }

foreach ($t in $targets) {
  if (Test-Path $t) {
    Remove-Item $t -Recurse -Force
    Say "已删除 $t"
  }
}

if ($RemoveRepo) {
  Remove-Item $RepoDir -Recurse -Force
  Say "已删除仓库 $RepoDir"
}

Write-Host "完成。"
