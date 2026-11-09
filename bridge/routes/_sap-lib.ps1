# ============================================================
# _sap-lib  -  SAP Driver 路由层共享函数库(2026-09-16 批四整合)。
# 文件名 _ 开头,_registry.ps1 不会当成路由暴露。
#
# 为什么要有这个文件:对抗审查实爆 Invoke-FacadeTool 有 6 份副本且**已实际分叉**——
# 默认超时 60/100/110s 各异、diagnose 版缺 facadeHttpMs、错误解析行为不同;JSON 拍平
# ×9、JSON map 缓存读写 ×6、进度上报 ×2、AI 调用样板 ×5 全是拷贝件。收敛到这里,
# 一次修对处普适。Fail()(1 行 ×12)有意不收编:触碰面大收益≈0。
#
# 依赖:dot-source 本文件前先 dot-source _sap-facade.ps1(本文件顶部会再 dot-source
# 一次,幂等);用到 AI 的路由 sap-ask/sap-diagnose/sap-probe 另需 dot-source
# _claude-helpers.ps1(Invoke-SapAi 依赖 Invoke-KbClaude,按动态作用域解析)。
# ============================================================

. (Join-Path $PSScriptRoot '_sap-facade.ps1')

# ---------- 共享常量 ----------
$global:SapProbeCacheDir = if ($env:SAP_PROBE_CACHE_DIR) { $env:SAP_PROBE_CACHE_DIR } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'sap-mcp-probe' }   # env 可覆盖,缺省=仓库 data/sap-mcp-probe
$global:SapProgressDir   = if ($env:SAP_PROGRESS_DIR) { $env:SAP_PROGRESS_DIR } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'sap-mcp-ask' }   # ask/diagnose 进度文件目录

# ---------- JSON 拍平(原 5+4 份拷贝) ----------
function ConvertTo-FlatHashtable {
  # IRM 反序列化产物是 PSCustomObject:$o.x=v 炸、$o['k'] 静默 null——浅拍平 hashtable。
  param($Obj)
  if ($null -eq $Obj) { return @{} }
  $h = @{}
  foreach ($p in @($Obj.PSObject.Properties)) { $h[$p.Name] = $p.Value }
  return $h
}

function ConvertTo-MutHashTable {
  # 深度递归转 hashtable(内外码转换要就地改值,PSCustomObject 改不动)。
  # ★空数组必须就地直写不走递归:函数 return @() 被管道展开成零输出→赋值变 $null→
  #   ConvertTo-Json 把 $null 键写成 {}(ddix 缓存毒条目生成器,09-17 ZUTIL_004 实爆链一环)。
  # ★数组型子值必须保形赋值(@(...)):裸赋值对 1 元素数组会因输出展开降级成标量
  #   ("Tables":"ZFG_BPM"→前端 .join 炸=结果卡渲染崩=加载态永转,09-17 用户实爆第二环)。
  param($Obj)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    $out = @{}
    foreach ($k in @($Obj.Keys)) {
      $v = $Obj[$k]
      if ($null -ne $v -and $v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and @($v).Count -eq 0) { $out[$k] = @() }
      elseif ($null -ne $v -and $v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and $v -isnot [System.Collections.IDictionary]) { $out[$k] = @(ConvertTo-MutHashTable $v) }
      else { $out[$k] = ConvertTo-MutHashTable $v }
    }
    return $out
  }
  if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
    $list = @()
    foreach ($v in @($Obj)) { $list += ,(ConvertTo-MutHashTable $v) }
    return $list
  }
  if ($Obj -is [pscustomobject]) {
    $h = @{}
    foreach ($p in @($Obj.PSObject.Properties)) {
      $v = $p.Value
      if ($null -ne $v -and $v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and @($v).Count -eq 0) { $h[$p.Name] = @() }
      elseif ($null -ne $v -and $v -is [System.Collections.IEnumerable] -and $v -isnot [string] -and $v -isnot [System.Collections.IDictionary]) { $h[$p.Name] = @(ConvertTo-MutHashTable $v) }
      else { $h[$p.Name] = ConvertTo-MutHashTable $v }
    }
    return $h
  }
  return $Obj
}

# ---------- facade 工具调用(原 6 份副本,已分叉:60/100/110s、facadeHttpMs 缺失) ----------
function Invoke-FacadeTool {
  # 统一默认超时 110s(取各副本最大值;前端/bridge 闸在其前面,放宽只会更少误杀);
  # 错误归一:HTTP 失败→FACADE_HTTP_FAILED/FACADE_TIMEOUT,facade 业务错→原样透传 code
  # (NEED_CREDENTIAL 判据在此,丢了前端凭证闸就静默失效——2026-09-14 实爆教训)。
  param([Parameter(Mandatory)][string]$Tool, [Parameter(Mandatory)][hashtable]$Args, [int]$TimeoutSec = 110)
  $json = $Args | ConvertTo-Json -Depth 24 -Compress
  $r = Invoke-SapFacadeApi -Method POST -Path "/run/$Tool" -JsonBody $json -TimeoutSec $TimeoutSec
  if (-not $r.ok) {
    $code = 'FACADE_HTTP_FAILED'
    if ($r.error -match 'timed out|timeout') { $code = 'FACADE_TIMEOUT' }
    return @{ ok = $false; error = @{ code = $code; message = [string]$r.error } }
  }
  $out = ConvertTo-FlatHashtable $r.data
  if ($out.ok -eq $false) {
    # facade 错误返回体是顶层 {ok:false,code,message},无 error 嵌套(2026-09-14 实测)
    $err = $out.error
    $ec = 'FACADE_ERROR'; $em = 'facade 返回失败'
    if ($err) {
      $errFlat = ConvertTo-FlatHashtable $err
      if ($errFlat.code) { $ec = [string]$errFlat.code }
      if ($errFlat.message) { $em = [string]$errFlat.message }
    } else {
      if ($out.code) { $ec = [string]$out.code }
      if ($out.message) { $em = [string]$out.message }
    }
    return @{ ok = $false; error = @{ code = $ec; message = $em } }
  }
  return @{ ok = $true; data = (ConvertTo-FlatHashtable $out.result); facadeHttpMs = [long]$r.httpMs }
}

function Initialize-SapRoute {
  # SAP 路由开头统一调一次:facade 死了 WMI 拉起。09-16 审查实爆:xref/codesearch/lint
  # 三个重型路由没有自愈,facade 死了直接 FACADE_HTTP_FAILED,与 ask/tool/status 行为不一。
  # 活着时 = 一次 ~2ms health 探测,可忽略。
  $up = Ensure-SapFacade
  if (-not $up.running) {
    throw "FACADE_DOWN: facade 拉起后仍无响应(端口占用/启动失败?)。可查 sap-mcp 目录手工排障。"
  }
  return $up
}

# ---------- JSON map 缓存读写(原 6 处内联:lint/dirt/e070/fphash/codesearch) ----------
function Get-SapCacheMap {
  # 格式 {fetchedAt, map:{k:v}};TtlDays>0 时超龄返回空表(当失效)。
  # 兼容旧平格式(无 map 包装,如 fphash-<SYS>.json 早期文件)。
  param([Parameter(Mandatory)][string]$Path, [double]$TtlDays = 0)
  try {
    if (Test-Path $Path) {
      $j = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.PSObject.Properties['map']) {
        if ($TtlDays -gt 0 -and $j.PSObject.Properties['fetchedAt']) {
          try { if (((Get-Date) - [datetime]$j.fetchedAt).TotalDays -ge $TtlDays) { return @{} } } catch { }
        }
        return ConvertTo-MutHashTable $j.map
      }
      return ConvertTo-MutHashTable $j
    }
  } catch { }
  return @{}
}

function Save-SapCacheMap {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Map)
  try {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    @{ fetchedAt = (Get-Date).ToString('o'); map = $Map } | ConvertTo-Json -Depth 12 -Compress |
      Set-Content -Path $Path -Encoding UTF8
  } catch { }
}

# ---------- 体检故障摘要(周报/月报综合分析 + diagpack digest 共用;v16.2 新增) ----------
function Get-SapHealthDigest {
  # 轻量三节:SNAP 近 7 天 dump / VBMOD 失败模块 / TBTCO 近 7 天取消。
  # 口径与阈值同 diagpack 主体(≥1 dump=WARN ≥100=CRIT;失败模块≥1=CRIT;取消≥1=WARN);
  # 另取各节 top 明细(模块名/账号/作业名 top3)——负载周报 AI 综合分析用「找谁确认什么」级别输入。
  # 单节失败置 $null+notes 记因,绝不炸调用方。4 次轻查询 ~2-3s;
  # ★PRD 实测例外:VBMOD 无索引全扫单查 ~83s(体检页签同款慢点)→结果按系统缓存 4 小时——
  #   周报/月报每次 run 都带 digest,不缓存则 PRD 每次都 +83s(2026-09-17 实爆 92.5s 构成主项)。
  param([Parameter(Mandatory)][string]$System)
  $cacheFile = Join-Path $global:SapProbeCacheDir "health-digest-$System.json"
  try {
    if (Test-Path $cacheFile) {
      $j = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($j.PSObject.Properties['fetchedAt'] -and ((Get-Date) - [datetime]$j.fetchedAt).TotalHours -lt 4) {
        return (ConvertTo-MutHashTable $j.digest)
      }
    }
  } catch { }
  $d = @{ st22Dumps = $null; sm13Failed = $null; jobsCanceled = $null
          sm13TopFuncs = @(); st22TopUsers = @(); jobsTopNames = @(); notes = @() }
  $d7 = (Get-Date).AddDays(-7).ToString('yyyyMMdd')
  try {
    $q = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $System; table = 'SNAP'; where = "DATUM >= '$d7'"; maxRows = 1 }
    if ($q.ok) { $d.st22Dumps = [int]$q.data.rowCount } else { $d.notes += "ST22 读取失败($($q.error.code))" }
  } catch { $d.notes += "ST22 读取失败" }
  if ($null -ne $d.st22Dumps -and $d.st22Dumps -gt 0) {
    try {
      # 样本聚合(控制字符风险:diagpack 同款 100 条样本 try/catch,失败不影响计数)
      $q2 = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $System; table = 'SNAP'; where = "DATUM >= '$d7'"; maxRows = 100 }
      if ($q2.ok) {
        $smp = @(ConvertTo-MutHashTable $q2.data.rows)
        $byUser = @{}
        foreach ($r in $smp) { $u = "$($r.UNAME)".ToUpper(); if ($u) { if (-not $byUser.ContainsKey($u)) { $byUser[$u] = 0 }; $byUser[$u]++ } }
        $d.st22TopUsers = @($byUser.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key)($($_.Value))" })
      }
    } catch { $d.st22TopUsers = @() }
  }
  try {
    $q = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $System; table = 'VBMOD'; where = "VBRC <> '0'"; maxRows = 100 }
    if ($q.ok) {
      $rows = @(ConvertTo-MutHashTable $q.data.rows)
      # ★口径与 diagpack 主体对齐(行数,≤100 截断如实)——rowCount 全量口径在 PRD 实测 6,756 万
      #   (历史 VBRC<>0 堆积),与体检页「失败模块 N 个」完全对不上,摘要会吓到人(09-17 实爆)。
      $d.sm13Failed = $rows.Count
      $d.sm13Truncated = ($rows.Count -ge 100)
      $byF = @{}
      foreach ($r in $rows) { $f = "$($r.VBFUNC)".Trim(); if ($f) { if (-not $byF.ContainsKey($f)) { $byF[$f] = 0 }; $byF[$f]++ } }
      $d.sm13TopFuncs = @($byF.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key)($($_.Value))" })
    } else { $d.notes += "SM13 读取失败($($q.error.code))" }
  } catch { $d.notes += "SM13 读取失败" }
  try {
    $q = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $System; table = 'TBTCO'; where = "STATUS = 'A' AND ENDDATE >= '$d7'"; maxRows = 100 }
    if ($q.ok) {
      $rows = @(ConvertTo-MutHashTable $q.data.rows)
      $d.jobsCanceled = [int]$q.data.rowCount
      $byJ = @{}
      foreach ($r in $rows) { $j = "$($r.JOBNAME)".Trim(); if ($j) { if (-not $byJ.ContainsKey($j)) { $byJ[$j] = 0 }; $byJ[$j]++ } }
      $d.jobsTopNames = @($byJ.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key)($($_.Value))" })
    } else { $d.notes += "作业读取失败($($q.error.code))" }
  } catch { $d.notes += "作业读取失败" }
  $rank = @{ OK = 0; WARN = 1; CRIT = 2 }; $d.overall = 'OK'
  $bump = { param($st) if ($st -in @('WARN', 'CRIT') -and $rank[$st] -gt $rank[$d.overall]) { $d.overall = $st } }
  if ($null -ne $d.st22Dumps) { if ($d.st22Dumps -ge 100) { & $bump 'CRIT' } elseif ($d.st22Dumps -ge 1) { & $bump 'WARN' } }
  if ($null -ne $d.sm13Failed -and $d.sm13Failed -ge 1) { & $bump 'CRIT' }
  if ($null -ne $d.jobsCanceled -and $d.jobsCanceled -ge 1) { & $bump 'WARN' }
  # 全节失败不落盘(09-18 审查 C4):三节查询全炸(facade 刚挂/凭证失效)时摘要全 null,
  # 落盘=把「假健康」钉进缓存 4 小时——只回本次、不毒化后续
  $anySuccess = ($null -ne $d.st22Dumps) -or ($null -ne $d.sm13Failed) -or ($null -ne $d.jobsCanceled)
  if ($anySuccess) {
    try {
      @{ fetchedAt = (Get-Date).ToString('o'); digest = $d } | ConvertTo-Json -Depth 8 -Compress |
        Set-Content -Path $cacheFile -Encoding UTF8
    } catch { }   # 缓存尽力而为
  }
  return $d
}

# ---------- 表查询行集(原 lint/diagpack 两份) ----------
function Get-QueryRows {
  # sap_query → 行数组(hashtable);失败上抛,附 FacadeCode 供路由透传(NEED_CREDENTIAL 判据)。
  param([Parameter(Mandatory)][string]$System, [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$Where, [int]$MaxRows = 100)
  $r = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $System; table = $Table; where = $Where; maxRows = $MaxRows }
  if (-not $r.ok) {
    $e = New-Object System.Management.Automation.RuntimeException("$($r.error.code): $($r.error.message)")
    $e.Data['FacadeCode'] = [string]$r.error.code
    $e.Data['FacadeMessage'] = [string]$r.error.message
    throw $e
  }
  # 无逗号:,@(数组) 会双重包裹成 Object[1]{Object[N]},调用方 foreach 只见 1 个内层数组
  # (字段访问变空格拼接垃圾键,DD03L/DD17S 批量分组全失效→假空索引元数据,09-17 实爆);
  # return @() 让行集平铺输出,调用方 @(Get-QueryRows ...) 直接得扁平行数组。
  return @(ConvertTo-MutHashTable $r.data.rows)
}

# ---------- 进度上报(原 ask/diagnose 两份同构 + 非原子写) ----------
function Write-SapProgress {
  # 进度文件原子替换(v15):WriteAllText 非原子,轮询撞上正在写的半截 JSON 时
  # found:false 被契约当成「已完成」。文件删除=完成信号(由各路由收尾自理)。
  param([string]$File, [string]$Phase, [int]$Step, [int]$Total, [string]$Tool)
  if (-not $File) { return }
  try {
    $dir = Split-Path $File -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $o = [ordered]@{ phase = $Phase; step = $Step; total = $Total; tool = $Tool
                     ts = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    $tmp = "$File.tmp"
    [System.IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Compress))
    if (Test-Path $File) { [System.IO.File]::Replace($tmp, $File, $null) }
    else { [System.IO.File]::Move($tmp, $File) }
  } catch { }   # 进度是尽力而为,绝不影响主流程
}

# ---------- AI 调用样板(原 5 处 try{Invoke-KbClaude→text/model}catch{} 同构) ----------
function Invoke-SapAi {
  # 失败返回 $null(-Throw 时抛出);成功 @{ text; model }。依赖调用方已 dot-source _claude-helpers.ps1。
  # TimeoutSec 默认 120(v15 前 6 处全吃 Invoke-KbClaude 默认 300s,最坏挂路由 ~10 分钟)。
  # v16:-Provider 透传(公司源码审查等场景固定 deepseek 内网,不降级外网);-Throw 供需要向用户透出失败原因的调用方。
  param([Parameter(Mandatory)][string]$UserPrompt, [Parameter(Mandatory)][string]$SystemPrompt,
        [int]$MaxTokens = 2000, [double]$Temperature = 0.3, [int]$TimeoutSec = 120,
        [ValidateSet('auto', 'deepseek')][string]$Provider = 'auto', [switch]$Throw)
  try {
    $r = Invoke-KbClaude -UserPrompt $UserPrompt -SystemPrompt $SystemPrompt -MaxTokens $MaxTokens -Temperature $Temperature -NoThinking -TimeoutSec $TimeoutSec -Provider $Provider
    if ($r -and $r.text) { return @{ text = [string]$r.text; model = $(if ($r.model) { [string]$r.model } else { '' }) } }
    if ($Throw) { throw 'AI 返回空' }
  } catch {
    if ($Throw) { throw }
  }
  return $null
}

function Get-SapNextHint {
  # <!--NEXT:...--> 提取并剥离(ask 汇总 / diagnose 终裁同款);返回 @{ answer; nextHint }。
  param([Parameter(Mandatory)][string]$Answer)
  $hint = ''
  if ($Answer -match '<!--NEXT:(.+?)-->') {
    $hint = $Matches[1].Trim()
    $Answer = ($Answer -replace '\r?\n?<!--NEXT:.+?-->', '').Trim()
  }
  return @{ answer = $Answer; nextHint = $hint }
}
function Get-SapObjectRef {
  # 对象识别链单源(2026-09-21 审查 P2:sap-lint/sap-xref 各写一份 TSTC→TFDIR→兜底且已漂移——
  # lint 凭证类错误上抛其余吞,xref 全静默吞;lint 无 TADIR 层,xref 有)。统一链:
  # TSTC(TCODE→PGMNA,空不采纳)→ TFDIR(FUNCNAME→PNAME,+SAPL<grp> 组名)→
  # TADIR(R3TR→OBJECT;★PGMID 真值=R3TR 非 R3T——原 xref 写 R3T 恒 0 行=该层从未生效,2026-09-21 实测修正;FUGR 切组主程序空间 SAPL<inp>)→ 原样当 PROG。
  # -ThrowOnFacadeError:查询失败带 FacadeCode 上抛(lint 用,NEED_CREDENTIAL 透传红线);
  #   默认吞掉继续降级(xref 容忍部分失败)。非凭证类表级错误两层都吞(降级下一识别)。
  # 返回 @{ ok=$true; kind=TRAN/FUNC/FUGR/PROG; objType; tcode; func; prog; grp; via } 或
  #       @{ ok=$false; code=TCODE_NO_PROG; message }。
  param([Parameter(Mandatory)][string]$System, [Parameter(Mandatory)][string]$Name,
        [switch]$ThrowOnFacadeError)
  $inp = ("$Name").Trim().ToUpper()
  $tcode = ''; $func = ''; $prog = $inp; $kind = 'PROG'; $grp = ''; $via = 'program'; $objType = 'PROG'
  try {
    $rows = @(Get-QueryRows -System $System -Table 'TSTC' -Where "TCODE = '$inp'" -MaxRows 1)
    if ($rows.Count -gt 0 -and ([string]$rows[0].PGMNA).Trim()) {
      $tcode = $inp; $prog = ([string]$rows[0].PGMNA).Trim().ToUpper(); $kind = 'TRAN'; $objType = 'TRAN'; $via = 'tcode'
    }
  } catch {
    if ($ThrowOnFacadeError -and $_.Exception.Data['FacadeCode']) { throw }
  }
  if ($kind -eq 'PROG') {
    try {
      $rows = @(Get-QueryRows -System $System -Table 'TFDIR' -Where "FUNCNAME = '$inp'" -MaxRows 1)
      if ($rows.Count -gt 0 -and ([string]$rows[0].PNAME).Trim()) {
        $func = $inp; $prog = ([string]$rows[0].PNAME).Trim().ToUpper(); $kind = 'FUNC'; $objType = 'FUNC'; $via = 'function'
        if ($prog -match '^SAPL(.+)$') { $grp = $Matches[1] }
      }
    } catch {
      if ($ThrowOnFacadeError -and $_.Exception.Data['FacadeCode']) { throw }
    }
  }
  if ($kind -eq 'PROG') {
    try {
      $rows = @(Get-QueryRows -System $System -Table 'TADIR' -Where "PGMID = 'R3TR' AND OBJ_NAME = '$inp'" -MaxRows 1)
      if ($rows.Count -gt 0) {
        $objType = ([string]$rows[0].OBJECT).Trim()
        if ($objType -eq 'FUGR') { $grp = $inp; $prog = 'SAPL' + $inp; $kind = 'FUGR'; $via = 'tadir-fugr' }
        elseif ($objType -ne 'PROG') { $via = 'tadir-' + $objType.ToLower() }
      }
    } catch {
      if ($ThrowOnFacadeError -and $_.Exception.Data['FacadeCode']) { throw }
    }
  }
  if (-not $prog) { return @{ ok = $false; code = 'TCODE_NO_PROG'; message = "$inp 在 $System 未识别为事务码/函数,也无法当程序名溯源" } }
  return @{ ok = $true; kind = $kind; objType = $objType; tcode = $tcode; func = $func; prog = $prog; grp = $grp; via = $via }
}
