<#
.SYNOPSIS
卸载桥的后台服务（计划任务）。不会删除仓库文件。
用法：.\uninstall-service.ps1
#>
$ErrorActionPreference = 'Stop'
$TaskName = 'dsh-openai-bridge'

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

Write-Host "[完成] 服务已卸载。以后可改用窗口模式：双击 start-dsh-chatbox.bat" -ForegroundColor Green
