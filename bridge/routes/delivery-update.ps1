param([Parameter(Mandatory)][hashtable]$Body)

# ============================================================
# delivery-update — 工单窄写路由(2026-11-04 P1,conventions v3)。
# 红线:模型/大脑不得直接写工单状态——status 与 stages.* 的推进只能:
#   ①走本路由(白名单键+机器校验守门) ②走 sap-ledger 合法转移表(CC 侧)。
# 白名单键:stages/checks/defects/coverage/requirement/review/artifacts/handoff/mossTodo
# 禁触键:status/objects/tr/eval/schema/ticket/createdAt(归属 sap-ledger 管辖,防双写者打架)。
# stages 值域校验:pending/doing/done/skipped/blocked;check 节点 done 要求最近一轮 pass。
# 全程:读→合并→ConvertTo-Json 回验→原子写(与 pw-asset-mirror 同款 tmp+Move)。
# ============================================================

$root = if ($env:SAP_DELIVERY_ROOT) { $env:SAP_DELIVERY_ROOT } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'delivery' }
$bodyInput = $Body.input
$ticket = if ($bodyInput -and $bodyInput.ticket) { [string]$bodyInput.ticket } else { '' }
if (-not $ticket -or $ticket -match '[\\/]') {
  return @{ ok = $false; error = @{ code = 'TICKET_REQUIRED'; message = 'input.ticket required(工单目录名,禁路径分隔符)' } }
}

$ALLOWED = @('stages','checks','defects','coverage','requirement','review','artifacts','handoff','mossTodo','stageRuns','doneFlag')
$FORBIDDEN = @('status','objects','tr','eval','schema','ticket','createdAt','prevState')

$f = Join-Path $root (Join-Path $ticket 'delivery.json')
if (-not (Test-Path -LiteralPath $f)) {
  return @{ ok = $false; error = @{ code = 'TICKET_NOT_FOUND'; message = "工单不存在:$ticket" } }
}
try {
  $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
  return @{ ok = $false; error = @{ code = 'PARSE_FAILED'; message = "delivery.json 解析失败,拒绝在档损文件上写入:$($_.Exception.Message)" } }
}

$patch = $bodyInput.patch
if (-not $patch) {
  return @{ ok = $false; error = @{ code = 'PATCH_REQUIRED'; message = 'input.patch required(要合并的键值对)' } }
}

# ---- 白名单/禁触键校验 ----
# 2026-11-04 实测坑:JSON→PS 反序列化,嵌套对象到 $Body 里可能成 hashtable(桥端 Body 转换链)
# 或 PSCustomObject(本路由二次 ConvertFrom-Json);hashtable 没有 .PSObject.Properties.Name
# 可用键集,统一归一:hashtable→PSCustomObject(PSCustomObject 的 .PSObject.Properties 才含
# ICollection 垃圾键——实测 Keys/Values/Count 全冒出来白名单必炸)
if ($patch -is [System.Collections.IDictionary]) {
  $patch = $patch | ConvertTo-Json -Depth 12 | ConvertFrom-Json
}
$patchProps = @($patch.PSObject.Properties.Name | Where-Object { $_ -notmatch '^(IsReadOnly|IsFixedSize|IsSynchronized|Keys|Values|SyncRoot|Count|SyncRoot)$' })
$bad = @($patchProps | Where-Object { $ALLOWED -notcontains $_ })
if ($bad.Count -gt 0) {
  return @{ ok = $false; error = @{ code = 'KEY_NOT_ALLOWED'
    message = "键不在白名单:$($bad -join ',')。可写:$($ALLOWED -join ',');status/objects/tr 等归 sap-ledger 管辖。" } }
}

# ---- stages 值域校验 ----
if ($patch.PSObject.Properties['stages']) {
  $VALID = @('pending','doing','done','skipped','blocked')
  $sp = $patch.stages
  foreach ($p in $sp.PSObject.Properties) {
    if ($VALID -notcontains [string]$p.Value) {
      return @{ ok = $false; error = @{ code = 'BAD_STAGE_VALUE'
        message = "stages.$($p.Name)='$($p.Value)' 非法;允许:$($VALID -join '/')" } }
    }
    # check 节点 done 的前置:最近一轮 checks.verdict=pass(机器判,不采信口头"做完了")
    if ($p.Name -eq 'check' -and [string]$p.Value -eq 'done') {
      $newChecks = if ($patch.PSObject.Properties['checks']) { @($patch.checks) } else { @($j.checks) }
      $last = $newChecks | Sort-Object { [int]$_.round } -Descending | Select-Object -First 1
      if (-not $last -or [string]$last.verdict -ne 'pass') {
        return @{ ok = $false; error = @{ code = 'CHECK_NOT_PASSED'
          message = 'stages.check=done 要求最近一轮 checks.verdict=pass(先落检查轮次再推进)' } }
      }
    }
  }
}

# ---- 合并(浅合并:patch 顶层键整体替换;stages 深合并到键级) ----
foreach ($p in $patch.PSObject.Properties) {
  $k = $p.Name
  if ($k -eq 'stages') {
    if (-not $j.PSObject.Properties['stages']) { $j | Add-Member -NotePropertyName stages -NotePropertyValue ([pscustomobject]@{}) }
    foreach ($sp in $p.Value.PSObject.Properties) {
      if ($j.stages.PSObject.Properties[$sp.Name]) { $j.stages.$($sp.Name) = $sp.Value }
      else { $j.stages | Add-Member -NotePropertyName $sp.Name -NotePropertyValue $sp.Value }
    }
  } else {
    if ($j.PSObject.Properties[$k]) { $j.$k = $p.Value }
    else { $j | Add-Member -NotePropertyName $k -NotePropertyValue $p.Value }
  }
}
$j.updatedAt = (Get-Date -Format 'yyyy-MM-dd')

# ---- 回验+原子写 ----
$json = $j | ConvertTo-Json -Depth 12
try {
  $null = $json | ConvertFrom-Json   # 回验可解析
} catch {
  return @{ ok = $false; error = @{ code = 'ROUNDTRIP_FAILED'; message = "合并后 JSON 回验失败,拒绝写入:$($_.Exception.Message)" } }
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$tmp = "$f.tmp"
[System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
Move-Item -LiteralPath $tmp -Destination $f -Force

return @{ ok = $true; result = @{ ticket = $ticket; updatedKeys = @($patchProps); updatedAt = [string]$j.updatedAt } }
