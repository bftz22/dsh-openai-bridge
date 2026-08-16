' dsh-openai-bridge 隐藏启动器（供计划任务调用，窗口完全不显示）
' 用法：wscript.exe "C:\Users\Administrator\deepseek-harness\start-watchdog-hidden.vbs"
Set ws = CreateObject("WScript.Shell")
ws.Run "cmd /c ""C:\Users\Administrator\deepseek-harness\start-watchdog.bat""", 0, False
