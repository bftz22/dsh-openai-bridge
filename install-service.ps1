<#
.SYNOPSIS
把桥安装为「开机自启的后台服务」（Windows 计划任务 + 看门狗自动重启）。
安装后无需再手动打开窗口；日志写入仓库根目录 bridge.log。

用法：
  .\install-service.ps1                     # 默认仓库 C:\Users\<你>\deepseek-harness
  .\install-service.ps1 -RepoDir D:\xxx\deepseek-harness

注意：服务模式与窗口模式（start-dsh-chatbox.bat）二选一，不要同时开。
#>
param(
  [string] = (Join-Path $HOME 'deepseek-harness')
)

$ErrorActionPreference = 'Stop'
$TaskName = 'dsh-openai-bridge'

$watchdog = Join-Path $RepoDir 'watchdog.cmd'
if (-not (Test-Path $watchdog)) {
  Write-Host "[错误] 找不到 $watchdog（请先复制 watchdog.cmd 到仓库目录）" -ForegroundColor Red
  exit 1
}

# 先停掉旧任务（如果有）
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action   = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c ""' + $watchdog + '""')
$trigger  = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
  -Description 'dsh-openai-bridge: DeepSeek Harness bridge for Chatbox (watchdog)' -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 2

Write-Host "[完成] 服务已安装并启动（登录后自动运行，看门狗自动重启）" -ForegroundColor Green
Write-Host "       查看状态：.\service-status.ps1" -ForegroundColor Cyan
Write-Host "       卸载服务：.\uninstall-service.ps1" -ForegroundColor Cyan
Write-Host "       日志文件：$RepoDir\bridge.log" -ForegroundColor Cyan
