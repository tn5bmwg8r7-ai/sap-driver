. $PSScriptRoot\bridge.config.json.ps1

# 跨 runspace 共享缓存仓(2026-09-11 批三续):重路由在子 runspace 里跑,而 $global: 是
# runspace 级——路由 helper 的会话/摘要/台账缓存在子 runspace 全灭,叠加 helper 的无条件
# 重置行,这些缓存此前实际只在单次请求内存活。Add-Type 的静态字段挂 AppDomain,主线程/
# worker/子 runspace 三层共享(-as [type] 防重复编译;本文件被三层各自 dot-source,是唯一
# 三层都过的加载点)。
if (-not ('PWCrossRunspaceCache' -as [type])) {
  Add-Type -TypeDefinition @"
using System.Collections.Concurrent;
public static class PWCrossRunspaceCache {
    public static readonly System.Collections.Concurrent.ConcurrentDictionary<string, object> Store = new System.Collections.Concurrent.ConcurrentDictionary<string, object>();
}
"@
}

function Invoke-BridgeConfig {
  return $script:BridgeConfig
}

function Test-BridgeOrigin {
  param([string]$Origin)
  if ([string]::IsNullOrEmpty($Origin)) { return $false }
  $cfg = Invoke-BridgeConfig
  foreach ($pattern in $cfg.allowedOrigins) {
    if ($pattern -eq $Origin) { return $true }
    if ($pattern.Contains('*')) {
      $regex = '^' + ([regex]::Escape($pattern) -replace '\\\*', '.*') + '$'
      if ($Origin -match $regex) { return $true }
    }
  }
  return $false
}

function Test-BridgeToken {
  param([string]$AuthorizationHeader)
  if ([string]::IsNullOrEmpty($AuthorizationHeader)) { return $false }
  if (-not $AuthorizationHeader.StartsWith('Bearer ')) { return $false }
  $presented = $AuthorizationHeader.Substring(7).Trim()
  # token 仅启动时 Ensure-BridgeToken 生成,运行期不变——首读后缓存(2026-09-01 审计:
  # 原 529 次 POST = 529 次"开文件-读-关";tokenFile mtime 变化时重读,手换 token 也能生效)
  $cfg = Invoke-BridgeConfig
  $tokenPath = [Environment]::ExpandEnvironmentVariables($cfg.tokenFile)
  if (-not (Test-Path $tokenPath)) { return $false }
  if (-not $script:BridgeTokenCache -or $script:BridgeTokenCache.Path -ne $tokenPath -or
      (Get-Item $tokenPath).LastWriteTimeTicks -ne $script:BridgeTokenCache.Mtime) {
    $script:BridgeTokenCache = @{
      Path  = $tokenPath
      Mtime = (Get-Item $tokenPath).LastWriteTimeTicks
      Token = (Get-Content $tokenPath -Raw).Trim()
    }
  }
  return ($presented -eq $script:BridgeTokenCache.Token)
}

function Write-BridgeCORS {
  param($Response)
  $Response.Headers.Add('Access-Control-Allow-Origin', '*')
  $Response.Headers.Add('Access-Control-Allow-Methods', 'POST, OPTIONS')
  $Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type, Authorization')
  $Response.Headers.Add('Access-Control-Max-Age', '86400')
}

function Write-BridgeJson {
  param($Response, [hashtable]$Payload, [int]$Status = 200)
  $Response.StatusCode = $Status
  $Response.ContentType = 'application/json; charset=utf-8'
  Write-BridgeCORS -Response $Response
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 10 -Compress))
  $Response.ContentLength64 = $bytes.Length
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-BridgeError {
  param($Response, [string]$Code, [string]$Message, [int]$Status = 400)
  Write-BridgeJson -Response $Response -Status $Status -Payload @{
    ok = $false
    error = @{ code = $Code; message = $Message }
  }
}

function New-SilentRouteEnvelope {
  # 路由零输出时的兜底分类(2026-09-17 dispatcher 吞错洞封堵)。
  # 旧行为:路由没吐任何输出(如子 runspace EAP=Continue 下只写了非终止错误就被打断)
  # → 一律伪造 ok:true+result:{},前端拿空壳当成功,排障时"路由明明炸了桥却说 ok"。
  # 新行为:
  #  - 有错误证据(错误记录)→ ok:false + ROUTE_SILENT_FAIL,HTTP 200 走前端既有软错误
  #    通道(与 FEATURE_LOCKED 同款,bridge-client run() 抛 err.code,调用方零改动)
  #  - 干净静默(路由确实什么都没返回且无错误)→ 维持 ok:true+result:{} 历史兜底
  param([object[]]$NewErrs = @())
  if ($NewErrs -and $NewErrs.Count -gt 0) {
    $msg = (@($NewErrs | ForEach-Object { if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "$_" } }) -join '; ')
    if ($msg.Length -gt 500) { $msg = $msg.Substring(0, 500) + '…' }
    return @{ ok = $false
               error = @{ code = 'ROUTE_SILENT_FAIL'
                          message = "路由执行出错且未返回结果: $msg" } }
  }
  return @{ ok = $true; result = @{} }
}
