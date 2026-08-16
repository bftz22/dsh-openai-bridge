@echo off
rem ================================================
rem  AI Bridge Self-Check Launcher
rem  Double-click to run check-bridge.ps1 with
rem  execution policy bypass; window stays open.
rem  NOTE: keep this file in the SAME folder as
rem  check-bridge.ps1
rem ================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-bridge.ps1"
echo.
echo ========== Done. You can close this window. ==========
pause
