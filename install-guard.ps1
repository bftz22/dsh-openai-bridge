<#
.SYNOPSIS
安装「危险命令拦截闸」：编译 guard.cs → guard.exe，并把 DSH_PWSH_GUARD 写入 .env。
之后管家的每条 pwsh 命令都会先经过 guard 检查，危险命令（杀进程/关机/删系统路径等）被直接拒绝。

用法：
  .\install-guard.ps1                     # 默认仓库 C:\Users\<你>\deepseek-harness
  .\install-guard.ps1 -RepoDir D:\xxx\deepseek-harness
安装后需要重启桥（或服务）生效。
#>
param(
  [string] = (Join-Path $HOME 'deepseek-harness')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RepoDir)) {
  Write-Host "[错误] 找不到目录：$RepoDir" -ForegroundColor Red
  exit 1
}

# 1) 定位 csc.exe（Windows 10/11 自带 .NET Framework 编译器）
$csc = @(
  "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
  "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $csc) {
  Write-Host "[错误] 未找到 csc.exe（需要 .NET Framework 4.x，Win10/11 自带）。" -ForegroundColor Red
  exit 1
}

# 2) 复制源码到仓库
$src = Join-Path $PSScriptRoot 'guard.cs'
$dstCs = Join-Path $RepoDir 'guard.cs'
if (-not (Test-Path $src)) {
  Write-Host "[错误] 找不到 $src（install-guard.ps1 应与 guard.cs 在同一文件夹）" -ForegroundColor Red
  exit 1
}
Copy-Item $src $dstCs -Force

# 3) 编译
$exe = Join-Path $RepoDir 'guard.exe'
Write-Host "[1/3] 编译 guard.exe ..."
& $csc /nologo /target:exe /out:$exe $dstCs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) {
  Write-Host "[错误] 编译失败（csc 退出码 $LASTEXITCODE）。请把 guard.cs 复制给技术支持。" -ForegroundColor Red
  exit 1
}

# 4) 写入 .env：DSH_PWSH_GUARD=<repo>\guard.exe
$envFile = Join-Path $RepoDir '.env'
$line = "DSH_PWSH_GUARD=$exe"
$content = @()
if (Test-Path $envFile) { $content = @(Get-Content $envFile) }
$content = @($content | Where-Object { $_ -notmatch '^DSH_PWSH_GUARD=' })
$content += $line
[System.IO.File]::WriteAllLines($envFile, [string[]]$content, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "[2/3] 已写入 .env：DSH_PWSH_GUARD=$exe" -ForegroundColor Green
Write-Host "[3/3] 完成！请重启桥（或服务）后生效：" -ForegroundColor Green
Write-Host "      窗口模式：关闭旧窗口 → 双击 start-dsh-chatbox.bat" -ForegroundColor Cyan
Write-Host "      服务模式：service-status.ps1 restart（或运行 uninstall-service.ps1 后再 install-service.ps1）" -ForegroundColor Cyan
