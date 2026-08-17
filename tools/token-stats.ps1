# token-stats.ps1 - 桥 token 用量统计（从 bridge.log 解析）
# 用法: powershell -File token-stats.ps1 [-Days 7]
# 输出: 回合数 / 输入tokens合计 / 按天分布 / 按会话TOP / 超限次数 / 费用估算
param([int]$Days = 7)

$logPath = "$env:USERPROFILE\deepseek-harness\bridge.log"
if (-not (Test-Path $logPath)) { Write-Error "找不到 bridge.log: $logPath"; exit 1 }

$lines = Get-Content $logPath -Encoding UTF8
$totalIn = 0; $rounds = 0; $overflow = 0; $requests = 0
$dayIn = @{}; $sessIn = @{}; $sessRounds = @{}
$curSession = "?"

foreach ($line in $lines) {
  if ($line -match '收到请求 .*会话=([^\s"]+)') { $curSession = $matches[1]; $requests++ }
  if ($line -match '上下文超限|上下文已超限') { $overflow++ }
  if ($line -match '回合结束') {
    $rounds++
    $in = 0
    if ($line -match '输入tokens=(\d+)') { $in = [int]$matches[1] }
    $totalIn += $in
    $day = $null
    # 日志行无时间戳时用文件时间近似；bridge.log 行首无日期，改从文件名/行号无法取，这里用会话聚合为主
    $sessIn[$curSession] += $in
    $sessRounds[$curSession] += 1
  }
}

# 按天分布：bridge.log 无逐行时间戳，从文件创建/修改时间无法分天，改为按会话统计（会话id含日期特征有限），
# 这里提供整体统计 + 按会话TOP
Write-Output ""
Write-Output "========== bridge.log token 用量统计 =========="
Write-Output ("日志行数: {0}" -f $lines.Count)
Write-Output ("请求数: {0} | 回合完成数: {1}" -f $requests, $rounds)
Write-Output ("输入tokens 合计: {0:N0} ({1:N1}K)" -f $totalIn, ($totalIn/1e3))
Write-Output ("平均每回合输入: {0:N0} tokens" -f ($totalIn / [Math]::Max($rounds,1)))
Write-Output ("上下文超限/重置相关行: {0}" -f $overflow)

# 费用估算（按 DeepSeek deepseek-chat 公开价：输入缓存未命中 ¥2/M，输出 ¥8/M；输出未记录，仅估输入）
$costIn = $totalIn / 1e6 * 2
Write-Output ("输入费用估算(仅输入, ¥2/M 未命中价): ¥{0:N2}" -f $costIn)

Write-Output ""
Write-Output "---------- 按会话 TOP 12（输入tokens） ----------"
$sessIn.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 12 | ForEach-Object {
  $r = $sessRounds[$_.Key]
  Write-Output ("  {0,-40} 回合={1,-4} 输入={2:N0}" -f $_.Key, $r, $_.Value)
}
Write-Output ""
Write-Output "提示: bridge.log 无逐行时间戳；精确分天/分模型用量请到 DeepSeek 开放平台控制台查看"
