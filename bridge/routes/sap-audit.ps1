param([Parameter(Mandatory)][hashtable]$Body)

# sap-audit  -  SAP Driver 统一总账时间线路由(P1,2026-09-14)。
# 尾部倒读当日 audit-<date>.jsonl(CC mcp 通道 + PW facade 通道统一台账),只取
# stage=finished 的最近 N 条。性能设计:FileStream 从文件尾按 16KB 块倒读,绝不
# 全文件解析(数据增长防线);条目裁剪(丢 params 明细,时间线只需要元信息)。

$ErrorActionPreference = 'Stop'

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$input_ = $Body.input
$lines = 50
$date = ''
if ($input_) {
  if ($input_.lines) { [void][int]::TryParse([string]$input_.lines, [ref]$lines) }
  if ($input_.date) { $date = ([string]$input_.date).Trim() }
}
if ($lines -lt 1) { $lines = 1 } ; if ($lines -gt 200) { $lines = 200 }

if (-not $date) { $date = Get-Date -Format 'yyyy-MM-dd' }
if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') { return (Fail 'BAD_DATE' "date 须为 yyyy-MM-dd: $date") }

$__auditRoot = if ($env:SAP_MCP_AUDIT_DIR) { $env:SAP_MCP_AUDIT_DIR } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'sap-mcp-audit' }
$auditFile = Join-Path $__auditRoot ("audit-$date.jsonl")
if (-not (Test-Path $auditFile)) {
  $sw.Stop()
  # 房子约定(bridge-client.run 只取 data.result):早退分支同样必须嵌 result 键,
  # 否则前端拿到 {} → timeline.entries undefined → .length 渲染崩(b728391 同型)
  return @{
    ok = $true
    result = [ordered]@{
      date = $date; file = $auditFile
      entries = @(); moreOlder = $false
      elapsedMs = $sw.ElapsedMilliseconds
    }
  }
}

# ---------- 尾部倒读:16KB 块,凑够 ~2N 行或到文件头即停 ----------
# 结构:按块分组($chunks,收集顺序=最新块在前),块内行保持文件正序。
# 全局"新→旧"输出 = 依块序遍历 + 块内倒序走(2026-09-14 截图实测修正:
# 之前"整体反转一次"会变成最旧块在前,展示的是最旧的 50 条)。
$fs = $null
$chunks = New-Object System.Collections.Generic.List[System.Collections.Generic.List[string]]
$totalLines = 0
try {
  $fs = [System.IO.File]::Open($auditFile, 'Open', 'Read', 'ReadWrite')
  $chunkSize = 16384
  $pos = $fs.Length
  $newlineCount = 0
  $need = ($lines * 2) + 8          # started/finished 成对,乘 2 留裕量
  $carry = ''
  while ($pos -gt 0 -and $newlineCount -lt $need) {
    $read = [Math]::Min($chunkSize, $pos)
    $pos -= $read
    $buf = New-Object byte[] $read
    [void]$fs.Seek($pos, 'Begin')
    [void]$fs.Read($buf, 0, $read)
    $text = [Text.Encoding]::UTF8.GetString($buf) + $carry
    $parts = $text -split "`n"
    $carry = $parts[0]              # 首段可能被切断,滚入下一块(更早的块)
    $newlineCount += ($parts.Count - 1)
    $cur = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -lt $parts.Count; $i++) { if ($parts[$i].Trim()) { $cur.Add($parts[$i].Trim()); $totalLines++ } }
    $chunks.Add($cur)
    if ($pos -eq 0 -and $carry.Trim()) { $cur.Insert(0, $carry.Trim()); $totalLines++ }
  }
} finally {
  if ($fs) { try { $fs.Dispose() } catch {} }
}

# ---------- 解析(块序=新→旧,块内倒序走=新→旧)、裁剪、取前 N ----------
$entries = New-Object System.Collections.Generic.List[object]
$moreOlder = $false
$seenRaw = 0
:outer foreach ($chunk in $chunks) {
  for ($j = $chunk.Count - 1; $j -ge 0; $j--) {
    $seenRaw++
    if ($entries.Count -ge $lines) { break outer }
    $line = $chunk[$j]
    # 微优化:started 行约一半,字符串预筛先跳过,ConvertFrom-Json 成本减半(50条实测见交付)
    if ($line -notmatch '"stage":"finished"') { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    if ($e.stage -ne 'finished') { continue }
    $err = ''
    if ($e.error) { $err = [string]$e.error; if ($err.Length -gt 160) { $err = $err.Substring(0, 160) } }
    $entries.Add([pscustomobject]@{
      ts = $e.ts; channel = ($(if ($e.channel) { [string]$e.channel } else { 'mcp' }))
      tool = [string]$e.tool; system = [string]$e.system
      opClass = [string]$e.operationClass; result = [string]$e.result
      code = [string]$e.code; rows = $e.rowsReturned; durationMs = $e.durationMs
      error = $err
    })
  }
}
if ($totalLines -ge $need -or $seenRaw -ge $need) { $moreOlder = $true }

$sw.Stop()
# 房子约定(bridge-client.run 只取 data.result):负载必须嵌在 result 键里
return @{
  ok = $true
  result = [ordered]@{
    date = $date; file = $auditFile
    entries = $entries; moreOlder = $moreOlder
    elapsedMs = $sw.ElapsedMilliseconds
  }
}
