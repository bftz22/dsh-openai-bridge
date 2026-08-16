@echo off
rem ============================================================
rem  dsh-openai-bridge - one-click restart
rem  Only terminates the bridge process listening on port 8787.
rem  The watchdog will relaunch it within 3 seconds.
rem  If no watchdog is running, this script starts one.
rem ============================================================
title dsh-openai-bridge - Restart
cd /d "%~dp0"

echo ============================================
echo    dsh-openai-bridge - One-click Restart
echo ============================================
echo.

rem ---- Step 1: find the bridge process on port 8787 ----
echo [1/3] Looking for bridge process (port 8787)...
set "PID="
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8787" ^| findstr "LISTENING"') do set "PID=%%a"

if defined PID (
  echo       Found PID=%PID%, terminating it (watchdog relaunches in 3s)...
  taskkill /F /T /PID %PID% >nul 2>&1
  if errorlevel 1 echo       [WARN] Failed to terminate process, check permission
) else (
  echo       No bridge process found (bridge is not running)
)

rem ---- Step 2: wait for watchdog to relaunch ----
echo [2/3] Waiting for watchdog relaunch (about 8s)...
ping -n 9 127.0.0.1 >nul

rem ---- Step 3: health check ----
echo [3/3] Health check...
set "CODE=0"
for /f "delims=" %%a in ('powershell -NoProfile -Command "try{(Invoke-WebRequest -Uri 'http://127.0.0.1:8787/healthz' -TimeoutSec 5 -UseBasicParsing).StatusCode}catch{0}"') do set "CODE=%%a"
if "%CODE%"=="200" goto :ok

echo       Bridge did not recover, starting watchdog...
start "" wscript.exe "%~dp0start-watchdog-hidden.vbs"
ping -n 7 127.0.0.1 >nul
set "CODE=0"
for /f "delims=" %%a in ('powershell -NoProfile -Command "try{(Invoke-WebRequest -Uri 'http://127.0.0.1:8787/healthz' -TimeoutSec 5 -UseBasicParsing).StatusCode}catch{0}"') do set "CODE=%%a"
if "%CODE%"=="200" goto :ok

echo.
echo   [FAILED] Bridge did not recover. Manual steps:
echo           1) Check the watchdog window (cmd process) in Task Manager
echo           2) Double-click start-watchdog.bat to start manually
echo           3) Check the tail of bridge.log
goto :end

:ok
echo.
echo   [OK] Bridge is back online
echo        URL: http://127.0.0.1:8787/v1
echo        Note: first request after restart needs 30-60s cold start
echo        Status: run "bridge-status" shortcut for details
goto :end

:end
echo.
pause