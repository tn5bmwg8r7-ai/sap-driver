# ============================================================
# _sap-facade  -  SAP MCP http-facade 访问单点(PW SAP Driver P1,2026-09-14)。
# 文件名 _ 开头,_registry.ps1 不会当成路由暴露。
#
# 职责:读 facade.local.json(port+token)→ 健康探测 → 死了就 WMI 拉起
# (wscript 隐藏包装器,规避控制台闪窗/QuickEdit 冻结)→ 提供统一 POST/GET 封装。
# facade 本体:sap-mcp\src\http-facade.js(127.0.0.1+Bearer,workerpool 热连接池)。
#
# 红线:token 只在内存流转,不写日志;密码只经 facade 进程内存,永不落盘。
# 依赖:无。调用方 dot-source 本文件。
# ============================================================

$script:SapFacadeRoot = if ($env:SAP_MCP_ROOT) { $env:SAP_MCP_ROOT } else { Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'mcp-server' }
$script:SapFacadeCfg  = Join-Path $script:SapFacadeRoot 'facade.local.json'
$script:SapFacadeVbs  = Join-Path $script:SapFacadeRoot 'Start-SapFacade.vbs'

function Get-SapFacadeConfig {
  if ($script:_sapFacadeCfg) { return $script:_sapFacadeCfg }
  if (-not (Test-Path $script:SapFacadeCfg)) {
    throw "SAP_FACADE_CFG_MISSING: $($script:SapFacadeCfg) 不存在(含 port/token,属本机文件,不分发)"
  }
  $j = Get-Content $script:SapFacadeCfg -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $j.port -or -not $j.token) { throw "SAP_FACADE_CFG_BAD: facade.local.json 缺 port/token" }
  $script:_sapFacadeCfg = @{ Port = [int]$j.port; Token = [string]$j.token
                             Base = "http://127.0.0.1:$([int]$j.port)" }
  return $script:_sapFacadeCfg
}

function Invoke-SapFacadeApi {
  param(
    [Parameter(Mandatory)][string]$Method,    # GET / POST
    [Parameter(Mandatory)][string]$Path,      # /health /tools /run/xxx /shutdown
    [string]$JsonBody = '',
    [int]$TimeoutSec = 10
  )
  $cfg = Get-SapFacadeConfig
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    if ($Method -eq 'GET') {
      $r = Invoke-RestMethod -Uri ($cfg.Base + $Path) -Method Get -TimeoutSec $TimeoutSec `
             -Headers @{ Authorization = "Bearer $($cfg.Token)" }
    } else {
      $r = Invoke-RestMethod -Uri ($cfg.Base + $Path) -Method Post -TimeoutSec $TimeoutSec `
             -ContentType 'application/json; charset=utf-8' `
             -Headers @{ Authorization = "Bearer $($cfg.Token)" } `
             -Body ([Text.Encoding]::UTF8.GetBytes($JsonBody))
    }
    $sw.Stop()
    return @{ ok = $true; data = $r; httpMs = $sw.ElapsedMilliseconds }
  } catch {
    $sw.Stop()
    $msg = $_.Exception.Message
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
    return @{ ok = $false; error = $msg; httpMs = $sw.ElapsedMilliseconds }
  }
}

function Test-SapFacadeUp {
  # 快探(1.5s):活着返回 $true。不拉起。
  $r = Invoke-SapFacadeApi -Method GET -Path '/health' -TimeoutSec 2
  return $r.ok
}

function Ensure-SapFacade {
  # 健康则直返;死了 WMI 拉起(隐藏窗口)并轮询最多 ~7s。
  # 返回 @{ running=[bool]; startedNow=[bool] }
  if (Test-SapFacadeUp) { return @{ running = $true; startedNow = $false } }
  if (-not (Test-Path $script:SapFacadeVbs)) {
    throw "SAP_FACADE_VBS_MISSING: $($script:SapFacadeVbs)"
  }
  $cmdline = "wscript.exe `"$script:SapFacadeVbs`""
  try {
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
      CommandLine = $cmdline; CurrentDirectory = $script:SapFacadeRoot
    } | Out-Null
  } catch {
    throw "SAP_FACADE_SPAWN_FAILED: $($_.Exception.Message)"
  }
  for ($i = 0; $i -lt 14; $i++) {           # 14 x 500ms = 7s 上限(node 冷启动 ~1-3s)
    Start-Sleep -Milliseconds 500
    if (Test-SapFacadeUp) { return @{ running = $true; startedNow = $true } }
  }
  return @{ running = $false; startedNow = $true }
}
