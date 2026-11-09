$configPath = Join-Path $PSScriptRoot 'bridge.config.json'
$raw = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Expand-BridgeValue {
  param([string]$Value)
  if ($null -eq $Value) { return $null }
  return [Environment]::ExpandEnvironmentVariables($Value)
}

$script:BridgeConfig = @{
  host             = $raw.host
  port             = [int]$raw.port
  allowedOrigins   = @($raw.allowedOrigins)
  tokenFile        = Expand-BridgeValue $raw.tokenFile
  scriptsDir       = Expand-BridgeValue $raw.scriptsDir
  systemListPath   = Expand-BridgeValue $raw.systemListPath
  routeMaxSec      = if ($raw.routeMaxSec) { [int]$raw.routeMaxSec } else { 600 }   # 重路由执行时长护栏(Start-Bridge worker),白名单外键会被静默丢弃
}

# BPM 门户 playwright profile 目录(bpm-todo-sync / bpm-todo-login / 两个 python 共用;
# 脚本端读 BPM_PORTAL_PROFILE,缺省回落 <LOCALAPPDATA>\pw-bpm-todo)。config 缺段则不动 env。
if ($raw.bpmPortal -and $raw.bpmPortal.profile) {
  $env:BPM_PORTAL_PROFILE = Expand-BridgeValue $raw.bpmPortal.profile
}
