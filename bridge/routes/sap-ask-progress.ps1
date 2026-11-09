param([Parameter(Mandatory)][hashtable]$Body)

# sap-ask-progress  -  SAP Driver「Agent Harness」执行进度查询(P2,2026-09-14)。
# widget 在 sap-ask 执行期间轮询本路由(传 callId),读 sap-ask 落的进度文件,
# 实现「规划→执行 i/N→汇总」阶段实时反馈。文件不存在 = 已完成/未开始,found:false。
# 轻路由:纯文件读,毫秒级。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-lib.ps1')   # SapProgressDir 常量单源(2026-09-21 审查;轻路由引库无副作用)

$input_ = $Body.input
$callId = if ($input_ -and $input_.callId) { [string]$input_.callId } else { '' }
# 前缀:ask=sap-ask 编排(默认);diag=sap-diagnose 诊断(v8 复用同一进度机制)
$kind = if ($input_ -and $input_.kind) { [string]$input_.kind } else { 'ask' }
if ($kind -notin @('ask', 'diag')) { $kind = 'ask' }
if ($callId -notmatch '^[a-f0-9-]{8,40}$') {
  return @{ ok = $false; error = @{ code = 'BAD_CALLID'; message = 'callId 非法' } }
}
$file = Join-Path $global:SapProgressDir ("$kind-$callId.json")
if (-not (Test-Path $file)) {
  return @{ ok = $true; result = @{ found = $false } }
}
try {
  $j = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
  return @{ ok = $true; result = [ordered]@{
    found = $true
    phase = [string]$j.phase; step = [int]$j.step; total = [int]$j.total
    tool = [string]$j.tool; ts = [long]$j.ts
  } }
} catch {
  return @{ ok = $true; result = @{ found = $false } }   # 读竞态(正在写)按未找到处理,下轮再读
}
