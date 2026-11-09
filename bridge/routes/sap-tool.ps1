param([Parameter(Mandatory)][hashtable]$Body)

# sap-tool  -  SAP Driver 工具执行转发路由(P1,2026-09-14)。
# POST facade /run/<tool>,治理(audit/env-policy/fm-check)全在 facade 同源生效,
# 本路由零业务逻辑、零第二套口径。白名单在 facade(FACADE_TOOLS),写类到这里会被 403。
# 超时:facade 侧 worker EXEC_TIMEOUT 90s,这里 100s 兜底;前端 bridge.run 传 110s。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$tool = ([string]$input_.tool).Trim()
if (-not $tool -or $tool -notmatch '^[a-z_]{3,40}$') { return (Fail 'BAD_TOOL' "tool 名非法: $tool") }

$argsObj = $input_.args
$json = '{}'
try {
  if ($null -ne $argsObj) { $json = $argsObj | ConvertTo-Json -Depth 24 -Compress }
} catch {
  return (Fail 'BAD_ARGS' "args 序列化失败: $($_.Exception.Message)")
}

try {
  $up = Ensure-SapFacade
  if (-not $up.running) { return (Fail 'FACADE_DOWN' 'facade 拉起失败,无法执行工具。') }
} catch {
  return (Fail 'FACADE_ENSURE_FAILED' $_.Exception.Message)
}

# 特例:sap_disconnect = facade 独立端点 /disconnect(不在 TOOLS 注册表,不能走 /run/)。
# 清 facade 进程内该系统凭证 + 杀该系统热 worker(真断连接);不影响其它系统。
if ($tool -eq 'sap_disconnect') {
  $r = Invoke-SapFacadeApi -Method POST -Path '/disconnect' -JsonBody $json -TimeoutSec 15
} else {
  $r = Invoke-SapFacadeApi -Method POST -Path "/run/$tool" -JsonBody $json -TimeoutSec 100
}
if (-not $r.ok) {
  $code = 'FACADE_HTTP_FAILED'
  if ($r.error -match 'timed out|timeout') { $code = 'FACADE_TIMEOUT' }
  return (Fail $code $r.error)
}

# ---- 凭证合一双写(2026-09-21 用户定案「小助理和 SAP 副驾走一个通道,DVP QAS PRD 都是」)----
# facade 连接/断开成功后,同步 bridge 内存槽:连接=同值写入该系统格,断开=清该格。
# 小助理文档链(action-run 表单密码为空时)从此取,主人只需在连接管理连一次。
# Client:仅存表单【显式填了】的值;空=消费端用各系统默认(见 _sap-conn 环境表),
# 因为 facade 空值走 facade 自己的默认(如 DVP=200),两链默认不同是历史口径,不强扭。
# PRD 格允许存在;消费端闸门不变(interface-doc 照旧 PRD_FORBIDDEN)。密码仅内存,红线不破。
if ($tool -eq 'sap_connect' -or $tool -eq 'sap_disconnect') {
  . (Join-Path $PSScriptRoot '_sap-conn.ps1')
  function Get-ArgStr([object]$o, [string]$n) {
    if ($o -is [System.Collections.IDictionary]) { $v = $o[$n] } else { $p = $o.PSObject.Properties[$n]; $v = if ($p) { $p.Value } else { $null } }
    return $(if ($null -ne $v) { [string]$v } else { '' })
  }
  $aSys = (Get-ArgStr $argsObj 'system').Trim().ToUpper()
  if ($tool -eq 'sap_connect') {
    $aPwd = Get-ArgStr $argsObj 'password'
    if ($aSys -in @('DVP','QAS','PRD') -and $aPwd) {
      Save-SapSessionCred -System $aSys -Password $aPwd `
        -User $(if (Get-ArgStr $argsObj 'user') { Get-ArgStr $argsObj 'user' } else { '' }) `
        -Client (Get-ArgStr $argsObj 'client').Trim() -TtlHours 12
    }
  } else {
    if ($aSys) { Clear-SapSessionCred -System $aSys }
  }
}

# facade 返回体透传(ok/code/message/result/durationMs),外加转发耗时,整体嵌进
# result 键(房子约定:bridge-client.run 只取 data.result)。
# PS 5.1 双坑(2026-09-14 实爆):IRM 反序列化产物是 PSCustomObject——直接赋新属性
# 炸 SetValueInvocationException,`$o['k']` 索引又静默返回 $null。统一拍平成 hashtable。
$out = @{}
foreach ($p in @($r.data.PSObject.Properties)) { $out[$p.Name] = $p.Value }
$out['facadeHttpMs'] = [long]$r.httpMs
return @{ ok = $true; result = $out }
