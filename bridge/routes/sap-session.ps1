param([Parameter(Mandatory)][hashtable]$Body)

# ============================================================
# sap-session - SAP 会话凭证内存槽管理(2026-09-20 建;2026-09-21 v2 按系统分格+凭证合一)。
#
#   input.action = inject | clear | status
#     inject: { user?, password, system?, ttlHours?, client? }
#             先 STFC_CONNECTION 验密 ping(失败不入槽,防注坏凭证后全自动链路集体失败),
#             通过才写入该系统的格。bridge 重启即失效。
#     clear : { system? } 省略 system=清全部;指定=只清该格(疑似泄露/换账号时用)。
#     status: 只回各格 user/system/client/expiresAt/剩余分钟,绝不回显密码。
#
#   主通道(2026-09-21 用户定案):连接管理 sap-tool sap_connect 成功即同值双写槽、断开同清
#   —— 本路由降级为脚本化备用通道(tools\set-sap-session.ps1 仍走这里)。
#   红线:密码仅内存,不落盘/不进日志/不在任何返回与报错中回显。
#   PRD:三系统同通道允许入槽;消费端闸门不动(interface-doc 照旧 PRD_FORBIDDEN)。
# ============================================================

$in = $Body.input
$action = if ($in -and $in.action) { ([string]$in.action).Trim().ToLower() } else { '' }
if (-not $action) {
  return @{ ok = $false; error = @{ code = 'MISSING_ACTION'; message = 'input.action required (inject/clear/status)' } }
}

. (Join-Path $PSScriptRoot '_sap-conn.ps1')
. (Join-Path $PSScriptRoot '_sap-rfclogin.ps1')   # Test-SapRfcLogin(本机部署专用,2026-09-21 V7 拆出)

if ($action -eq 'clear') {
  $cSys = if ($in.system) { ([string]$in.system).Trim().ToUpper() } else { '' }
  Clear-SapSessionCred -System $cSys
  return @{ ok = $true; result = @{ cleared = $true; system = $cSys } }
}

if ($action -eq 'status') {
  $store = Get-SapSessionCred
  $items = @()
  if ($store -is [System.Collections.IDictionary]) {
    foreach ($kv in @($store.GetEnumerator())) {
      $c = Get-SapSessionCred -System ([string]$kv.Key)   # 走过期顺手清逻辑
      if (-not $c) { continue }
      $items += [ordered]@{
        system = [string]$kv.Key; user = [string]$c.User; client = [string]$c.Client
        expiresAt = $c.ExpiresAt.ToString('yyyy-MM-dd HH:mm:ss')
        remainingMinutes = [int]($c.ExpiresAt - (Get-Date)).TotalMinutes
      }
    }
  }
  $res = @{ ready = ($items.Count -gt 0); systems = @($items) }
  if (-not $items.Count) { $res.reason = '未注入或已过期(bridge 重启也会清空)' }
  return @{ ok = $true; result = $res }
}

if ($action -ne 'inject') {
  return @{ ok = $false; error = @{ code = 'BAD_ACTION'; message = 'input.action 仅支持 inject/clear/status' } }
}

# ---------- inject ----------
$password = if ($in.password) { [string]$in.password } else { '' }
if (-not $password) {
  return @{ ok = $false; error = @{ code = 'MISSING_PASSWORD'; message = 'input.password required' } }
}
$user   = if ($in.user) { [string]$in.user } else { '' }   # 开源版:默认空,调用方显式传
$system = if ($in.system) { ([string]$in.system).Trim().ToUpper() } else { 'DVP' }
$client = if ($in.client) { ([string]$in.client).Trim() } else { '' }
$ttlHours = 12
if ($in.ttlHours) { $ttlHours = [int]$in.ttlHours }
if ($ttlHours -lt 1 -or $ttlHours -gt 72) { $ttlHours = 12 }
if ($system -notin @('DVP','QAS','PRD')) {
  return @{ ok = $false; error = @{ code = 'BAD_SYSTEM'; message = 'system 仅支持 DVP/QAS/PRD' } }
}

# 验密 ping(2026-09-21 审查收拢:引导链切 _sap-conn Test-SapRfcLogin):失败不入槽,当场报错(不含密码)。
$login = Test-SapRfcLogin -System $system -User $user -Password $password -Client $client -PingTag 'pw-session'
if (-not $login.ok) {
  return @{ ok = $false; error = @{ code = $login.code; message = $login.message + ' —— 凭证未入槽' } }
}

Save-SapSessionCred -Password $password -System $system -User $user -Client $client -TtlHours $ttlHours
$c = Get-SapSessionCred -System $system
return @{ ok = $true; result = @{
  ready = $true; system = $system; user = $c.User; client = [string]$c.Client
  expiresAt = $c.ExpiresAt.ToString('yyyy-MM-dd HH:mm:ss')
  remainingMinutes = [int]($c.ExpiresAt - (Get-Date)).TotalMinutes
} }
