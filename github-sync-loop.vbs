' github-sync-loop.vbs - ?15?????? github-sync.ps1 -Auto??????HKCU Run?
Set ws = CreateObject("Wscript.Shell")
Do
  ws.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\Users\Administrator\dsh-openai-bridge\github-sync.ps1"" -Auto", 0, True
  WScript.Sleep 900000
Loop
