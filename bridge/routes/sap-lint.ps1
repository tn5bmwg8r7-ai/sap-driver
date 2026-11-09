param([Parameter(Mandatory)][hashtable]$Body)

# sap-lint  -  代码质量静态检查:五关 SQL + L0 基础逻辑盲区(2026-10-10 v17)。
# 输入(程序/函数/事务码 三态识别)→ sap_prog_read 拉 include 族 → _abap-lint 本地引擎 →
# DD03L 主键 + DD17S 活跃二级索引(7 天缓存)→ 关2 终判 → 五关报告。
# v17 增:函数定域——单函数只审自己的 U<nn>(TFDIR.INCLUDE 一发定位)+ 组 TOP,不拖同组其它函数;
#         AI 深审与静态共用同一定域源码(v16 双份拉取式已废)。
# v16 增:L0 基础逻辑(①字段 DDIC 描述↔报错文案错位 DD03T/DD03L/DD04T 三级解析 ②同例程报错文案雷同);
#         G1 循环内 SELECT 由 HIGH 降 MED(用户定案:小数据量场景可接受);
#         action='ai' AI 语义深审分支(源码喂公司内网 DeepSeek 通读,输出结构化盲区报告,不走结果缓存)。
# 零 SAP 写入(只读);语法不做检查(RS_SYNTAX_CHECK 不 RFC),只做静态口径。
# 缓存(<缓存目录>(env SAP_PROBE_CACHE_DIR,缺省=仓库 data/sap-mcp-probe)):
#   lint-<SYS>.json   结果缓存,key=主程序 PROG|UNAM|UDAT|UTIME 指纹(未改零成本),≤50 条 LRU
#   ddix-<SYS>.json   表索引元数据,每表 7 天
# 凭证:NEED_CREDENTIAL 原样透传(前端弹连接面板);refresh:true 跳结果缓存。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_abap-lint.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')   # v15 整合:facade工具/拍平/QueryRows/缓存读写收敛到共享件
. (Join-Path $PSScriptRoot '_claude-helpers.ps1')   # v16 AI 深审:Invoke-SapAi(内部 Invoke-KbClaude,动态作用域解析)

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

# L0 用:接口参数项归一(PSCustomObject/IDictionary → hashtable;explain-lib 的 ConvertTo-ItemHashtable
# 在本路由依赖链外,为免引半个 explain 库,内联轻量版——2026-10-10 实爆:直取 ['name'] 遇 PSCustomObject 静默空)
function ConvertTo-LintItemHash {
    param($Item)
    $h = @{}
    if ($null -eq $Item) { return $h }
    if ($Item -is [System.Collections.IDictionary]) { foreach ($k in @($Item.Keys)) { $h[[string]$k] = $Item[$k] }; return $h }
    foreach ($p in $Item.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

# ============ 入参 ============
$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$system = ([string]$input_.system).Trim().ToUpper()
if ($system -notin @('DVP', 'QAS', 'PRD')) { return (Fail 'BAD_SYSTEM' "system 必须是 DVP/QAS/PRD,收到: '$system'") }
$object = ([string]$input_.object).Trim().ToUpper()
if (-not $object) { return (Fail 'BAD_PARAM' 'object(程序/函数/事务码)必填') }
$refresh = (($input_.refresh -eq $true) -or (([string]$input_.refresh) -eq 'true'))

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cacheDir = $global:SapProbeCacheDir   # 常量单源(2026-09-21 审查,原硬编码)

# action='ai' → AI 语义深审(与静态检查独立;静态检查不吃此参数,老前端透传不受影响)
$action = (([string]$input_.action).Trim().ToLower())

try {
  # ============ 1. 输入识别:TSTC → TFDIR → TADIR → 原样当程序(单源切 Get-SapObjectRef,2026-09-21 审查;TADIR 层为增益:输入函数组名现在能识别到 SAPL<组> 主程序) ============
  $ref = Get-SapObjectRef -System $system -Name $object -ThrowOnFacadeError
  $resolved = $ref.prog; $resolvedVia = $ref.via

  # ============ 1.8 函数定域(v17):单函数只审它自己的 U<nn> + 组 TOP(全局声明),不拖同组其它函数 ============
  # 配方:TFDIR.INCLUDE=include 序号一发定位(ZAPS 诊断在案);序号异常/REPOSRC 无激活版 → 回落全组旧行为
  # 用户痛点:函数组挂几十个函数时全组审查"眼花缭乱"(2026-10-10)
  $roots = @()
  $scopeNote = ''
  if ($resolvedVia -eq 'function') {
    $fnInc = ''
    try {
      $rows = @(Get-QueryRows -System $system -Table 'TFDIR' -Where "FUNCNAME = '$object'" -MaxRows 1)
      if ($rows.Count -gt 0) {
        $incNo = ([string]$rows[0].INCLUDE).Trim()
        $pn = ([string]$rows[0].PNAME).Trim().ToUpper()
        # $Matches 只属最后一个 -match:必须嵌套判定,并列 -and 里第二个无分组 match 会把组1冲成 null(10-10 实爆 LU12)
        if ($pn -match '^SAPL(.+)$') {
          $fnGrp = [string]$Matches[1]
          if ($incNo -match '^\d{1,2}$') {
            $cand = ('L{0}U{1:d2}' -f $fnGrp, [int]$incNo)
            $rows = @(Get-QueryRows -System $system -Table 'REPOSRC' -Where "PROGNAME = '$cand' AND R3STATE = 'A'" -MaxRows 1)
            if ($rows.Count -gt 0) { $fnInc = $cand }
          }
        }
      }
    } catch { }
    if ($fnInc) {
      $roots = @($fnInc, ('L{0}TOP' -f $fnGrp))
      $scopeNote = ('单函数定域:只审 {0} + {1}(全局声明),不含同组其它函数' -f $fnInc, ('L{0}TOP' -f $fnGrp))
    }
  }

  # ============ 1.9 函数接口参数类型(v18 提前:静态 L0 与 AI 校准共用,避免重复 RFC) ============
  # varTypes: 参数名→DDIC类型(供 L0 变量类型解析);tablesParams: TABLES 参数名(供 AI 校准"结构参数判空幻觉"降级)
  $varTypes = @{}; $tablesParams = @()
  if ($resolvedVia -eq 'function') {
    try {
      $fr = Invoke-FacadeTool -Tool 'sap_fm_read' -Args @{ system = $system; function = $object; includeSource = $false } -TimeoutSec 40
      $prim = @('I', 'C', 'N', 'P', 'D', 'T', 'F', 'X', 'STRING', 'XSTRING', 'ANY', 'INT', 'INT8', 'DATA', 'CLIKE', 'SIMPLE', 'NUMERIC', 'TABLE')
      $ifn = $fr.data['interface']
      $iface = if ($null -ne $ifn) { ConvertTo-FlatHashtable $ifn } else { @{} }
      foreach ($k in @('importing', 'exporting', 'changing', 'tables')) {
        foreach ($i0 in @($iface[$k])) {
          $h0 = ConvertTo-LintItemHash $i0   # PSCustomObject/hashtable 归一(直取 ['name'] 遇 PSCustomObject 静默空)
          $pn = ([string]$h0['name']).Trim().ToUpper(); $pt = ([string]$h0['type']).Trim().ToUpper()
          if (-not $pn -or -not $pt) { continue }
          if ($k -eq 'tables') { $tablesParams += $pn }
          if (($prim -notcontains $pt) -and (-not $varTypes.ContainsKey($pn))) { $varTypes[$pn] = $pt }
        }
      }
    } catch { }   # 接口拿不到不阻塞:引擎源码声明仍可用
  }

  # ============ 2. 主程序指纹(REPOSRC 激活版;定域时加挂 U<nn>/TOP 指纹——组主程序时间戳不随单函数改码而动,防陈旧缓存) ============
  $rows = @(Get-QueryRows -System $system -Table 'REPOSRC' -Where "PROGNAME = '$resolved' AND R3STATE = 'A'" -MaxRows 1)
  if ($rows.Count -eq 0) {
    return (Fail 'NOT_FOUND' "REPOSRC 无激活版 <$resolved>(system=$system,via=$resolvedVia)。检查对象名是否输对。")
  }
  $fp = ('{0}|{1}|{2}|{3}' -f $resolved, $rows[0].UNAM, $rows[0].UDAT, $rows[0].UTIME)
  foreach ($rt in $roots) {
    try {
      $rows = @(Get-QueryRows -System $system -Table 'REPOSRC' -Where "PROGNAME = '$rt' AND R3STATE = 'A'" -MaxRows 1)
      if ($rows.Count -gt 0) { $fp += ('|{0}|{1}|{2}' -f $rt, $rows[0].UDAT, $rows[0].UTIME) }
    } catch { }
  }
  $fp = $fp + '|lint5'   # lint5(10-10):函数定域改族构成,键随定域指纹自然分流;旧 lint4 全组结果一并失效

  # ============ 3. 结果缓存(未改零成本;AI 深审不走缓存——每次点击都是新判断) ============
  $cache = $null
  if (-not $refresh -and $action -ne 'ai') {
    $cache = Get-SapCacheMap -Path (Join-Path $cacheDir ("lint-$system.json"))
    if ($cache.ContainsKey($fp)) {
      $hit = $cache[$fp]
      $hit.cacheHit = $true
      $hit.durMs = $sw.ElapsedMilliseconds
      return @{ ok = $true; result = $hit }
    }
  }

  # ============ 4. INCLUDE 族拉取(深度 3 / ≤30 文件 / ≤2 万行,与 SCAN FM 同口径;定域时根=U<nn>+TOP) ============
  $reInc = '(?im)^\s*INCLUDE\s+(?!STRUCTURE\b|TYPE\b)([A-Z0-9_\/\-]+)'
  $sources = @{}            # name → string[](源码行)
  $unreadable = @()         # @{name,code}
  $seen = New-Object System.Collections.Generic.List[string]
  $current = New-Object System.Collections.Generic.List[string]
  if ($roots.Count -gt 0) {
    foreach ($rt in $roots) { [void]$seen.Add($rt); [void]$current.Add($rt) }
  } else {
    [void]$seen.Add($resolved); [void]$current.Add($resolved)
  }
  $totalLines = 0; $capHit = $false
  for ($wave = 1; $wave -le 3 -and $current.Count -gt 0; $wave++) {
    $next = New-Object System.Collections.Generic.List[string]
    foreach ($prog in $current.ToArray()) {
      if ($sources.Count -ge 30) { $capHit = $true; break }
      $r = Invoke-FacadeTool -Tool 'sap_prog_read' -Args @{ system = $system; program = $prog }
      if (-not $r.ok) {
        if ($sources.Count -eq 0) { return @{ ok = $false; error = $r.error } }   # 主程序读不了=硬失败透传
        $unreadable += ,@{ name = $prog; code = $r.error.code }
        continue
      }
      $lines = @(([string]$r.data.source) -split "\r?\n")
      $sources[$prog] = $lines
      $totalLines += $lines.Count
      if ($totalLines -gt 20000) { $capHit = $true; break }
      if ($wave -lt 3) {
        foreach ($m in [regex]::Matches(([string]$r.data.source), $reInc)) {
          $inc = $m.Groups[1].Value.ToUpperInvariant()
          if (-not $seen.Contains($inc)) { [void]$seen.Add($inc); [void]$next.Add($inc) }
        }
      }
    }
    $current = $next
  }

  # ============ 4.5 AI 语义深审分支(v17:共用上方已拉源码,静态/AI 同源同范围;不走结果缓存) ============
  # 安全口径:源码属公司资产,固定 Provider=deepseek(内网),绝不静默降级外网;失败原样透出。
  # 提示词预算 ≤10 文件/≤1200 行(定域后单函数天然满足,超出截断如实标注);roots 优先排最前。
  if ($action -eq 'ai') {
    $orderAi = @($sources.Keys)
    if ($roots.Count -gt 0) { $orderAi = @($roots) + @($sources.Keys | Where-Object { $roots -notcontains $_ } | Sort-Object) }
    $blocksAi = New-Object System.Collections.Generic.List[string]
    $totalAi = 0; $usedAi = 0; $truncAi = $false
    foreach ($k in $orderAi) {
      if ($usedAi -ge 10 -or $totalAi -ge 1200) { $truncAi = $true; break }
      $linesAi = @($sources[$k])
      if ($totalAi + $linesAi.Count -gt 1200) { $linesAi = @($linesAi | Select-Object -First ([Math]::Max(1, 1200 - $totalAi))); $truncAi = $true }
      $totalAi += $linesAi.Count; $usedAi++
      $numAi = New-Object System.Collections.Generic.List[string]
      for ($li = 0; $li -lt $linesAi.Count; $li++) { [void]$numAi.Add(('{0,4}|{1}' -f ($li + 1), $linesAi[$li])) }
      [void]$blocksAi.Add(("===== INCLUDE $k =====") + "`n" + ($numAi.ToArray() -join "`n"))
    }
    if ($totalAi -eq 0) { return (Fail 'AI_NO_SOURCE' "源码拉取为空,无法深审 <$resolved>(system=$system)") }
    $sysPrompt = @'
你是资深 SAP ABAP 代码审查专家。任务:通读以下源码,找出「人容易漏看」的逻辑盲区错误,重点排查:
1) 校验字段与报错文案语义错位(复制报错模板漏改文字,如校验"海外投入"字段却报"远期收益")
2) 复制粘贴漏改:相似分支中该改没改的字段名/表名/常量/消息编号
3) 漏校验:缺空值/初始值判断、SELECT 后不查 sy-subrc 就用结果、除零、日期/金额/币种/单位处理矛盾
4) 相近变量名误用、内表/工作区串用、循环内变量未清
5) 接口字段映射错位:赋值顺序、字段张冠李戴、必填参数漏传
【ABAP 语义红线(跨语言误判防护,违反=幻觉)】
a) TABLES/STRUCTURE 参数与内表为空时,LOOP/READ/READ TABLE 天然零次执行,这【不是缺陷】;严禁建议给函数的 STRUCTURE 参数加 IS NOT INITIAL 前置判空(除非该参数由 SELECT 直读填充后直接访问组件)。此类"发现"最多标 LOW。
b) IF/CHECK/TRY 的作用域以 ENDIF/ENDTRY 为界:断言某行「在守卫块作用域之外/之内」前,必须先定位该块的起止行号自查一遍,拿不准就不要下此断言(改标 LOW 或不报)。
输出严格 JSON,除 JSON 外不要任何文字:
{"findings":[{"line":123,"severity":"HIGH","type":"文案错位","message":"问题描述","suggestion":"修改方向","evidence":"断言行附近的逐字源码原文(≤80字符,供程序校验行号真实性)","guardRange":[30,45]}],"summary":"一句话总评"}
字段要求:evidence 必填;guardRange 仅当发现依赖"守卫作用域内外"判断时必填(该 IF/CHECK/TRY 块的起止行号,单元素数组可省);severity 只能 HIGH/MED/LOW;最多 15 条,按严重度降序;确实没有就输出 {"findings":[],"summary":"未发现明显逻辑盲区"}。
'@
    $truncTag = ''
    if ($truncAi) { $truncTag = ';⚠源码超预算已截断,结论可能不全,发现仅为可见部分' }
    $usrPrompt = ('审查对象:{0}(system={1},经{2} 解析,共 {3} 行{4}):' -f $object, $system, $resolvedVia, $totalAi, $truncTag) + "`n`n" + ($blocksAi.ToArray() -join "`n")
    $aiText = ''; $aiModel = ''
    try {
      $aiR = Invoke-SapAi -UserPrompt $usrPrompt -SystemPrompt $sysPrompt -MaxTokens 4096 -Temperature 0.2 -TimeoutSec 180 -Provider 'deepseek' -Throw
      $aiText = [string]$aiR.text; $aiModel = [string]$aiR.model
    } catch {
      return (Fail 'AI_REVIEW_FAILED' ('AI 深审失败(固定公司内网 DeepSeek,不降级外网):' + $_.Exception.Message))
    }
    $clean = $aiText.Trim()
    $clean = [regex]::Replace($clean, '(?s)^```(?:json)?\s*', '')
    $clean = [regex]::Replace($clean, '(?s)\s*```\s*$', '')
    $findingsAi = New-Object System.Collections.Generic.List[object]
    $summaryAi = ''
    $parsedOk = $true
    try {
      $jAi = $clean | ConvertFrom-Json
      $summaryAi = [string]$jAi.summary
      foreach ($fd0 in @($jAi.findings)) {
        if (-not $fd0) { continue }
        $ln0 = 0
        if ("$($fd0.line)" -match '^\d+$') { $ln0 = [int]$fd0.line }
        $gr0 = @()
        if ($null -ne $fd0.guardRange) { $gr0 = @($fd0.guardRange | ForEach-Object { [int]$_ }) }
        $findingsAi.Add(@{
          line = $ln0; severity = ([string]$fd0.severity).ToUpper(); type = [string]$fd0.type
          message = [string]$fd0.message; suggestion = [string]$fd0.suggestion
          evidence = [string]$fd0.evidence; guardRange = $gr0; note = ''
        })
      }
    } catch { $parsedOk = $false }
    # ---- 校准层(v18,源自用户两轮实测反馈):幻觉防御,只降级不改判,⚖ 注可追溯 ----
    # ①STRUCTURE 参数判空建议 → LOW(跨语言幻觉;TABLES 参数名单来自 FM 接口)②evidence 与源码对不上 → LOW(行号幻觉)
    # ③guardRange 非法 → LOW;①③仅压 HIGH/MED,LOW 保持 LOW
    if ($parsedOk) {
      $corpusN = ''
      foreach ($k2 in @($sources.Keys)) { $corpusN += ((@($sources[$k2]) -join ' ') -replace '\s', '') }
      $corpusN = $corpusN.ToUpperInvariant()
      $guardRe = 'IS\s*NOT\s*INITIAL|判空|未判空|空值|未初始化|初始值|空表'
      $calibN = 0
      foreach ($fd in $findingsAi) {
        if ($fd.severity -in @('HIGH', 'MED') -and ([string]$fd.message) -match $guardRe) {
          foreach ($tp in $tablesParams) {
            if ($tp -and (([string]$fd.message) -match [regex]::Escape($tp))) {
              $fd.severity = 'LOW'
              $fd.note = ('已校准:STRUCTURE 参数 {0} 判空建议=跨语言幻觉(ABAP 空表 LOOP/READ 天然安全,除非该参数为 SELECT 直读)' -f $tp)
              $calibN++; break
            }
          }
        }
        $ev = ([string]$fd.evidence)
        if ($ev) {
          $evN = ($ev -replace '\s', '').ToUpperInvariant()
          if ($evN.Length -ge 4 -and (-not $corpusN.Contains($evN))) {
            if ($fd.severity -in @('HIGH', 'MED')) { $fd.severity = 'LOW' }
            $fd.note = '已校准:引用片段在源码中找不到(行号/内容疑幻觉),降级待人工'
            $calibN++
          }
        }
        $gr = @($fd.guardRange)
        if ($gr.Count -ge 2) {
          if (([int]$gr[0] -gt [int]$gr[1]) -or ([int]$gr[0] -lt 1)) {
            if ($fd.severity -in @('HIGH', 'MED')) { $fd.severity = 'LOW' }
            if (-not $fd.note) { $fd.note = '已校准:guardRange 起止行号非法' }
            $calibN++
          }
        }
      }
      $calibNote = ('校准 {0} 处' -f $calibN)
    }
    $aiRes = @{
      tool = 'ai_review'; program = $object; system = $system; requested = $object
      resolvedVia = $resolvedVia; scopeNote = $scopeNote; model = $aiModel; durMs = $sw.ElapsedMilliseconds
      truncated = $truncAi; sourceLines = $totalAi; sourceCount = $usedAi
    }
    if ($parsedOk) { $aiRes.findings = $findingsAi.ToArray(); $aiRes.summary = $summaryAi; $aiRes.calibrated = $calibNote }
    else { $aiRes.parseError = $true; $aiRes.raw = $aiText }
    return @{ ok = $true; result = $aiRes }
  }

  # ============ 5. 引擎分析 ============
  $factsList = @()
  foreach ($name in @($sources.Keys)) {
    $factsList += ,(Get-AbapSqlFacts -Lines $sources[$name] -IncludeName $name)
  }

  # ============ 5.5 L0 标签解析(v16):DD03T→DD03L→DD04T 三级批量取字段描述 ============
  # 类型来源:引擎源码 DATA/TABLES 声明(引擎内建)+ 函数接口参数(1.9 已取)
  # 描述来源:DD03T 字段级描述 → 缺则 DD03L 取 ROLLNAME → DD04T 数据元素描述;全缺=该组跳过不判(不误报)
  $FieldLabels = @{}
  $l0Pairs = @{}   # '结构|字段' → 待解析
  foreach ($f0 in $factsList) {
    foreach ($kv0 in @($f0.VarTypes.Keys)) { if (-not $varTypes.ContainsKey($kv0)) { $varTypes[$kv0] = [string]$f0.VarTypes[$kv0] } }   # 家族级合并(TOP 声明喂到使用点)
  }
  foreach ($f0 in $factsList) {
    foreach ($sp0 in @($f0.LogicSuspects)) {
      $t0 = [string]$sp0.Type
      if (-not $t0 -and $varTypes.ContainsKey([string]$sp0.Var)) { $t0 = [string]$varTypes[[string]$sp0.Var] }
      if ($t0) { $l0Pairs[('{0}|{1}' -f $t0, $sp0.Field)] = $true }
      $ck0 = ('{0}-{1}' -f $sp0.Var, $sp0.Field)   # 组件级(BEGIN OF 内 LIKE 表-字段)
      if ($varTypes.ContainsKey($ck0)) {
        $cv0 = [string]$varTypes[$ck0]
        if ($cv0 -match '-') { $s0 = $cv0.Split('-'); $l0Pairs[('{0}|{1}' -f $s0[0], $s0[$s0.Count - 1])] = $true }
      }
    }
  }
  $l0PairKeys = @($l0Pairs.Keys | Select-Object -First 80)   # 上限 80 对:防超长 WHERE,超出如实少判
  if ($l0PairKeys.Count -gt 0) {
    $lblPref = '1'   # DDLANGUAGE 1=中文优先,E 兜底,其余任意非空兜底
    $pickTxt = {
      param($rows)
      $best = ''
      foreach ($r in $rows) {
        $t = ([string]$r.DDTEXT).Trim()
        if (-not $t) { continue }
        $lg = ([string]$r.DDLANGUAGE).Trim().ToUpper()
        if ($lg -eq $lblPref) { return $t }
        if ($lg -eq 'E' -and $best -notmatch '[一-鿿]') { if (-not $best) { $best = $t } }
        elseif (-not $best) { $best = $t }
      }
      return $best
    }
    # pass1:DD03T 字段级描述
    $need = New-Object System.Collections.Generic.List[string]
    foreach ($k in $l0PairKeys) { $seg = $k.Split('|'); if (-not $FieldLabels.ContainsKey($k)) { [void]$need.Add($k) } }
    for ($gi = 0; $gi -lt $need.Count; $gi += 40) {
      $grp = @($need | Select-Object -Skip $gi -First 40)
      $w = ($grp | ForEach-Object { $s = $_.Split('|'); "( TABNAME = '$($s[0])' AND FIELDNAME = '$($s[1])' )" }) -join ' OR '
      try {
        $rows = @(Get-QueryRows -System $system -Table 'DD03T' -Where $w -MaxRows 1000)
        $byPair = @{}
        foreach ($r0 in $rows) {
          $k0 = ('{0}|{1}' -f "$($r0.TABNAME)".ToUpper(), "$($r0.FIELDNAME)".ToUpper())
          if (-not $byPair.ContainsKey($k0)) { $byPair[$k0] = New-Object System.Collections.Generic.List[object] }
          [void]$byPair[$k0].Add($r0)
        }
        foreach ($k0 in $byPair.Keys) {
          $t0 = & $pickTxt $byPair[$k0].ToArray()
          if ($t0) { $FieldLabels[$k0] = $t0 }
        }
      } catch { }
    }
    # pass2/3:缺描述的取 ROLLNAME → DD04T
    $needRoll = @{}
    $missKeys = @($l0PairKeys | Where-Object { -not $FieldLabels.ContainsKey($_) })
    if ($missKeys.Count -gt 0) {
      for ($gi = 0; $gi -lt $missKeys.Count; $gi += 40) {
        $grp = @($missKeys | Select-Object -Skip $gi -First 40)
        $w = ($grp | ForEach-Object { $s = $_.Split('|'); "( TABNAME = '$($s[0])' AND FIELDNAME = '$($s[1])' )" }) -join ' OR '
        try {
          $rows = @(Get-QueryRows -System $system -Table 'DD03L' -Where "( $w ) AND AS4LOCAL = 'A' AND ROLLNAME <> ''" -MaxRows 1000)
          foreach ($r0 in $rows) {
            $k0 = ('{0}|{1}' -f "$($r0.TABNAME)".ToUpper(), "$($r0.FIELDNAME)".ToUpper())
            $rn = ([string]$r0.ROLLNAME).Trim().ToUpper()
            if ($rn -and (-not $needRoll.ContainsKey($k0))) { $needRoll[$k0] = $rn }
          }
        } catch { }
      }
      $rnList = @($needRoll.Values | Select-Object -Unique | Select-Object -First 60)
      if ($rnList.Count -gt 0) {
        $dd04 = @{}
        for ($gi = 0; $gi -lt $rnList.Count; $gi += 40) {
          $grp = @($rnList | Select-Object -Skip $gi -First 40)
          $w = ($grp | ForEach-Object { "ROLLNAME = '$_'" }) -join ' OR '
          try {
            $rows = @(Get-QueryRows -System $system -Table 'DD04T' -Where $w -MaxRows 1000)
            foreach ($r0 in $rows) {
              $rn = ([string]$r0.ROLLNAME).Trim().ToUpper()
              if (-not $dd04.ContainsKey($rn)) { $dd04[$rn] = New-Object System.Collections.Generic.List[object] }
              [void]$dd04[$rn].Add($r0)
            }
          } catch { }
        }
        foreach ($k0 in $missKeys) {
          if ($needRoll.ContainsKey($k0) -and $dd04.ContainsKey($needRoll[$k0])) {
            $t0 = & $pickTxt $dd04[$needRoll[$k0]].ToArray()
            if ($t0) { $FieldLabels[$k0] = $t0 }
          }
        }
      }
    }
  }

  # ============ 6. DDIC 索引(DD03L 主键 + DD17S 活跃索引,7 天缓存) ============
  $allTables = @()
  foreach ($f in $factsList) { foreach ($t in $f.DistinctTables) { if ($allTables -notcontains $t) { $allTables += $t } } }
  $tableCapHit = ($allTables.Count -gt 15)
  $TableIndex = @{}
  $ddixPath = Join-Path $cacheDir ("ddix-$system.json")
  $ddix = @{ tables = @{} }
  try {
    if (Test-Path $ddixPath) {
      $j = Get-Content $ddixPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.tables) { $ddix.tables = ConvertTo-MutHashTable $j.tables }
    }
  } catch { $ddix = @{ tables = @{} } }
  $ddixDirty = $false
  # v15 批查:缺失表先收集,DD03L(服务端滤 KEYFLAG='X',≤15 表约百余行)一次取回;
  # DD17S 按 5 表一组分片(服务端滤 AS4LOCAL='A' AND INDEXNAME<>'0',每片 ≤~500 行防截断)。
  # 原逐表 2 次 × 15 表 = 30 次往返,冷路径(DB 过期/首查)省 26 次。
  $missTables = @()
  foreach ($t in @($allTables | Select-Object -First 15)) {
    $e = $null
    if ($ddix.tables.ContainsKey($t)) {
      $cand = $ddix.tables[$t]
      # 形态闸:pk/idx 必须是数组形态。历史中间版(09-16 13:36 批)曾把 pk 写成空对象{},
      # 读回成空 Hashtable,@($hashtable)=1元素数组→引擎 .ToUpperInvariant 炸(09-17 ZUTIL_004 实爆);
      # 坏形态按「缓存未命中」处理,走 DD03L/DD17S 重查自愈。
      $shapeOk = $false
      try {
        # pk 必须是非空字符串数组形态:null/空(历史假空)或坏形态都当未命中重查自愈
        # (真无主键的表重查代价=每轮 1 次查询,可接受)
        $pkOk = (($null -ne $cand.pk) -and ($cand.pk -is [System.Collections.IEnumerable]) -and ($cand.pk -isnot [System.Collections.IDictionary]) -and ($cand.pk -isnot [string]))
        if ($pkOk -and @($cand.pk).Count -ge 1) { $shapeOk = $true }
        if ($shapeOk) {
          foreach ($ix0 in @($cand.idx)) {
            if (-not (($ix0.f -is [System.Collections.IEnumerable]) -and ($ix0.f -isnot [System.Collections.IDictionary]) -and ($ix0.f -isnot [string]))) { $shapeOk = $false; break }
          }
        }
      } catch { $shapeOk = $false }
      $age = 999
      if ($shapeOk) {
        try { $age = ((Get-Date) - [datetime]$cand.at).TotalDays } catch { }
        if ($age -lt 7) { $e = $cand }
      }
    }
    if ($e) { $TableIndex[$t] = $e } else { $missTables += $t }
  }
  if ($missTables.Count) {
    $pkByTable = @{}
    $wPk = ($missTables | ForEach-Object { "TABNAME = '$_'" }) -join ' OR '
    try {
      $rows = @(Get-QueryRows -System $system -Table 'DD03L' -Where "( $wPk ) AND KEYFLAG = 'X'" -MaxRows 1000)
      foreach ($r0 in $rows) {
        $tb = "$($r0.TABNAME)".ToUpper()
        if (-not $pkByTable.ContainsKey($tb)) { $pkByTable[$tb] = New-Object System.Collections.Generic.List[object] }
        [void]$pkByTable[$tb].Add($r0)
      }
    } catch { }
    for ($gi = 0; $gi -lt $missTables.Count; $gi += 5) {
      $grp = @($missTables | Select-Object -Skip $gi -First 5)
      $wIx = ($grp | ForEach-Object { "SQLTAB = '$_'" }) -join ' OR '
      $ixByTable = @{}
      try {
        $rows = @(Get-QueryRows -System $system -Table 'DD17S' -Where "( $wIx ) AND AS4LOCAL = 'A' AND INDEXNAME <> '0'" -MaxRows 1000)
        foreach ($r0 in $rows) {
          $tb = "$($r0.SQLTAB)".ToUpper()
          if (-not $ixByTable.ContainsKey($tb)) { $ixByTable[$tb] = New-Object System.Collections.Generic.List[object] }
          [void]$ixByTable[$tb].Add($r0)
        }
      } catch { }
      foreach ($t in $grp) {
        $err = ''
        $pk = @()
        if ($pkByTable.ContainsKey($t)) {
          $pk = @($pkByTable[$t] | Sort-Object { if ("$($_.POSITION)" -match '^\d+$') { [int]$_.POSITION } else { 9999 } } |
            ForEach-Object { "$($_.FIELDNAME)".ToUpper() })
        }
        $ix = @()
        if ($ixByTable.ContainsKey($t)) {
          $groups = @{}
          foreach ($rr in $ixByTable[$t]) {
            $n = "$($rr.INDEXNAME)".ToUpper()
            if (-not $groups.ContainsKey($n)) { $groups[$n] = New-Object System.Collections.Generic.List[object] }
            [void]$groups[$n].Add($rr)
          }
          foreach ($n in $groups.Keys) {
            $flds = @($groups[$n] | Sort-Object { if ("$($_.POSITION)" -match '^\d+$') { [int]$_.POSITION } else { 9999 } } |
              ForEach-Object { "$($_.FIELDNAME)".ToUpper() })
            $ix += ,@{ n = $n; f = $flds }
          }
        }   # 无活跃二级索引=正常结果(ix 留空,G2 审计按 FULL_SCAN 判),不算 err
        $e = @{ at = (Get-Date).ToString('o'); pk = $pk; idx = $ix; err = $err }
        $ddix.tables[$t] = $e; $ddixDirty = $true
        $TableIndex[$t] = $e
      }
    }
  }
  if ($ddixDirty) {
    try {
      New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
      @{ fetchedAt = (Get-Date).ToString('o'); tables = $ddix.tables } | ConvertTo-Json -Depth 12 -Compress |
        Set-Content -Path $ddixPath -Encoding UTF8
    } catch { }
  }

  # ============ 7. 关2 终判 + 报告 ============
  $rep = Complete-AbapSqlLint -FactsList $factsList -TableIndex $TableIndex -Program $resolved -FieldLabels $FieldLabels -VarTypes $varTypes
  $rep.l0LabelResolved = $FieldLabels.Count   # 观测口径:本次实际解析到的 DDIC 描述对数
  $incList = @()
  foreach ($name in @($sources.Keys)) { $incList += ,@{ name = $name; lines = $sources[$name].Count } }
  $rep.system = $system
  $rep.requested = $object
  $rep.resolvedVia = $resolvedVia
  if ($roots.Count -gt 0) { $rep.program = $object; $rep.scopeNote = $scopeNote }   # 定域:标题显示函数名而非组主程序
  $rep.fingerprint = $fp
  $rep.includes = $incList
  $rep.includesUnreadable = $unreadable
  $rep.capHit = $capHit
  $rep.tableCapHit = $tableCapHit
  $rep.tableCount = $allTables.Count
  $rep.cacheHit = $false
  $rep.durMs = $sw.ElapsedMilliseconds

  # 结果缓存 LRU ≤50(v15:命中判定段已读过一次,这里复用 $cache,不再二次整读)
  try {
    if (-not $cache) { $cache = Get-SapCacheMap -Path (Join-Path $cacheDir ("lint-$system.json")) }
    $rep.cachedAt = (Get-Date).ToString('o')
    $cache[$fp] = $rep
    if ($cache.Count -gt 50) {
      $keep = @($cache.Keys | Sort-Object { $cache[$_].cachedAt } -Descending | Select-Object -First 50)
      $pruned = @{}
      foreach ($k in $keep) { $pruned[$k] = $cache[$k] }
      $cache = $pruned
    }
    Save-SapCacheMap -Path (Join-Path $cacheDir ("lint-$system.json")) -Map $cache
  } catch { }

  return @{ ok = $true; result = $rep }
} catch {
  # Get-QueryRows 抛的 Exception.Data.FacadeCode = facade 透传错误,原样回(NEED_CREDENTIAL 判据不能丢)
  if ($_.Exception.Data['FacadeCode']) {
    return @{ ok = $false; error = @{ code = [string]$_.Exception.Data['FacadeCode']; message = [string]$_.Exception.Data['FacadeMessage'] } }
  }
  return (Fail 'LINT_FAILED' $_.Exception.Message)
}
