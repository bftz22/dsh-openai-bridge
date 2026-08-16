' dsh-openai-bridge hidden launcher (for scheduler; no window at all)
' Usage: wscript.exe "C:\Users\Administrator\deepseek-harness\start-watchdog-hidden.vbs"
Set ws = CreateObject("WScript.Shell")
ws.Run "cmd /c ""C:\Users\Administrator\deepseek-harness\start-watchdog.bat""", 0, False
