param([Parameter(Mandatory)][hashtable]$Body)

# sap-diagpack  -  🩺 系统体检(2026-09-16 v14;同日加第 4 节 SM12 锁)。
# 选系统 → 一键巡检四块:ST22 dump(SNAP)/ SM13 更新请求(VBMOD+VBHDR)/ 后台作业(TBTCO 取消+卡死)/ SM12 当前锁(ENQUEUE_READ)。
# 只读:三节走 sap_query 查表,锁节走 fm_exec ENQUEUE_READ 内存读;单节失败标 NA 带原因,绝不炸整份报告。
# 字段口径(2026-09-16 DD03L 实探 DVP):
#   SNAP=DVP 老 ECC 精简版(AHOST/DATUM/UNAME/UZEIT/XHOLD…,无 XCPID/程序名)→ 只做计数+用户聚合
#   VBMOD(VBKEY/VBFUNC/VBMODE/VBRC)失败模块直接 WHERE VBRC<>'0';VBHDR 近2天活跃(VBSTATE 分布)
#   TBTCO(STATUS/STRTDATE/STRTTIME/ENDDATE/ENDTIME)终态=F/A 无 S(09-15 RUN2 实证)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')   # v15 整合:Invoke-FacadeTool/拍平/Get-QueryRows 收敛到共享件(顶部幂等 dot-source _sap-facade)

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

function Get-QueryResp {
  # sap_query → 完整返回(rowCount=引擎全量匹配数,rows=受 maxRows 限制)。diagpack 特有:
  # SNAP 计数要 rowCount,shared Get-QueryRows 只回 rows 不够用。
  param([string]$System, [string]$Table, [string]$Where, [int]$MaxRows = 200)
  $q = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $System; table = $Table; where = $Where; maxRows = $MaxRows }
  if (-not $q.ok) {
    $ex = New-Object System.Exception ("{0}: {1}" -f $q.error.code, $q.error.message)
    $ex.Data['FacadeCode'] = [string]$q.error.code
    $ex.Data['FacadeMessage'] = [string]$q.error.message
    throw $ex
  }
  return $q.data
}

# ============ 入参 ============
$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$system = ([string]$input_.system).Trim().ToUpper()
if ($system -notin @('DVP', 'QAS', 'PRD')) { return (Fail 'BAD_SYSTEM' "system 必须是 DVP/QAS/PRD,收到: '$system'") }
Initialize-SapRoute | Out-Null   # v15:facade 死了 WMI 拉起(原无自愈,会三节全 NA 假装体检完)

# ============ action=digest(2026-09-17 v16.2:周报/月报末行「体检摘要」轻量入口) ============
# 三次轻查询只取计数,口径与下方主体完全一致;负载周报按需调用,不强制每次体检跑全量。
if (([string]($input_.action)).Trim() -eq 'digest') {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $dg = Get-SapHealthDigest -System $system
  return @{ ok = $true; result = [ordered]@{
    system = $system; digest = $dg
    generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); durMs = $sw.ElapsedMilliseconds
  } }
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$today = (Get-Date).ToString('yyyyMMdd')
$d2 = (Get-Date).AddDays(-2).ToString('yyyyMMdd')
$d7 = (Get-Date).AddDays(-7).ToString('yyyyMMdd')
# ============ 体检结果短 TTL 缓存(2026-09-21 审查定案,用户批):10 分钟,refresh:true 跳过 ============
# PRD 的 VBMOD 无索引全扫 ~83s,重复体检每次全价(整份 ~1.5 分钟);TTL 内重复点=毫秒级。
# 巡检语义下结论滞后 ≤10 分钟可接受;实时要求高的场景走前端「↻强刷」(refresh:true)。
# digest 轻入口不在此列(上方已 early-return,自带 4h 缓存)。
$refresh = ($input_.refresh -eq $true -or $input_.refresh -eq 'true')
$cachePath = Join-Path $global:SapProbeCacheDir ("health-pack-" + $system + ".json")
if (-not $refresh) {
  $cached = Get-SapCacheMap -Path $cachePath -TtlDays 0.006944   # 10 分钟
  if ($cached -and $cached['result']) {
    $r0 = $cached['result']
    $r0['fromCache'] = $true
    return @{ ok = $true; result = $r0 }
  }
}

$checks = New-Object System.Collections.Generic.List[object]

# ============ 1. ST22(SNAP 近7天) ============
# 注(09-16 实爆):SNAP 行含 dump 原文(FLIST*)控制字符,Q3 手拼 JSON 大行数必炸(198KB 处 parse 失败)。
# 对策:总数/逐日计数用 rowCount(引擎全量匹配数,maxRows=1 即精确);用户聚合只用 100 条样本并如实标注。
$t1 = $sw.ElapsedMilliseconds
try {
  $resp = Get-QueryResp -System $system -Table 'SNAP' -Where "DATUM >= '$d7'" -MaxRows 1
  $snapTotal = [int]($resp.rowCount)
  $dayRows = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt 7; $i++) {
    $d = (Get-Date).AddDays(-6 + $i).ToString('yyyyMMdd')
    try {
      $cnt = [int]((Get-QueryResp -System $system -Table 'SNAP' -Where "DATUM = '$d'" -MaxRows 1).rowCount)
      if ($cnt -gt 0) {
        [void]$dayRows.Add([ordered]@{ '日期' = ("{0}-{1}-{2}" -f $d.Substring(0, 4), $d.Substring(4, 2), $d.Substring(6, 2)); 'DUMP 数' = $cnt })
      }
    } catch { }   # 单日查询失败跳过,不影响整体
  }
  $usersTxt = '-'
  try {
    $samp = @(ConvertTo-MutHashTable (Get-QueryResp -System $system -Table 'SNAP' -Where "DATUM >= '$d7'" -MaxRows 100).rows)
    $byUser = @{}
    foreach ($r in $samp) { $u = "$($r.UNAME)".ToUpper(); if (-not $byUser.ContainsKey($u)) { $byUser[$u] = 0 }; $byUser[$u]++ }
    $u = (@($byUser.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ', ')
    if ($u) { $usersTxt = $u }
  } catch { $usersTxt = '-' }   # 样本里撞控制字符 → 不聚合,如实标
  $st = 'OK'; if ($snapTotal -ge 1) { $st = 'WARN' }
  if ($snapTotal -ge 100) { $st = 'CRIT' }
  $checks.Add(@{
    id = 'st22'; title = 'ST22 短 dump(SNAP 近 7 天)'; status = $st
    summary = ("{0} 个 dump;样本活跃用户:{1}" -f $snapTotal, $usersTxt)
    note = '计数=引擎全量匹配数(逐日精确);用户聚合仅前 100 条样本;SNAP 行含 dump 原文控制字符,不宜整表拉取;明细看 ST22。'
    cols = @('日期', 'DUMP 数'); rows = $dayRows.ToArray(); truncated = ($snapTotal -gt 100); ms = ($sw.ElapsedMilliseconds - $t1)
  })
} catch {
  $code = 'READ_FAILED'; if ($_.Exception.Data['FacadeCode']) { $code = $_.Exception.Data['FacadeCode'] }
  $why = ("{0}: {1}" -f $code, $_.Exception.Message)
  if ($why -match 'JSON') { $why += '(SNAP 行含 dump 原文控制字符,Q3 JSON 串行化无法承载,待 ZLILY 字段裁剪支持;明细请直接看 ST22)' }
  $checks.Add(@{ id = 'st22'; title = 'ST22 短 dump(SNAP 近 7 天)'; status = 'NA'; summary = '读不到'; note = $why; cols = @(); rows = @(); truncated = $false; ms = ($sw.ElapsedMilliseconds - $t1) })
}

# ============ 2. SM13(VBMOD 失败模块 + VBHDR 近2天) ============
$t2 = $sw.ElapsedMilliseconds
try {
  $failed = @(Get-QueryRows -System $system -Table 'VBMOD' -Where "VBRC <> '0'" -MaxRows 100)
  $hdr = @(Get-QueryRows -System $system -Table 'VBHDR' -Where "VBDATE >= '$d2'" -MaxRows 300)
  $stateDist = @{}
  foreach ($h in $hdr) { $s = "$($h.VBSTATE)"; if (-not $stateDist.ContainsKey($s)) { $stateDist[$s] = 0 }; $stateDist[$s]++ }
  $distTxt = (@($stateDist.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "VBSTATE $($_.Key)=$($_.Value)" }) -join ', ')
  $failRows = @($failed | Select-Object -First 20 | ForEach-Object {
    [ordered]@{ '更新键' = "$($_.VBKEY)"; '模块' = "$($_.VBFUNC)"; 'VBRC' = "$($_.VBRC)" }
  })
  $st = 'OK'; if ($failed.Count -ge 1) { $st = 'CRIT' }
  $checks.Add(@{
    id = 'sm13'; title = 'SM13 更新请求失败(VBMOD/VBHDR)'; status = $st
    summary = ("失败/挂起模块 {0} 个;近 2 天更新请求 {1} 个($distTxt)" -f $failed.Count, $hdr.Count)
    note = 'VBRC<>0 的更新模块停留在 SM13 待处理,会阻塞相关业务更新;VBMOD 无日期字段,失败项以现存量为准。'
    cols = @('更新键', '模块', 'VBRC'); rows = $failRows; truncated = ($failed.Count -ge 100); ms = ($sw.ElapsedMilliseconds - $t2)
  })
} catch {
  $code = 'READ_FAILED'; if ($_.Exception.Data['FacadeCode']) { $code = $_.Exception.Data['FacadeCode'] }
  $checks.Add(@{ id = 'sm13'; title = 'SM13 更新请求失败(VBMOD/VBHDR)'; status = 'NA'; summary = '读不到'; note = ("{0}: {1}" -f $code, $_.Exception.Message); cols = @(); rows = @(); truncated = $false; ms = ($sw.ElapsedMilliseconds - $t2) })
}

# ============ 3. 后台作业(TBTCO 取消 + 卡死) ============
$t3 = $sw.ElapsedMilliseconds
try {
  $canceled = @(Get-QueryRows -System $system -Table 'TBTCO' -Where "STATUS = 'A' AND ENDDATE >= '$d7'" -MaxRows 100)
  $running = @(Get-QueryRows -System $system -Table 'TBTCO' -Where "STATUS = 'R'" -MaxRows 200)
  # 空开始日期不计入卡死/跨天(""-le 任何日期恒真,刚释放还没排上的作业会被误判卡死——09-16 审查实爆)
  $stuck = @($running | Where-Object { $sd = "$($_.STRTDATE)"; $sd -and ($sd -le $d2) })    # 开始于前天或更早还在跑=卡死嫌疑
  $long = @($running | Where-Object { $sd = "$($_.STRTDATE)"; $sd -and ($sd -lt $today) -and ($sd -gt $d2) })
  $jobRow = {
    param($j, $tag)
    [ordered]@{ '作业名' = "$($j.JOBNAME)"; '编号' = "$($j.JOBCOUNT)"; '判定' = $tag
      '开始日期' = "$($j.STRTDATE)"; '服务器' = "$($j.REAXSERVER)" }
  }
  $rows3 = @()
  foreach ($j in $stuck) { $rows3 += ,(& $jobRow $j '⚠运行超2天') }
  foreach ($j in $long) { $rows3 += ,(& $jobRow $j '·跨天运行') }
  foreach ($j in @($canceled | Select-Object -First 15)) { $rows3 += ,(& $jobRow $j '✗近7天取消') }
  $st = 'OK'
  if ($stuck.Count -ge 1) { $st = 'CRIT' }
  elseif ($long.Count -ge 1 -or $canceled.Count -ge 1) { $st = 'WARN' }
  $checks.Add(@{
    id = 'jobs'; title = '后台作业(TBTCO 取消/卡死)'; status = $st
    summary = ("运行中 {0} 个(跨天 {1},超 2 天 {2});近 7 天取消 {3} 个" -f $running.Count, $long.Count, $stuck.Count, $canceled.Count)
    note = '运行超 2 天的作业大概率死锁或挂死(SM37 看日志后决定是否 TBTCO 硬停);取消作业看 Job log 定位。'
    cols = @('作业名', '编号', '判定', '开始日期', '服务器'); rows = $rows3; truncated = ($canceled.Count -ge 100 -or $running.Count -ge 200); ms = ($sw.ElapsedMilliseconds - $t3)
  })
} catch {
  $code = 'READ_FAILED'; if ($_.Exception.Data['FacadeCode']) { $code = $_.Exception.Data['FacadeCode'] }
  $checks.Add(@{ id = 'jobs'; title = '后台作业(TBTCO 取消/卡死)'; status = 'NA'; summary = '读不到'; note = ("{0}: {1}" -f $code, $_.Exception.Message); cols = @(); rows = @(); truncated = $false; ms = ($sw.ElapsedMilliseconds - $t3) })
}

# ============ 4. SM12(ENQUEUE_READ 锁条目;RFC 内存读零 DB,与 SM12 画面同源) ============
$t4 = $sw.ElapsedMilliseconds
try {
  # GUNAME 传空=全用户(FM 默认 SY-UNAME 只看自己);字段经 PRD 实测:GNAME=锁表/GARG=锁键/GUNAME=持锁人/GTCODE=来源事务码/GTDATE+GTTIME=锁定时刻
  $ex = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args @{ system = $system; function = 'ENQUEUE_READ'; import = @{ GUNAME = '' } }
  if (-not $ex.ok) {
    $exn = New-Object System.Exception ("{0}: {1}" -f $ex.error.code, $ex.error.message)
    $exn.Data['FacadeCode'] = [string]$ex.error.code
    throw $exn
  }
  $p = $ex.data; if ($p -and $p.result) { $p = $p.result }
  $enq = @($p.ENQ | Where-Object { $null -ne $_ })   # 键缺失/空表都归零,防 @($null) 假 1 把锁
  $modeTxt = @{ E = '排他'; X = '排他不累积'; S = '共享' }
  $now = Get-Date
  $lockRow = {
    param($e)
    $age = '-'
    try {
      $ts = [datetime]::ParseExact(("$($e.GTDATE) $($e.GTTIME)").Trim(), 'yyyy-MM-dd HH:mm:ss', $null)
      $age = ('{0:N0} 分' -f ($now - $ts).TotalMinutes)
    } catch { }
    [ordered]@{ '锁表' = "$($e.GNAME)"; '锁键' = "$($e.GARG)"; '模式' = $modeTxt["$($e.GMODE)"]; '用户' = "$($e.GUNAME)"
      '事务码' = "$($e.GTCODE)"; '锁定于' = ("{0} {1}" -f "$($e.GTDATE)", "$($e.GTTIME)"); '已持有' = $age }
  }
  $stale = @($enq | Where-Object { "$($_.GTDATE)" -and "$($_.GTDATE)" -lt $now.ToString('yyyy-MM-dd') })   # 跨天仍持有=会话异常残留
  $rows4 = @($stale | Select-Object -First 10 | ForEach-Object { ,(& $lockRow $_) })
  $byTab = @{}
  foreach ($e in $enq) { $t = "$($e.GNAME)"; if (-not $byTab.ContainsKey($t)) { $byTab[$t] = 0 }; $byTab[$t]++ }
  $topTxt = (@($byTab.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key)($($_.Value))" }) -join ', ')
  if (-not $topTxt) { $topTxt = '-' }
  $st = 'OK'; if ($stale.Count -ge 1) { $st = 'WARN' }
  $checks.Add(@{
    id = 'locks'; title = 'SM12 当前锁(ENQUEUE_READ)'; status = $st
    summary = ("当前锁 {0} 个(表 top:{1});跨天未释放 {2} 个" -f $enq.Count, $topTxt, $stale.Count)
    note = '数据=ENQUEUE_READ(RFC 内存读,毫秒级零 DB,与 SM12 画面同源);GUNAME 传空=全用户;跨天仍持有的锁多为会话异常残留,找持锁人确认后 SM12 删除;模式 E=排他 S=共享。'
    cols = @('锁表', '锁键', '模式', '用户', '事务码', '锁定于', '已持有'); rows = $rows4; truncated = ($enq.Count -gt 10); ms = ($sw.ElapsedMilliseconds - $t4)
  })
} catch {
  $code = 'READ_FAILED'; if ($_.Exception.Data['FacadeCode']) { $code = $_.Exception.Data['FacadeCode'] }
  $checks.Add(@{ id = 'locks'; title = 'SM12 当前锁(ENQUEUE_READ)'; status = 'NA'; summary = '读不到'; note = ("{0}: {1}(若 FM 未放行:ENQUEUE_READ 加进 systems.json qasGetWhitelist 后重启 facade)" -f $code, $_.Exception.Message); cols = @(); rows = @(); truncated = $false; ms = ($sw.ElapsedMilliseconds - $t4) })
}

# ============ 汇总 ============
$rank = @{ OK = 0; WARN = 1; CRIT = 2 }
$overall = 'OK'
foreach ($c in $checks) { if ($c.status -in @('WARN', 'CRIT') -and $rank[$c.status] -gt $rank[$overall]) { $overall = $c.status } }
$overallText = @{ OK = '健康'; WARN = '需关注'; CRIT = '有问题' }[$overall]

$resultOut = [ordered]@{
  system = $system; overall = $overall; overallText = $overallText
  checks = $checks.ToArray(); generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  durMs = $sw.ElapsedMilliseconds
}
try { Save-SapCacheMap -Path $cachePath -Map @{ result = $resultOut } } catch {}   # 10 分钟短缓存
return @{ ok = $true; result = $resultOut }
