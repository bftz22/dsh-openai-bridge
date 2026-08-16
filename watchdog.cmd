@echo off
rem ============================================================
rem  dsh-openai-bridge 看门狗
rem  node 退出（被误杀/崩溃）后 3 秒自动重启，保证桥一直在
rem  日志写入同目录 bridge.log
rem  用法：直接双击，或由 install-service.ps1 注册为开机自启任务
rem  （2026-08-16 加固1：用 ping 替代 timeout，兼容隐藏/无输入控制台；
rem   加固2：启动前检查 8787 是否已被监听，防止双开抢端口）
rem ============================================================
title dsh-openai-bridge (watchdog)
cd /d "%~dp0"
rem ---- 单实例守卫：若 8787 已有桥在监听，本看门狗直接退出 ----
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
