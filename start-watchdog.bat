@echo off
rem dsh-openai-bridge watchdog launcher (fix PATH then call watchdog.cmd)
rem Usage: double-click this file, or call from any terminal/scheduler
rem Boots itself minimized on first run to avoid popping up a window
if /i "%~1"=="minimized" goto :run
start "" /min cmd /c "%~f0" minimized
exit /b
:run
setlocal
set "PATH=C:\Program Files\nodejs;%PATH%"
cd /d "%~dp0"
call watchdog.cmd
