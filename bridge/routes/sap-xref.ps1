param([Parameter(Mandatory)][hashtable]$Body)

# sap-xref  -  SAP Driver「🔗 引用」路由(v10 2026-09-15;v12 影响分析改造 2026-09-15)。
# 场景:接口排查时搞清「这个表/结构/字段/函数组被哪些程序用」「这段逻辑在哪个程序」。
# 数据源零部署:WBCROSSGT(workbench 交叉引用,激活对象全量)+ REPOSRC + TRDIRT(程序标题)。
# 只读通道全程 sap_query / sap_prog_read(ZLILY_DIAG_Q3 / ZLILY_DIAG_UNPACK),PRD 只读可用。
#
# action:
#   whereused { system, name, field? }   → NAME='X' 或 field 给了 → NAME='X\TY:FIELD'
#                                            v12: 附带 titles(REPID→标题,TRDIRT 批量)
#   uses      { system, include }        → 反向:该程序引用了什么(WHERE INCLUDE=)· v12 同样补标题
#   search    { system, kw }             → REPOSRC 按名搜 + TRDIRT 按标题搜(descHits,中文可搜)
#   code      { system, include, name?, field?, otype? } → 拉该 include 源码,按 OTYPE 定位引用行
#                                            (±2 行上下文分段;主模式零命中回退全词;附 head300 兜底)
#   tr / trlist                          → v11 传输查询(E070/E071),见各分支
#
# 名字护栏:统一 UPPER;剥掉引号/分号(动态 WHERE 字面量防注入);\TY: 转发支持。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')   # v15 整合:facade工具/缓存读写收敛到共享件

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

function Clean-Name([string]$s) {
  # 对象名护栏:UPPER + 剥引号/分号/注释符(WHERE 字面量注入面收窄;逐个 Replace 免正则字符类坑)
  $s = ([string]$s).Trim().ToUpper()
  foreach ($ch in @("'", '`', ';', '-')) { $s = $s.Replace($ch, '') }
  return $s
}

function Get-MainName([string]$inc) {
  # include → 主程序归组(启发式):函数组 include L组名UXX/F01/TOP → SAPL组;
  # 报表 include 去尾部 TOP/Fnn/Onn/Inn/Enn/Dnn/Pnn/Snn;类池去 '=' 填充(CL_X====CP → CL_X)。
  if ($inc -match '^L(.+?)(?:UXX|(?:F|O|I|E|U|D|P|S|V|X)\d\d|TOP)$') { return 'SAPL' + $Matches[1] }
  if ($inc -match '^(.+?)(?:TOP|(?:F|O|I|E|D|P|S)\d\d)$') { return $Matches[1] }
  if ($inc -match '^([A-Z][A-Z0-9_/]*?)=+') { return $Matches[1] }
  return $inc
}

function Get-SrcFingerprint {
  # v13.3 双指纹:full=全文 SHA256 前 16 hex;code=剥离整行注释后的代码 SHA256 前 16 hex。
  # ★为什么不用 REPOSRC 时间戳跨系统比(09-16 用户实爆 ZRPT1003 假阳性):**导入会重写目标系统
  #   的 UDAT/UTIME 为导入时刻**,时间戳「指纹」同版本必判不一致,口径根本错误。内容 hash 唯一真解。
  # ★为什么要 code 指纹(09-16 二次实爆 ZRPT1003):PRD 与 DVP 全文唯一差异是一行注释编号
  #   (2.2.*.* vs 2.2.1.1),全文 hash 亮「不一致」橙灯实属虚惊——剥离注释后可区分
  #   「仅注释差异」与「真代码差异」。
  #   注释行口径:首个非空白字符为 * 或 " 的整行(ABAP 行首 * 必为注释;行内 " 不剥——
  #   字符串字面量里合法出现,无法安全识别)。
  # 缓存:fphash-<SYS>.json,key = "PROG|UNAM|UDAT|UTIME",值 "full:code" 打包——
  #   对象未改(key 不变)永久零成本;跨程序共享。旧格式(无冒号,仅 full)视为半条:
  #   重读源码补齐 code 后覆盖。
  param([string]$System, [string]$Prog, [string]$Unam, [string]$Udat, [string]$Utime, $Cache)
  $key = "$Prog|$Unam|$Udat|$Utime"
  if ($Cache.ContainsKey($key)) {
    $v = [string]$Cache[$key]
    if ($v.Contains(':')) { $pp = $v -split ':', 2; return @{ hash = $pp[0]; code = $pp[1] } }
  }
  # readfail 不缓存(79-83 行注释):网络/凭证类失败下次重试。v15 删只读不写的 ERR| 哨兵死分支。
  $r = Invoke-FacadeTool -Tool 'sap_prog_read' -Args @{ system = $System; program = $Prog } -TimeoutSec 60
  if (-not $r.ok) {
    # REPOSRC 无此对象(未传)是常态;其它错误(网络/凭证)也暂标 readfail,下次重试(不缓存)
    if ($r.error.code -eq 'READ_FAILED') { return @{ miss = $true } }
    return @{ readfail = $true }
  }
  $lines = ([string]$r.data.source) -split "`r?`n"
  $norm = ($lines | ForEach-Object { $_.TrimEnd() }) -join "`n"
  $code = ($lines | Where-Object { $_ -notmatch '^\s*[\*"]' } | ForEach-Object { $_.TrimEnd() }) -join "`n"
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h1 = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm)))).Replace('-', '').Substring(0, 16).ToLower()
  $h2 = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($code)))).Replace('-', '').Substring(0, 16).ToLower()
  $Cache[$key] = "$h1`:$h2"
  return @{ hash = $h1; code = $h2 }
}

function Test-XrefCustom([string]$name) {
  # 自定义判定:Z*/Y* 或 /NSP/ 命名空间;SAPL+Z/Y = Z/Y 函数组主程序。
  # ★不能把裸 '/' 放进字符类——/ISDFPS/ 等 SAP 行业命名空间会被误判成自定义,
  #   字母序又排最前,曾把 60 个标题查询名额全部占掉(09-15 实爆 titles=0)。
  if ($name.StartsWith('/NSP/')) { return $true }
  if ($name -match '^[ZY]') { return $true }
  if ($name.StartsWith('SAPL') -and $name.Length -gt 4 -and ($name[4] -eq 'Z' -or $name[4] -eq 'Y')) { return $true }
  return $false
}

function Get-XrefTitleTargets([string[]]$incs) {
  # 引用行 include 清单 → 标题查询目标(主程序 ∪ include 自身),自定义 Z/Y 优先
  $targets = New-Object System.Collections.Generic.List[string]
  foreach ($inc in $incs) {
    $m = Get-MainName $inc
    if ($m -and $m -ne $inc -and -not $targets.Contains($m)) { $targets.Add($m) }
    if (-not $targets.Contains($inc)) { $targets.Add($inc) }
  }
  return @(@($targets | Where-Object { Test-XrefCustom $_ }) + @($targets | Where-Object { -not (Test-XrefCustom $_) }))
}

function Get-DirtTitles {
  # 程序标题(只读增强)——「全量拉 Z/Y 标题 + 本地缓存 7 天」策略:
  # ★为什么不做多行 OR 批查(09-15 三连实爆):ZLILY_DIAG_Q3 的 IT_WHERE 多行拼接会丢
  #   行尾空格,chunk72 切分点落在哪坏哪(87 字符 2 行就报「列 NAME= 未知」),不可用。
  #   单行 LIKE 零风险 → 干脆 Z%/SAPLZ%/Y%/SAPLY% 四条单行全量拉,缓存本地,
  #   冷启动 4 次查询(~0.6s),7 天内 0 次 SAP 调用。
  # ★TRDIRT 程序名字段 = NAME(非 REPID);标题语言优先 中文>英文>德文>其他。
  param([string]$System, [string[]]$Reps)
  $out = @{}; $errs = New-Object System.Collections.Generic.List[string]
  if (-not $Reps -or -not $Reps.Count) { return @{ titles = $out; errs = $errs } }
  $cacheFile = Join-Path $global:SapProbeCacheDir ("dirt-" + $System + ".json")
  $map = @{}
  $cachedDirt = Get-SapCacheMap -Path $cacheFile -TtlDays 7
  foreach ($k in @($cachedDirt.Keys)) { $map[$k] = @{ text = [string]$cachedDirt[$k]; prio = 0 } }
  if (-not $map -or $map.Count -eq 0) {
    foreach ($pref in @('Z%', 'SAPLZ%', 'Y%', 'SAPLY%')) {
      try {
        $r = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $System; table = 'TRDIRT'; maxRows = 1000; where = "NAME LIKE '$pref'" }
        if (-not $r.ok) { $errs.Add("${pref}: " + [string]$r.error.message); continue }
        foreach ($row in $r.data.rows) {
          $rep = [string]$row.NAME; $sp = [string]$row.SPRSL; $tx = ([string]$row.TEXT).Trim()
          if (-not $rep -or -not $tx) { continue }
          $prio = switch ($sp) { '1' { 0 } 'E' { 2 } 'D' { 3 } default { 4 } }
          $cur = $map[$rep]
          if (-not $cur -or $prio -lt $cur.prio) { $map[$rep] = @{ text = $tx; prio = $prio } }
        }
      } catch { $errs.Add("${pref}: " + $_.Exception.Message) }
    }
    if ($map.Count -gt 0) {
      $snap = @{}
      foreach ($k in $map.Keys) { $snap[$k] = [string]$map[$k].text }
      Save-SapCacheMap -Path $cacheFile -Map $snap
    }
  }
  foreach ($rep in $Reps) {
    $hit = $map[$rep]
    if ($hit) { $out[$rep] = @{ text = [string]$hit.text; prio = [int]$hit.prio } }
  }
  return @{ titles = $out; errs = $errs }
}

$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$action = ([string]$input_.action).Trim()
if (-not $action) { return (Fail 'BAD_ACTION' 'action required') }
$system = ([string]$input_.system).Trim().ToUpper()
if ($system -notin @('DVP', 'QAS', 'PRD')) { return (Fail 'BAD_SYSTEM' "system 必须是 DVP/QAS/PRD,收到: '$system'") }
Initialize-SapRoute | Out-Null   # v15:facade 死了 WMI 拉起(原三个重型路由之一,无自愈)

try {
  switch ($action) {

    'whereused' {
      $name = Clean-Name $input_.name
      if (-not $name) { return (Fail 'BAD_PARAM' 'name 必填') }
      $field = Clean-Name $input_.field
      if (-not $field -and $name.Contains('.')) {
        # 路由兜底拆「表.字段」(前端已拆时 field 直传,不受影响)
        $i = $name.IndexOf('.')
        $field = $name.Substring($i + 1)
        $name = $name.Substring(0, $i)
      }
      # 字段级:WBCROSSGT 记类型引用为 OBJ\TY:FIELD(09-15 实测 MARA\TY:MATNR)
      $val = if ($field) { "$name\TY:$field" } else { $name }
      $r = Invoke-FacadeTool -Tool 'sap_query' -Args @{
        system = $system; table = 'WBCROSSGT'
        where = @(@{ field = 'NAME'; op = '='; value = $val })
        maxRows = 1000
      }
      if (-not $r.ok) { return $r }
      # v12:自定义专项补全——大对象引用上千行,主查询 maxRows=1000 截断后自定义程序
      # 可能整批丢在后面(09-15 实爆 MARA.MATNR 8181 行)。专项 LIKE 抓 Z*/Y*/LZ*/LY*
      # (L+Z = Z 开头函数组的 include),保证影响分析里自定义程序永远齐全。
      # v15 截断门控:rowCount=全量匹配数(Q3 语义),≤1000 = 行集完整、补查必是已合并数据的
      # 子集——白烧一次往返。仅截断时(moreAvailable 或 rowCount>1000)才发。
      $rows = @($r.data.rows); $customCount = 0; $customMore = $false
      $truncated = [bool]$r.data.moreAvailable -or ([int]$r.data.rowCount -gt 1000)
      try {
        $rc = $null
        if ($truncated) {
          $rc = Invoke-FacadeTool -Tool 'sap_query' -Args @{
            system = $system; table = 'WBCROSSGT'; maxRows = 1000
            where = "( NAME = '$val' AND ( INCLUDE LIKE 'Z%' OR INCLUDE LIKE 'Y%' OR INCLUDE LIKE 'LZ%' OR INCLUDE LIKE 'LY%' ) )"
          }
        }
        if ($rc -and $rc.ok -and [int]$rc.data.rowCount -gt 0) {
          $customCount = [Math]::Min([int]$rc.data.rowCount, 1000); $customMore = [bool]$rc.data.moreAvailable
          $seen = New-Object 'System.Collections.Generic.HashSet[string]'
          $merged = New-Object System.Collections.Generic.List[object]
          foreach ($x in $rc.data.rows) { $k = [string]$x.INCLUDE + '|' + [string]$x.NAME + '|' + [string]$x.OTYPE; if ($seen.Add($k)) { $merged.Add($x) } }
          foreach ($x in $rows) { $k = [string]$x.INCLUDE + '|' + [string]$x.NAME + '|' + [string]$x.OTYPE; if ($seen.Add($k)) { $merged.Add($x) } }
          $rows = $merged
        }
      } catch { }
      # v12:标题增强(TRDIRT,主程序∪include,Z/Y 优先,≤60 个)
      $t0 = [DateTime]::Now
      $titles = @{}; $titlesErrs = @()   # 引用集为空时也要给数组(与 search 口径一致,避免序列化成 null)
      $incs = @($rows | ForEach-Object { [string]$_.INCLUDE } | Where-Object { $_ } | Sort-Object -Unique)
      if ($incs.Count) {
        $targets = Get-XrefTitleTargets $incs
        $td = Get-DirtTitles -System $system -Reps @($targets | Select-Object -First 60)
        $titles = $td.titles; $titlesErrs = $td.errs
      }
      return @{ ok = $true; result = @{
        system = $system; name = $name; field = $field; val = $val
        refs = $rows; count = $r.data.rowCount
        moreAvailable = $r.data.moreAvailable
        customCount = $customCount; customMore = $customMore
        titles = $titles; titlesErrs = $titlesErrs; titlesCount = @($titles.Keys).Count
        facadeHttpMs = $r.facadeHttpMs; titleMs = [int]([DateTime]::Now - $t0).TotalMilliseconds
      } }
    }

    'uses' {
      $inc = Clean-Name $input_.include
      if (-not $inc) { return (Fail 'BAD_PARAM' 'include 必填') }
      # v12:主程序名自动展开为「本名 + 组内 include」——报表 ZPROG001 → LIKE 'ZPROG001%'
      # (抓 ZPROG001TOP/F01);函数组 SAPLZREP001 → ='SAPLZREP001' OR LIKE 'LZREP001%'。
      # Clean-Name 已剥引号,LIKE 字面量安全(% 不剥,护栏内放行)。
      $where = "INCLUDE = '$inc'"
      if ($inc -match '^SAPL(.+)$') { $where = "( INCLUDE = '$inc' OR INCLUDE LIKE 'L$($Matches[1])%' )" }
      elseif ($inc -notmatch '^(L|SAPL)') { $where = "( INCLUDE = '$inc' OR INCLUDE LIKE '$inc%' )" }
      $r = Invoke-FacadeTool -Tool 'sap_query' -Args @{
        system = $system; table = 'WBCROSSGT'
        where = $where
        maxRows = 1000
      }
      if (-not $r.ok) { return $r }
      $t0 = [DateTime]::Now
      $titles = @{}; $titlesErrs = @()
      $incs = @($r.data.rows | ForEach-Object { [string]$_.NAME } | Where-Object { $_ } | Sort-Object -Unique)
      if ($incs.Count) {
        $td = Get-DirtTitles -System $system -Reps @($incs | Select-Object -First 60)
        $titles = $td.titles; $titlesErrs = $td.errs
      }
      return @{ ok = $true; result = @{
        system = $system; include = $inc
        refs = $r.data.rows; count = $r.data.rowCount
        moreAvailable = $r.data.moreAvailable
        titles = $titles; titlesErrs = $titlesErrs; titlesCount = @($titles.Keys).Count
        facadeHttpMs = $r.facadeHttpMs; titleMs = [int]([DateTime]::Now - $t0).TotalMilliseconds
      } }
    }

    'search' {
      $kw = Clean-Name $input_.kw
      if (-not $kw) { return (Fail 'BAD_PARAM' 'kw 必填') }
      $t0 = [DateTime]::Now
      $r = Invoke-FacadeTool -Tool 'sap_query' -Args @{
        system = $system; table = 'REPOSRC'
        fields = @('PROGNAME', 'SUBC', 'R3STATE', 'UNAM', 'UDAT')
        where = @(@{ field = 'PROGNAME'; op = 'LIKE'; value = "%$kw%" })
        maxRows = 300
      }
      if (-not $r.ok) { return $r }
      # v12:描述命中(TRDIRT TEXT LIKE——按中文标题也能搜到程序)+ 名字命中补标题(前 40)
      $descRows = @(); $descCount = 0
      try {
        $d = Invoke-FacadeTool -Tool 'sap_query' -Args @{
          system = $system; table = 'TRDIRT'; maxRows = 80; where = "TEXT LIKE '%$kw%'"
        }
        if ($d.ok) { $descRows = @($d.data.rows); $descCount = [int]$d.data.rowCount }
      } catch { }
      $names = @($r.data.rows | ForEach-Object { [string]$_.PROGNAME } | Where-Object { $_ } | Sort-Object -Unique)
      $ordered = @(@($names | Where-Object { $_ -match '^[ZY/]' }) + @($names | Where-Object { $_ -notmatch '^[ZY/]' }))
      $td = Get-DirtTitles -System $system -Reps @($ordered | Select-Object -First 40)
      $titles = $td.titles; $titlesErrs = $td.errs
      return @{ ok = $true; result = @{
        system = $system; kw = $kw
        progs = $r.data.rows; count = $r.data.rowCount
        descHits = $descRows; descCount = $descCount
        titles = $titles; titlesErrs = $titlesErrs; titlesCount = @($titles.Keys).Count
        moreAvailable = $r.data.moreAvailable
        facadeHttpMs = $r.facadeHttpMs; titleMs = [int]([DateTime]::Now - $t0).TotalMilliseconds
      } }
    }

    'code' {
      # v12 看代码:拉 include 源码(sap_prog_read/REPOSRC 解压),按 OTYPE 选定位模式:
      #   FU=CALL FUNCTION 'X' / ME=->X 或 =>X / FR=PERFORM|FORM X / 其他=全词 \bX\b;
      # 主模式零命中回退全词(WBCROSSGT 是激活索引,代码可能已变);附 head300 兜底。
      $inc = Clean-Name $input_.include
      if (-not $inc) { return (Fail 'BAD_PARAM' 'include 必填') }
      $name = Clean-Name $input_.name
      $field = Clean-Name $input_.field
      $otype = ([string]$input_.otype).Trim().ToUpper()
      $t0 = [DateTime]::Now
      $src = Invoke-FacadeTool -Tool 'sap_prog_read' -Args @{ system = $system; program = $inc } -TimeoutSec 90
      if (-not $src.ok) { return $src }
      $lines = @(([string]$src.data.source) -split "`r?`n")
      # 引用词:field 优先;否则 name 的 \TY: 尾段(MARA\TY:MATNR → MATNR)
      $word = $field
      if (-not $word -and $name) {
        $word = @($name -split '\\') | Select-Object -Last 1
        if ($word -match '^TY:(.+)$') { $word = $Matches[1] }
      }
      $word = ([string]$word).Trim()
      if (-not $word) { return (Fail 'BAD_PARAM' 'name/field 至少给一个(定位引用词)') }
      $esc = [regex]::Escape($word)
      $primary = "(?i)\b${esc}\b"
      switch ($otype) {
        'FU' { $primary = "(?i)CALL\s+FUNCTION\s+'${esc}'" }
        'ME' { $primary = "(?i)(?:->|=>)\s*${esc}\b" }
        'FR' { $primary = "(?i)\b(?:PERFORM|FORM)\s+${esc}\b" }
        default { }
      }
      $fallback = $false
      $rx = [regex]$primary
      $hitIdx = New-Object System.Collections.Generic.List[int]
      $totalHits = 0
      for ($pass = 0; $pass -lt 2; $pass++) {
        $hitIdx = New-Object System.Collections.Generic.List[int]
        $totalHits = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
          if ($rx.IsMatch([string]$lines[$i])) {
            $totalHits++
            if ($hitIdx.Count -lt 40) { $hitIdx.Add($i) }
          }
        }
        if ($totalHits -gt 0 -or $primary -eq "(?i)\b${esc}\b") { break }
        $rx = [regex]"(?i)\b${esc}\b"; $fallback = $true
      }
      # 命中行 ±2 合并为连续段(≤40 段)
      $segs = @(); $cur = $null
      foreach ($h in $hitIdx) {
        $f = [Math]::Max(0, $h - 2); $t = [Math]::Min($lines.Count - 1, $h + 2)
        if ($null -ne $cur -and $f -le ([int]$cur.to + 1)) {
          if ($t -gt [int]$cur.to) { $cur.to = $t }
          $cur.hits += ($h + 1)
        } else {
          if ($null -ne $cur) { $segs += $cur }
          $cur = @{ from = $f; to = $t; hits = @($h + 1) }
        }
      }
      if ($null -ne $cur) { $segs += $cur }
      $segRows = @($segs | ForEach-Object {
        $rows = @()
        for ($i = [int]$_.from; $i -le [int]$_.to; $i++) { $rows += @{ no = $i + 1; text = [string]$lines[$i] } }
        @{ from = [int]$_.from + 1; to = [int]$_.to + 1; hits = $_.hits; rows = $rows }
      })
      $head = @()
      $headMax = [Math]::Min(299, $lines.Count - 1)
      for ($i = 0; $i -le $headMax; $i++) { $head += [string]$lines[$i] }
      return @{ ok = $true; result = @{
        system = $system; include = $inc; word = $word; otype = $otype
        scanned = $lines.Count; hitCount = $totalHits
        segments = $segRows; truncated = ($totalHits -gt $hitIdx.Count)
        fellBack = $fallback; head300 = $head
        facadeHttpMs = $src.facadeHttpMs; ms = [int]([DateTime]::Now - $t0).TotalMilliseconds
      } }
    }

    'objtr' {
      # v13 按对象传输溯源(用户日常场景):输入事务码/程序/函数组 →
      #   ① TSTC 识别(事务码→程序) ② E071 反查(主前缀+L 前缀,LIKE 单行)→ 涉及请求×对象矩阵
      #   ③ 请求头+描述(E070/E07T 逐请求,**永久本地缓存** e070-<SYS>.json 跨程序复用,越用越热)
      #   ④ 三系统 REPOSRC 指纹比对(UNAM+UDAT+UTIME,激活版)→ ✓一致/⚠不一致/✗未传
      $inp = Clean-Name $input_.obj
      if (-not $inp) { return (Fail 'BAD_PARAM' 'obj 必填(程序/事务码/函数组,如 ZREP001 或 MM02)') }
      $t0 = [DateTime]::Now
      # ① 类型识别:TSTC(事务码)→ TFDIR(函数模块)→ TADIR(R3T 对象类型)→ 兜底程序名。
      #   v15.2 类型感知:函数模块/函数组此前被纯程序名前缀漏掉 E071 本名行(LIMU FUNC/R3TR FUGR),
      #   表等非程序对象做 REPOSRC 矩阵是空转 → 识别类型分路(09-16 ZUTIL_002 实爆)
      # 识别链单源切 Get-SapObjectRef(2026-09-21 审查 P2;TADIR maxRows 5→1:TADIR 主键 PGMID+OBJECT+OBJ_NAME,R3T 过滤后唯一)
      $ref = Get-SapObjectRef -System $system -Name $inp
      if (-not $ref.ok) { return (Fail $ref.code $ref.message) }
      $tcode = $ref.tcode; $func = $ref.func; $prog = $ref.prog; $objType = $ref.objType; $grp = $ref.grp
      if (-not $prog) { return (Fail 'TCODE_NO_PROG' "$inp 在 $system 未识别为事务码/函数,也无法当程序名溯源") }
      # 函数组 include 前缀:SAPLX → LX;报表 X → LX(SE80 include 命名)
      $lpre = ''
      if ($prog -match '^SAPL(.+)$') { $lpre = 'L' + $Matches[1] }
      elseif ($prog -notmatch '^(L|SAPL|CL_)') { $lpre = 'L' + $prog }
      # ② E071 反查:前缀(SAPL<grp>% / L<grp>%)收 include 级行,精确项收对象本名行
      #   (LIMU FUNC <函数名> / R3TR FUGR <组名> / R3TR TABL <表名>——纯前缀会系统性漏掉本名行)
      $trObjs = @{}   # trkorr → @{ n; objs=List }
      $e71Total = 0; $e71More = $false
      $e71Terms = New-Object System.Collections.Generic.List[string]
      foreach ($pfx in @($prog, $lpre)) { if ($pfx) { [void]$e71Terms.Add("OBJ_NAME LIKE '$pfx%'") } }
      if ($func) {
        [void]$e71Terms.Add("OBJ_NAME = '$func'")
        if ($grp -and $grp -ne $func) { [void]$e71Terms.Add("OBJ_NAME = '$grp'") }
      }
      elseif ($objType -ne 'PROG' -and $objType -ne 'TRAN') { [void]$e71Terms.Add("OBJ_NAME = '$inp'") }
      $e71Uniq = @($e71Terms.ToArray() | Select-Object -Unique)
      $w71 = $e71Uniq -join ' OR '
      if ($e71Uniq.Count -gt 1) { $w71 = '( ' + $w71 + ' )' }   # 单条件不带括号,RFC_READ_TABLE 回退也能走
      $r71 = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E071'; maxRows = 1000; where = $w71 }
      if (-not $r71.ok) { return $r71 }
      $e71Total = [int]$r71.data.rowCount
      $e71More = [bool]$r71.data.moreAvailable
      foreach ($row in $r71.data.rows) {
        $tk = [string]$row.TRKORR; $on = [string]$row.OBJ_NAME
        if (-not $tk -or -not $on) { continue }
        if (-not $trObjs[$tk]) { $trObjs[$tk] = @{ n = 0; objs = New-Object System.Collections.Generic.List[string] } }
        $trObjs[$tk].n += 1
        if (-not $trObjs[$tk].objs.Contains($on)) { $trObjs[$tk].objs.Add($on) }
      }
      # ③ 请求头+描述:按对象数排序取前 40,逐个查(E070 状态/人/日期 + E07T 描述中文优先)→ 永久缓存
      $top = @($trObjs.Keys | Sort-Object { -[int]$trObjs[$_].n })
      $top40 = @($top | Select-Object -First 40)
      $cacheDir = $global:SapProbeCacheDir
      $cacheFile = Join-Path $cacheDir ("e070-" + $system + ".json")
      $trMap = @{}
      # v13.3:载入即归一;旧缓存无 parent 键 → 哨兵 $null(区别于「查过但确实是顶层请求」
      #   的空串,后者不重查)——lastTr 补查时据此重拉一次
      $cachedE070 = Get-SapCacheMap -Path $cacheFile
      foreach ($p in @($cachedE070.Keys)) {
        $v = $cachedE070[$p]
        $par = $null
        if ($v -is [System.Collections.IDictionary] -and $v.Contains('parent')) { $par = [string]$v['parent'] }
        $trMap[$p] = @{ status = [string]$v['status']; func = [string]$v['func']; user = [string]$v['user']; date = [string]$v['date']; text = [string]$v['text']; parent = $par }
      }
      $fetched = 0
      # v15 批查:未缓存/**未释放态**的请求按 10 个一组 OR 批查头+描述(原逐个 2 次往返,
      # top40 冷态最多 80 次——09-16 审查实测 ZRPT1003 冷 12.1s)。未释放态每次重查:
      # release 后 TRSTATUS/描述会变,永久缓存不再吃旧值。OR 单行条件沿用 whereused 已验证形态,
      # 10 个一组 ≈300 字符,远低于 Q3 单行安全上界的保守分片。
      $need = @($top40 | Where-Object { $c = $trMap[$_]; (-not $c) -or ([string]$c.status -ne 'R') })
      for ($ci = 0; $ci -lt $need.Count; $ci += 10) {
        $chunk = @($need | Select-Object -Skip $ci -First 10)
        $w = ($chunk | ForEach-Object { "TRKORR = '$_'" }) -join ' OR '
        $h = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E070'; maxRows = 20; where = $w }
        if (-not $h.ok) { continue }   # 批查失败:这些请求保持无头显示(与旧逐个失败行为一致)
        $descBest = @{}
        $td = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E07T'; maxRows = 200; where = $w }
        if ($td.ok) {
          foreach ($trow in $td.data.rows) {
            $tk2 = [string]$trow.TRKORR
            $sp = [string]$trow.SPRSL; $prio = switch ($sp) { '1' { 0 } 'E' { 2 } 'D' { 3 } default { 4 } }
            $tx2 = ([string]$trow.AS4TEXT).Trim()
            if (-not $tx2) { continue }
            $cur = $descBest[$tk2]
            if (-not $cur -or $prio -lt $cur.best) { $descBest[$tk2] = @{ best = $prio; txt = $tx2 } }
          }
        }
        foreach ($h0 in $h.data.rows) {
          $tk = [string]$h0.TRKORR
          $trMap[$tk] = @{ status = [string]$h0.TRSTATUS; func = [string]$h0.TRFUNCTION; user = [string]$h0.AS4USER; date = [string]$h0.AS4DATE
            text = $(if ($descBest[$tk]) { [string]$descBest[$tk].txt } else { '' }); parent = [string]$h0.STRKORR }
          $fetched++
        }
      }
      $requests = @($top40 | ForEach-Object {
        $c = $trMap[$_]
        @{ trkorr = $_; n = [int]$trObjs[$_].n; objs = @($trObjs[$_].objs)
           status = if ($c) { [string]$c.status } else { '' }; user = if ($c) { [string]$c.user } else { '' }
           date = if ($c) { [string]$c.date } else { '' }; text = if ($c) { [string]$c.text } else { '' } }
      })
      # ④ 三系统 REPOSRC 清单 + 内容级指纹(源码 SHA256——时间戳跨系统不可比,导入会重写)
      $sysList = @('DVP', 'QAS', 'PRD')
      $fps = @{}
      $fpOk = @{}   # v17.1:该系统清单查询是否成功——失败≠未传,绝不让查询失败冒充「未传输」
      $fpErrs = @()
      foreach ($s in $sysList) {
        $fps[$s] = @{}
        $fpOk[$s] = $false
        if (@('PROG', 'TRAN', 'FUNC', 'FUGR') -notcontains $objType) { $fpOk[$s] = $true; continue }   # 非程序对象(表/数据元素等)无源码矩阵
        # v15:双前缀合并单行 OR(每系统 2→1 次往返,三系统 6→3);maxRows 300→600 保合并后覆盖
        $wRepo = if ($lpre) { "( PROGNAME LIKE '$prog%' OR PROGNAME LIKE '$lpre%' ) AND R3STATE = 'A'" } else { "PROGNAME LIKE '$prog%' AND R3STATE = 'A'" }
        $rf = Invoke-FacadeTool -Tool 'sap_query' -Args @{
          system = $s; table = 'REPOSRC'; maxRows = 600
          fields = @('PROGNAME', 'SUBC', 'UNAM', 'UDAT', 'UTIME')
          where = $wRepo
        }
        if (-not $rf.ok) { $fpErrs += "${s}: " + [string]$rf.error.message; continue }
        $fpOk[$s] = $true
        foreach ($row in $rf.data.rows) {
          $nm = [string]$row.PROGNAME
          $fps[$s][$nm] = @{ unam = [string]$row.UNAM; udat = [string]$row.UDAT; utime = [string]$row.UTIME; subc = [string]$row.SUBC }
        }
      }
      # 内容级指纹详查:前 30 个对象(DVP 日期序)× 3 系统 prog_read → SHA256(hash 永久缓存,对象未改零成本)
      $orderedObjs = @($fps[$system].Keys | Sort-Object { -([long]($fps[$system][$_].udat + $fps[$system][$_].utime)) } | Select-Object -First 30)
      $hashCaches = @{}
      foreach ($s in $sysList) {
        $hashCaches[$s] = Get-SapCacheMap -Path (Join-Path $cacheDir ("fphash-" + $s + ".json"))   # 旧平格式由共享读取兼容
        if (-not $hashCaches[$s]) { $hashCaches[$s] = @{} }
      }
      foreach ($nm in $orderedObjs) {
        foreach ($s in $sysList) {
          $fp2 = $fps[$s][$nm]
          if (-not $fp2) { continue }
          $fr = Get-SrcFingerprint -System $s -Prog $nm -Unam $fp2.unam -Udat $fp2.udat -Utime $fp2.utime -Cache $hashCaches[$s]
          if ($fr.hash) {
            $fps[$s][$nm].hash = [string]$fr.hash
            $fps[$s][$nm].codehash = [string]$fr.code
          }
          elseif ($fr.miss) { $fps[$s][$nm].srcmiss = $true }
        }
      }
      foreach ($s in $sysList) {
        Save-SapCacheMap -Path (Join-Path $cacheDir ("fphash-" + $s + ".json")) -Map $hashCaches[$s]
      }
      # obj → 最近请求:v13.3 改按 **TRKORR 序号最大** 判定——TR 序号全系统单调递增,
      #   序号最大即最新,零额外查询且不需要每请求的日期。两轮实爆教训:
      #   ① 只遍历 top40(按对象数)漏掉小请求;② 补拉 120 个日期仍漏(ZRPT1003 涉及 243 请求,
      #   真·最新 DEVK900003 只带 1 个对象)。选定后对缺头的 lastTr 补拉 E070(每对象最多 1 次,
      #   永久缓存)填日期,供前端展示。
      $objLastTr = @{}
      foreach ($tk in $trObjs.Keys) {
        $num = [long]0
        if ($tk -match '(\d+)$') { $num = [long]$Matches[1] }
        foreach ($on in $trObjs[$tk].objs) {
          $cur = $objLastTr[$on]
          if (-not $cur -or $num -gt [long]$cur.num) { $objLastTr[$on] = @{ trkorr = [string]$tk; num = $num } }
        }
      }
      # v17.1 对象→请求反查(每系统推断 TR 用;trObjs 是请求→对象,这里倒一手)
      $objTrs = @{}
      foreach ($tk in $trObjs.Keys) {
        foreach ($on in $trObjs[$tk].objs) {
          if (-not $objTrs[$on]) { $objTrs[$on] = @() }
          $objTrs[$on] += [string]$tk
        }
      }
      # v18.2 批查补头(2026-09-21 审查 P2):lastTr 引用请求与父请求两处原在循环内逐个
      # E070 单查(maxRows=1),冷态最多百余次往返(~5-15s);改三阶段=收集缺头→10/组 OR 批查
      # (同 427 行 v15 模式)→回填,再纯内存组装。失败语义不变:查不到保持无头显示。
      $needHeads = New-Object System.Collections.Generic.List[string]
      foreach ($on in @($objLastTr.Keys)) {
        $tk = [string]$objLastTr[$on].trkorr
        if ((-not $trMap[$tk] -or $null -eq $trMap[$tk].parent) -and $needHeads -notcontains $tk) { [void]$needHeads.Add($tk) }
      }
      for ($ci = 0; $ci -lt $needHeads.Count; $ci += 10) {
        $chunk = @($needHeads | Select-Object -Skip $ci -First 10)
        $w = ($chunk | ForEach-Object { "TRKORR = '$_'" }) -join ' OR '
        $h = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E070'; maxRows = 20; where = $w }
        if (-not $h.ok) { continue }
        foreach ($h0 in $h.data.rows) {
          $tk = [string]$h0.TRKORR
          if (-not $trMap[$tk] -or $null -eq $trMap[$tk].parent) {
            $trMap[$tk] = @{ status = [string]$h0.TRSTATUS; func = [string]$h0.TRFUNCTION; user = [string]$h0.AS4USER; date = [string]$h0.AS4DATE; text = ''; parent = [string]$h0.STRKORR }
            $fetched++
          }
        }
      }
      # v13.3 任务号折算父请求号:E071 对象常挂在任务号下(DEVK900004),SE10 里用户看到的是
      #   请求号——lastTr 列展示父请求;父请求缺头的收集后同样批查一轮。
      $needParents = New-Object System.Collections.Generic.List[string]
      foreach ($on in @($objLastTr.Keys)) {
        $tk = [string]$objLastTr[$on].trkorr
        if ($trMap[$tk] -and [string]$trMap[$tk].parent) {
          $par = [string]$trMap[$tk].parent
          if (-not $trMap[$par] -and $needParents -notcontains $par) { [void]$needParents.Add($par) }
        }
      }
      if ($needParents.Count -gt 0) {
        for ($ci = 0; $ci -lt $needParents.Count; $ci += 10) {
          $chunk = @($needParents | Select-Object -Skip $ci -First 10)
          $w = ($chunk | ForEach-Object { "TRKORR = '$_'" }) -join ' OR '
          $h = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E070'; maxRows = 20; where = $w }
          if (-not $h.ok) { continue }
          foreach ($h0 in $h.data.rows) {
            $par = [string]$h0.TRKORR
            $trMap[$par] = @{ status = [string]$h0.TRSTATUS; func = [string]$h0.TRFUNCTION; user = [string]$h0.AS4USER; date = [string]$h0.AS4DATE; text = ''; parent = [string]$h0.STRKORR }
            $fetched++
          }
        }
      }
      foreach ($on in @($objLastTr.Keys)) {
        $tk = [string]$objLastTr[$on].trkorr
        $show = $tk
        if ($trMap[$tk] -and [string]$trMap[$tk].parent) {
          $par = [string]$trMap[$tk].parent
          if ($trMap[$par]) { $show = $par }
        }
        $objLastTr[$on] = @{ trkorr = $show; num = [long]$objLastTr[$on].num; date = if ($trMap[$show]) { [string]$trMap[$show].date } else { '' } }
      }
      if ($fetched -gt 0) {
        Save-SapCacheMap -Path $cacheFile -Map $trMap
      }
      # 矩阵:以视角系统清单为全集;结论 未传(红) > 不一致(橙) > 仅注释差异(灰) > 一致(绿) > 未详查(灰)
      # verdict 只认源码 hash;REPOSRC 缺失(目标系统无此对象)=未传
      $matrix = @()
      foreach ($nm in $fps[$system].Keys) {
        $d = $fps[$system][$nm]
        # v17.1.1 函数组 include(L<grp>Uxx / SAPL<grp>*)不单独进 E071——随 R3TR FUGR 复合对象走,
        #   E071 只有 <组>/<FM> 本名行。这类 include 的请求集=组相关请求集(09-17 实爆:ZUTIL_004
        #   矩阵 20 个 include 的 lastTr/TR 全空,E071 全集仅 ZUTIL_004+ZFG_UTIL 两行)
        $isGrpInc = ($func -or $objType -eq 'FUGR') -and ($nm -like "L$grp*" -or $nm -like "SAPL$grp*")
        $cells = @{}
        foreach ($s in $sysList) {
          $c = $fps[$s][$nm]
          # v17.1 miss=「查询成功且 REPOSRC 无此行」才是真未传;查询失败(未连接/网络)走 sysfail,
          #   绝不冒充「未传输」(09-17 实爆:PRD 未登录时整列被误写成「未传输」)
          $cells[$s] = if ($c) { @{ unam = $c.unam; udat = $c.udat; utime = $c.utime; hash = [string]$c.hash; code = [string]$c.codehash; srcmiss = [bool]$c.srcmiss; miss = $false; sysfail = $false; tr = '' } } else { @{ unam = ''; udat = ''; utime = ''; hash = ''; code = ''; srcmiss = $true; miss = [bool]$fpOk[$s]; sysfail = (-not $fpOk[$s]); tr = '' } }
        }
        $q = $cells['QAS']; $p = $cells['PRD']
        # v17.1 五态:missing(未传)> diff(代码不一致)> cosmetic(仅注释差异)> same > unverified(查询失败无法比对)> unchecked
        $verdict = 'same'; $sev = 3
        $failedSys = @($sysList | Where-Object { $cells[$_].sysfail })
        if ($q.miss -or $p.miss) { $verdict = 'missing'; $sev = 0 }
        elseif ($failedSys.Count -gt 0) { $verdict = 'unverified'; $sev = 4 }
        elseif ($d.hash -and $q.hash -and $p.hash) {
          if ($d.hash -ne $q.hash -or $d.hash -ne $p.hash) {
            # ★$d 是 $fps 条目(键名 codehash);$q/$p 是 cells(键名 code)——别混
            $chD = [string]$d.codehash; $chQ = [string]$q.code; $chP = [string]$p.code
            if ($chD -and $chQ -and $chP -and $chD -eq $chQ -and $chQ -eq $chP) { $verdict = 'cosmetic'; $sev = 2 }
            else { $verdict = 'diff'; $sev = 1 }
          }
        } else { $verdict = 'unchecked'; $sev = 4 }
        # 说明备注:一句话讲清「哪不一致/谁落后」——按内容 hash 等价类推断
        #   (时间戳跨系统不可比,导入会重写,不参与推断)。
        $why = ''
        if ($verdict -eq 'missing') {
          $who = @(); if ($q.miss) { $who += 'QAS' }; if ($p.miss) { $who += 'PRD' }
          $why = ($who -join '/') + ' 无此对象(未传输)'
        } elseif ($verdict -eq 'unverified') {
          $why = ($failedSys -join '/') + ' 版本查询失败(未连接或查询出错)——不是「未传输」,补连凭证后点重查即可比对'
        } elseif ($verdict -eq 'cosmetic') {
          # 09-16 用户治理口径:QAS/PRD 只能靠 TR,注释差异同样=有改动未传齐,不算「没事」
          $why = '仅注释差异:功能代码逐字一致,但注释改动未传(不影响运行,建议随下批 TR 同步)'
        } elseif ($verdict -eq 'diff') {
          $dh = [string]$d.hash; $qh = [string]$q.hash; $ph = [string]$p.hash
          if ($dh -and $qh -and $ph) {
            if ($qh -eq $dh) { $why = 'PRD 落后:DVP/QAS 一致,代码改动未传 PRD' }
            elseif ($ph -eq $dh) { $why = 'QAS 与 DVP/PRD 不同(QAS 有独立改动或导入过其他版本)' }
            elseif ($qh -eq $ph) { $why = 'DVP 已改:QAS/PRD 均为旧版,改动未传' }
            else { $why = '三系统代码各不相同,需逐系统核对' }
          } else { $why = '有系统源码未能读取,无法定位差异方向' }
        } elseif ($verdict -eq 'unchecked') { $why = '超出本次详查范围(仅前 30 个对象)' }
        # v17.1 每系统「该版本对应的最新 TR」:E070/E071 是全局目录,分不出请求导入到哪个系统
        #   (严格答案在目标系统导入历史,受 Q3 表白名单闸限制不引)。可用真实信号=REPOSRC 的
        #   UDAT/UTIME 在目标系统=该版本导入时刻(v13.1 实锤口径):取该对象涉及请求中
        #   「日期≤导入日」里序号最大的一个,任务号折算父请求(lastTr 同款),如实按推断展示。
        #   仅非 missing 推断(missing 无导入无 TR 可推);候选缺日期补拉 1 次入永久缓存。
        if ($verdict -ne 'missing') {
          foreach ($s in @('QAS', 'PRD')) {
            $impDate = [long]0
            if (($cells[$s].udat) -match '^\d{8}$') { $impDate = [long]$Matches[0] }
            $cands = $objTrs[$nm]
            if (-not $cands -and $isGrpInc) {
              # include 不在 E071:借用组名/FM 本名行的请求并集
              $cands = @()
              if ($grp -and $objTrs[$grp]) { $cands += $objTrs[$grp] }
              if ($func -and $func -ne $grp -and $objTrs[$func]) { $cands += $objTrs[$func] }
              $cands = @($cands | Select-Object -Unique)
            }
            if ($impDate -le 0 -or -not $cands) { continue }
            $best = ''
            foreach ($tk in @($cands | Sort-Object { -[long]($_ -replace '^\D+', '') })) {
              $hdr = $trMap[$tk]
              if (-not $hdr) {
                $h3 = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'E070'; maxRows = 1; where = "TRKORR = '$tk'" }
                if ($h3.ok -and [int]$h3.data.rowCount -gt 0) {
                  $trMap[$tk] = @{ status = [string]$h3.data.rows[0].TRSTATUS; func = [string]$h3.data.rows[0].TRFUNCTION; user = [string]$h3.data.rows[0].AS4USER; date = [string]$h3.data.rows[0].AS4DATE; text = ''; parent = [string]$h3.data.rows[0].STRKORR }
                  $fetched++
                } else { $trMap[$tk] = @{ status = ''; func = ''; user = ''; date = ''; text = ''; parent = '' } }
                $hdr = $trMap[$tk]
              }
              $d8 = [string]$hdr.date
              if ($d8 -match '^\d{8}$' -and [long]$d8 -le $impDate) {
                $best = if ([string]$hdr.parent) { [string]$hdr.parent } else { $tk }
                break
              }
            }
            $cells[$s].tr = $best
          }
        }
        $lt = $objLastTr[$nm]
        if (-not $lt -and $isGrpInc) {
          # include 的 lastTr 同源修正:取组名/FM 本名行里序号最大的请求(传组=传整组)
          foreach ($k in @($grp, $(if ($func -ne $grp) { $func } else { $null }))) {
            if (-not $k) { continue }
            $c2 = $objLastTr[$k]
            if ($c2 -and ((-not $lt) -or ([long]$c2.num -gt [long]$lt.num))) { $lt = $c2 }
          }
        }
        $matrix += [pscustomobject]@{ obj = $nm; subc = $d.subc; verdict = $verdict; sev = $sev; dvpUdat = $d.udat
                      lastTr = if ($lt) { [string]$lt.trkorr } else { '' }
                      why = $why
                      dvp = $cells['DVP']; qas = $cells['QAS']; prd = $cells['PRD'] }
      }
      $matrix = @($matrix | Sort-Object -Property @{ e = 'sev' }, @{ e = 'dvpUdat'; Descending = $true })
      if ($fetched -gt 0) { Save-SapCacheMap -Path $cacheFile -Map $trMap }   # v17.1 推断补拉的请求头也入永久缓存
      return @{ ok = $true; result = @{
        system = $system; obj = $inp; tcode = $tcode; func = $func; prog = $prog; lpre = $lpre; objType = $objType
        e71Total = $e71Total; e71More = $e71More; trCount = $trObjs.Count; trShown = $top40.Count
        requests = $requests; trCacheFetched = $fetched
        matrix = $matrix; fpErrs = $fpErrs
        ms = [int]([DateTime]::Now - $t0).TotalMilliseconds
      } }
    }

    'tr' {
      # v11 传输查询:E070 头 + E071 对象清单 + E070 子任务(纯读,TR 目录全局可见)
      $t = Clean-Name $input_.trkorr
      if (-not $t) { return (Fail 'BAD_PARAM' 'trkorr 必填,如 DEVK900001') }
      $h = Invoke-FacadeTool -Tool 'sap_query' -Args @{
        system = $system; table = 'E070'; maxRows = 1
        where = @(@{ field = 'TRKORR'; op = '='; value = $t })
      }
      if (-not $h.ok) { return $h }
      if ($h.data.rowCount -eq 0) { return (Fail 'TR_NOT_FOUND' "请求 $t 在 $system 不存在(TR 目录系统级共享,换环境查)") }
      $objs = Invoke-FacadeTool -Tool 'sap_query' -Args @{
        system = $system; table = 'E071'; maxRows = 500
        where = @(@{ field = 'TRKORR'; op = '='; value = $t })
      }
      if (-not $objs.ok) { return $objs }
      $subs = Invoke-FacadeTool -Tool 'sap_query' -Args @{
        system = $system; table = 'E070'; maxRows = 50
        where = @(@{ field = 'STRKORR'; op = '='; value = $t })
      }
      if (-not $subs.ok) { return $subs }
      return @{ ok = $true; result = @{
        system = $system; trkorr = $t
        head = $h.data.rows[0]
        objects = $objs.data.rows; objCount = $objs.data.rowCount
        subtasks = $subs.data.rows
        facadeHttpMs = $h.facadeHttpMs
      } }
    }

    'trlist' {
      # v11 列某用户最近的传输请求(E070,最多 30 条;顺序=返回原序,前端按日期排)
      $u = Clean-Name $input_.user
      if (-not $u) { return (Fail 'BAD_PARAM' 'user 必填,如 XXX.YYY.Z') }
      $r = Invoke-FacadeTool -Tool 'sap_query' -Args @{
        system = $system; table = 'E070'; maxRows = 30
        where = @(@{ field = 'AS4USER'; op = '='; value = $u })
      }
      if (-not $r.ok) { return $r }
      return @{ ok = $true; result = @{
        system = $system; user = $u
        list = $r.data.rows; count = $r.data.rowCount
        moreAvailable = $r.data.moreAvailable
        facadeHttpMs = $r.facadeHttpMs
      } }
    }

    default { return (Fail 'BAD_ACTION' "未知 action: $action") }
  }
} catch {
  return (Fail 'XREF_FAILED' $_.Exception.Message)
}
