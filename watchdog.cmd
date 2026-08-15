@echo off
rem ============================================================
rem  dsh-openai-bridge 看门狗
rem  node 退出（被误杀/崩溃）后 3 秒自动重启，保证桥一直在
rem  日志写入同目录 bridge.log
rem  用法：直接双击，或由 install-service.ps1 注册为开机自启任务
rem ============================================================
title dsh-openai-bridge (watchdog)
cd /d "%~dp0"
:loop
echo [%date% %time%] starting node server.mjs >> bridge.log
node server.mjs >> bridge.log 2>&1
echo [%date% %time%] node exited code %errorlevel%, restart in 3s >> bridge.log
timeout /t 3 /nobreak >nul
goto loop
