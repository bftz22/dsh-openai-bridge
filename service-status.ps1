<#
.SYNOPSIS
查看桥服务状态（计划任务 + healthz 健康检查）。
用法：.\service-status.ps1
#>
$ErrorActionPreference = 'SilentlyContinue'
$TaskName = 'dsh-openai-bridge'

$task = Get-ScheduledTask -TaskName $TaskName
if (-not $task) {
  Write-Host "服务未安装（用 install-service.ps1 安装）"
} else {
  $info = Get-ScheduledTaskInfo -TaskName $TaskName
  Write-Host ("任务状态 : " + $task.State)
  Write-Host ("上次运行 : " + $info.LastRunTime)
  Write-Host ("上次结果 : " + $info.LastTaskResult)
}

try {
  $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8787/healthz' -UseBasicParsing -TimeoutSec 3
  if ($r.StatusCode -eq 200) { Write-Host "桥状态   : 正常 ✅ (http://127.0.0.1:8787)" } else { Write-Host "桥状态   : 异常（HTTP $($r.StatusCode)）" }
} catch {
  Write-Host "桥状态   : 未响应 ❌（看门狗运行中？看 bridge.log）"
}
