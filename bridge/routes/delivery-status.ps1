param([Parameter(Mandatory)][hashtable]$Body)

# ============================================================
# delivery-status — 交付工单只读扫描(2026-11-04 T1,TAB设计-v1.md §5)。
# 扫 <交付根>(env SAP_DELIVERY_ROOT,缺省=仓库 data/delivery)\*\delivery.json(排除 _trash-* 软删),返回归一化列表
# 供「🚰 一站式交付」TAB 工单卡渲染。纯读零写;单工单详情走 input.ticket 精确取。
# JSON 解析失败的单子返回 error:parseFailed 不静默丢(数据丢失红线:宁可报错不可看似没了)。
# ============================================================

$root = if ($env:SAP_DELIVERY_ROOT) { $env:SAP_DELIVERY_ROOT } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'delivery' }
if (-not (Test-Path -LiteralPath $root)) {
  return @{ ok = $true; result = @{ tickets = @(); total = 0 } }
}

$bodyInput = $Body.input
$wantTicket = if ($bodyInput -and $bodyInput.ticket) { [string]$bodyInput.ticket } else { '' }

$tickets = New-Object System.Collections.ArrayList
# 精确取(input.ticket)不过 _trash 过滤——软删单也要能查(测试/回查场景;2026-11-04 P3 实测:
# _trash 单精确取返回空数组,total:0,投影无从验证)
$dirs = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
  Where-Object { $wantTicket -or ($_.Name -notlike '_trash-*') } |
  Sort-Object Name -Descending

foreach ($d in $dirs) {
  $f = Join-Path $d.FullName 'delivery.json'
  if (-not (Test-Path -LiteralPath $f)) { continue }
  if ($wantTicket -and $d.Name -ne $wantTicket) { continue }
  try {
    $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    # 解析失败不静默丢:带 error 标记返回,前端显示「档损待修」
    [void]$tickets.Add(@{
      ticket = $d.Name; parseError = $true
      updatedAt = $null; status = $null
    })
    continue
  }
  # 归一化投影:只取 TAB 渲染所需字段(窄读,不搬全文;objects 只留摘要)
  # parseError=false 显式落值(2026-11-04 实测:PSCustomObject 没写的属性=缺失而非 false,
  # 前端 JSON 序列化时会把整对象塞进 parseError 位——展示层拿它当真值判断就全量误报档损)
  $objs = @()
  if ($j.objects) {
    $objs = @($j.objects | ForEach-Object { @{ type = [string]$_.type; name = [string]$_.name; trkorr = [string]$_.trkorr } })
  }
  $checks = @()
  if ($j.checks) { $checks = @($j.checks) }
  # P2:artifacts/handoff/defects/requirement 投影(前端窄写合并旧值需要;窄读不变)
  $handoff = $null
  if ($j.handoff) { $handoff = $j.handoff }
  $artifacts = $null
  if ($j.artifacts) { $artifacts = $j.artifacts }
  $defects = @()
  if ($j.defects) { $defects = @($j.defects) }
  $stageRuns = $null
  if ($j.stageRuns) { $stageRuns = $j.stageRuns }   # P3:节点→通道执行史(徽标"谁干的")
  $requirement = $null
  if ($j.requirement) { $requirement = $j.requirement }
  $moss = $null
  if ($j.mossTodo -and $j.mossTodo.sourceId) { $moss = @{ sourceId = [string]$j.mossTodo.sourceId; title = [string]$j.mossTodo.title } }
  [void]$tickets.Add(@{
    ticket     = [string]$j.ticket
    dir        = $d.Name
    status     = [string]$j.status
    summary    = [string]$j.summary
    source     = [string]$j.source
    systemScope = @($j.systemScope)
    stages     = $j.stages
    checks     = $checks
    objects    = $objs
    mossTodo   = $moss
    handoff    = $handoff
    artifacts  = $artifacts
    defects    = $defects
    stageRuns  = $stageRuns
    requirement = $requirement
    updatedAt  = [string]$j.updatedAt
    schema     = [int]$j.schema
    parseError = $false
    doneFlag  = [bool]$j.doneFlag
  })
}

return @{ ok = $true; result = @{ tickets = @($tickets); total = $tickets.Count } }
