@echo off
rem ============================================================
rem  dsh-openai-bridge - status viewer
rem  Shows: health check / port / process tree / watchdog / log tail
rem ============================================================
title dsh-openai-bridge - Status
cd /d "%~dp0"

echo ============================================
echo    dsh-openai-bridge - Status
echo ============================================
echo.

echo [Health check]
powershell -NoProfile -Command "try{$r=Invoke-WebRequest -Uri 'http://127.0.0.1:8787/healthz' -TimeoutSec 5 -UseBasicParsing; Write-Host ('  HTTP ' + $r.StatusCode + '  ' + $r.Content)}catch{Write-Host ('  FAILED - ' + $_.Exception.Message)}"
echo.

echo [Port 8787]
netstat -ano | findstr ":8787" | findstr "LISTENING"
echo.

echo [node processes]
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='node.exe'\" | ForEach-Object { '  PID=' + $_.ProcessId + '  Parent=' + $_.ParentProcessId + '  ' + $_.CommandLine }"
echo.

echo [watchdog process]
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='cmd.exe'\" | Where-Object { $_.CommandLine -match 'watchdog' } | ForEach-Object { '  PID=' + $_.ProcessId + '  ' + $_.CommandLine }"
echo.

echo [Recent log]
powershell -NoProfile -Command "Get-Content 'C:\Users\Administrator\deepseek-harness\bridge.log' -Tail 6 -Encoding UTF8"
echo.
pause