@echo off
rem ============================================================
rem  dsh-openai-bridge watchdog
rem  Auto-restart node 3s after it exits (killed/crashed); keeps the bridge alive
rem  Logs go to bridge.log in the same directory
rem  Usage: double-click it, or register via install-service.ps1
rem  (2026-08-16 harden-1: use ping instead of timeout, works in hidden/no-input consoles;
rem   harden-2: check port 8787 before start to prevent duplicate instances)
rem ============================================================
title dsh-openai-bridge (watchdog)
cd /d "%~dp0"
rem ---- single-instance guard: exit if 8787 is already listening ----
netstat -ano | findstr ":8787" | findstr "LISTENING" >nul
if not errorlevel 1 (
  echo [%date% %time%] port 8787 already in use - another bridge instance running, watchdog exits >> bridge.log
  exit /b
)
:loop
echo [%date% %time%] starting node server.mjs >> bridge.log
node server.mjs >> bridge.log 2>&1
echo [%date% %time%] node exited code %errorlevel%, restart in 3s >> bridge.log
ping -n 4 127.0.0.1 >nul
goto loop
