@echo off
rem ============================================================
rem  DeepSeek Harness launcher (dsh workspace + bridge)
rem  - ensures dsh-openai-bridge is running (via watchdog)
rem  - opens the workspace folder
rem  Called from launch-dsh.vbs (hidden) -> desktop shortcut
rem ============================================================
cd /d "%~dp0"

rem 1) bridge health check; start watchdog if down
curl -s -m 3 http://127.0.0.1:8787/healthz >nul 2>&1
if errorlevel 1 (
  start "" /min cmd /c "%~dp0start-watchdog.bat"
)

rem 2) open the workspace in Explorer
start explorer.exe "%~dp0"

exit /b
