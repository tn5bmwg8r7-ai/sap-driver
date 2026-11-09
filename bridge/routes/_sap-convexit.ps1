# ============================================================
# _sap-convexit  -  SAP 内外码转换助手(PW SAP Driver,2026-09-15)。
# 文件名 _ 开头,_registry.ps1 不会当成路由暴露。
#
# 解决的问题:SE37 变式/第三方报文/人手输入的参数值是**外码**(如物料 10000000000),
# RFC 直调不做转换出口,字段里落进去的是外码原样 → 查不到数/函数内部行为不对。
# 本助手在 sap-probe exec 的统一咽喉点做 ALPHA/MATN1 类外码→内码(左补零到域长)。
#
# 数据来源(全部只读、全在 facade 白名单内):
#   结构/表参数   → sap_object_meta(DDIF_FIELDINFO_GET 字段目录,含 CONVEXIT)
#   标量参数(数据元素)→ DD04L(ROLLNAME→DOMNAME)→ DD01L(CONVEXIT+LENG)
# 缓存:<缓存目录>(env SAP_PROBE_CACHE_DIR,缺省=仓库 data/sap-mcp-probe)\ddic-<SYS>.json,每对象 7 天,DDIC 几乎不变。
#
# 安全边界:只转换纯数字、短于域长的值;非 ALPHA/MATN1 出口一律不动并记入 skipped,
# 绝不猜。任何失败(查不到元数据/接口读不到)都静默跳过,绝不阻塞执行主链。

# 缓存容器:存 PWCrossRunspaceCache 进程级 hashtable 引用(2026-09-21 审查 P2 二次修正——
# 此前 09-16 改 $global: 的假设「跨请求存活」在重路由子 runspace 化后不成立,内存层实际
# 仍只活单请求,ddic json 每请求重读重解析、冷标量每请重查 DD04L+DD01L;落盘层兜底所以
# 无功能损害,纯性能浪费)。$SapConvexitCacheFile 仍按请求传(仅本请求内写盘用)。
# 依赖 _sap-lib 的 ConvertTo-MutHashTable(幂等 dot-source;本文件不再自带旧版拍平拷贝——
# 旧版缺 09-17 三条保形规则,ddic 缓存回读走它=毒条目隐患活体,09-18 审查 D3 收编)。
. (Join-Path $PSScriptRoot '_sap-lib.ps1')
function Get-SapConvexitMem {
  $m = [PWCrossRunspaceCache]::Store['SapConvexitCache']
  if (-not $m) { $m = @{}; [PWCrossRunspaceCache]::Store['SapConvexitCache'] = $m }
  return $m
}
$SapConvexitCacheFile = $null

function Get-SapConvexitCached {
  # 进程内 + 落盘双层缓存;返回该对象的 @{ primary=@{convexit,leng}; fields=@{COL→fld} } 或 $null
  # -Scalar:标量(数据元素)路径显式声明——替代调用方临时清 $script:SapConvexitFetchStruct 的脆弱做法
  param([Parameter(Mandatory)][string]$System, [Parameter(Mandatory)][string]$Object, [switch]$Scalar)

  $obj = $Object.Trim().ToUpper()
  if (-not $obj -or $obj.Length -gt 30 -or $obj -notmatch '^[A-Z0-9_/]+$') { return $null }

  # 落盘文件按系统分;内存层 $global: 跨请求,每系统仅首次访问时装载
  $convMem = Get-SapConvexitMem
  if (-not $convMem['_loaded_']) { $convMem['_loaded_'] = @{} }
  $cacheFile = Join-Path $global:SapProbeCacheDir ("ddic-$System.json")
  $SapConvexitCacheFile = $cacheFile
  if (-not $convMem['_loaded_'][$System]) {
    $convMem['_loaded_'][$System] = $true
    try {
      if (Test-Path $cacheFile) {
        $j = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in @($j.PSObject.Properties)) { if ($p.Name -ne '_loaded_') { $convMem[$p.Name] = ConvertTo-MutHashTable $p.Value } }
      }
    } catch { }
  }
  # 内存 key 带 system 前缀:同进程先后服务 DVP/QAS 不串缓存(落盘文件本就按系统分开)
  $memKey = "$System/$obj"
  $hit = $convMem[$memKey]
  if ($hit) {
    $ageMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [long]$hit.ts
    if ($hit.negative) {
      if ($ageMs -lt 1L * 24 * 3600 * 1000) { return $null }   # 负缓存 1 天:查不到的类型不反复烧 RFC(v15)
    } elseif ($ageMs -lt 7L * 24 * 3600 * 1000) { return $hit }
  }

  $meta = $null
  try {
    if (-not $Scalar -and $script:SapConvexitFetchStruct) {
      # 结构/表参数路径:object_meta 一次拿全字段目录(含 CONVEXIT)
      $r = & $script:SapConvexitFetchStruct 'sap_object_meta' @{ system = $System; object = $obj; includeEnums = $false }
      if ($r.ok -and $r.data.fields -and @($r.data.fields).Count) {
        $fields = @{}
        foreach ($f in @($r.data.fields)) {
          $fields[[string]$f.name] = @{ convexit = $(if ($f.convexit) { [string]$f.convexit } else { '' }); leng = [string]$f.leng }
        }
        $meta = @{ fields = $fields; primary = $null }
      }
    } else {
      # 标量(数据元素)路径:DD04L → DD01L
      $d4 = & $script:SapConvexitFetchQuery 'sap_query' @{ system = $System; table = 'DD04L'
              where = @(@{ field = 'ROLLNAME'; op = '='; value = $obj }, @{ field = 'AS4LOCAL'; op = '='; value = 'A' }); maxRows = 1 }
      $dom = ''
      if ($d4.ok -and @($d4.data.rows).Count) { $dom = [string]$d4.data.rows[0].DOMNAME }
      if ($dom.Trim()) {
        $d1 = & $script:SapConvexitFetchQuery 'sap_query' @{ system = $System; table = 'DD01L'
                where = @(@{ field = 'DOMNAME'; op = '='; value = $dom.Trim() }, @{ field = 'AS4LOCAL'; op = '='; value = 'A' }); maxRows = 1 }
        if ($d1.ok -and @($d1.data.rows).Count) {
          $row = $d1.data.rows[0]
          $meta = @{ primary = @{ convexit = ([string]$row.CONVEXIT).Trim(); leng = [string]$row.LENG }; fields = @{} }
        }
      }
    }
  } catch { $meta = $null }   # 元数据拿不到 ≠ 执行失败,静默跳过

  if ($meta) {
    $meta.ts = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $convMem[$memKey] = $meta
  } else {
    # 负缓存 1 天(v15):DD04L/DD01L 查不到的类型此前每次 exec 重复 2 次 RFC 往返
    $convMem[$memKey] = @{ negative = $true; ts = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
  }
  try {
    $dir = Split-Path $SapConvexitCacheFile -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $persist = @{}
    foreach ($kv in $convMem.GetEnumerator()) { if ($kv.Key -ne '_loaded_') { $persist[$kv.Key] = $kv.Value } }
    ($persist | ConvertTo-Json -Depth 8 -Compress) | Set-Content $SapConvexitCacheFile -Encoding UTF8
  } catch {}
  return $meta
}

function Convert-SapAlphaInValue {
  # 单值转换判定。返回转换后字符串或 $null(不转)。$Applied/$Skipped 为 [System.Collections.ArrayList]。
  param([string]$Path, [string]$Value, $Fld, [System.Collections.ArrayList]$Applied, [System.Collections.ArrayList]$Skipped)

  $ce = ''
  if ($Fld -and $Fld.convexit) { $ce = [string]$Fld.convexit }
  if (-not $ce) { return $null }
  if ($ce -notin @('ALPHA', 'MATN1')) {
    [void]$Skipped.Add(@{ path = $Path; convexit = $ce; value = $Value; reason = "出口 $ce 非 ALPHA 类,不自动转" })
    return $null
  }
  $t = $Value.Trim()
  if (-not $t) { return $null }
  if ($t -notmatch '^\d+$') {
    [void]$Skipped.Add(@{ path = $Path; convexit = $ce; value = $Value; reason = '含非数字字符,不自动转' })
    return $null
  }
  $leng = 0
  if ($Fld.leng) { [void][int]::TryParse([string]$Fld.leng, [ref]$leng) }
  if ($leng -le 0 -or $t.Length -ge $leng) { return $null }   # 等长/超长/长度未知:原样
  $newv = $t.PadLeft($leng, '0')
  [void]$Applied.Add(@{ path = $Path; convexit = $ce; from = $Value; to = $newv })
  return $newv
}

function Add-SapConvexit {
  # 主入口:就地转换 $Import/$Tables(hashtable),返回 @{ applied=@(); skipped=@() }。
  # $Sig 为 sap_fm_read 归一化接口:importing/changing[].name,type=TYP;tables[].name,type=DBSTRUCT。
  param(
    [Parameter(Mandatory)][string]$System,
    $Sig,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Import,
    [Parameter(Mandatory)][System.Collections.IDictionary]$Tables,
    [Parameter(Mandatory)][scriptblock]$FetchQuery,
    [Parameter(Mandatory)][scriptblock]$FetchStruct
  )

  $applied = New-Object System.Collections.ArrayList
  $skipped = New-Object System.Collections.ArrayList
  if (-not $Sig) { return @{ applied = $applied; skipped = $skipped } }

  $script:SapConvexitFetchQuery = $FetchQuery
  $script:SapConvexitFetchStruct = $FetchStruct
  try {
    # ---- IMPORT / CHANGING 标量(数据元素)----
    $impType = @{}
    foreach ($p in @($Sig.importing)) { if ($p -and $p.name) { $impType[[string]$p.name] = [string]$p.type } }
    foreach ($p in @($Sig.changing))  { if ($p -and $p.name -and -not $impType[[string]$p.name]) { $impType[[string]$p.name] = [string]$p.type } }
    foreach ($k in @($Import.Keys)) {
      $v = $Import[$k]
      $typ = ''
      if ($impType.ContainsKey([string]$k)) { $typ = $impType[[string]$k] }
      if (-not $typ) { continue }
      if ($v -is [string]) {
        $meta = Get-SapConvexitCached -System $System -Object $typ -Scalar   # 标量走 DD04L/DD01L 路径
        if ($meta -and $meta.primary) {
          $nv = Convert-SapAlphaInValue -Path "[IMPORT] $k" -Value $v -Fld $meta.primary -Applied $applied -Skipped $skipped
          if ($null -ne $nv) { $Import[$k] = $nv }
        }
      } elseif ($v -is [System.Collections.IDictionary]) {
        # 结构参数:object_meta 按字段转(深度 1)
        $meta = Get-SapConvexitCached -System $System -Object $typ
        if ($meta -and $meta.fields -and $meta.fields.Count) {
          foreach ($fk in @($v.Keys)) {
            $fv = $v[$fk]
            if ($fv -isnot [string]) { continue }
            $fld = $meta.fields[[string]$fk]
            if (-not $fld) { continue }
            $nv = Convert-SapAlphaInValue -Path "[IMPORT] $k.$fk" -Value $fv -Fld $fld -Applied $applied -Skipped $skipped
            if ($null -ne $nv) { $v[$fk] = $nv }
          }
        }
      }
    }

    # ---- TABLES 行内格(DBSTRUCT)----
    $tblType = @{}
    foreach ($p in @($Sig.tables)) { if ($p -and $p.name) { $tblType[[string]$p.name] = [string]$p.type } }
    foreach ($k in @($Tables.Keys)) {
      $typ = ''
      if ($tblType.ContainsKey([string]$k)) { $typ = $tblType[[string]$k] }
      if (-not $typ) { continue }
      $rows = $Tables[$k]
      if ($rows -isnot [System.Collections.IEnumerable] -or $rows -is [string]) { continue }
      $meta = Get-SapConvexitCached -System $System -Object $typ
      if (-not $meta -or -not $meta.fields -or -not $meta.fields.Count) { continue }
      $ri = -1
      foreach ($row in @($rows)) {
        $ri++
        if ($row -isnot [System.Collections.IDictionary]) { continue }
        foreach ($fk in @($row.Keys)) {
          $fv = $row[$fk]
          if ($fv -isnot [string]) { continue }
          $fld = $meta.fields[[string]$fk]
          if (-not $fld) { continue }
          $nv = Convert-SapAlphaInValue -Path "[TABLES] $k[$ri].$fk" -Value $fv -Fld $fld -Applied $applied -Skipped $skipped
          if ($null -ne $nv) { $row[$fk] = $nv }
        }
      }
    }
  } finally {
    Remove-Item variable:script:SapConvexitFetchQuery -ErrorAction SilentlyContinue
    Remove-Item variable:script:SapConvexitFetchStruct -ErrorAction SilentlyContinue
  }

  return @{ applied = $applied; skipped = $skipped }
}
