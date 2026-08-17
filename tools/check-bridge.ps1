# check-bridge.ps1 - AI bridge one-click self-check (3 layers)
# Recommended: double-click check-bridge.bat in the same folder (window stays open)
# or run: powershell -ExecutionPolicy Bypass -File .\check-bridge.ps1
# Layer 1: bridge process (healthz) / Layer 2: model list / Layer 3: real chat round-trip

Write-Output "========== AI Bridge Self-Check =========="

# ---- Layer 1: is the bridge process alive ----
Write-Output ""
Write-Output "[Layer 1] Bridge process (http://127.0.0.1:8787) ..."
try {
  $r = Invoke-WebRequest -Uri "http://127.0.0.1:8787/healthz" -UseBasicParsing -TimeoutSec 60
  Write-Output ("  Layer 1: [OK] HTTP {0} {1}" -f $r.StatusCode, $r.Content)
} catch {
  Write-Output ("  Layer 1: [FAIL] cannot reach bridge - {0}" -f $_.Exception.Message)
  Write-Output "  -> Bridge not started: wait 30-60s (autostart delay) and retry; otherwise run start-dsh-chatbox.bat in the bridge folder"
  exit 1
}

# ---- Layer 2: model list endpoint ----
Write-Output ""
Write-Output "[Layer 2] Model list endpoint ..."
try {
  $r = Invoke-WebRequest -Uri "http://127.0.0.1:8787/v1/models" -UseBasicParsing -TimeoutSec 20
  if ($r.Content -match "deepseek-v4-flash") {
    Write-Output "  Layer 2: [OK] model deepseek-v4-flash exists"
  } else {
    Write-Output ("  Layer 2: [WARN] content returned but deepseek-v4-flash not found: {0}" -f $r.Content)
  }
} catch {
  Write-Output ("  Layer 2: [FAIL] {0}" -f $_.Exception.Message)
}

# ---- Layer 3: real chat round-trip (bridge -> DeepSeek, tiny token cost) ----
Write-Output ""
Write-Output "[Layer 3] Real chat round-trip (bridge->DeepSeek) ..."
Write-Output "  (first test cold-start 30-60s is normal, please wait)"
try {
  $body = '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"Reply with the single word: OK"}],"stream":false}'
  $r = Invoke-RestMethod -Uri "http://127.0.0.1:8787/v1/chat/completions" -Method Post -ContentType "application/json" -Headers @{ 'x-dsh-session' = 'bridge-selfcheck' } -Body $body -TimeoutSec 180
  $reply = $r.choices[0].message.content
  Write-Output ("  Layer 3: [OK] bridge can chat, AI replied: {0}" -f $reply)
} catch {
  Write-Output ("  Layer 3: [FAIL] {0}" -f $_.Exception.Message)
  Write-Output "  -> Bridge process is fine but chat failed: usually invalid DeepSeek API Key or empty balance (check platform.deepseek.com)"
}

Write-Output ""
Write-Output "========== Self-check finished =========="
Write-Output "All 3 layers [OK] = bridge fully works; if the client still fails, check the client config (see README client section)"
Write-Output "Any layer [FAIL] = screenshot this window and open an issue (see README)"
