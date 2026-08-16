@echo off
rem dsh-openai-bridge 看门狗启动器（修复 PATH 后调用 watchdog.cmd）
rem 用法：双击本文件，或由计划任务/任何终端调用
rem 首次运行自动以「最小化窗口」方式自举，避免弹出窗口打扰
if /i "%~1"=="minimized" goto :run
start "" /min cmd /c "%~f0" minimized
exit /b
:run
setlocal
set "PATH=C:\Program Files\nodejs;%PATH%"
cd /d "%~dp0"
call watchdog.cmd
