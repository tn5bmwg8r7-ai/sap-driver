param([Parameter(Mandatory)][hashtable]$Body)

# sap-status  -  SAP Driver 状态条聚合路由(P1,2026-09-14)。
# 一次请求返回:facade 运行态(死则 WMI 拉起)+ 三系统凭证缓存态/连接配置 + 今日审计计数。
# 性能预算:热 ≤300ms(纯 health+文件计数);冷(facade 需拉起)≤8s 上限,实测见交付。
# 红线:只读;不碰密码;PRD 治理在 facade/env-policy 同源生效,本路由不做第二套口径。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_sap-conn.ps1')   # Get-SapSessionCred:小助理文档链内存槽(与本进程同 AppDomain,直读即可)

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------- 1) facade 健康(死则拉起) ----------
$startedNow = $false
try {
  $up = Ensure-SapFacade
  $startedNow = [bool]$up.startedNow
  if (-not $up.running) {
    return (Fail 'FACADE_DOWN' "facade 拉起后仍无响应(端口占用/启动失败?)。可查 sap-mcp 目录手工排障。")
  }
} catch {
  return (Fail 'FACADE_ENSURE_FAILED' $_.Exception.Message)
}
$health = Invoke-SapFacadeApi -Method GET -Path '/health' -TimeoutSec 5
if (-not $health.ok) { return (Fail 'FACADE_HEALTH_FAILED' $health.error) }
$h = $health.data

$cached = @()
if ($h.credCached) { $cached = @($h.credCached | ForEach-Object { [string]$_ }) }

$systems = [ordered]@{}
foreach ($kv in @($h.systems.PSObject.Properties)) {
  $systems[$kv.Name] = [ordered]@{
    host = $kv.Value.appServerHost; client = [string]$kv.Value.client
    user = $kv.Value.user; role = $kv.Value.role
    cached = ($cached -contains $kv.Name)
  }
}

# ---------- 1.5) 小助理文档链内存槽(2026-09-21;同日晚 v2 按系统分格)----------
# 与 facade 凭证缓存是两条链:本槽喂钉钉小助理自动接口文档(action-run 表单密码为空时兜底),
# 主通道=连接管理 sap_connect 成功双写/sap_disconnect 同清(凭证合一,2026-09-21 用户定案)。
# bridge 重启即清空——状态条把它亮出来,别被 facade 的「已连」掩盖。
# 只报 user/system/client/到期,绝不回显密码。
$store = Get-SapSessionCred
$slotItems = @()
if ($store -is [System.Collections.IDictionary]) {
  foreach ($kv in @($store.GetEnumerator())) {
    $c = Get-SapSessionCred -System ([string]$kv.Key)   # 走过期顺手清格逻辑
    if (-not $c) { continue }
    $slotItems += [ordered]@{ system = [string]$kv.Key; user = [string]$c.User; client = [string]$c.Client
                              expiresAt = $c.ExpiresAt.ToString('yyyy-MM-dd HH:mm:ss')
                              remainingMinutes = [int]($c.ExpiresAt - (Get-Date)).TotalMinutes }
  }
}
$botDocChain = [ordered]@{ ready = ($slotItems.Count -gt 0); systems = @($slotItems) }

# ---------- 2) 今日审计计数(统一总账:CC 的 mcp 通道 + PW 的 pw 通道都在这) ----------
$auditDir = if ($env:SAP_MCP_AUDIT_DIR) { $env:SAP_MCP_AUDIT_DIR } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'sap-mcp-audit' }
$today = Get-Date -Format 'yyyy-MM-dd'
$auditFile = Join-Path $auditDir ("audit-$today.jsonl")
$cnt = @{ total = 0; ok = 0; error = 0; denied = 0; lastTs = $null }
try {
  if (Test-Path $auditFile) {
    foreach ($ln in [System.IO.File]::ReadLines($auditFile)) {
      if (-not $ln) { continue }
      if (-not $ln.Contains('"stage":"finished"')) { continue }   # 字符串预筛:started 行不进 JSON 解析(sap-audit 同款)
      try { $e = $ln | ConvertFrom-Json } catch { continue }
      if ($e.stage -ne 'finished') { continue }
      $cnt.total++
      if ($e.result -eq 'ok') { $cnt.ok++ }
      elseif ($e.result -eq 'error') { $cnt.error++ }
      elseif ($e.result -eq 'denied') { $cnt.denied++ }
      if ($null -ne $e.ts) { $cnt.lastTs = [long]$e.ts }
    }
  }
} catch {
  # 计数失败不影响状态可用性:降级返回 facade 侧信息
  $cnt.parseError = $_.Exception.Message
}

$sw.Stop()
# 房子约定(bridge-client.run 只取 data.result):负载必须嵌在 result 键里
return @{
  ok = $true
  result = [ordered]@{
    facade = [ordered]@{ running = $true; startedNow = $startedNow; pid = $h.pid
                         uptimeMs = $h.uptimeMs; exposedToolCount = @($h.exposedTools).Count }
    systems = $systems
    botDocChain = $botDocChain
    audit = [ordered]@{ date = $today; file = $auditFile; total = [int]$cnt.total
                        ok = [int]$cnt.ok; error = [int]$cnt.error; denied = [int]$cnt.denied
                        lastTs = $cnt.lastTs }
    elapsedMs = $sw.ElapsedMilliseconds
  }
}
