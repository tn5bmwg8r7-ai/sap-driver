param([Parameter(Mandatory)][hashtable]$Body)

# sap-codesearch  -  🔍 代码内容搜索(2026-09-16 v14)。
# 关键字搜进 Z/Y 程序源码内容(名字 LIKE 收窄范围 → REPOSRC 指纹增量拉源 → 本地扫描)。
# ★范围铁律:DVP 活跃 Z 系 8500+ 程序(09-16 实测 Z%=5503/LZ%=2684),全量索引不现实;
#   按程序名模式(默认 Z*,支持 *)收窄,匹配数 >300 直接返回 needNarrow 劝收窄,绝不硬扛。
# 缓存:<缓存目录>(env SAP_PROBE_CACHE_DIR,缺省=仓库 data/sap-mcp-probe)\
#   srccache-<SYS>.json   指纹表 {PROG: "UNAM|UDAT|UTIME"}(UNAM|UDAT|UTIME 来自 REPOSRC)
#   src\<SYS>\<PROG>.txt  源码按程序一文件(增量更新,不重拉未变件)
# 输入:system, kw(必填), pattern(默认 'Z*'), sinceDays?(只看近 N 天改过的), refresh?

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')   # v15 整合:facade工具/拍平/缓存读写收敛到共享件

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

# ============ 入参 ============
$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$system = ([string]$input_.system).Trim().ToUpper()
if ($system -notin @('DVP', 'QAS', 'PRD')) { return (Fail 'BAD_SYSTEM' "system 必须是 DVP/QAS/PRD,收到: '$system'") }
$kw = ([string]$input_.kw).Trim()
if (-not $kw) { return (Fail 'BAD_PARAM' 'kw(搜索关键字)必填') }
$pattern = ([string]$input_.pattern).Trim().ToUpper()
if (-not $pattern) { $pattern = 'Z*' }
if ($pattern -notmatch '^[A-Z0-9_%*\-\/]+$') { return (Fail 'BAD_PARAM' "pattern 只允许字母数字和 * % - _ /,收到: '$pattern'") }
Initialize-SapRoute | Out-Null   # v15:facade 死了 WMI 拉起(原无自愈)
$like = $pattern.Replace('*', '%')
$sinceDays = 0
[int32]::TryParse([string]$input_.sinceDays, [ref]$sinceDays) | Out-Null
$refresh = (($input_.refresh -eq $true) -or (([string]$input_.refresh) -eq 'true'))
$cap = 300

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$cacheDir = $global:SapProbeCacheDir   # 常量单源(2026-09-21 审查,原硬编码)
$srcDir = Join-Path $cacheDir ("src\$system")
$fpsPath = Join-Path $cacheDir ("srccache-$system.json")

try {
  # ============ 1. 枚举 REPOSRC(名字 LIKE + 激活版,超 cap 劝收窄) ============
  $where = "PROGNAME LIKE '$like' AND R3STATE = 'A'"
  if ($sinceDays -ge 1) {
    $d = (Get-Date).AddDays(-$sinceDays).ToString('yyyyMMdd')
    $where = "PROGNAME LIKE '$like' AND R3STATE = 'A' AND UDAT >= '$d'"
  }
  $q = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'REPOSRC'; where = $where; maxRows = ($cap + 1) }
  if (-not $q.ok) { return @{ ok = $false; error = $q.error } }
  $rows = @(ConvertTo-MutHashTable $q.data.rows)
  $nameMatch = [int]$q.data.rowCount
  if ($nameMatch -gt $cap) {
    return @{ ok = $true; result = [ordered]@{
      needNarrow = $true; nameMatch = $nameMatch; cap = $cap
      hint = ("名字匹配 {0} 个程序,超过单次上限 {1}。请用更窄的程序名前缀(如 ZFIT* / ZMM*),或配合「只看近 N 天」再搜。" -f $nameMatch, $cap)
      kw = $kw; pattern = $pattern; durMs = $sw.ElapsedMilliseconds
    } }
  }

  # ============ 2. 指纹增量拉源(缓存:指纹表 JSON + 源码按程序一文件) ============
  $fps = Get-SapCacheMap -Path $fpsPath
  if (-not $fps) { $fps = @{} }
  if (-not (Test-Path $srcDir)) { New-Item -ItemType Directory -Force -Path $srcDir | Out-Null }

  $pulled = 0; $reused = 0; $readFailed = @(); $sources = @{}
  $pullBudget = 80   # v15:单次请求拉源预算(原无上限,宽 pattern 冷搜最多 300 次串行 prog_read,必撞超时)
  $indexPartial = $false; $pendingPull = 0
  foreach ($r in $rows) {
    $prog = "$($r.PROGNAME)".ToUpper()
    if (-not $prog) { continue }
    $fp = ("{0}|{1}|{2}" -f $r.UNAM, $r.UDAT, $r.UTIME)
    $safeName = ($prog -replace '[^A-Z0-9_\-]', '_')
    $srcFile = Join-Path $srcDir "$safeName.txt"
    if (-not $refresh -and $fps.ContainsKey($prog) -and "$($fps[$prog])" -eq $fp -and (Test-Path $srcFile)) {
      $sources[$prog] = @((Get-Content $srcFile -Encoding UTF8))
      $reused++
      continue
    }
    if ($pulled -ge $pullBudget) { $indexPartial = $true; $pendingPull++; continue }   # 预算内拉不完:下次调用指纹增量续
    $rd = Invoke-FacadeTool -Tool 'sap_prog_read' -Args @{ system = $system; program = $prog }
    if (-not $rd.ok) { $readFailed += $prog; continue }
    $src = [string]$rd.data.source
    $sources[$prog] = @($src -split "\r?\n")
    try { [System.IO.File]::WriteAllText($srcFile, $src, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    $fps[$prog] = $fp
    $pulled++
  }
  if ($pulled -gt 0) {   # v15:指纹表零变化时不重写落盘
    Save-SapCacheMap -Path $fpsPath -Map $fps
  }

  # ============ 3. 本地扫描(大小写不敏感子串) ============
  $t2 = $sw.ElapsedMilliseconds
  $hits = New-Object System.Collections.Generic.List[object]
  $totalHits = 0
  $kwCmp = [System.StringComparison]::OrdinalIgnoreCase
  foreach ($prog in @($sources.Keys)) {
    $lines = $sources[$prog]
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i].IndexOf($kw, $kwCmp) -lt 0) { continue }
      $totalHits++
      if ($hits.Count -ge 200) { continue }   # 计数继续,明细封顶
      $txt = $lines[$i].Trim()
      if ($txt.Length -gt 200) { $txt = $txt.Substring(0, 200) }
      [void]$hits.Add(@{ program = $prog; line = ($i + 1); text = $txt })
    }
  }

  return @{ ok = $true; result = [ordered]@{
    needNarrow = $false; system = $system; kw = $kw; pattern = $pattern
    nameMatch = $nameMatch; indexed = $sources.Count; pulled = $pulled; reused = $reused
    indexPartial = $indexPartial; pendingPull = $pendingPull; pullBudget = $pullBudget
    readFailedCount = $readFailed.Count; readFailed = @($readFailed | Select-Object -First 10)
    hits = $hits.ToArray(); totalHits = $totalHits; hitCap = 200
    indexMs = ($t2 - 0); searchMs = ($sw.ElapsedMilliseconds - $t2); durMs = $sw.ElapsedMilliseconds
    refreshedFrom = $fps.Count
  } }
} catch {
  return (Fail 'CODESEARCH_FAILED' $_.Exception.Message)   # v15 删死分支:本文件从无写 FacadeCode 处(那是 sap-lint 的模式)
}
