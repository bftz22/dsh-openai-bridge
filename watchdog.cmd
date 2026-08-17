@echo off
rem ============================================================
rem  dsh-openai-bridge watchdog
rem  Auto-restart bridge 3s after it exits (killed/crashed)
rem  FUSE (2026-08-18): if bridge fails to start 5 times in a row
rem  (no 8787 listener within 20s), pause 10 minutes instead of
rem  hammering restarts, and write an alert to bridge.log
rem  Logs go to bridge.log in the same directory
rem  Usage: double-click it, or register via install-service.ps1
rem  (2026-08-16 harden-1: use ping instead of timeout, works in
rem   hidden/no-input consoles; harden-2: check port 8787 before
rem   start to prevent duplicate instances)
rem ============================================================
setlocal EnableDelayedExpansion
title dsh-openai-bridge (watchdog)
cd /d "%~dp0"

rem ---- single-instance guard: exit if 8787 is already listening ----
netstat -ano | findstr ":8787" | findstr "LISTENING" >nul
if not errorlevel 1 (
  echo [%date% %time%] port 8787 already in use - another bridge instance running, watchdog exits >> bridge.log
  exit /b
)

set FAILCOUNT=0

:loop
echo [%date% %time%] starting node server.mjs >> bridge.log
start "dsh-bridge-node" /b cmd /c "node server.mjs >> bridge.log 2>&1"

rem ---- health probe: bridge must listen on 8787 within 20s ----
ping -n 21 127.0.0.1 >nul
netstat -ano | findstr ":8787" | findstr "LISTENING" >nul
if errorlevel 1 goto startup_failed

rem ---- bridge is up: reset fail counter, then wait for exit ----
set FAILCOUNT=0
:waitloop
ping -n 4 127.0.0.1 >nul
netstat -ano | findstr ":8787" | findstr "LISTENING" >nul
if not errorlevel 1 goto waitloop
echo [%date% %time%] node exited, restart in 3s >> bridge.log
goto post_exit

:startup_failed
set /a FAILCOUNT+=1
echo [%date% %time%] bridge startup failed (no 8787 within 20s), fail=!FAILCOUNT! >> bridge.log

:post_exit
if !FAILCOUNT! geq 5 goto fuse
ping -n 4 127.0.0.1 >nul
goto loop

:fuse
echo [%date% %time%] WATCHDOG-FUSE: !FAILCOUNT! consecutive startup failures, pause 10 minutes >> bridge.log
echo [%date% %time%] WATCHDOG-FUSE: check bridge.log above for the startup error >> bridge.log
echo [%date% %time%] WATCHDOG-FUSE: hints: run inside dsh repo root, set DSH_REPO_DIR, or npm install >> bridge.log
ping -n 601 127.0.0.1 >nul
set FAILCOUNT=0
goto loop
