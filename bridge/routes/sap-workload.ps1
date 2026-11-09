param([Parameter(Mandatory)][hashtable]$Body)

# sap-workload  -  📈 负载周报/月报 V2 分析版(2026-09-17;v16 单周报 + v16.2 降级修复演进)。
# 【定位】给模块顾问/运维看的周期负载报告:系统忙不忙/反应快不快/资源大头在哪/和上期比变了什么
#   → 确定性分析(数字全由代码算,结论可解释)+ AI 只做解读建议(禁 Basis 行话,大白话)。
# 数据源(TFDIR FMODE=R 实锤,零 SAP 部署;SWNC_/SAPWL_ 已在脱敏层豁免→TOP 用户真名):
#   SAPWL_WORKLOAD_GET_SUMMARY —— PERIODTYPE 'D'(日)/'W'(周)/'M'(月);返回 SAPWLSUMRY
#     =人话 TASKTYPE+毫秒。周汇总 'W'×1 / 月汇总 'M'×1 / 周报趋势 'D'×7(轻)。
#   SWNC_GET_WORKLOAD_STATISTIC —— 只取 USERTCODE/USERWORKLOAD 两键做 TOP 榜+活跃用户;
#     时间字段=微秒,均值 /1000。
#   SWNC_GET_WORKLOAD_DIRECTORY —— 降级时取该实例统计目录最新记录日(dirLatest),让「为什么
#     没数据」有数字可答(DVP/QAS 实测=2023-02 拷贝件)。
# 周期口径:granularity week/month × mode last(上一完整周期,默认)/this(本期至今);
#   currentStart/baselineStart(yyyyMMdd)显式给定时按自选对比。月报趋势=月内各周 'W'(跨月周
#   如实标注;逐日 30+ 次真查会撞 bridge 120s,月粒度趋势周分段信息量足够)。
# 对比:compare 指标阈值 |Δ|≥30% 显著(响应类升高=恶化,步数类中性「更忙/回落」);
#   TOP 榜 new/dropped/surge(步数>1000 防小基数爆炸)。
# 体检摘要:digest action(Get-SapHealthDigest,与 🩺体检同口径)→ SM13 失败/ST22 dump/取消作业。
# 缓存 workload-p-<SYS>.json:key=p-<D|W|M>-<startyyyyMMdd>;含今天 30 分钟 TTL,历史永久。
#   周报逐日趋势沿用 workload-d-<SYS>.json(历史天永久)。周聚合过期重拉。
# action: run(数据+对比+四问+体检摘要)/ comment(AI 解读建议 V2)/ mail(Outlook 存草稿,绝不自动发送)。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')
. (Join-Path $PSScriptRoot '_claude-helpers.ps1')   # comment 动作:Invoke-SapAi 依赖 Invoke-KbClaude

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

# ---------- 入参 ----------
$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$action = ([string]($input_.action)).Trim(); if (-not $action) { $action = 'run' }
# ★mail 分支必须在 system 校验之前:前端发邮件不带 system,放在校验后必被 BAD_SYSTEM 拒
#   (2026-09-17 用户「存草稿失败」真因——mail 请求根本没走到 Outlook)。
if ($action -eq 'mail') {
  $to = ([string]($input_.to)).Trim()
  $subject = ([string]($input_.subject)).Trim(); if (-not $subject) { $subject = 'SAP 负载报告' }
  $html = [string]($input_.html)
  if (-not $html) { return (Fail 'BAD_INPUT' 'html required(先跑一轮,前端把导出 HTML 传入)') }
  if ($html.Length -gt 900000) { return (Fail 'BAD_INPUT' "html 过大($($html.Length) 字符),请精简后再发") }
  $attB64 = [string]($input_.attachBase64)
  $attName = ([string]($input_.attachName)).Trim(); if ($attName) { $attName = $attName -replace '[\\/:*?"<>|]', '_' }
  if ($attB64.Length -gt 28000000) { return (Fail 'BAD_INPUT' "附件过大(base64 $($attB64.Length) 字符)") }
  $tmp = $null
  try {
    $ol = New-Object -ComObject Outlook.Application
    $mail = $ol.CreateItem(0)
    if ($to) { $mail.To = $to }
    $mail.Subject = $subject
    $mail.HTMLBody = $html
    if ($attB64) {
      if (-not $attName) { $attName = '负载报告明细.xlsx' }
      $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "pw-wl-$([guid]::NewGuid().ToString('N').Substring(0,8))-$attName"
      [System.IO.File]::WriteAllBytes($tmp, [Convert]::FromBase64String($attB64))
      [void]$mail.Attachments.Add($tmp)
    }
    $mail.Save()
    return @{ ok = $true; result = [ordered]@{
      saved = $true; folder = 'Outlook 草稿箱'; subject = $subject
      to = $(if ($to) { $to } else { '(空,请在草稿箱补收件人)' })
      attachment = $(if ($attB64) { $attName } else { $null })
      generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } }
  } catch {
    return (Fail 'MAIL_FAILED' "Outlook 草稿创建失败:$($_.Exception.Message)(需本机安装并登录 Outlook)")
  } finally {
    if ($tmp -and (Test-Path $tmp)) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  }
}
# ============ action=comment(AI 解读 V2:只解读不算数,禁 Basis 行话,大白话) ============
if ($action -eq 'comment') {
  $res = $input_.res
  if (-not $res) { return (Fail 'BAD_INPUT' 'res required(先跑一轮拿结果)') }
  $o = ConvertTo-MutHashTable $res
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add("SAP 系统 $($o['system']) 负载报告(周期:$($o['cur']['label']))")
  $L.Add('')
  $L.Add('【确定性分析(数字已核实,直接引用即可,禁止改写/新造数字)】')
  foreach ($k in @('busy', 'fast', 'where', 'changes')) { $L.Add("- $($o['plain'][$k])") }
  $L.Add('')
  $L.Add('每日/每周趋势(时段|总步数|在线操作步数|平均响应ms|后台|RFC|更新):')
  foreach ($d in @($o['curData']['trend'])) { $L.Add("$($d['label']) | $($d['totalSteps']) | $($d['dialogSteps']) | $($d['dialogAvgMs']) | $($d['batchSteps']) | $($d['rfcSteps']) | $($d['updateSteps'])") }
  $L.Add('')
  if ($o['compare'] -and @($o['compare']['notes']).Count -ge 1) {
    $L.Add('环比显著变化:')
    foreach ($n in @($o['compare']['notes'])) { $L.Add("- $n") }
    $L.Add('')
  }
  if ($o['digest']) {
    $dg = $o['digest']
    $L.Add(("体检摘要:近 7 天程序崩溃 {0} 次;更新处理失败积压 {1} 项;近 7 天被取消的后台作业 {2} 个。" -f $dg['st22Dumps'], $dg['sm13Failed'], $dg['jobsCanceled']))
    $L.Add('')
  }
  $L.Add('任务类型明细(类型|步数|平均响应ms):')
  foreach ($t in @($o['curData']['tasktypes'])) { $L.Add("$($t['type'])/$($t['name']) | $($t['steps']) | $($t['avgMs'])") }

  $sysPrompt = '你是面向 SAP 模块顾问(懂业务、不懂数据库和系统内部)的运维解读助手。基于给定的负载报告数据写 300~450 字中文解读,' +
    '硬性要求:①绝对禁止出现 DIALOG/BCKGRD/RFC/SM13/ST22/VBMOD/SWNC/SAPWL/UPDATE 等系统术语,改说「在线操作/后台作业/接口调用/更新处理/系统崩溃/更新失败」;②只用给定数字,禁止编造或改写;③结构:第一段两句总体结论(忙不忙、快不快),然后「值得注意:」1~3 条(每条带数字、说人话),最后「建议:」1~2 条可执行动作(如找谁确认什么、调整什么作业时间);④语气克制专业,面向业务部门负责人。'
  $ai = Invoke-SapAi -UserPrompt ($L -join "`n") -SystemPrompt $sysPrompt -MaxTokens 1200
  if (-not $ai) { return (Fail 'AI_FAILED' 'AI 解读生成失败(通道/网络/配置),可稍后重试') }
  return @{ ok = $true; result = [ordered]@{ comment = $ai.text; model = $ai.model; generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } }
}

$system = ([string]($input_.system)).Trim().ToUpper()
if ($system -notin @('DVP', 'QAS', 'PRD')) { return (Fail 'BAD_SYSTEM' "system 必须是 DVP/QAS/PRD,收到: '$system'") }
Initialize-SapRoute | Out-Null

$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---------- 实例名自动发现 ----------
# ★实爆(2026-09-16 真链):INSTANCE='total' 在 ECC6 上 NO_DATA_FOUND——total 是 ST03N 动态合计
#   不落盘,SWNC 聚合记录按实例存 COMPONENT='主机_SID_序'(RFC_SYSTEM_INFO 的 RFCDEST 正是它)。
$fmExec = {
  param([string]$Fn, [hashtable]$Imp)
  $r = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args @{ system = $system; function = $Fn; import = $Imp }
  # ★连接级失败幂等重试一次(2026-09-17 PRD 真跑实爆:.NET 复用被服务端关掉的 keepalive 死连接)。
  #   负载查询全只读,重试安全;业务错(NEED_CREDENTIAL/白名单/FM_EXEC_FAILED)绝不重试。
  if (-not $r.ok -and "$($r.error.code)" -in @('FACADE_HTTP_FAILED', 'FACADE_TIMEOUT')) {
    Start-Sleep -Milliseconds 400
    $r = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args @{ system = $system; function = $Fn; import = $Imp }
  }
  if (-not $r.ok) {
    $e = New-Object System.Management.Automation.RuntimeException("$($r.error.code): $($r.error.message)")
    $e.Data['FacadeCode'] = [string]$r.error.code
    throw $e
  }
  # facade 返回双层 result;IRM 产物 PSCustomObject——逐层剥+拍平(嵌套 ['k'] 索引静默 null 实锤)。
  $p = $r.data
  if ($p -is [System.Collections.IDictionary] -and $p.ContainsKey('result') -and $null -ne $p['result']) { $p = $p['result'] }
  return (ConvertTo-FlatHashtable $p)
}

$instance = $null; $discErr = ''
try {
  $info = & $fmExec 'RFC_SYSTEM_INFO' @{}
  if ($info) {
    $c = ConvertTo-FlatHashtable $info['RFCSI_EXPORT']
    if ($c.ContainsKey('RFCDEST') -and $c['RFCDEST']) { $instance = ([string]$c['RFCDEST']).Trim() }
  }
} catch { $instance = $null; $discErr = "$($_.Exception.Message)" }
if (-not $instance) { return (Fail 'INSTANCE_DISCOVERY_FAILED' "无法确定 $system 的实例名(RFC_SYSTEM_INFO 失败:$discErr;负载聚合按实例存,total 不落盘,不能缺省)") }

# ---------- 降级判据(2026-09-17 实爆):fm_exec 失败 FacadeCode 恒=FM_EXEC_FAILED,NO_DATA_FOUND
# 只在 message 文本——必须 code+message 双查,否则无聚合系统整份报告炸红✗而不是优雅降级。 ----------
function Test-NoData($ex) {
  if ("$($ex.Exception.Data['FacadeCode'])" -match 'NO_DATA_FOUND') { return $true }
  return ("$($ex.Exception.Message)" -match 'NO_DATA_FOUND')
}

# ---------- 周期计算 ----------
# week: last=上一完整周一~周日 / this=本周一~今天;month: last=上个自然月 / this=本月至今。
# explicitStart(yyyyMMdd)显式给定时覆盖 start(end 按 granularity 推)。
$now = Get-Date
$granularity = ([string]($input_.granularity)).Trim().ToLower(); if (-not $granularity) { $granularity = 'week' }
if ($granularity -notin @('week', 'month')) { return (Fail 'BAD_INPUT' "granularity 必须是 week/month,收到: '$granularity'") }
$mode = ([string]($input_.mode)).Trim().ToLower(); if (-not $mode) { $mode = 'last' }
if ($mode -notin @('last', 'this')) { return (Fail 'BAD_INPUT' "mode 必须是 last/this,收到: '$mode'") }

function Get-Period([string]$Gran, [string]$Mode, [string]$ExplicitStart) {
  $r = @{ pType = 'W'; isPartial = $false }
  if ($Gran -eq 'month') {
    $r.pType = 'M'
    if ($ExplicitStart) {
      $r.start = [datetime]::ParseExact($ExplicitStart, 'yyyyMMdd', $null)
      $r.start = $r.start.AddDays(1 - $r.start.Day)          # 归到当月 1 号
      $r.end = $r.start.AddMonths(1).AddDays(-1)
    } elseif ($Mode -eq 'this') {
      $r.start = $now.Date.AddDays(1 - $now.Day); $r.end = $now.Date; $r.isPartial = $true
    } else {
      $r.start = $now.Date.AddDays(1 - $now.Day).AddMonths(-1); $r.end = $r.start.AddMonths(1).AddDays(-1)
    }
  } else {
    if ($ExplicitStart) {
      $r.start = [datetime]::ParseExact($ExplicitStart, 'yyyyMMdd', $null)
      $r.start = $r.start.AddDays(-(([int]$r.start.DayOfWeek + 6) % 7))   # 归到该周周一
      $r.end = $r.start.AddDays(6)
    } elseif ($Mode -eq 'this') {
      $monday = $now.Date.AddDays(-([int]$now.DayOfWeek) + 1)
      if ([int]$now.DayOfWeek -eq 0) { $monday = $now.Date.AddDays(-6) }
      $r.start = $monday; $r.end = $now.Date; $r.isPartial = $true
    } else {
      $monday = $now.Date.AddDays(-([int]$now.DayOfWeek) + 1)
      if ([int]$now.DayOfWeek -eq 0) { $monday = $now.Date.AddDays(-6) }
      $r.start = $monday.AddDays(-7); $r.end = $r.start.AddDays(6)
    }
  }
  return $r
}

$cur = Get-Period $granularity $mode ([string]($input_.currentStart)).Trim()
$base = $null
$baseExplicit = ([string]($input_.baselineStart)).Trim()
if ($baseExplicit) {
  $base = Get-Period $granularity 'last' $baseExplicit
} elseif ($mode -eq 'last') {
  # 上一完整周期 vs 再往前一个同长周期(默认环比)
  $base = @{ pType = $cur.pType; isPartial = $false }
  if ($granularity -eq 'month') { $base.start = $cur.start.AddMonths(-1); $base.end = $base.start.AddMonths(1).AddDays(-1) }
  else { $base.start = $cur.start.AddDays(-7); $base.end = $base.start.AddDays(6) }
}
# mode='this' 且未显式给 baseline:对比上一完整周期
if (-not $base -and $mode -eq 'this') {
  $base = Get-Period $granularity 'last' $null
}

$curDays = ([int]($cur.end - $cur.start).TotalDays) + 1
if ($base) { $baseDays = ([int]($base.end - $base.start).TotalDays) + 1 }

# ---------- TOP 榜中文描述/用户中文名(顾问报告可读性;TSTCT 事务码文本/TRDIRT 报表标题/USR21+ADRP 姓名) ----------
# 永久缓存 tcode-text-<SYS>.json / user-name-<SYS>.json:描述与姓名不变,查一次终身用。
# ★entry 榜混四类:真事务码(VA01)/后台作业报表名(RSM13000)/RFC 函数组(SAPL*)/系统内部活动
#   (<NUMBER RANGE BUFFER>/(BATCH))——分类标注让顾问知道「这不是事务码也正常」。
function Get-EntryDesc([string]$Entry) {
  # ENTRY_ID 实测格式=「名称+空格+类型码」:MD04 T(事务码)/RSM13000 R(报表)/<...> R(系统活动)
  # →查表用第一段($base),类型码路由查哪张表(T=TSTCT 事务码文本,R=TRDIRT 报表标题)。
  $e = ("$Entry" -replace '\s+', ' ').Trim()
  if ($script:DescMap.ContainsKey($e)) { return $script:DescMap[$e] }
  $parts = @($e -split '\s+') | Where-Object { $_ }
  $base = if ($parts.Count -ge 1) { $parts[0] } else { $e }
  $code = if ($parts.Count -ge 2) { $parts[-1] } else { '' }
  $r = $null
  try {
    if ($base -match '^[<\(]' -or $e -match '^[<\(]') {
      $zh = @{ '<NUMBER RANGE BUFFER>' = '号段缓冲(系统内部)'; '(BATCH)' = '后台批处理(系统内部)'; '(DIALOG)' = '对话(系统内部)' }
      $r = @{ type = 'sys'; text = $(if ($zh.ContainsKey($base)) { $zh[$base] } else { '系统内部活动' }) }
    } elseif ($base -like 'SAPL*') {
      $r = @{ type = 'rfc'; text = 'RFC 函数调用' }
    } else {
      if ($code -ne 'R') {
        $q = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'TSTCT'; where = "SPRSL = '1' AND TCODE = '$base'"; maxRows = 1 }
        if ($q.ok) {
          $rows = @(ConvertTo-MutHashTable $q.data.rows)
          if ($rows.Count -ge 1 -and "$($rows[0].TTEXT)".Trim()) { $r = @{ type = 'tcode'; text = "$($rows[0].TTEXT)".Trim() } }
        }
      }
      if (-not $r -and $code -ne 'T') {
        $q = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'TRDIRT'; where = "SPRSL = '1' AND NAME = '$base'"; maxRows = 1 }
        if ($q.ok) {
          $rows = @(ConvertTo-MutHashTable $q.data.rows)
          if ($rows.Count -ge 1 -and "$($rows[0].TEXT)".Trim()) {
            $t0 = ("$($rows[0].TEXT)" -replace '\s+', ' ').Trim()
            $r = @{ type = $(if ($base -like 'Z*' -or $base -like 'Y*' -or $base -like 'LZ*' -or $base -like 'LY*') { 'zprog' } else { 'report' }); text = $t0 }
          }
        }
      }
    }
  } catch { $r = $null }   # 查询失败不补描述,不影响榜单
  if (-not $r) { $r = @{ type = 'other'; text = '' } }
  $script:DescMap[$e] = $r
  $script:DescDirty = $true
  return $r
}

function Get-UserCn([string]$Account) {
  $u = "$Account".Trim().ToUpper()
  if (-not $u) { return '' }
  if ($script:NameMap.ContainsKey($u)) { return "$($script:NameMap[$u])" }
  $cn = ''
  try {
    $q = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'USR21'; where = "BNAME = '$u'"; maxRows = 1 }
    if ($q.ok) {
      $rows = @(ConvertTo-MutHashTable $q.data.rows)
      if ($rows.Count -ge 1) {
        $pers = "$($rows[0].PERSNUMBER)".Trim()
        if ($pers) {
          $q2 = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'ADRP'; where = "PERSNUMBER = '$pers'"; maxRows = 1 }
          if ($q2.ok) {
            $rows2 = @(ConvertTo-MutHashTable $q2.data.rows)
            if ($rows2.Count -ge 1) { $cn = ("$($rows2[0].NAME_LAST)$($rows2[0].NAME_FIRST)" -replace '\s+', ' ').Trim() }
          }
        }
      }
    }
  } catch { $cn = '' }
  $script:NameMap[$u] = $cn
  $script:NameDirty = $true
  return $cn
}

# ---------- 基础取数(带缓存) ----------
$cacheDir = $global:SapProbeCacheDir
$cacheP = Join-Path $cacheDir "workload-p-$system.json"
$cacheD = Join-Path $cacheDir "workload-d-$system.json"

# 描述/姓名缓存(顶层初始化,函数体内引用;查表 miss 才标 dirty)
$script:DescMap = Get-SapCacheMap -Path (Join-Path $cacheDir "tcode-text-$system.json")
$script:DescDirty = $false
$script:NameMap = Get-SapCacheMap -Path (Join-Path $cacheDir "user-name-$system.json")
$script:NameDirty = $false

function Get-Summary([string]$PeriodType, [string]$StartDate) {
  $p = & $fmExec 'SAPWL_WORKLOAD_GET_SUMMARY' @{ PERIODTYPE = $PeriodType; HOSTID = ''; STARTDATE = $StartDate; INSTANCE = $instance }
  $rows = @()
  if ($p -is [System.Collections.IDictionary] -and $p.ContainsKey('SUMMARY')) { $rows = @($p['SUMMARY']) }
  # 无逗号(同 Get-QueryRows 09-17 修):,@(数组) 双包成 Object[1]{Object[N]},foreach 只见
  # 1 个内层数组→字段访问空格拼接→计数全零/空天假行;.Count 恒 1→「无数据返回 $null」契约失效。
  return @(ConvertTo-MutHashTable $rows)
}

function Get-SwncTops([string]$PeriodType, [datetime]$Start) {
  $p = & $fmExec 'SWNC_GET_WORKLOAD_STATISTIC' @{ SYSTEMID = $system; INSTANCE = $instance
      PERIODTYPE = $PeriodType; PERIODSTRT = $Start.ToString('yyyyMMdd'); SUMMARY_ONLY = '' }
  $top = @{}
  foreach ($k in @('USERTCODE', 'USERWORKLOAD')) {
    if ($p -is [System.Collections.IDictionary] -and $p.ContainsKey($k)) { $top[$k] = @(ConvertTo-MutHashTable $p[$k]) }
  }
  return $top
}

function Get-TasktypeBucket([string]$TaskType) {
  # TASKTYPE → 桶名单源(2026-09-21 审查 P3:Day/Week/Totals 三份 switch -Wildcard 收拢;
  # 消「Day 有 cpuMs/Week 没有」类单边漂移温床,新增桶只改这里)。未知类型返回 $null。
  $tt = "$TaskType".Trim().ToUpper()
  if ($tt -like 'DIALOG*') { return 'dialog' }
  if ($tt -like 'BCKGRD*') { return 'batch' }
  if ($tt -like 'RFC*')    { return 'rfc' }
  if ($tt -like 'UPDATE*') { return 'update' }
  if ($tt -like 'SPOOL*')  { return 'spool' }
  return $null
}

function Get-DayRow([datetime]$day) {
  # 一天的任务类型汇总 → 趋势行。该天全无数据(停机/聚合未生成)返回 $null。
  $rows = Get-Summary 'D' $day.ToString('yyyyMMdd')
  if (-not $rows.Count) { return $null }
  $d = [ordered]@{
    date = $day.ToString('yyyy-MM-dd'); totalSteps = [double]0
    dialogSteps = [double]0; dialogAvgMs = 0.0; dialogCpuMs = 0.0
    batchSteps = [double]0; rfcSteps = [double]0; updateSteps = [double]0; spoolSteps = [double]0
  }
  $dresp = [double]0; $dcnt = [double]0; $dcpu = [double]0
  foreach ($r0 in $rows) {
    $tt = "$($r0.TASKTYPE)".Trim().ToUpper()
    $cnt = 0.0; try { $cnt = [double]("$($r0.COUNT)") } catch { }
    $respti = 0.0; try { $respti = [double]("$($r0.RESPTI)") } catch { }
    $cputi = 0.0; try { $cputi = [double]("$($r0.CPUTI)") } catch { }
    $d.totalSteps += $cnt
    switch (Get-TasktypeBucket $tt) {
      'dialog' { $d.dialogSteps += $cnt; $dresp += $respti; $dcnt += $cnt; $dcpu += $cputi }
      'batch' { $d.batchSteps += $cnt }
      'rfc' { $d.rfcSteps += $cnt }
      'update' { $d.updateSteps += $cnt }
      'spool' { $d.spoolSteps += $cnt }
    }
  }
  if ($dcnt -gt 0) { $d.dialogAvgMs = [math]::Round($dresp / $dcnt, 0); $d.dialogCpuMs = [math]::Round($dcpu / $dcnt, 0) }
  return $d
}

function Get-WeekRow([datetime]$ws) {
  # 一周的任务类型汇总(SAPWLSUMRY 'W',轻)→ 月报趋势行。无数据返回 $null。
  $rows = Get-Summary 'W' $ws.ToString('yyyyMMdd')
  if (-not $rows.Count) { return $null }
  $w = [ordered]@{
    date = $ws.ToString('yyyy-MM-dd'); totalSteps = [double]0
    dialogSteps = [double]0; dialogAvgMs = 0.0
    batchSteps = [double]0; rfcSteps = [double]0; updateSteps = [double]0; spoolSteps = [double]0
  }
  $dresp = [double]0; $dcnt = [double]0
  foreach ($r0 in $rows) {
    $tt = "$($r0.TASKTYPE)".Trim().ToUpper()
    $cnt = 0.0; try { $cnt = [double]("$($r0.COUNT)") } catch { }
    $respti = 0.0; try { $respti = [double]("$($r0.RESPTI)") } catch { }
    $w.totalSteps += $cnt
    switch (Get-TasktypeBucket $tt) {
      'dialog' { $w.dialogSteps += $cnt; $dresp += $respti; $dcnt += $cnt }
      'batch' { $w.batchSteps += $cnt }
      'rfc' { $w.rfcSteps += $cnt }
      'update' { $w.updateSteps += $cnt }
      'spool' { $w.spoolSteps += $cnt }
    }
  }
  if ($dcnt -gt 0) { $w.dialogAvgMs = [math]::Round($dresp / $dcnt, 0) }
  return $w
}

# ★口径裁定(2026-09-16 PRD 真链实爆):TASKTYPE 行 CNT001-009 响应分布在 SWNC 转换层语义不可信
#   (<1s=4.7%/<2s=1.7% 倒挂)——不做响应分布,宁缺毋假。

function Get-PeriodSummary($Period) {
  # 汇总('W'/'M'×1)+ SWNC TOP 榜 + 趋势(周报=逐日 'D'×N,月报=月内各周 'W');全部过缓存。
  # 含今天的周期 30 分钟 TTL;历史完整周期永久。NO_DATA_FOUND → periodMissing 降级,绝不炸。
  $pType = $Period.pType
  $key = "p-$pType-$($Period.start.ToString('yyyyMMdd'))"
  $containsToday = ($Period.start.Date -le $now.Date -and $Period.end.Date -ge $now.Date)
  $map = Get-SapCacheMap -Path $cacheP
  if ($map.ContainsKey($key)) {
    $v = $map[$key]
    $fresh = $true
    if ($containsToday) {
      try { if (((Get-Date) - [datetime]$v['fetchedAt']).TotalMinutes -ge 30) { $fresh = $false } } catch { $fresh = $false }
    }
    if ($fresh) {
      # ★缓存往返形状自愈(2026-09-17 实爆):空数组曾被坏序列化写成 {},读回变 hashtable——
      #   不修正会自续污染(@[hashtable] 变单元素数组再写回)。数组字段非数组(含 hashtable)一律归零;
      #   只影响「空态」(非空数组从不漂移),数据零损失。
      foreach ($k in @('tasktypes', 'topEntry', 'topUser', 'trend', 'trendMissing')) {
        if ($v[$k] -isnot [System.Collections.IEnumerable] -or $v[$k] -is [string] -or $v[$k] -is [System.Collections.IDictionary]) { $v[$k] = @() }
      }
      return @{ data = $v; cached = $true }
    }
  }

  $missing = $false
  $tt = @(); $tops = @{ USERTCODE = @(); USERWORKLOAD = @() }
  try {
    $tt = Get-Summary $pType $Period.start.ToString('yyyyMMdd')
    $tops = Get-SwncTops $pType $Period.start
  } catch {
    if (Test-NoData $_) { $missing = $true }
    else { throw }
  }

  $dirLatest = ''
  if ($missing) {
    # 降级附目录实况:该实例统计目录最新记录日。目录失败静默——降级链绝不二次炸。
    try {
      $d = & $fmExec 'SWNC_GET_WORKLOAD_DIRECTORY' @{}
      $rowsD = @()
      if ($d -is [System.Collections.IDictionary] -and $d.ContainsKey('WORKLOAD_DIRECTORY')) { $rowsD = @($d['WORKLOAD_DIRECTORY']) }
      $mine = @($rowsD | Where-Object { $_ -and ("$($_.COMPONENT)".Trim()) -eq $instance })
      if ($mine.Count) { $dirLatest = ([string]($mine | Measure-Object -Property PERIODSTRT -Maximum).Maximum) }
      elseif ($rowsD.Count) { $dirLatest = ([string]($rowsD | Measure-Object -Property PERIODSTRT -Maximum).Maximum) }
    } catch { }
  }

  # 任务类型行(全类型如实,步数降序)
  $zh = @{ DIALOG = '对话'; UPDATE = '更新'; UPDATE2 = '更新(2)'; BCKGRD = '后台作业'; RFC = 'RFC 调用'
           SPOOL = '打印'; 'BUF.SYN' = '缓冲区同步'; AUTOABA = '自动 ABAP'; ALE = 'ALE/A PC' }
  $ttRows = @()
  foreach ($r0 in $tt) {
    $name = "$($r0.TASKTYPE)".Trim().ToUpper()
    if (-not $name) { continue }
    $cnt = 0.0; try { $cnt = [double]("$($r0.COUNT)") } catch { }
    $respti = 0.0; try { $respti = [double]("$($r0.RESPTI)") } catch { }
    $cputi = 0.0; try { $cputi = [double]("$($r0.CPUTI)") } catch { }
    $avg = 0.0; if ($cnt -gt 0) { $avg = [math]::Round($respti / $cnt, 0) }
    $ttRows += ,@{ type = $name; name = $zh[$name]; steps = $cnt; avgMs = $avg; cpuTotalMs = [math]::Round($cputi, 0) }
  }
  $ttRows = @($ttRows | Sort-Object { $_.steps } -Descending)

  # TOP 事务码/报表(ENTRY_ID 聚合;微秒→ms)+ 活跃账号
  $agg = @{}
  foreach ($r0 in $tops['USERTCODE']) {
    $e = ("$($r0.ENTRY_ID)" -replace '\s+', ' ').Trim()   # ENTRY_ID 定长字段带 padding,压缩内部空白(Trim 只去首尾)
    if (-not $e) { continue }
    if (-not $agg.ContainsKey($e)) { $agg[$e] = @{ steps = [double]0; respti = [double]0; cputi = [double]0; users = @{} } }
    $a = $agg[$e]
    $c = 0.0; try { $c = [double]("$($r0.COUNT)") } catch { }
    $a.steps += $c
    try { $a.respti += [double]("$($r0.RESPTI)") } catch { }
    try { $a.cputi += [double]("$($r0.CPUTI)") } catch { }
    $u = "$($r0.ACCOUNT)".Trim().ToUpper(); if ($u) { $a.users[$u] = $true }
  }
  $topEntry = @($agg.GetEnumerator() | ForEach-Object {
    $a = $_.Value
    @{ entry = $_.Key; users = $a.users.Count; steps = $a.steps
       avgMs = $(if ($a.steps -gt 0) { [math]::Round($a.respti / $a.steps / 1000.0, 0) } else { 0 }) }
  } | Sort-Object { $_.steps } -Descending | Select-Object -First 15)

  $aggU = @{}
  foreach ($r0 in $tops['USERWORKLOAD']) {
    $u = "$($r0.USERNAME)".Trim().ToUpper()
    if (-not $u) { $u = "$($r0.ACCOUNT)".Trim().ToUpper() }
    if (-not $u) { continue }
    if (-not $aggU.ContainsKey($u)) { $aggU[$u] = @{ steps = [double]0; respti = [double]0; cputi = [double]0 } }
    $a = $aggU[$u]
    $c = 0.0; try { $c = [double]("$($r0.COUNT)") } catch { }
    $a.steps += $c
    try { $a.respti += [double]("$($r0.RESPTI)") } catch { }
    try { $a.cputi += [double]("$($r0.CPUTI)") } catch { }
  }
  $topUser = @($aggU.GetEnumerator() | ForEach-Object {
    $a = $_.Value
    @{ user = $_.Key; steps = $a.steps
       avgMs = $(if ($a.steps -gt 0) { [math]::Round($a.respti / $a.steps / 1000.0, 0) } else { 0 })
       cpuS = [math]::Round($a.cputi / 1000000.0, 1) }
  } | Sort-Object { $_.steps } -Descending | Select-Object -First 10)
  $activeUsers = $aggU.Count

  # 趋势:周报=逐日 'D'(历史天永久缓存);月报=月内各周 'W'(跨月周如实标注)
  $trend = @(); $trendMissing = @(); $dirtyD = $false
  if ($pType -eq 'W') {
    $mapD = Get-SapCacheMap -Path $cacheD
    for ($i = 0; $i -lt $curDays; $i++) {
      $day = $Period.start.AddDays($i)
      $dkey = "d-$($day.ToString('yyyyMMdd'))"
      $row = $null
      if ($day.Date -lt $now.Date -and $mapD.ContainsKey($dkey)) {
        $row = $mapD[$dkey]
      } else {
        try {
          $row = Get-DayRow $day
          if ($null -eq $row) { $trendMissing += $day.ToString('yyyy-MM-dd') }
          elseif ($day.Date -lt $now.Date) { $mapD[$dkey] = $row; $dirtyD = $true }
        } catch {
          if (Test-NoData $_) { $trendMissing += $day.ToString('yyyy-MM-dd') } else { throw }
        }
      }
      if ($row) {
        $row['label'] = ('{0} 周{1}' -f $day.ToString('MM-dd'), '日一二三四五六'[[int]$day.DayOfWeek])
        $trend += ,($row)
      }
    }
    if ($dirtyD) { Save-SapCacheMap -Path $cacheD -Map $mapD }
  } else {
    # 月内各周:从月初所在周的周一枚举,与月相交的周都查;跨月周如实标含邻月数据
    $ws = $Period.start.Date.AddDays(-(([int]$Period.start.DayOfWeek + 6) % 7))   # 月初所在周周一
    while ($ws -le $Period.end.Date) {
      $row = $null
      try { $row = Get-WeekRow $ws } catch { if (Test-NoData $_) { $row = $null } else { throw } }
      if ($row) {
        $we = $ws.AddDays(6)
        $cross = ($ws -lt $Period.start.Date) -or ($we -gt $Period.end.Date)
        $row['label'] = ("{0}~{1} 周" -f $ws.ToString('MM-dd'), $we.ToString('MM-dd'))
        $row['crossMonth'] = [bool]$cross
        $trend += ,($row)
      }
      $ws = $ws.AddDays(7)
    }
  }

  # ★出口数组全部 @() 重建实例(PS 5.1 ConvertTo-Json 对部分空数组实例漂移写成 {}:重建是
  #   实测有效的缓解;即使仍偶发,读路径归一化已兜住,UI 与 API 均稳)
  $data = @{ tasktypes = @($ttRows); topEntry = @($topEntry); topUser = @($topUser); activeUsers = $activeUsers
             trend = @($trend); trendMissing = @($trendMissing); periodMissing = $missing; dirLatest = $dirLatest
             fetchedAt = (Get-Date).ToString('o') }
  $map[$key] = $data
  Save-SapCacheMap -Path $cacheP -Map $map
  return @{ data = $data; cached = $false }
}

$curSum = Get-PeriodSummary $cur
$baseSum = $null
if ($base) { $baseSum = Get-PeriodSummary $base }

# ---------- 汇总量(totals)+ health ----------
function Get-Totals($Sum, $Period) {
  $ttRows = @($Sum.data.tasktypes)
  $t = [ordered]@{ totalSteps = [double]0; dialogSteps = [double]0; dialogAvgMs = 0.0
                   batchSteps = [double]0; batchAvgMs = 0.0; rfcSteps = [double]0; updateSteps = [double]0
                   spoolSteps = [double]0; activeUsers = [int]$Sum.data.activeUsers }
  $resp = [double]0; $cnt = [double]0; $bresp = [double]0; $bcnt = [double]0
  foreach ($r0 in $ttRows) {
    $t.totalSteps += [double]$r0.steps
    switch (Get-TasktypeBucket "$($r0.type)") {
      'dialog' { $t.dialogSteps = [double]$r0.steps; $resp = [double]$r0.steps * [double]$r0.avgMs; $cnt = [double]$r0.steps }
      'batch' { $t.batchSteps = [double]$r0.steps; $bresp = [double]$r0.steps * [double]$r0.avgMs; $bcnt = [double]$r0.steps }
      'rfc' { $t.rfcSteps = [double]$r0.steps }
      'update' { $t.updateSteps = [double]$r0.steps }
      'spool' { $t.spoolSteps = [double]$r0.steps }
    }
  }
  if ($cnt -gt 0) { $t.dialogAvgMs = [math]::Round($resp / $cnt, 0) }
  if ($bcnt -gt 0) { $t.batchAvgMs = [math]::Round($bresp / $bcnt, 0) }
  return $t
}

function Get-Health([double]$DialogSteps, [double]$DialogAvgMs) {
  if ($DialogSteps -le 0) { return @{ status = 'NA'; text = '本期无对话负载数据' } }
  if ($DialogAvgMs -le 1000) { return @{ status = 'OK'; text = '响应良好' } }
  if ($DialogAvgMs -le 2000) { return @{ status = 'WARN'; text = '响应偏慢' } }
  return @{ status = 'CRIT'; text = '响应过慢' }
}

$curTotals = Get-Totals $curSum $cur

# ---------- TOP 榜补中文描述/用户中文名(永久缓存,miss 才查表) ----------
foreach ($t in @($curSum.data.topEntry)) {
  $d0 = Get-EntryDesc $t.entry
  $t['desc'] = "$($d0.text)"; $t['etype'] = "$($d0.type)"
}
foreach ($t in @($curSum.data.topUser)) {
  $t['fullName'] = (Get-UserCn $t.user)
}
if ($script:DescDirty) {
  Save-SapCacheMap -Path (Join-Path $cacheDir "tcode-text-$system.json") -Map $script:DescMap
  $script:DescDirty = $false
}
if ($script:NameDirty) {
  Save-SapCacheMap -Path (Join-Path $cacheDir "user-name-$system.json") -Map $script:NameMap
  $script:NameDirty = $false
}
$curHealth = Get-Health $curTotals.dialogSteps $curTotals.dialogAvgMs

# ---------- 确定性环比(compare)+ 大白话显著项 ----------
function Pct([double]$A, [double]$B) {
  if ($B -le 0) { return $null }
  return [math]::Round(($A - $B) / $B * 100.0, 0)
}
function FmtN([double]$v) { return [math]::Round($v, 0).ToString('#,0') }

$compareRows = @(); $compareNotes = @()
if ($baseSum) {
  $baseTotals = Get-Totals $baseSum $base
  # 指标集:label/取值/方向(dir: up=恶化 up, flat=中性)
  $metrics = @(
    @{ k = 'totalSteps'; label = '总步数'; dir = 'flat' }
    @{ k = 'dialogSteps'; label = '在线操作步数'; dir = 'flat' }
    @{ k = 'dialogAvgMs'; label = '在线操作平均响应 ms'; dir = 'up' }
    @{ k = 'batchSteps'; label = '后台作业步数'; dir = 'flat' }
    @{ k = 'rfcSteps'; label = 'RFC 调用步数'; dir = 'flat' }
    @{ k = 'updateSteps'; label = '更新处理步数'; dir = 'flat' }
    @{ k = 'spoolSteps'; label = '打印步数'; dir = 'flat' }
    @{ k = 'activeUsers'; label = '活跃账号数'; dir = 'flat' }
  )
  foreach ($m in $metrics) {
    $a = [double]$curTotals[$m.k]; $b = [double]$baseTotals[$m.k]
    $p = Pct $a $b
    $verdict = '—'
    if ($null -ne $p -and [math]::Abs($p) -ge 30) {
      if ($m.dir -eq 'up') { $verdict = $(if ($p -gt 0) { '▲ 变慢' } else { '▼ 变快' }) }
      else { $verdict = $(if ($p -gt 0) { '▲ 更忙' } else { '▼ 回落' }) }
      $compareNotes += ("{0}:{1}→{2}({3:+0%;-0%;0}),{4}" -f $m.label, (FmtN $b), (FmtN $a), ($p / 100.0), $verdict)   # ★格式化 % 自带百分号,再加字面 % 变双 %%
    }
    $compareRows += @{ metric = $m.label; a = $a; b = $b; deltaPct = $p; verdict = $verdict }
  }

  # TOP 榜对比:新上榜/跌出 + 激增(步数>1000 防小基数)
  $aE = @{}; $bE = @{}
  foreach ($t in @($curSum.data.topEntry)) { $aE["$($t.entry)"] = [double]$t.steps }
  foreach ($t in @($baseSum.data.topEntry)) { $bE["$($t.entry)"] = [double]$t.steps }
  $newOn = @($aE.Keys | Where-Object { $_ -and -not $bE.ContainsKey($_) })   # $_ 非空防御:空键条目(如 ENTRY_ID 空串)不算「新上榜」
  $dropped = @($bE.Keys | Where-Object { $_ -and -not $aE.ContainsKey($_) })
  $surge = @($aE.Keys | Where-Object { $bE.ContainsKey($_) -and $bE[$_] -gt 1000 } | ForEach-Object {
    $p = Pct $aE[$_] $bE[$_]
    if ($null -ne $p -and $p -ge 50) { @{ entry = $_; b = $bE[$_]; a = $aE[$_]; deltaPct = $p } }
  } | Sort-Object { $_.deltaPct } -Descending)
  foreach ($s in @($surge | Select-Object -First 3)) {
    $compareNotes += ("{0} 步数激增 {1:+0%;-0%;0}({2}→{3} 步),建议确认是否有新批处理/接口在跑" -f $s.entry, ($s.deltaPct / 100.0), (FmtN $s.b), (FmtN $s.a))
  }
  # 括号红线(09-18 审查):-f 先于 -join 求值,不套内层括号则仅 {0} 填第一个元素(PS5.1 实测)
  if ($newOn.Count -ge 1) { $compareNotes += ("新进入 TOP 榜:{0}" -f (($newOn | Select-Object -First 5) -join ', ')) }
}

# ---------- 大白话四问(busy/fast/where/changes) ----------
$plain = [ordered]@{ }
$granZh = $(if ($granularity -eq 'month') { '本月' } else { '本周' })
if ($mode -eq 'this') { $granZh = $(if ($granularity -eq 'month') { '本月至今' } else { '本周至今' }) }
if ($curTotals.totalSteps -gt 0) {
  $busyTxt = ("{0}系统共处理 {1} 步操作,约 {2} 个账号在用" -f $granZh, (FmtN $curTotals.totalSteps), $curTotals.activeUsers)
  if ($baseSum) {
    $bt = Get-Totals $baseSum $base
    $p = Pct $curTotals.totalSteps $bt.totalSteps
    if ($null -ne $p) { $busyTxt += (",比上期{0}({3:+0%;-0%;0})" -f $(if ($p -ge 0) { '多' } else { '少' }), $null, $null, ($p / 100.0)) }
  }
  $plain.busy = "$busyTxt。"
} else { $plain.busy = "$($granZh)系统无负载数据(可能停机或聚合未生成)。" }   # ★$()显式包裹:PS 变量名会把紧贴的中文并进去("$granZh系统"=$granZh系统 整体当变量名)

if ($curTotals.dialogSteps -gt 0) {
  $fastTxt = ("大家在系统里的操作平均 {0} 秒得到响应({1})" -f ([math]::Round($curTotals.dialogAvgMs / 1000.0, 2)), $curHealth.text)
  $slow = @(@($curSum.data.trend) | Where-Object { $_.dialogSteps -gt 0 } | Sort-Object { $_.dialogAvgMs } -Descending | Select-Object -First 1)
  if ($slow.Count -ge 1 -and [double]$slow[0].dialogAvgMs -gt $curTotals.dialogAvgMs * 1.5) {
    $fastTxt += (";最慢的一天是 {0}(平均 {1} 秒{2})" -f $slow[0].label, ([math]::Round([double]$slow[0].dialogAvgMs / 1000.0, 2)),
      $(if ([double]$slow[0].dialogSteps -lt $curTotals.dialogSteps / 5) { ',当天操作量小' } else { '' }))
  }
  $plain.fast = "$fastTxt。"
} else { $plain.fast = "本期没有在线操作数据。" }

if ($curTotals.dialogSteps -gt 0 -or $curTotals.batchSteps -gt 0) {
  $whereParts = @()
  $top1 = @(@($curSum.data.topEntry) | Select-Object -First 1)
  if ($top1.Count -ge 1 -and $curTotals.dialogSteps -gt 0) {
    $share = [math]::Round([double]$top1[0].steps / $curTotals.totalSteps * 100.0, 0)
    $whereParts += ("单一最大负载来源是 {0}({1} 步,约占总量的 {2}%)" -f $top1[0].entry, (FmtN $top1[0].steps), $share)
  }
  if ($curTotals.totalSteps -gt 0) {
    $bshare = [math]::Round($curTotals.batchSteps / $curTotals.totalSteps * 100.0, 0)
    if ($bshare -ge 20) { $whereParts += ("后台批处理占了总量的 {0}%" -f $bshare) }
  }
  if ($whereParts.Count -ge 1) { $plain.where = ($whereParts -join ';') + '。' }
  else { $plain.where = '负载分布较均匀,没有明显大头。' }
} else { $plain.where = '无数据可比。' }

if ($compareNotes.Count -ge 1) { $plain.changes = ("和上期比:{0}。" -f ($compareNotes -join ';')) }
elseif ($baseSum) { $plain.changes = '和上期相比各指标波动都在 30% 以内,基本平稳。' }
else { $plain.changes = '未选对比期。' }

# ---------- 体检摘要(与 🩺体检同口径;失败不炸报告) ----------
$digest = $null
try { $digest = Get-SapHealthDigest -System $system } catch { $digest = $null }

# ---------- 周期标签 ----------
function PeriodLabel($P) {
  if ($null -eq $P) { return '' }
  if ($P.pType -eq 'M') { return $P.start.ToString('yyyy年M月') }
  return ("{0} ~ {1}" -f $P.start.ToString('yyyy-MM-dd'), $P.end.ToString('yyyy-MM-dd'))
}

# ============ action=run 返回 ============
if ($action -eq 'run') {
  return @{ ok = $true; result = [ordered]@{
    system = $system; granularity = $granularity; mode = $mode
    cur = @{ pType = $cur.pType; start = $cur.start.ToString('yyyy-MM-dd'); end = $cur.end.ToString('yyyy-MM-dd')
             label = PeriodLabel $cur; isPartial = [bool]$cur.isPartial }
    base = $(if ($base) { @{ pType = $base.pType; start = $base.start.ToString('yyyy-MM-dd'); end = $base.end.ToString('yyyy-MM-dd')
             label = PeriodLabel $base; isPartial = [bool]$base.isPartial } } else { $null })
    health = @{ status = $curHealth.status; text = $curHealth.text; dialogAvgMs = $curTotals.dialogAvgMs; dialogSteps = $curTotals.dialogSteps }
    plain = $plain
    curData = @{ tasktypes = @($curSum.data.tasktypes); topEntry = @($curSum.data.topEntry); topUser = @($curSum.data.topUser)
                 trend = @($curSum.data.trend); trendMissing = @($curSum.data.trendMissing)
                 periodMissing = [bool]$curSum.data.periodMissing; dirLatest = "$($curSum.data.dirLatest)"
                 activeUsers = $curSum.data.activeUsers; totals = $curTotals }
    baseData = $(if ($baseSum) { @{ tasktypes = @($baseSum.data.tasktypes); topEntry = @($baseSum.data.topEntry); topUser = @($baseSum.data.topUser)
                 trend = @($baseSum.data.trend); trendMissing = @($baseSum.data.trendMissing)
                 periodMissing = [bool]$baseSum.data.periodMissing; dirLatest = "$($baseSum.data.dirLatest)"
                 activeUsers = $baseSum.data.activeUsers; totals = (Get-Totals $baseSum $base) } } else { $null })
    compare = @{ rows = $compareRows; notes = @($compareNotes) }
    digest = $digest
    topCached = [bool]$curSum.cached; generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); durMs = $sw.ElapsedMilliseconds
  } }
}

return (Fail 'BAD_ACTION' "action 必须是 run/comment/mail,收到: '$action'")
