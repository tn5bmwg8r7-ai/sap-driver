param([Parameter(Mandatory)][hashtable]$Body)

# sap-gate  -  交付门禁:交付顾问测试前的最后一道自动检查(v1,2026-10-14)。
# 场景:程序/接口写完了,放行给顾问测试前,把人工交付核验清单固化成自动化——
#   ①发现自己没发现的功能 BUG ②防止交付后传输还有问题(2026-10-14 ZREP002 实战清单固化:
#   LIMU TABD 缺 R3TR TABL 本体/表定义激活晚于程序/显式字段引用逐一比对,全由此抓出)。
# 输入三态:请求号(如 DEVK900001)/ 程序·函数·事务码(Get-SapObjectRef 单源识别)。
#   请求集定位:对象 → E071 反查(复用 objtr 前缀+本名模式)→ 未释放(TRSTATUS='D')主请求
#   = 交付目标;无未释放 → 审计最近已释放请求并如实降级 WARN。
# 五段检查(每段独立 PASS/WARN/FAIL/NA,聚合总 verdict):
#   G1 传输包:对象清单/脏树(标准对象混入=FAIL,清单外 Z/Y=WARN)/★LIMU↔R3TR 配对
#      (TABD·TABT 无全局 R3TR TABL=导入必败 WARN;新建程序无 R3TR PROG 主对象行同理)/TADIR 注册
#   G2 对象健康:程序激活态(REPOSRC)/事务码指向(TSTC)/表激活(DD02L)/W3MI 模板在位(WWWDATA)/标题
#   G3 表↔程序兼容:源码引用 Z 表 → 在本请求?传过?从未挂请求=WARN;复合引用 字段 ⊆ DD03L
#      激活字段(引用了不存在的字段=FAIL);表定义改动时间晚于程序最后激活=WARN(有人动过表)
#   G4 代码质量:整链复用 sap-lint 路由(五关 SQL+ECC 语法+风格;指纹缓存,二次秒回)
#   G5 需求覆盖(AI,选填):requirements 每行一条 → AI 逐条对照源码 PASS/GAP/PARTIAL + 逻辑 bug
#      疑点;evidence 校准(源码找不到=降级防幻觉,复用 lint v18 模式);公司内网 DeepSeek 不降级外网
# verdict:FAIL=修完再交;WARN=列疑点人工复核;PASS=可交付。G5 未填需求=NA 豁免不拉黄。
# 缓存(<缓存目录>(env SAP_PROBE_CACHE_DIR,缺省=仓库 data/sap-mcp-probe)\gate-<SYS>.json):key=程序|指纹|请求|对象数|需求hash,
#   ≤30 条 LRU;refresh:true 跳缓存。
# 只读(全程 sap_query/sap_prog_read);PRD 可用但交付门禁主战场是 DVP。
# ★宁缺毋假(v17.1 教训):所有元数据查询走 Get-GateRows 信封——查询失败(网络/凭证/闸)
#   标「未验」,绝不冒充「不存在」。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')
. (Join-Path $PSScriptRoot '_claude-helpers.ps1')   # G5:Invoke-SapAi(公司内网 DeepSeek)

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

function Clean-GateName([string]$s) {
    $s = ([string]$s).Trim().ToUpper()
    foreach ($ch in @("'", '`', ';', '-')) { $s = $s.Replace($ch, '') }
    return $s
}

# 元数据查询信封:ok=false=查询失败(网络/凭证/闸),与「查无此行」严格区分(v17.1:PRD 未连曾被
# 误写成未传输;本路由所有存在性判定都吃这个教训)
function Get-GateRows([string]$System, [string]$Table, [string]$Where, [int]$Max = 1) {
    try {
        $r = @(Get-QueryRows -System $System -Table $Table -Where $Where -MaxRows $Max)
        return @{ ok = $true; rows = $r }
    } catch {
        return @{ ok = $false; err = $_.Exception.Message }
    }
}

# 分段结果收集:函数显式返回新 status(scriptblock & 调用是子作用域,赋值不回传——2026-10-14 自查改函数式)
function Add-Gate([System.Collections.Generic.List[object]]$List, [string]$Cur, [string]$Lvl, [string]$Msg, [string]$Detail) {
    $List.Add(@{ level = $Lvl; msg = $Msg; detail = [string]$Detail })
    if ($Lvl -eq 'FAIL') { return 'FAIL' }
    if ($Lvl -eq 'WARN' -and $Cur -ne 'FAIL') { return 'WARN' }
    return $Cur
}

# ---- 输入 ----
$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$system = ([string]$input_.system).Trim().ToUpper()
if ($system -notin @('DVP', 'QAS', 'PRD')) { return (Fail 'BAD_SYSTEM' "system 必须是 DVP/QAS/PRD,收到: '$system'") }
$object = Clean-GateName $input_.object
if (-not $object) { return (Fail 'BAD_PARAM' 'object(程序/函数/事务码/请求号)必填') }
$refresh = (($input_.refresh -eq $true) -or (([string]$input_.refresh) -eq 'true'))
# 需求要点:前端 textarea 每行一条;路由兼容字符串/数组,≤30 条
$reqs = @()
foreach ($r0 in @($input_.requirements)) {
    if ($null -eq $r0) { continue }
    foreach ($ln in ([string]$r0) -split "(`r?`n|`n)") {
        $t = ([string]$ln).Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        if ($reqs -notcontains $t) { $reqs += $t }
    }
}
$reqs = @($reqs | Select-Object -First 30)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cacheDir = $global:SapProbeCacheDir

try {
  # ============ 0. 识别:请求号 or 对象 ============
  $isTrInput = ($object -match '^[A-Z0-9]{3}K\d{6}$')
  $mainProg = ''; $func = ''; $tcode = ''; $grp = ''; $objType = 'PROG'; $resolvedVia = ''
  $targetTr = ''          # 交付目标主请求
  $reqKeys = @()          # 主请求+子任务全集(E071 对象清单范围)
  $trMap = @{}            # trkorr → @{status;func;user;date;text;parent;tarsystem}
  $e070CachePath = Join-Path $cacheDir ("e070-" + $system + ".json")

  if ($isTrInput) {
    $targetTr = $object; $resolvedVia = 'trkorr'
    $h = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E070'; maxRows = 1; where = "TRKORR = '$object'" }
    if (-not $h.ok) { return $h }
    if ([int]$h.data.rowCount -eq 0) { return (Fail 'TR_NOT_FOUND' "请求 $object 在 $system 不存在(TR 目录系统级共享)") }
    $head = $h.data.rows[0]
    $trMap[$object] = @{ status = [string]$head.TRSTATUS; func = [string]$head.TRFUNCTION; user = [string]$head.AS4USER; date = [string]$head.AS4DATE; text = ''; parent = [string]$head.STRKORR; tarsystem = ([string]$head.TARSYSTEM).Trim() }
    if ($trMap[$object].parent) { $targetTr = $trMap[$object].parent; $trMap[$targetTr] = $trMap[$object] }   # 传任务号 → 折算主请求
    $subs = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E070'; maxRows = 50; where = "STRKORR = '$targetTr'" }
    if (-not $subs.ok) { return $subs }
    foreach ($s0 in $subs.data.rows) {
      $tk = [string]$s0.TRKORR
      $trMap[$tk] = @{ status = [string]$s0.TRSTATUS; func = [string]$s0.TRFUNCTION; user = [string]$s0.AS4USER; date = [string]$s0.AS4DATE; text = ''; parent = [string]$s0.STRKORR; tarsystem = ([string]$s0.TARSYSTEM).Trim() }
    }
    $reqKeys = @($trMap.Keys)
    $o71 = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E071'; maxRows = 500; where = "TRKORR = '$targetTr'" }
    if (-not $o71.ok) { return $o71 }
    $trProg = @($o71.data.rows | Where-Object { ([string]$_.OBJECT) -eq 'PROG' } | ForEach-Object { [string]$_.OBJ_NAME })
    if ($trProg.Count -eq 0) { return (Fail 'NO_PROG_IN_TR' "请求 $targetTr 内没有 PROG 对象,交付门禁按程序维度深检;纯表/配置请求请人工核验") }
    if ($trProg.Count -gt 1) { $multiProgNote = "请求含 $($trProg.Count) 个程序,深度检查只覆盖 $trProg[0],其余人工核验" }
    $mainProg = $trProg[0]; $objType = 'PROG'
  } else {
    $ref = Get-SapObjectRef -System $system -Name $object -ThrowOnFacadeError
    if (-not $ref.ok) { return (Fail $ref.code $ref.message) }
    $tcode = $ref.tcode; $func = $ref.func; $mainProg = $ref.prog; $grp = $ref.grp; $objType = $ref.objType; $resolvedVia = $ref.via
    # E071 反查(复用 objtr 前缀+本名模式): prog% / L<prog>% / func 本名 / 组本名
    $lpre = ''
    if ($mainProg -match '^SAPL(.+)$') { $lpre = 'L' + $Matches[1] }
    elseif ($mainProg -notmatch '^(L|SAPL|CL_)') { $lpre = 'L' + $mainProg }
    $terms = New-Object System.Collections.Generic.List[string]
    foreach ($pfx in @($mainProg, $lpre)) { if ($pfx) { [void]$terms.Add("OBJ_NAME LIKE '$pfx%'") } }
    if ($func) { [void]$terms.Add("OBJ_NAME = '$func'"); if ($grp -and $grp -ne $func) { [void]$terms.Add("OBJ_NAME = '$grp'") } }
    elseif ($objType -ne 'PROG' -and $objType -ne 'TRAN') { [void]$terms.Add("OBJ_NAME = '$object'") }
    $uniq = @($terms.ToArray() | Select-Object -Unique)
    $w71 = $uniq -join ' OR '
    if ($uniq.Count -gt 1) { $w71 = '( ' + $w71 + ' )' }
    $r71 = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E071'; maxRows = 1000; where = $w71 }
    if (-not $r71.ok) { return $r71 }
    $trObjs = @{}
    foreach ($row in $r71.data.rows) {
      $tk = [string]$row.TRKORR; $on = [string]$row.OBJ_NAME
      if (-not $tk -or -not $on) { continue }
      if (-not $trObjs[$tk]) { $trObjs[$tk] = New-Object System.Collections.Generic.List[string] }
      if (-not $trObjs[$tk].Contains($on)) { [void]$trObjs[$tk].Add($on) }
    }
    if ($trObjs.Count -eq 0) { return (Fail 'NO_TR_HISTORY' "$object 在 $system 无任何传输记录(E071),还没进过任何请求——先在 SE10 挂请求再跑交付门禁") }
    # 请求头(E070 批查 10/组;未缓存/未释放态重查——复用 e070 永久缓存,未释放不落旧值)
    $cached = @{}
    try {
      $c0 = Get-SapCacheMap -Path $e070CachePath
      foreach ($k in @($c0.Keys)) {
        $v = $c0[$k]
        if ($v -is [System.Collections.IDictionary]) {
          $cached[$k] = @{ status = [string]$v['status']; func = [string]$v['func']; user = [string]$v['user']; date = [string]$v['date']; text = [string]$v['text']; parent = [string]$v['parent']; tarsystem = [string]$v['tarsystem'] }
        }
      }
    } catch { }
    $need = @($trObjs.Keys | Where-Object { $c = $cached[$_]; (-not $c) -or ([string]$c.status -ne 'R') })
    $fetched = 0
    for ($ci = 0; $ci -lt $need.Count; $ci += 10) {
      $chunk = @($need | Select-Object -Skip $ci -First 10)
      $w = ($chunk | ForEach-Object { "TRKORR = '$_'" }) -join ' OR '
      $h = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E070'; maxRows = 20; where = $w }
      if (-not $h.ok) { continue }
      foreach ($h0 in $h.data.rows) {
        $tk = [string]$h0.TRKORR
        $cached[$tk] = @{ status = [string]$h0.TRSTATUS; func = [string]$h0.TRFUNCTION; user = [string]$h0.AS4USER; date = [string]$h0.AS4DATE; text = ''; parent = [string]$h0.STRKORR; tarsystem = ([string]$h0.TARSYSTEM).Trim() }
        $fetched++
      }
    }
    $trMap = $cached
    # 交付目标 = 未释放(TRSTATUS='D')请求里序号最大的主请求(TRFUNCTION='K';任务折算 parent)
    $openTks = @($trObjs.Keys | Where-Object { $trMap[$_] -and ([string]$trMap[$_].status) -eq 'D' } | Sort-Object { -[long]($_ -replace '^\D+', '') })
    foreach ($tk in $openTks) {
      $cand = $tk
      if ($trMap[$tk].parent) { $cand = [string]$trMap[$tk].parent }   # 任务 → 主请求
      if ($trMap[$cand] -and ([string]$trMap[$cand].func) -eq 'K') { if (-not $targetTr) { $targetTr = $cand }; break }
      if (-not $targetTr) { $targetTr = $cand }
    }
    if (-not $targetTr) {
      # 全已释放 → 审计最近(序号最大)请求,聚合段如实降 WARN
      $allTks = @($trObjs.Keys | Sort-Object { -[long]($_ -replace '^\D+', '') })
      foreach ($tk in $allTks) {
        $cand = if ($trMap[$tk].parent) { [string]$trMap[$tk].parent } else { $tk }
        if ($trMap[$cand] -and ([string]$trMap[$cand].func) -eq 'K') { $targetTr = $cand; break }
      }
      if (-not $targetTr) { $targetTr = $allTks[0] }
    }
    $subs = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E070'; maxRows = 50; where = "STRKORR = '$targetTr'" }
    if (-not $subs.ok) { return $subs }
    foreach ($s0 in $subs.data.rows) {
      $tk = [string]$s0.TRKORR
      if (-not $trMap[$tk]) {
        $trMap[$tk] = @{ status = [string]$s0.TRSTATUS; func = [string]$s0.TRFUNCTION; user = [string]$s0.AS4USER; date = [string]$s0.AS4DATE; text = ''; parent = [string]$s0.STRKORR; tarsystem = ([string]$s0.TARSYSTEM).Trim() }
      }
    }
    # ★主请求头补查(v19.1 冒烟实爆):E071 对象常挂任务号(928294),折算 parent(928293)后
    #   trMap 里只有任务头没有主请求头 → G1 的状态/目标系统/人/日期全空。单查一次补齐。
    if (-not $trMap[$targetTr]) {
      $h = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E070'; maxRows = 1; where = "TRKORR = '$targetTr'" }
      if ($h.ok -and [int]$h.data.rowCount -gt 0) {
        $h0 = $h.data.rows[0]
        $trMap[$targetTr] = @{ status = [string]$h0.TRSTATUS; func = [string]$h0.TRFUNCTION; user = [string]$h0.AS4USER; date = [string]$h0.AS4DATE; text = ''; parent = [string]$h0.STRKORR; tarsystem = ([string]$h0.TARSYSTEM).Trim() }
        $fetched++
      }
    }
    $reqKeys = @(@($targetTr) + @($subs.data.rows | ForEach-Object { [string]$_.TRKORR }))
    # $trMap=$cached 同引用:批查+主请求头补查的全部新增一并落盘(下次秒回)
    if ($fetched -gt 0) {
      try { Save-SapCacheMap -Path $e070CachePath -Map $cached } catch { }
    }
  }

  # ============ 1. 主程序指纹 + 结果缓存(确定性四段;需求 hash 进 key,变了重跑) ============
  $rows = @(Get-QueryRows -System $system -Table 'REPOSRC' -Where "PROGNAME = '$mainProg' AND R3STATE = 'A'" -MaxRows 1)
  if ($rows.Count -eq 0) {
    return (Fail 'NOT_FOUND' "REPOSRC 无激活版 <$mainProg>(system=$system,via=$resolvedVia)。程序未激活或名字输错。")
  }
  $progUdat = [string]$rows[0].UDAT; $progUtime = [string]$rows[0].UTIME
  $reqHash = ''
  if ($reqs.Count -gt 0) {
    $sha0 = [System.Security.Cryptography.SHA256]::Create()
    $reqHash = ([System.BitConverter]::ToString($sha0.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($reqs -join "`n")))).Replace('-', '').Substring(0, 8).ToLower()
  }
  # ★fp 掺主请求 TR 状态(2026-10-30 十轮审查):TR 释放 D→R / 表结构修复后重挂,程序指纹
  #   全不变,旧 fp 必命中过期结果——E070 重查(:147 未释放态)在缓存检查之前拿到实时值却被
  #   丢弃,界面仍显示释放前"未释放"。trMap=targetTr 主请求头,TR 输入与反查两分支都已填齐。
  $trStatusNow = if ($targetTr -and $trMap[$targetTr]) { [string]$trMap[$targetTr].status } else { '' }
  $fp = ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|g2' -f $mainProg, $rows[0].UNAM, $progUdat, $progUtime, $targetTr, $reqKeys.Count, $reqHash, $trStatusNow)
  $cache = $null
  if (-not $refresh) {
    $cache = Get-SapCacheMap -Path (Join-Path $cacheDir ("gate-$system.json"))
    if ($cache.ContainsKey($fp)) {
      $hit = $cache[$fp]
      $hit.cacheHit = $true; $hit.durMs = $sw.ElapsedMilliseconds
      return @{ ok = $true; result = $hit }
    }
  }

  # ============ 2. G1 传输包 ============
  $wReq = ($reqKeys | ForEach-Object { "TRKORR = '$_'" }) -join ' OR '
  $o71 = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E071'; maxRows = 500; where = $wReq }
  if (-not $o71.ok) { return $o71 }
  $objects = @($o71.data.rows | ForEach-Object {
    @{ pgmid = [string]$_.PGMID; type = [string]$_.OBJECT; name = [string]$_.OBJ_NAME; trkorr = [string]$_.TRKORR } })
  $g1 = New-Object System.Collections.Generic.List[object]
  $g1Status = 'PASS'
  $th = $trMap[$targetTr]
  $stZh = '未知'
  if ($th) { $stZh = switch ([string]$th.status) { 'D' { '未释放' } 'R' { '已释放' } 'L' { '已释放' } default { [string]$th.status } } }
  $tarSys = if ($th -and $th.tarsystem) { [string]$th.tarsystem } else { '未设目标' }
  $g1Msg = ('交付目标请求 {0}({1},目标系统 {2},{3} {4})+ 子任务 {5} 个' -f $targetTr, $stZh, $tarSys, $(if ($th) { [string]$th.user } else { '?' }), $(if ($th) { [string]$th.date } else { '?' }), ([Math]::Max($reqKeys.Count - 1, 0)))
  if ($th -and ([string]$th.status) -ne 'D') {
    $g1Status = Add-Gate $g1 $g1Status 'WARN' "无未释放请求:$object 涉及的请求已全部释放(最新 $targetTr)。本次按最近已交付请求审计;若这是新改动,先 SE10 建请求挂对象再跑" ''
  } else {
    $g1Status = Add-Gate $g1 $g1Status 'INFO' $g1Msg ''
  }
  # TADIR 注册(R3TR 主对象必查;查询失败标「未验」不冒充缺失)
  $r3trObjs = @($objects | Where-Object { $_.pgmid -eq 'R3TR' })
  $tadirMiss = @(); $tadirErr = 0
  foreach ($o in $r3trObjs) {
    $gr = Get-GateRows $system 'TADIR' "PGMID = '$($o.pgmid)' AND OBJECT = '$($o.type)' AND OBJ_NAME = '$($o.name)'"
    if (-not $gr.ok) { $tadirErr++; continue }
    if ($gr.rows.Count -eq 0) { $tadirMiss += ("$($o.pgmid) $($o.type) $($o.name)") }
  }
  if ($tadirMiss.Count -gt 0) { $g1Status = Add-Gate $g1 $g1Status 'FAIL' ('TADIR 未注册(对象目录缺失,传输会失败):' + ($tadirMiss -join ', ')) '' }
  else { $g1Status = Add-Gate $g1 $g1Status 'OK' ('R3TR 主对象 TADIR 注册齐全({0} 个{1})' -f $r3trObjs.Count, $(if ($tadirErr -gt 0) { ";$tadirErr 个查询失败未验" } else { '' })) '' }
  # 脏树:非自定义命名空间 = FAIL;/NSP/=自定义;清单外 Z/Y = 源码词法确认(源码 G3 前拉,先收集后判)
  # ★自定义前缀要含 SAPL[ZY]/L[ZY](函数组主程序/include,S 开头 L 开头不是 Z,别误判标准)
  $famNames = @($mainProg) + @($reqKeys) + @($object)
  $stdObjs = @(); $zynObjs = @()
  foreach ($o in ($objects | ForEach-Object { $_.name } | Select-Object -Unique)) {
    if ($famNames -contains $o) { continue }
    if ($o -match '^(SAPL[ZY]|L[ZY]|[ZY])') { if ($zynObjs -notcontains $o) { $zynObjs += $o } }
    elseif ($o.StartsWith('/NSP/')) { if ($zynObjs -notcontains $o) { $zynObjs += $o } }
    else { if ($stdObjs -notcontains $o) { $stdObjs += $o } }
  }
  if ($stdObjs.Count -gt 0) { $g1Status = Add-Gate $g1 $g1Status 'FAIL' ('疑似标准对象混入请求(脏树,绝不释放):' + ($stdObjs -join ', ')) '' }
  # ★LIMU↔R3TR 配对(2026-10-14 ZREP002 实战:4 表只挂 LIMU TABD/TABT,全传输体系无 R3TR TABL,导入目标无此表必失败)
  $limuTab = @($objects | Where-Object { $_.pgmid -eq 'LIMU' -and $_.type -in @('TABD', 'TABT') } | ForEach-Object { $_.name } | Select-Object -Unique)
  $orphanTab = @(); $pairErr = 0
  foreach ($t in $limuTab) {
    $gr = Get-GateRows $system 'E071' "OBJECT = 'TABL' AND OBJ_NAME = '$t'"
    if (-not $gr.ok) { $pairErr++; continue }
    if ($gr.rows.Count -eq 0) { $orphanTab += $t }
  }
  if ($orphanTab.Count -gt 0) {
    $g1Status = Add-Gate $g1 $g1Status 'WARN' ('表只挂了 LIMU 子对象,全传输体系无 R3TR TABL 主对象行:' + ($orphanTab -join ', ') + ' —— 若目标系统不存在这些表,导入会失败。SE10 往请求补挂 R3TR TABL 再释放(约 1 分钟)') ''
  } elseif ($limuTab.Count -gt 0) { $g1Status = Add-Gate $g1 $g1Status 'OK' ('表配对完整:{0} 张表的 R3TR TABL 已在传输体系' -f $limuTab.Count) '' }
  # 新建程序无 R3TR PROG 行:程序 TADIR CREATED_ON ≥ 请求创建日 → 目标系统无程序壳,导入后无此程序
  $progRow = @($objects | Where-Object { $_.pgmid -eq 'R3TR' -and $_.type -eq 'PROG' -and $_.name -eq $mainProg })
  if ($progRow.Count -eq 0) {
    $createdOn = ''
    $gr = Get-GateRows $system 'TADIR' "PGMID = 'R3TR' AND OBJECT = 'PROG' AND OBJ_NAME = '$mainProg'"
    if ($gr.ok -and $gr.rows.Count -gt 0) { $createdOn = ([string]$gr.rows[0].CREATED_ON).Trim() }
    $thDate = if ($th) { [string]$th.date } else { '' }
    if ($createdOn -match '^\d{8}$' -and $thDate -match '^\d{8}$' -and ([long]$createdOn) -ge ([long]$thDate)) {
      $g1Status = Add-Gate $g1 $g1Status 'FAIL' ("程序 $mainProg 创建于 $createdOn,不早于请求 $targetTr 创建日($thDate),但请求内没有 R3TR PROG 主对象行——目标系统无程序壳,导入后无此程序。SE10 补挂 R3TR PROG") ''
    } else {
      $g1Status = Add-Gate $g1 $g1Status 'WARN' ("请求内无 R3TR PROG $mainProg 主对象行(仅 LIMU 子对象)。若程序已传过目标系统(仅改码)可正常导入;若为首次交付必失败,请人工确认") ''
    }
  } else {
    $g1Status = Add-Gate $g1 $g1Status 'OK' "R3TR PROG $mainProg 主对象行在请求内" ''
  }

  # ============ 3. 源码拉取(G3/G5 共用;深度 2/≤30 文件/≤2 万行,与 lint 同口径) ============
  $reInc = '(?im)^\s*INCLUDE\s+(?!STRUCTURE\b|TYPE\b)([A-Z0-9_\/\-]+)'
  $sources = @{}; $seen = New-Object System.Collections.Generic.List[string]
  [void]$seen.Add($mainProg)
  $current = New-Object System.Collections.Generic.List[string]; [void]$current.Add($mainProg)
  $totalLines = 0; $srcCap = $false
  for ($wave = 1; $wave -le 2 -and $current.Count -gt 0; $wave++) {
    $next = New-Object System.Collections.Generic.List[string]
    foreach ($prog in $current.ToArray()) {
      if ($sources.Count -ge 30) { $srcCap = $true; break }
      $r = Invoke-FacadeTool -Tool 'sap_prog_read' -Args @{ system = $system; program = $prog }
      if (-not $r.ok) { continue }
      $lines = @(([string]$r.data.source) -split "\r?\n")
      $sources[$prog] = $lines
      $totalLines += $lines.Count
      if ($totalLines -gt 20000) { $srcCap = $true; break }
      if ($wave -lt 2) {
        foreach ($m in [regex]::Matches(([string]$r.data.source), $reInc)) {
          $inc = $m.Groups[1].Value.ToUpperInvariant()
          if (-not $seen.Contains($inc)) { [void]$seen.Add($inc); [void]$next.Add($inc) }
        }
      }
    }
    $current = $next
  }
  $corpus = ''
  foreach ($k in @($sources.Keys)) { $corpus += ((@($sources[$k]) -join ' ') + ' ') }
  $corpusN = ($corpus -replace '\s', '').ToUpperInvariant()
  # 脏树判定下半场:清单外 Z/Y 对象在源码词法找引用(找不到=WARN 人工确认,不是 FAIL——可能是配套表/文本)
  if ($zynObjs.Count -gt 0) {
    $unseen = @($zynObjs | Where-Object { -not $corpusN.Contains($_) })
    if ($unseen.Count -gt 0) { $g1Status = Add-Gate $g1 $g1Status 'WARN' ('请求内对象在程序源码中未见引用:' + ($unseen -join ', ') + ' —— 确认是否本批交付范围(不是则移出请求)') '' }
    else { $g1Status = Add-Gate $g1 $g1Status 'OK' ('清单外 Z/Y 对象源码可见引用:' + ($zynObjs -join ', ')) '' }
  } elseif ($stdObjs.Count -eq 0) { $g1Status = Add-Gate $g1 $g1Status 'OK' '无脏树:请求内对象全部可归属(主程序家族+源码可见引用)' '' }

  # ============ 4. G2 对象健康 ============
  $g2 = New-Object System.Collections.Generic.List[object]
  $g2Status = 'PASS'
  $g2Status = Add-Gate $g2 $g2Status 'OK' ("主程序 $mainProg 激活态 A,最后修改 $progUdat $progUtime") ''
  $incBad = @(); $incChk = 0; $incErr = 0
  foreach ($inc in @($sources.Keys | Where-Object { $_ -ne $mainProg } | Select-Object -First 20)) {
    $incChk++
    $gr = Get-GateRows $system 'REPOSRC' "PROGNAME = '$inc' AND R3STATE = 'A'"
    if (-not $gr.ok) { $incErr++; continue }
    if ($gr.rows.Count -eq 0) { $incBad += $inc }
  }
  if ($incBad.Count -gt 0) { $g2Status = Add-Gate $g2 $g2Status 'FAIL' ('include 无激活版:' + ($incBad -join ', ')) '' }
  elseif ($incChk -gt 0) { $g2Status = Add-Gate $g2 $g2Status 'OK' ("include 激活抽查 $incChk 个全 A$(if ($incErr -gt 0) { ";$incErr 个查询失败未验" })") '' }
  # 事务码指向(请求内有 TRAN 或识别链经 tcode)
  $tranNames = @($objects | Where-Object { $_.type -eq 'TRAN' } | ForEach-Object { $_.name })
  if ($tcode -and ($tranNames -notcontains $tcode)) { $tranNames += $tcode }
  foreach ($tc in ($tranNames | Select-Object -Unique)) {
    $gr = Get-GateRows $system 'TSTC' "TCODE = '$tc'"
    if (-not $gr.ok) { $g2Status = Add-Gate $g2 $g2Status 'WARN' "事务码 $tc 指向未验(TSTC 查询失败,不阻塞)" ''; continue }
    if ($gr.rows.Count -eq 0) { $g2Status = Add-Gate $g2 $g2Status 'FAIL' "事务码 $tc 不存在(TSTC)" ''; continue }
    $pgm = ([string]$gr.rows[0].PGMNA).Trim().ToUpper()
    if ($pgm -eq $mainProg) { $g2Status = Add-Gate $g2 $g2Status 'OK' "事务码 $tc → $mainProg ✓" '' }
    else { $g2Status = Add-Gate $g2 $g2Status 'WARN' "事务码 $tc 指向 $pgm(≠主程序 $mainProg)" '' }
  }
  # 表激活(请求内 TABD/TABL 对象;查询失败标未验)
  $tabNames = @((($objects | Where-Object { $_.type -in @('TABD', 'TABL') } | ForEach-Object { $_.name }) + $limuTab) | Select-Object -Unique)
  $tabBad = @(); $tabErr = 0
  foreach ($t in $tabNames) {
    $gr = Get-GateRows $system 'DD02L' "TABNAME = '$t' AND AS4LOCAL = 'A'"
    if (-not $gr.ok) { $tabErr++; continue }
    if ($gr.rows.Count -eq 0) { $tabBad += $t }
  }
  if ($tabNames.Count -eq 0) { $g2Status = Add-Gate $g2 $g2Status 'OK' '无表对象' '' }
  elseif ($tabBad.Count -gt 0) { $g2Status = Add-Gate $g2 $g2Status 'FAIL' ('表无激活版(DD02L):' + ($tabBad -join ', ')) '' }
  else { $g2Status = Add-Gate $g2 $g2Status 'OK' ('{0} 张表激活态 A:{1}' -f $tabNames.Count, (($tabNames | Select-Object -First 6) -join ', ')) '' }
  # W3MI 模板在位(程序 SMW0 模板下载场景,WWWDATA 空=运行时报「模板未上传」)
  $w3miNames = @($objects | Where-Object { $_.type -eq 'W3MI' } | ForEach-Object { $_.name } | Select-Object -Unique)
  foreach ($w in $w3miNames) {
    $gr = Get-GateRows $system 'WWWDATA' "SRTF2 = 0 AND RELID = 'MI' AND OBJID = '$w'"
    if (-not $gr.ok) { $g2Status = Add-Gate $g2 $g2Status 'WARN' "W3MI 模板 $w 存在性未验(WWWDATA 查询失败,不阻塞)" ''; continue }
    if ($gr.rows.Count -eq 0) { $g2Status = Add-Gate $g2 $g2Status 'FAIL' "W3MI 模板 $w 在 WWWDATA 无数据(上传模板缺失,运行时报「模板未上传」)" '' }
    else { $g2Status = Add-Gate $g2 $g2Status 'OK' "W3MI 模板 $w 在位" '' }
  }
  # 中文标题
  $gr = Get-GateRows $system 'TRDIRT' "NAME = '$mainProg' AND SPRSL = '1'"
  if ($gr.ok -and $gr.rows.Count -gt 0) { $g2Status = Add-Gate $g2 $g2Status 'OK' ('标题:' + ([string]$gr.rows[0].TEXT)) '' }

  # ============ 5. G3 表↔程序兼容 ============
  $g3 = New-Object System.Collections.Generic.List[object]
  $g3Status = 'PASS'
  # 源码引用的 Z/Y 表(SQL 上下文 + TABLES: 声明;标准表不查;INTO 后 Z 名内表误抓=多查一次无害)
  $reZtab = '(?i)\b(?:FROM|INTO|UPDATE|INSERT|MODIFY|DELETE\s+FROM)\s+([ZY][A-Z0-9_]{2,})\b'
  $zRefs = New-Object System.Collections.Generic.List[string]
  foreach ($m in [regex]::Matches($corpus, $reZtab)) {
    $nm = $m.Groups[1].Value.ToUpperInvariant()
    if ($zRefs -notcontains $nm) { [void]$zRefs.Add($nm) }
  }
  foreach ($m in [regex]::Matches($corpus, '(?im)^\s*TABLES:\s*([^\r\n\.]+)')) {
    foreach ($seg in ($m.Groups[1].Value -split ',')) {
      $nm = ([string]$seg).Trim().ToUpper()
      if ($nm -match '^[ZY][A-Z0-9_]+$' -and $zRefs -notcontains $nm) { [void]$zRefs.Add($nm) }
    }
  }
  $reqObjNames = @($objects | ForEach-Object { $_.name } | Select-Object -Unique)
  foreach ($t in $zRefs) {
    if ($reqObjNames -contains $t) { $g3Status = Add-Gate $g3 $g3Status 'OK' "引用表 $t 在本请求内 ✓" ''; continue }
    $gr = Get-GateRows $system 'E071' "OBJ_NAME = '$t'"
    if (-not $gr.ok) { $g3Status = Add-Gate $g3 $g3Status 'WARN' "引用表 $t 传输历史未验(E071 查询失败)" ''; continue }
    if ($gr.rows.Count -gt 0) { $g3Status = Add-Gate $g3 $g3Status 'OK' "引用表 $t 不在本请求(已随历史请求传过)" '' }
    else { $g3Status = Add-Gate $g3 $g3Status 'WARN' ("程序引用表 $t 从未进过任何传输请求——首次交付必漏。挂进本请求或确认它在目标系统已存在") '' }
  }
  if ($zRefs.Count -eq 0) { $g3Status = Add-Gate $g3 $g3Status 'OK' '源码无 Z/Y 表引用(纯标准表/无落库)' '' }
  # 复合引用字段 ⊆ DD03L 激活字段(「表-字段」形态;SQL 列清单跨表同名不可对准,limitation 如实)
  $allTabs = @(($limuTab + $tabNames + @($zRefs)) | Select-Object -Unique)
  $fieldMiss = New-Object System.Collections.Generic.List[string]
  $fldTabCnt = 0
  foreach ($t in $allTabs) {
    $gr = Get-GateRows $system 'DD03L' "TABNAME = '$t' AND AS4LOCAL = 'A'" 300
    if (-not $gr.ok -or $gr.rows.Count -eq 0) { continue }
    $fldTabCnt++
    $flds = @($gr.rows | ForEach-Object { ([string]$_.FIELDNAME).Trim().ToUpper() })
    foreach ($m in [regex]::Matches($corpus, ('(?i)\b' + [regex]::Escape($t) + '-([A-Z_][A-Z0-9_]*)\b'))) {
      $fn = $m.Groups[1].Value.ToUpperInvariant()
      if ($flds -notcontains $fn) { $fieldMiss.Add("$t-$fn") }
    }
  }
  $fieldMissU = @($fieldMiss | Select-Object -Unique)
  if ($fieldMissU.Count -gt 0) { $g3Status = Add-Gate $g3 $g3Status 'FAIL' ('程序引用了表结构中不存在的字段(运行时必 dump):' + ($fieldMissU -join ', ')) '' }
  else { $g3Status = Add-Gate $g3 $g3Status 'OK' ('复合字段引用比对 {0} 张表全命中' -f $fldTabCnt) '' }
  # 表改动时间 vs 程序最后激活(2026-10-14 实战:表 10-14 09:42 被动过程序 10-13 14:39)
  foreach ($t in (@($limuTab) + @($tabNames) | Select-Object -Unique)) {
    $gr = Get-GateRows $system 'DD02L' "TABNAME = '$t' AND AS4LOCAL = 'A'"
    if (-not $gr.ok -or $gr.rows.Count -eq 0) { continue }
    $td8 = ([string]$gr.rows[0].AS4DATE).Trim(); $tt6 = ([string]$gr.rows[0].AS4TIME).Trim()
    if ($td8 -match '^\d{8}$' -and $progUdat -match '^\d{8}$') {
      $tTime = $tt6.PadRight(6, '0'); $pTime = $progUtime.PadRight(6, '0')
      if (([long]($td8 + $tTime)) -gt ([long]($progUdat + $pTime))) {
        $g3Status = Add-Gate $g3 $g3Status 'WARN' ("表 $t 定义改动($td8 $tt6)晚于程序最后激活($progUdat $progUtime)——表结构变过程序没动,建议 SE38 重新激活程序+复核引用") ''
      }
    }
  }

  # ============ 6. G4 代码质量(整链复用 sap-lint:五关+指纹缓存) ============
  $g4 = New-Object System.Collections.Generic.List[object]
  $g4Status = 'NA'
  $lintRes = $null
  try {
    $lintRaw = & (Join-Path $PSScriptRoot 'sap-lint.ps1') -Body @{ input = @{ system = $system; object = $object } }
    if ($lintRaw.ok) {
      $lintRes = $lintRaw.result
      $g4Status = switch ([string]$lintRes.verdict) { 'FAIL' { 'FAIL' } 'WARN' { 'WARN' } 'ADVISE' { 'WARN' } 'PASS' { 'PASS' } default { 'NA' } }
      $hi = @($lintRes.findings | Where-Object { $_.Severity -eq 'HIGH' }).Count
      $me = @($lintRes.findings | Where-Object { $_.Severity -eq 'MED' }).Count
      $lo = @($lintRes.findings | Where-Object { $_.Severity -eq 'LOW' }).Count
      $lv4 = $(if ($g4Status -eq 'FAIL') { 'FAIL' } elseif ($g4Status -eq 'WARN') { 'WARN' } else { 'OK' })
      $g4Status = Add-Gate $g4 $g4Status $lv4 ('五关审查 {0}:{1} 高危 / {2} 中等 / {3} 建议{4}' -f [string]$lintRes.verdictText, $hi, $me, $lo, $(if ($lintRes.cacheHit) { '(缓存)' } else { '' })) '按五关军规从严判定,含可人工豁免项:FAE 语义自动去重,SORT/去重属建议性;守卫可经外层 IF 传递保证(如驱动表在守卫块内由 LOOP 填充);MAX(主键前缀) 无 WHERE 常为取最新版本的设计意图——逐条看源码片段判读,确属安全的可放行'
    } else {
      $g4Status = Add-Gate $g4 $g4Status 'WARN' ('质量审查未跑成:{0}' -f [string]$lintRaw.error.message) ''
    }
  } catch {
    $g4Status = Add-Gate $g4 $g4Status 'WARN' ('质量审查未跑成:' + $_.Exception.Message) ''
  }

  # ============ 7. G5 需求覆盖(AI,选填;未填需求=NA 豁免) ============
  $g5 = New-Object System.Collections.Generic.List[object]
  $g5Status = 'NA'
  $g5Meta = @{ reqCount = $reqs.Count; model = ''; findings = @(); reqs = @(); summary = ''; truncated = $false }
  if ($reqs.Count -gt 0 -and $totalLines -gt 0) {
    $g5Status = 'WARN'
    # 源码预算 ≤2000 行(lint ai 的 1200 是函数定域场景;门禁对象是整程序,1495 行单程序是常态,放宽防截断)
    $orderAi = @($sources.Keys | Sort-Object)
    $blocks = New-Object System.Collections.Generic.List[string]
    $tot = 0; $trunc5 = $false
    foreach ($k in $orderAi) {
      if ($tot -ge 2000) { $trunc5 = $true; break }
      $ls = @($sources[$k])
      if ($tot + $ls.Count -gt 2000) { $ls = @($ls | Select-Object -First ([Math]::Max(1, 2000 - $tot))); $trunc5 = $true }
      $tot += $ls.Count
      $num = New-Object System.Collections.Generic.List[string]
      for ($li = 0; $li -lt $ls.Count; $li++) { [void]$num.Add(('{0,4}|{1}' -f ($li + 1), $ls[$li])) }
      [void]$blocks.Add(('===== INCLUDE ' + $k + ' =====') + "`n" + ($num.ToArray() -join "`n"))
    }
    $g5Meta.truncated = $trunc5
    $reqLines = New-Object System.Collections.Generic.List[string]
    for ($ri = 0; $ri -lt $reqs.Count; $ri++) { [void]$reqLines.Add(('[R{0}] {1}' -f ($ri + 1), $reqs[$ri])) }
    $sysPrompt = @'
你是资深 SAP ABAP 交付审查专家。对照需求清单逐条核对源码实现,并找逻辑 BUG:
1) 每条需求给 status:PASS=已实现且语义正确 / GAP=完全没实现 / PARTIAL=实现但语义存疑(note 说明疑点)
2) 同时找逻辑 bug:漏校验、sy-subrc 不查、复制粘贴漏改、边界条件(空表/零/负数/月界限)、公式与描述不符
【纪律】evidence 必须逐字摘自源码(≤80字符);宁标 PARTIAL 不编造;需求条目在源码找不到任何痕迹才标 GAP;除 JSON 外不要任何文字。
输出严格 JSON:
{"reqs":[{"no":1,"status":"PASS","evidence":"...","note":"一句话"}],
 "findings":[{"line":123,"severity":"HIGH","message":"...","suggestion":"...","evidence":"..."}],
 "summary":"总评一句话,≤60字"}
'@
    $truncTag = ''
    if ($trunc5) { $truncTag = ';⚠源码超 2000 行已截断,结论仅覆盖可见部分' }
    $usrPrompt = ("审查对象:{0}(system={1},共 {2} 行{3})`n`n【需求清单】`n{4}`n`n【源码】`n" -f $object, $system, $tot, $truncTag, ($reqLines.ToArray() -join "`n")) + ($blocks.ToArray() -join "`n")
    try {
      $aiR = Invoke-SapAi -UserPrompt $usrPrompt -SystemPrompt $sysPrompt -MaxTokens 4096 -Temperature 0.2 -TimeoutSec 180 -Provider 'deepseek' -Throw
      $clean = ([string]$aiR.text).Trim()
      $clean = [regex]::Replace($clean, '(?s)^```(?:json)?\s*', '')
      $clean = [regex]::Replace($clean, '(?s)\s*```\s*$', '')
      $j5 = $clean | ConvertFrom-Json
      $g5Meta.model = [string]$aiR.model
      # 校准:evidence 在源码找不到 → req 降 PARTIAL+注/findings 降 LOW(防幻觉,复用 lint v18 模式)
      $calib = 0
      $reqOut = New-Object System.Collections.Generic.List[object]
      foreach ($r5 in @($j5.reqs)) {
        if (-not $r5) { continue }
        $ev = (([string]$r5.evidence) -replace '\s', '')
        $st = ([string]$r5.status).ToUpper(); $note5 = [string]$r5.note
        if ($ev.Length -ge 4 -and (-not $corpusN.Contains($ev))) {
          if ($st -eq 'PASS') { $st = 'PARTIAL'; $note5 = ($note5 + ';⚠证据未命中源码,降级待人工').Trim(';'); $calib++ }
        }
        $no5 = 0
        if ("$($r5.no)" -match '^\d+$') { $no5 = [Math]::Min([Math]::Max([int]$Matches[0], 1), $reqs.Count) }
        $reqOut.Add(@{ no = $no5; req = $reqs[$no5 - 1]; status = $st; evidence = [string]$r5.evidence; note = $note5 })
      }
      $fOut = New-Object System.Collections.Generic.List[object]
      foreach ($f5 in @($j5.findings)) {
        if (-not $f5) { continue }
        $sev = ([string]$f5.severity).ToUpper(); $ev = (([string]$f5.evidence) -replace '\s', ''); $note5 = ''
        if ($ev.Length -ge 4 -and (-not $corpusN.Contains($ev))) { if ($sev -in @('HIGH', 'MED')) { $sev = 'LOW' }; $note5 = '⚠证据未命中源码,降级待人工'; $calib++ }
        $ln5 = 0
        if ("$($f5.line)" -match '^\d+$') { $ln5 = [int]$Matches[0] }
        $fOut.Add(@{ line = $ln5; severity = $sev; message = [string]$f5.message; suggestion = [string]$f5.suggestion; evidence = [string]$f5.evidence; note = $note5 })
      }
      $g5Meta.reqs = $reqOut.ToArray(); $g5Meta.findings = $fOut.ToArray(); $g5Meta.summary = [string]$j5.summary; $g5Meta.calibrated = $calib
      $nGap = @($reqOut | Where-Object { $_.status -eq 'GAP' }).Count
      $nPart = @($reqOut | Where-Object { $_.status -eq 'PARTIAL' }).Count
      if ($nGap -gt 0) { $g5Status = 'FAIL' } elseif ($nPart -gt 0) { $g5Status = 'WARN' } else { $g5Status = 'PASS' }
      $lv5 = $(if ($g5Status -eq 'FAIL') { 'FAIL' } elseif ($g5Status -eq 'WARN') { 'WARN' } else { 'OK' })
      $g5Status = Add-Gate $g5 $g5Status $lv5 ('需求覆盖 {0}/{1} PASS,{2} GAP,{3} PARTIAL{4};逻辑疑点 {5} 条' -f ($reqOut.Count - $nGap - $nPart), $reqOut.Count, $nGap, $nPart, $(if ($calib -gt 0) { "(校准 $calib)" } else { '' }), $fOut.Count) ([string]$j5.summary)
    } catch {
      $g5Status = 'NA'
      [void]$g5.Add(@{ level = 'WARN'; msg = ('需求覆盖检查未跑成(AI 通道,固定内网 DeepSeek 不降级):' + $_.Exception.Message); detail = '' })
    }
  } elseif ($reqs.Count -gt 0) {
    [void]$g5.Add(@{ level = 'WARN'; msg = '需求要点已填但源码拉取为空,G5 无法执行'; detail = '' })
  }

  # ============ 8. 聚合 verdict(G5 NA=没填需求,豁免不拉黄;G4 NA=审查没跑成,算疑点) ============
  $checks = @(
    @{ id = 'G1'; title = '传输包完整性'; status = $g1Status; items = $g1.ToArray() },
    @{ id = 'G2'; title = '对象健康'; status = $g2Status; items = $g2.ToArray() },
    @{ id = 'G3'; title = '表↔程序兼容'; status = $g3Status; items = $g3.ToArray() },
    @{ id = 'G4'; title = '代码质量(五关)'; status = $g4Status; items = $g4.ToArray() },
    @{ id = 'G5'; title = '需求覆盖(AI)'; status = $g5Status; items = $g5.ToArray() }
  )
  $verdict = 'PASS'; $vText = '✓ 可交付'
  foreach ($c in $checks) { if ($c.status -eq 'FAIL') { $verdict = 'FAIL'; $vText = '✗ 不可交付(先修 FAIL 项)'; break } }
  if ($verdict -ne 'FAIL') {
    foreach ($c in $checks) {
      if ($c.id -eq 'G5' -and $c.status -eq 'NA') { continue }   # 没填需求是正常态
      if ($c.status -in @('WARN', 'NA')) { $verdict = 'WARN'; $vText = '⚠ 有疑点,人工复核后交付'; break }
    }
  }
  $fails = @(); $warns = @()
  foreach ($c in $checks) {
    foreach ($it in $c.items) {
      if ($it.level -eq 'FAIL') { $fails += ('[{0}] {1}' -f $c.id, $it.msg) }
      elseif ($it.level -eq 'WARN') { $warns += ('[{0}] {1}' -f $c.id, $it.msg) }
    }
  }
  $summary = if ($verdict -eq 'PASS') { '五段全绿,可以放行给顾问测试' }
    elseif ($fails.Count -gt 0) { ('FAIL {0} 项:{1}' -f $fails.Count, (($fails | Select-Object -First 2) -join ';')) }
    else { ('WARN {0} 项:{1}' -f $warns.Count, (($warns | Select-Object -First 2) -join ';')) }

  $limitations = @(
    'AI 需求覆盖(G5)是第二双眼睛,不保证穷尽;采纳前人工核对行号与代码',
    'G3 字段比对只覆盖「表-字段」复合引用形态,SQL 列清单(SELECT a b FROM t)跨表同名不可对准,不在比对范围',
    'LIMU↔R3TR 配对查的是全传输体系有无主对象行,不校验目标系统(QAS)实际是否已有该表——有凭证时可用「传输形态·按对象分析」三系统矩阵复核',
    'G4 复用质量审查路由,能力边界同五关声明(动态 SQL/动态表不判);FAE 三要素按军规从严,守卫传递/FAE 自动去重/MAX 取最新版本等场景人工判读可豁免'
  )

  $rep = @{
    tool = 'delivery_gate'; system = $system; object = $object
    resolvedVia = $resolvedVia; objType = $objType
    mainProg = $mainProg; tcode = $tcode; func = $func
    targetTr = $targetTr; targetStatus = $(if ($th) { [string]$th.status } else { '' })
    tasks = @($reqKeys | Where-Object { $_ -ne $targetTr })
    requestText = $(if ($th) { [string]$th.text } else { '' })
    objects = $objects
    verdict = $verdict; verdictText = $vText; summary = $summary
    checks = $checks
    g4 = $(if ($lintRes) { @{ verdict = [string]$lintRes.verdict; verdictText = [string]$lintRes.verdictText; findings = @($lintRes.findings); passes = @($lintRes.passes); selectAudit = @($lintRes.selectAudit); limitations = @($lintRes.limitations) } } else { $null })
    g5 = $g5Meta
    srcLines = $totalLines; srcFiles = $sources.Count; srcCapHit = $srcCap
    fingerprint = $fp
    cacheHit = $false; durMs = $sw.ElapsedMilliseconds
    limitations = $limitations
  }

  try {
    if (-not $cache) { $cache = Get-SapCacheMap -Path (Join-Path $cacheDir ("gate-$system.json")) }
    $rep.cachedAt = (Get-Date).ToString('o')
    $cache[$fp] = $rep
    if ($cache.Count -gt 30) {
      $keep = @($cache.Keys | Sort-Object { $cache[$_].cachedAt } -Descending | Select-Object -First 30)
      $pruned = @{}
      foreach ($k in $keep) { $pruned[$k] = $cache[$k] }
      $cache = $pruned
    }
    Save-SapCacheMap -Path (Join-Path $cacheDir ("gate-$system.json")) -Map $cache
  } catch { }

  return @{ ok = $true; result = $rep }
} catch {
  if ($_.Exception.Data['FacadeCode']) {
    return @{ ok = $false; error = @{ code = [string]$_.Exception.Data['FacadeCode']; message = [string]$_.Exception.Data['FacadeMessage'] } }
  }
  return (Fail 'GATE_FAILED' $_.Exception.Message)
}
