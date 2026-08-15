@echo off
rem dsh-openai-bridge autostart helper (Startup folder version)
rem Starts the OpenAI-compatible bridge on login.
rem Skips if the bridge is already listening on port 8787.
rem
rem NOTE: install.ps1 generates a copy of this script with the actual
rem repo path baked in and places it in the user Startup folder.
rem Usage:  copy to "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\"
rem         after adjusting the cd line below.

cd /d "%~dp0"
netstat -ano | findstr ":8787" | findstr "LISTENING" >nul
if not errorlevel 1 (
  rem bridge already running, exit
  exit /b 0
)
node server.mjs
