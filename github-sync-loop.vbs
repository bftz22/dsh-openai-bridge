' github-sync-loop.vbs - silent loop: run github-sync.ps1 every 15 minutes (hidden window)
' NOTE: keep this file ASCII-only (cmd/vbs encoding rule)
Set ws = CreateObject("WScript.Shell")
Do
  ws.Run "powershell -NoProfile -ExecutionPolicy Bypass -File ""C:\Users\Administrator\dsh-openai-bridge\github-sync.ps1"" -Auto", 0, True
  WScript.Sleep 15 * 60 * 1000
Loop
