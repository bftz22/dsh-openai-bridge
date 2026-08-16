@echo off
rem ================================================
rem  AI Bridge Environment Check Launcher
rem  Double-click to run check-env.ps1 (Chinese UI)
rem  with execution policy bypass; window stays open.
rem ================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check-env.ps1"
