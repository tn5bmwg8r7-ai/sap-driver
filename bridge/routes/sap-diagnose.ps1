param([Parameter(Mandatory)][hashtable]$Body)

# sap-diagnose  -  SAP Driver「🔍 排查」诊断引擎(v8,2026-09-15)。
# 用户定案:排查工具必须回答「为什么报错 / 为什么没数据」,不是 POSTMAN;
# 结论要唯一性定位——证据充分给唯一根因,不充分就明说差哪个数据并给裁决动作。
#
# 管线(facade 零改动,全走现有只读工具):
#   0 collect  确定性采集:fm_read 源码(定位 RAISE/MESSAGE 行)+ T100 消息解码 +
#              参数 DDIC 体检(类型/长度/转换出口/检查表/域固定值) —— 零 AI
#   1 locate   AI 一次调用:候选根因(每条挂证据)→ verdict = unique | ambiguous | need_data
#   2 verify   自动反证验证(AI 给 VERIFY 步骤,≤2 步,仅白名单只读工具)
#   3 verdict  AI 终裁:唯一性结论 + 证据链 + 修复建议 / 裁决动作
# 进度文件 diag-<callId>.json(与 ask 同目录同机制,widget 轮询 sap-ask-progress kind='diag')。
# 输入的 execError/execRes 由前端透传(复用已发生的执行,不重跑函数,零副作用风险)。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_claude-helpers.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')   # v15 整合:facade工具/拍平/进度/AI样板收敛到共享件

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

# ---------- 进度(与 sap-ask 同机制;文件删除=完成) ----------
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$system = ([string]$input_.system).Trim().ToUpper()
if (@('DVP', 'QAS', 'PRD') -notcontains $system) { return (Fail 'BAD_SYSTEM' "system 仅支持 DVP/QAS/PRD: $system") }
$fm = ([string]$input_.function).Trim()
if (-not $fm) { return (Fail 'BAD_FM' 'function 必填') }
$diagKind = ([string]$input_.kind).Trim()
if (-not $diagKind) { $diagKind = 'fm' }
$execError = [string]$input_.execError
$execResObj = $input_.execRes
$emptyHint = [bool]$input_.emptyHint
if (-not $execError -and -not $execResObj) { return (Fail 'NO_SIGNAL' 'execError / execRes 至少带一个(诊断必须有信号源)。') }
Initialize-SapRoute | Out-Null   # v15:facade 死了 WMI 拉起
$form = $input_.form

$script:DiagProgressFile = $null
$callId = [string]$input_.callId
if ($callId -match '^[a-f0-9-]{8,40}$') {
  $script:DiagProgressFile = Join-Path $global:SapProgressDir ("diag-$callId.json")
}
function Write-DiagProgress([string]$Phase, [int]$Step, [int]$Total, [string]$Tool) {
  Write-SapProgress -File $script:DiagProgressFile -Phase $Phase -Step $Step -Total $Total -Tool $Tool   # v15:共享件(原子替换)
}

# ---------- 0) 确定性采集 ----------
Write-DiagProgress 'collect' 0 0 ''
$swCollect = [System.Diagnostics.Stopwatch]::StartNew()
$signals = [ordered]@{ fm = $fm; system = $system }

# 0.1 执行信号(前端透传,不重跑)
$sig = [ordered]@{}
if ($execError) { $sig.execError = $(if ($execError.Length -gt 600) { $execError.Substring(0, 600) } else { $execError }) }
if ($emptyHint) { $sig.observation = '执行成功但返回为空(所有导出参数/表均无内容)' }
if ($null -ne $execResObj) {
  $ej = '{}'
  try { $ej = $execResObj | ConvertTo-Json -Depth 12 -Compress } catch {}
  if ($ej.Length -gt 4000) { $ej = $ej.Substring(0, 4000) + '...(截断)' }
  $sig.execResult = $ej
}
if ($form -and $form.import) {
  $fj = '{}'
  try { $fj = $form.import | ConvertTo-Json -Depth 8 -Compress } catch {}
  if ($fj.Length -gt 1200) { $fj = $fj.Substring(0, 1200) + '...' }
  $sig.importArgs = $fj
}
if ($form -and $form.tables) {
  $tj = '[]'
  try { $tj = $form.tables | ConvertTo-Json -Depth 8 -Compress } catch {}
  if ($tj.Length -gt 1500) { $tj = $tj.Substring(0, 1500) + '...' }
  $sig.tablesArgs = $tj
}

# 0.2 源码(定位 RAISE/MESSAGE 行 + 内部 WHERE 过滤逻辑);v11 report=读报表程序本身
$source = ''
$sigIface = $null
try {
  if ($diagKind -eq 'report') {
    $fr = Invoke-FacadeTool -Tool 'sap_prog_read' -Args @{ system = $system; program = $fm }
    if ($fr.ok) {
      if ($fr.data.source) { $source = [string]$fr.data.source }
      if ($fr.data.sourceError) { $sig.sourceError = [string]$fr.data.sourceError }
    }
    if ($input_.form -and $input_.form.seltab) {
      $sj = '[]'
      try { $sj = $input_.form.seltab | ConvertTo-Json -Depth 8 -Compress } catch {}
      if ($sj.Length -gt 1500) { $sj = $sj.Substring(0, 1500) + '...' }
      $sig.seltabArgs = $sj
    }
  } else {
    $fr = Invoke-FacadeTool -Tool 'sap_fm_read' -Args @{ system = $system; function = $fm }
    if ($fr.ok) {
      if ($fr.data.source) { $source = [string]$fr.data.source }
      if ($fr.data.sourceError) { $sig.sourceError = [string]$fr.data.sourceError }   # RPY 读不到源码的原因,给 AI 看
      if ($fr.data.interface) { $sigIface = $fr.data.interface }
    }
  }
} catch {}
if ($source) { $sig.source = $(if ($source.Length -gt 9000) { $source.Substring(0, 9000) + '...(源码截断)' } else { $source }) }

# 0.3 T100 消息解码:从错误串/返回结构里抓 msgid+msgno,查中文全文
$decoded = @()
$pairs = New-Object System.Collections.ArrayList
$hay = $execError
if ($null -ne $execResObj) { try { $hay = "$execError " + ($execResObj | ConvertTo-Json -Depth 10 -Compress) } catch { $hay = $execError } }
if ($hay) {
  # RETURN/BAPIRET 结构: "ID":"XX","NUMBER":"123" / 消息串: ZZXX 123
  foreach ($m in [regex]::Matches($hay, '"(?:ID|MSGID)"\s*:\s*"([A-Za-z0-9_]{1,20})"\s*,\s*"(?:NUMBER|MSGNO)"\s*:\s*"?(\d{3})"?')) {
    [void]$pairs.Add(@{ id = $m.Groups[1].Value.ToUpper(); no = $m.Groups[2].Value })
  }
  if (-not $pairs.Count) {
    foreach ($m in [regex]::Matches($hay, '\b([A-Z][A-Z0-9_]{2,14})\s?(\d{3})\b')) {
      $cand = $m.Groups[1].Value
      if ($cand -match '^(SY|ECAT|FC)' -or $cand -eq $fm) { continue }
      [void]$pairs.Add(@{ id = $cand; no = $m.Groups[2].Value })
    }
  }
}
$seen = @{}
foreach ($p in @($pairs) | Select-Object -First 3) {
  $key = "$($p.id)$($p.no)"
  if ($seen.ContainsKey($key)) { continue }
  $seen[$key] = $true
  try {
    $txt = ''
    foreach ($lang in @('1', 'E')) {   # 中文优先,英文兜底(消息类未翻译时)
      $q = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'T100'; maxRows = 1
        where = @(@{ field = 'SPRSL'; op = '='; value = $lang }, @{ field = 'ARBGB'; op = '='; value = $p.id }, @{ field = 'MSGNR'; op = '='; value = $p.no }) }
      if ($q.ok -and @($q.data.rows).Count) { $txt = [string]$q.data.rows[0].TEXT; break }
    }
    if ($txt) { $decoded += @{ msgid = $p.id; msgno = $p.no; text = $txt } }
  } catch {}
}
if ($decoded.Count) { $sig.decodedMessages = $decoded }

# 0.4 参数 DDIC 体检:关键参数的类型/长度/转换出口/检查表/域固定值
$paramMeta = @()
try {
  if ($sigIface) {
    $iface = ConvertTo-FlatHashtable $sigIface
    $typeNames = New-Object System.Collections.ArrayList
    foreach ($sec in @('importing', 'changing', 'tables')) {
      foreach ($pp in @($iface[$sec])) {
        if ($pp -and $pp.type) { [void]$typeNames.Add([string]$pp.type) }
      }
    }
    $uniq = @($typeNames | Sort-Object -Unique | Select-Object -First 5)
    foreach ($t in $uniq) {
      if ($t -notmatch '^[A-Z0-9_/]+$' -or $t.Length -gt 30) { continue }
      try {
        $mr = Invoke-FacadeTool -Tool 'sap_object_meta' -Args @{ system = $system; object = $t; includeEnums = $true }
        if ($mr.ok) {
          $flds = @()
          foreach ($f in @($mr.data.fields) | Select-Object -First 12) {
            $flds += @{ name = [string]$f.name; datatype = [string]$f.datatype; leng = [string]$f.leng
                        convexit = $(if ($f.convexit) { [string]$f.convexit } else { '' })
                        checkTable = $(if ($f.checkTable) { [string]$f.checkTable } else { '' }) }
          }
          $enums = @()
          foreach ($e in @($mr.data.enums) | Select-Object -First 4) {
            $ef = ConvertTo-FlatHashtable $e
            if ($ef.values) { $enums += @{ domain = [string]$ef.domain; values = @($ef.values | Select-Object -First 10) } }
          }
          $paramMeta += @{ object = $t; fields = $flds; enums = $enums }
        }
      } catch {}
    }
  }
} catch {}
if ($paramMeta.Count) { $sig.paramMeta = $paramMeta }

# 0.5 v12(2026-09-15)report 定点归因:变式筛选条件 → 业务表数据可达性硬数字。
#     「应该取到却没取到」最常见的答案是「变式把数据筛空了」——与其让 AI 猜,
#     不如按变式条件直接数业务表(≤5 张表 × ≤31 行探针,边界收敛,全只读)。
#     SQL 红线自证:循环有界(≤5)、每次查询独立成句且边界封顶 31 行、无循环内拼接大查询。
if ($diagKind -eq 'report' -and $input_.form -and $input_.form.seltab) {
  try {
    $selRows = @($input_.form.seltab | ForEach-Object { ConvertTo-FlatHashtable $_ })
    $tables = New-Object System.Collections.ArrayList
    $seenT = @{}
    foreach ($m in [regex]::Matches($source, '(?i)\bFROM\s+([A-Za-z_/][A-Za-z0-9_/]{2,15})')) {
      $t = $m.Groups[1].Value.ToUpper()
      if ($t -match '^(IT_|LT_|GT_|WA_|LS_|GS_|RT_|SO_|S_|P_|PA_)') { continue }   # 内表/选择表命名形态
      if ($t -match '_') { continue }                                              # 物理表名极少带下划线
      if ($seenT.ContainsKey($t)) { continue }
      $seenT[$t] = $true
      [void]$tables.Add($t)
      if ($tables.Count -ge 5) { break }
    }
    $reach = New-Object System.Collections.ArrayList
    foreach ($t in $tables) {
      try {
        $mr = Invoke-FacadeTool -Tool 'sap_object_meta' -Args @{ system = $system; object = $t; includeEnums = $false }
        if (-not $mr.ok) { continue }
        $fldNames = @{}
        foreach ($f in @($mr.data.fields)) { $fldNames[[string]$f.name] = $true }
        $where = New-Object System.Collections.ArrayList
        $filters = New-Object System.Collections.ArrayList
        foreach ($s in $selRows) {
          $sn = (([string]$s.SELNAME).ToUpper() -replace '^(SO_|S_|P_|PA_)', '')
          if (-not $sn -or -not $fldNames.ContainsKey($sn)) { continue }
          $low = [string]$s.LOW; $high = [string]$s.HIGH
          if (-not $low -and -not $high) { continue }
          if (([string]$s.SIGN).ToUpper() -eq 'E') { continue }   # 排除行不进探针(口径=包含条件)
          $opt = ([string]$s.OPTION).ToUpper(); if (-not $opt) { $opt = 'EQ' }
          if ($opt -eq 'EQ' -and $low) {
            [void]$where.Add(@{ field = $sn; op = '='; value = $low })
            [void]$filters.Add(@{ param = [string]$s.SELNAME; field = $sn; cond = "= $low" })
          } elseif ($opt -eq 'BT' -and $low -and $high) {
            [void]$where.Add(@{ field = $sn; op = '>='; value = $low })
            [void]$where.Add(@{ field = $sn; op = '<='; value = $high })
            [void]$filters.Add(@{ param = [string]$s.SELNAME; field = $sn; cond = "$low ~ $high" })
          } elseif (@('GE','LE','GT','LT','NE','CP') -contains $opt -and $low) {
            $opMap = @{ GE = '>='; LE = '<='; GT = '>'; LT = '<'; NE = '<>'; CP = 'LIKE' }
            $psop = $opMap[$opt]
            [void]$where.Add(@{ field = $sn; op = $psop; value = $low })
            [void]$filters.Add(@{ param = [string]$s.SELNAME; field = $sn; cond = "$psop $low" })
          }
          # 其余 OPTION(NB 等)罕见,不进探针,宁缺毋错
        }
        if (-not $where.Count) { continue }   # 映射不上任何条件 → 无法归因到这张表,跳过
        $qr = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = $t; maxRows = 31; where = $where }
        $n = -1
        if ($qr.ok) { $n = @($qr.data.rows).Count }
        $probeNote = switch ($n) {
          0 { '0 条——该表在这些筛选条件下无数据' }
          31 { '≥31 条(有数据)' }
          -1 { '(查询失败)' }
          default { "$n 条" }
        }
        [void]$reach.Add([ordered]@{ table = $t; filters = $filters; probe = $probeNote })
      } catch {}
    }
    if ($reach.Count) { $sig.dataReach = $reach }
  } catch {}
}

$swCollect.Stop()

# ---------- 1) AI 定位(候选根因,STRICT JSON) ----------
Write-DiagProgress 'locate' 0 0 ''
$swLocate = [System.Diagnostics.Stopwatch]::StartNew()
if ($diagKind -eq 'report') {
$locateSys = @"
你是 SAP 资深排错定位器。报表程序经 SUBMIT 执行**报错**或**输出为空**,请基于给定信号定位根因,输出 STRICT JSON(无 markdown 无解释)。

信号包含:执行错误串/返回结果(EV_MESSAGE/列表行数)、选择屏幕入参(seltab:参数名/类型/值)、dataReach(按变式筛选条件直接数业务表的行数,≤31 封顶;filters=用到的条件,probe=行数结论)、报表 ABAP 源码(RAISE/MESSAGE/内部 WHERE 过滤)、T100 解码消息。

排查先验(按顺序过一遍,别漏):
0. dataReach 是硬证据:某表 probe「0 条」= 数据根本不在这些筛选条件的检索范围内——结合 filters 直接指认筛空数据的参数(如「工厂=1000 在 EKPO 里 0 条,而源数据以 2000 为主」);「≥31 条」说明数据在,问题出在程序后续逻辑/权限/输出形态
1. 选择屏幕值合法性:ALPHA 类字段缺前导零?日期格式/区间反了?S 选项 SIGN/OPTION 组合是否把数据排光?
2. 数据不在:公司代码/工厂/日期区间选错,数据根本不在检索范围
3. 变式:变式属于别的程序/被保护/内容为空
4. 内部过滤:源码 WHERE/SELECT 条件把数据滤掉了(对照源码逐条件看)
5. 权限:报表内 AUTHORITY-CHECK 失败分支
6. 输出形态:全屏 ALV GRID 类报表不落列表缓冲——取回为空但报表本身没毛病(此时结论应指向「需 GUI 前台查看」)

输出 JSON:
{"understanding":"一句话:这次执行在干什么、期望什么",
 "hypotheses":[{"cause":"根因假设(具体到参数/表/源码行)","evidence":"信号里的具体证据","confidence":"high|mid|low"}],
 "verdict":"unique|ambiguous|need_data",
 "verify":[{"tool":"sap_query|sap_object_meta|sap_prog_read","args":{...},"why":"验证什么","expect":"什么结果证实什么"}]}

规则:
- verify 最多 2 步,只许 sap_query / sap_object_meta / sap_prog_read 三个工具——**禁用 sap_fm_read**(诊断对象是报表程序不是函数,用了必误报 FUNCTION_NOT_FOUND);args 里 system 一律 "$system"
- 工具真实参数名(必须照抄,用错即拒):sap_query(system,table,where,maxRows,fields) / sap_object_meta(system,object) / sap_prog_read(system,program)
- 能用一步查证就不用两步;查证要能**区分**候选根因(证伪其一)
- 不编造表名/字段名;源码里看到的表/条件优先
"@
} else {
$locateSys = @"
你是 SAP 资深排错定位器。函数调用**报错**或**返回空**,请基于给定信号定位根因,输出 STRICT JSON(无 markdown 无解释)。

信号包含:执行错误串/返回结果、入参、函数 ABAP 源码(看 RAISE/MESSAGE 行与内部 WHERE 过滤)、T100 解码消息、参数 DDIC 体检(类型/长度/转换出口/检查表/域固定值)。

排查先验(按顺序过一遍,别漏):
1. 输入合法性:物料/科目等 ALPHA 类字段缺前导零?日期格式?单位/币种?值域?
2. 检查表:输入值在配置表/主数据里到底存不存在(这决定后面给不给验证步骤)
3. 配置缺失:函数读的定制视图/条件表没配数据
4. 数据不在:client/工厂/公司代码/日期区间不对,数据根本不在检索范围
5. 内部过滤:源码 WHERE/EINGRAF 条件把数据滤掉了(对照源码逐条件看)
6. 权限/异常:RAISE 未授权类、sy-subrc 分支

输出 JSON:
{"understanding":"一句话:这次调用在干什么、期望什么",
 "hypotheses":[{"cause":"根因假设(具体到参数/表/源码行)","evidence":"信号里的具体证据","confidence":"high|mid|low"}],
 "verdict":"unique|hypotheses 唯一 high 时填 unique,有 2 个以上可能填 ambiguous,信号不足填 need_data",
 "verify":[{"tool":"sap_query|sap_object_meta|sap_prog_read|sap_fm_read","args":{...},"why":"验证什么","expect":"什么结果证实什么"}]}

规则:
- verify 最多 2 步,只许列出的 4 个只读工具;args 里 system 一律 "$system"
- 工具真实参数名(必须照抄,用错即拒):sap_query(system,table,where,maxRows,fields) / sap_object_meta(system,object) / sap_fm_read(system,function) / sap_prog_read(system,program)
- 能用一步查证就不用两步;查证要能**区分**候选根因(证伪其一)
- 不编造表名/字段名;源码里看到的表/条件优先
"@
}
# 采集段产出($sig)并入信号包——2026-09-16 审查实爆:$signals 只含 fm/system,
# 源码/T100/paramMeta/dataReach 全程没送达 locate 与终裁两轮 AI。
foreach ($k in @($sig.Keys)) { $signals[$k] = $sig[$k] }
$sigJson = '{}'
try { $sigJson = $signals | ConvertTo-Json -Depth 12 -Compress } catch {}
$locateUser = "诊断信号:`n$sigJson"
$hypo = $null
$locateAi = Invoke-SapAi -UserPrompt $locateUser -SystemPrompt $locateSys -MaxTokens 1600 -Temperature 0.1
if ($locateAi) { $hypo = ConvertFrom-ClaudeJson -Text $locateAi.text }
$swLocate.Stop()
if (-not $hypo) {
  if ($script:DiagProgressFile) { Remove-Item $script:DiagProgressFile -Force -ErrorAction SilentlyContinue }
  return (Fail 'DIAG_LOCATE_FAILED' 'AI 定位失败,请重试(执行结果仍保留在结果区)。')
}

# ---------- 2) 自动反证验证(≤2 步,白名单只读工具) ----------
# v11 report:禁 sap_fm_read(报表不是函数,AI 用它验证必误报 FUNCTION_NOT_FOUND)
$verifyAllowed = @('sap_query', 'sap_object_meta', 'sap_prog_read')
if ($diagKind -ne 'report') { $verifyAllowed += 'sap_fm_read' }
$verifyReports = @()
$vSteps = @()
try { if ($hypo.verify) { $vSteps = @($hypo.verify) | Where-Object { $_ -and $_.tool } | Select-Object -First 2 } } catch { $vSteps = @() }
$vi = 0
foreach ($v in $vSteps) {
  $vi++
  $tool = ([string]$v.tool).Trim()
  Write-DiagProgress 'verify' $vi $vSteps.Count $tool
  $rec = [ordered]@{ tool = $tool; why = [string]$v.why; expect = [string]$v.expect; ok = $false }
  if ($tool -notin $verifyAllowed) {
    $rec.error = "工具 $tool 不在验证白名单"
    $verifyReports += $rec
    continue
  }
  $vArgs = $v.args
  try {
    if ($vArgs -is [string]) { $vArgs = $vArgs | ConvertFrom-Json }
    $vArgs = ConvertTo-FlatHashtable $vArgs
    if (-not $vArgs.system) { $vArgs.system = $system }
    $rec.args = $vArgs
    $vr = Invoke-FacadeTool -Tool $tool -Args $vArgs
    if ($vr.ok) {
      $rec.ok = $true
      $rj = '{}'
      try { $rj = $vr.data | ConvertTo-Json -Depth 10 -Compress } catch {}
      if ($rj.Length -gt 2500) { $rj = $rj.Substring(0, 2500) + '...(截断)' }
      $rec.result = $rj
    } else {
      $rec.error = "$($vr.error.code): $($vr.error.message)"
      if ($rec.error -match 'NEED_CREDENTIAL') {
        # 凭证失效:验证链没意义,直接终止(如实上抛)
        $verifyReports += $rec
        break
      }
    }
  } catch {
    $rec.error = $_.Exception.Message
  }
  $verifyReports += $rec
}

# ---------- 3) AI 终裁(唯一性结论) ----------
Write-DiagProgress 'verdict' 0 0 ''
$swVerdict = [System.Diagnostics.Stopwatch]::StartNew()
$hypoJson = '{}'
try { $hypoJson = @{ understanding = $hypo.understanding; hypotheses = $hypo.hypotheses; verdict = $hypo.verdict } | ConvertTo-Json -Depth 8 -Compress } catch {}
$verifyJson = '[]'
try { $verifyJson = $verifyReports | ConvertTo-Json -Depth 8 -Compress } catch {}
$verdictSys = @"
你是 SAP 资深排错定位器,做**终裁**。前面已给出候选根因,并按建议执行了反证验证。请输出 markdown 诊断报告:

- 若证据已收敛:开头一行「**根因(唯一)**:…」,再给「证据链」(引用具体源码行/表/字段/数字)、「修复建议」(具体到改什么值/配什么表/找谁)
- 若仍不可唯一:开头说明「两个候选根因,差一个数据裁决」,列「候选 A/B」各带证据,给「裁决动作」(查哪张表/跑哪个 tcode/改哪个参数重试)
- 绝不编造没依据的结论;权限类根因要指明用 SU53 前台确认
- 中文,紧凑;能用小表格就用表格
- 结尾如存在**一个明确的、一句话就能接着执行**的后续动作,输出 <!--NEXT:动作描述-->;没有就不输出
"@
$verdictUser = "诊断信号(摘要):`n" + $(if ($sigJson.Length -gt 6000) { $sigJson.Substring(0, 6000) + '...' } else { $sigJson }) + "`n`n候选根因:`n$hypoJson`n`n反证验证结果:`n$verifyJson"
$verdictAi = Invoke-SapAi -UserPrompt $verdictUser -SystemPrompt $verdictSys -MaxTokens 2200
$answer = $(if ($verdictAi) { $verdictAi.text } else { '' })
$swVerdict.Stop()
if (-not $answer) { $answer = 'AI 终裁失败——候选根因与反证验证结果仍有效,见下方结构化数据。' }
$nh = Get-SapNextHint -Answer $answer          # v15:NEXT 剥离收敛共享件
$answer = $nh.answer; $nextHint = $nh.nextHint

if ($script:DiagProgressFile) { Remove-Item $script:DiagProgressFile -Force -ErrorAction SilentlyContinue }
$swTotal.Stop()
$model = $(if ($verdictAi) { $verdictAi.model } else { '' })

$verdictOut = [string]$hypo.verdict
if ($verdictOut -notin @('unique', 'ambiguous', 'need_data')) { $verdictOut = 'need_data' }

return @{
  ok = $true
  result = [ordered]@{
    fm = $fm; system = $system
    verdict = $verdictOut
    understanding = [string]$hypo.understanding
    answer = $answer
    nextHint = $nextHint
    decodedMessages = $decoded
    verify = $verifyReports
    signalsCollected = [ordered]@{ hasSource = [bool]$source; msgDecoded = $decoded.Count; paramMetaObjects = $paramMeta.Count }
    timings = [ordered]@{
      collectMs = [long]$swCollect.ElapsedMilliseconds
      locateMs = [long]$swLocate.ElapsedMilliseconds
      verdictMs = [long]$swVerdict.ElapsedMilliseconds
      totalMs = [long]$swTotal.ElapsedMilliseconds
    }
    model = $model
  }
}
