param([Parameter(Mandatory)][hashtable]$Body)

# sap-func-explain  -  🔍 接口功能速查(2026-09-18,补齐问答↔SAP副驾链的「功能咨询」一环)
# 场景:问答里问「ZIF_MM_POCHG这个接口是干嘛的」→ 自动读 SAP 接口签名+源码要点,
#      以 append-enrich 方式追加进答案正文(零 AI 转述,杜绝幻觉)。
# 契约:_qa-intents.Invoke-IntentAppendEnrich 通用 enrichRoute(input.query → result.markdown)。
# 链:正则抽 Z/Y 名(≤3 候选;词面定函数/程序路径)→ 共用库 Get-SapExplainTarget(读签名/源码
#    /INCLUDE 跟读,2026-09-20 整合)→ Invoke-SapExplainAi chatty 解读(2026-09-21 整合)→ md。
# 降级:未识别函数名 / 函数不存在 / 凭证未连 → 一律 ok:true + 诚实说明(append 层照常展示,
#      不拦答案);仅 facade 不可达/整体失败才 ok:false(上层显示「自动查询出错」)。
# 边界:仅 qa-answer 单题链跑 append-enrich,qa-from-chat 会话链不跑(与 auth-ledger 同款边界)。
# 缓存:落盘 <缓存目录>(env SAP_PROBE_CACHE_DIR,缺省=仓库 data/sap-mcp-probe)\func-explain\,TTL 6h,键=函数名+参数问法位
#      (并行化后本路由跑在子进程,内存缓存随进程消亡失效故改盘;同函数不同问法二次命中即回)
# 凭证:复用 facade 内存凭证,本路由零密码处理(NEED_CREDENTIAL 判据在 Invoke-FacadeTool)。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')
. (Join-Path $PSScriptRoot '_sap-explain-lib.ps1')   # 共用读取库:函数/程序/INCLUDE 跟读+归一(2026-09-20 整合)
. (Join-Path $PSScriptRoot '_claude-helpers.ps1')   # Invoke-SapAi 依赖(同 sap-ask 用法)
. (Join-Path $PSScriptRoot '_qa-prefill.ps1')       # Get-QaFmNames:函数名抽取单源(2026-09-21 审查 P1——本地副本与加固版漂移 4 处,删)

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }


# ---- 问句抽函数名:单源切 _qa-prefill 的 Get-QaFmNames(2026-09-21 审查 P1)。
# 本地副本已删——与加固版漂移 4 处(缺 BAPI 模式/缺 200ms ReDoS 超时/第二字符不限字母/
# 尾下划线不剥);\b 中文边界知识见 _qa-prefill.ps1 头注。此处只做大写归一+截前 3。 ----

# ---- md 单元格转义(竖线/换行/超长截断) ----
function ConvertTo-MdCell([string]$v, [int]$maxLen = 60) {
  $t = ([string]$v).Trim() -replace '\|', '/' -replace '\r?\n', ' '
  if ($t.Length -gt $maxLen) { $t = $t.Substring(0, $maxLen) + '…' }
  return $t
}

# ---- 签名清单 → md 表(超限截断并如实注记) ----
function ConvertTo-ParamTable {
  param($Items, [string]$Title, [int]$MaxRows = 14)
  $rows = @()
  foreach ($i in @($Items)) {
    $h = ConvertTo-ItemHashtable $i
    $n = [string]$h['name']
    if ($n) { $rows += @{ name = $n; type = [string]$h['type']; text = [string]$h['text'] } }
  }
  if ($rows.Count -eq 0) { return '' }
  $out = @()
  $out += ('**' + $Title + '(' + $rows.Count + ')**')
  $out += ''
  $out += '| 参数 | 类型 | 说明 |'
  $out += '|---|---|---|'
  $shown = [Math]::Min($rows.Count, $MaxRows)
  for ($k = 0; $k -lt $shown; $k++) {
    $out += ('| ' + (ConvertTo-MdCell $rows[$k].name) + ' | ' + (ConvertTo-MdCell $rows[$k].type) + ' | ' + (ConvertTo-MdCell $rows[$k].text) + ' |')
  }
  if ($rows.Count -gt $shown) { $out += ('' + ('> (其余 ' + ($rows.Count - $shown) + ' 个参数略)')) }
  $out += ''
  return ($out -join "`n")
}

# ============ 入参 ============
$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$query = [string]$input_.query
# 出入参表按需产出:问句问到参数才附表(2026-09-18 用户定案——问接口逻辑要的是中文解读,不是参数清单)
$wantsParams = ($query -match '入参|出参|出入参|表参|传参|参数')
# 问题导向(用户实爆案例:「某工资报表的明细按钮跳转的是哪个报表」)——问句带具体疑问点
# → AI 改为问题导向作答(答他问的那一点,不再泛泛整体解读),并附确定性跳转目标清单
$wantsLogic = ($query -match '按钮|跳转|跳到|提交到|哪个报表|哪个程序|哪个事务|取数|哪张表|哪个表|逻辑在哪|在哪实现|怎么实现|如何实现|为啥|为什么')

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$system = 'QAS'   # 签名/源码各环境传输后一致,默认 QAS(与 interface-diag 同款默认)

# ---- ① 抽函数名 ----
# ★调用方一律 @() 收集(自家铁律):单元素返回流会被解包成字符串,$cands[0] 变取首字符 'Z'
$cands = @(Get-QaFmNames -Texts $query | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -First 3)
if ($cands.Count -eq 0) {
  # 目录 fastMatch 已要求函数名,走到这多为目录被手改/降级路径——诚实说明,不报错
  return @{ ok = $true; result = @{ markdown = '> ℹ 未在问题中识别到 Z/Y 函数名,跳过接口速查。'; ms = $sw.ElapsedMilliseconds } }
}
$funcName = $cands[0]

# ---- ② 缓存(6h;★落盘为主——并行化后本路由跑在子进程里,内存缓存随进程消亡失效)。
#      键含 wantsParams 位(两种产出形状分开);md 自报来源系统,键不含系统 ----
# 2026-10-14 审查 P1:wantsLogic 时必须掺问题指纹——Question 进了 AI 链(200 行)没进键,
# 同函数两个不同问法 6h 内后者直接吃前者的定向回答(答非所问且带"依据"更显可信)
$qf = $(if ($wantsLogic) { ([System.Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($query)) | ForEach-Object { $_.ToString('x2') }) -join '' })
$qf = $(if ($qf) { $qf.Substring(0, 8) } else { '' })
$cacheKey = "fn-$funcName-" + $(if ($wantsParams) { 'p1' } else { 'p0' }) + $(if ($wantsLogic) { 'l1' + $qf } else { 'l0' }) + '.json'
$cachePath = Join-Path $global:SapProbeCacheDir ("func-explain\" + $cacheKey)
$ce = Get-SapCacheMap -Path $cachePath -TtlDays 0.25
if ($ce -and $ce['md']) {
  # 溯源透传(2026-09-22):缓存命中也要带 fn/sys(写入本就存了),否则 live 来源标题缺函数名
  return @{ ok = $true; result = @{ markdown = [string]$ce['md']; function = $(if ($ce['fn']) { [string]$ce['fn'] } else { $funcName }); system = $(if ($ce['sys']) { [string]$ce['sys'] } else { $system }); cached = $true; ms = $sw.ElapsedMilliseconds } }
}

# ---- ③ 目标读取(共用库 _sap-explain-lib:函数优先→程序兜底→壳跟读→签名/源码/调用归一。
#      2026-09-20 整合:与副驾 sap-probe explain 同一实现,一个功能只写一次) ----
try { Initialize-SapRoute | Out-Null } catch {
  return (Fail 'FACADE_DOWN' "facade 拉起后仍无响应: $($_.Exception.Message)")
}
# 词面定路径(2026-09-20 用户定案):明说「程序/报表/事务码」只走程序;明说「接口/函数」只走
# 函数;都没说才 auto(函数优先,程序兜底)——说了程序就别再浪费函数查询。
$kindHint = 'auto'
if ($query -match '程序|报表|事务码') { $kindHint = 'prog' }
elseif ($query -match '接口|函数') { $kindHint = 'fm' }
$t = Get-SapExplainTarget -Names $cands -Kind $kindHint -Systems @('QAS', 'DVP') -TimeoutSec 15
# 事务码兜底(2026-10-13):Z 事务码名≠程序名时,TSTC 反查真实程序名再试一次;仍 miss 才走 notFound
$viaTcode = ''
if (-not $t.ok -and $kindHint -ne 'fm') {
  try {
    $tstc = @(Get-QueryRows -System 'QAS' -Table 'TSTC' -Where ("TCODE = '" + $cands[0] + "'") -MaxRows 1)
    if ($tstc.Count -gt 0) {
      $row0 = $tstc[0]
      $pg = ''
      if ($row0 -is [System.Collections.IDictionary]) { $pg = ([string]$row0['PGMNA']).Trim() }
      else { $p2 = $row0.PSObject.Properties['PGMNA']; if ($p2) { $pg = ([string]$p2.Value).Trim() } }
      if ($pg -and @($cands) -notcontains $pg) {
        $t2 = Get-SapExplainTarget -Names @($pg) -Kind 'prog' -Systems @('QAS', 'DVP') -TimeoutSec 15
        if ($t2.ok) { $t = $t2; $viaTcode = (';事务码 ' + $cands[0] + ' → 程序 ' + $pg) }
      }
    }
  } catch { }   # TSTC 反查失败不说话,主流程已如实
}
if (-not $t.ok) {
  $why = ''
  if ($t.tried.Count -gt 0) { $why = '未读取到(' + ($t.tried -join ', ') + ')' }
  if ($t.credMiss.Count -gt 0) {
    $why = $why + $(if ($why) { '; ' }) + (($t.credMiss | ForEach-Object { "$_ 未连凭证" }) -join ',')
    return @{ ok = $true; result = @{
      markdown = ("> ℹ 识别到 ``$funcName``:$why。连接 SAP 后重问,或用「接口排查」指令一键分析。")
      ms = $sw.ElapsedMilliseconds } }
  }
  # 查无此对象(2026-09-21 长名函数实爆):notFound=true 供 qa-answer 注入
  # 「禁编造」硬约束(主答案严禁把 KB 泛口径当作该名称的取数逻辑);前缀模糊搜索给最接近候选——
  # 先试名前两段(超长名→取前两段),零命中再退首段。
  $fuzzyTxt = ''
  try {
    $segs = $funcName.Split('_')
    $fz = @()
    $prefixes = @()
    if ($segs.Count -ge 2 -and $segs[0] -and $segs[1]) { $prefixes += ($segs[0] + '_' + $segs[1]) }
    $prefixes += $segs[0]
    foreach ($px in $prefixes) {
      if ($fz.Count -gt 0) { break }
      foreach ($row in @(Get-QueryRows -System 'QAS' -Table 'TFDIR' -Where ("FUNCNAME LIKE '" + $px + "%'") -MaxRows 8)) {
        $fn = ''
        if ($row -is [System.Collections.IDictionary]) { $fn = ([string]$row['FUNCNAME']).Trim() }
        else { $p2 = $row.PSObject.Properties['FUNCNAME']; if ($p2) { $fn = ([string]$p2.Value).Trim() } }
        if ($fn -and $fn -ne $funcName) { $fz += $fn }
      }
    }
    $fz = @($fz | Select-Object -Unique -First 5)
    if ($fz.Count -gt 0) { $fuzzyTxt = ('最接近的函数候选:' + ($fz -join '、') + '。') }
  } catch { $fuzzyTxt = '' }   # 模糊搜索失败不说话,主话术已如实
  return @{ ok = $true; result = @{
    markdown = ("> ⚠ 识别到 ``$funcName``,在 QAS/DVP $why(函数与程序都查过)。$($fuzzyTxt)请确认名称/来源,或用「接口排查」指令人工核实。")
    notFound = $true
    ms = $sw.ElapsedMilliseconds } }
}
$isProg = ($t.kind -eq 'prog')
$funcName = $t.name
$system = $t.system
$srcText = $t.source
$calls = $t.calls
$imports = $t.imports; $exports = $t.exports; $changings = $t.changings; $tablesIf = $t.tables

# ---- ⑤ 源码要点:头部 * 注释(≤8 行);内部调用清单已由共用库归一提供 ----
$headNotes = @()
if ($srcText) {
  foreach ($line in ($srcText -split "`r?`n")) {
    if ($headNotes.Count -ge 8) { break }
    $ln = $line.Trim()
    # 注释行(Z FM 生成块是 *" 前缀,手写头注是 * 或 "):StripStart 两种字符后过滤签名自动生成块
    # (分隔线/局部接口标记/IMPORTING 等段名/参数声明行),只留真有信息量的头注
    if (($ln.StartsWith('*') -or $ln.StartsWith('"')) -and $ln.Length -gt 1) {
      $c = $ln.TrimStart('*', '"').Trim()
      if (-not $c) { continue }
      if ($c -match '^[-=]{3,}') { continue }
      if ($c -match '局部接口') { continue }
      if ($c -match '^(VALUE\(|IMPORTING|EXPORTING|CHANGING|TABLES)') { continue }
      if ($c -match '^(LIKE|TYPE|STRUCTURE)\s' -or $c -match '\s(STRUCTURE|LIKE|TYPE)\s+') { continue }
      if ($c -match '^(OPTIONAL|DEFAULT)\b') { continue }
      $headNotes += (ConvertTo-MdCell $c 100)
    }
  }
}

# ---- ⑥ AI 解读(主产出:中文大白话讲是干嘛的)+ 组 md ----
# 用户定案(2026-09-18):问接口逻辑=要中文解读;出入参表仅当问句问参数时附(wantsParams)。
# 2026-09-21 整合二期:提示词/调用全切共用库 Invoke-SapExplainAi(chatty 款,与副驾 explain
# 同一分析规则);源码截断也在库内。失败降级=源码确定性要点,不编造。
$sep = [string][char]10
$toolName = if ($isProg) { 'sap_prog_read' } else { 'sap_fm_read' }
$kindTitle = if ($isProg) { '程序解读' } else { '接口解读' }
$md = @()
$md += ("> 📡 解读基于实时读取的 SAP $system 源码(``$toolName``$viaTcode;内部调用为确定性读取,解读为 AI 生成)")
$md += ''
$md += ('### ' + $funcName + ' · ' + $kindTitle)
$md += ''

$aiRes = $null
if ($srcText.Trim()) {
  $aiRes = Invoke-SapExplainAi -Target $t -Style 'chatty' -Question $(if ($wantsLogic) { $query } else { '' }) -TimeoutSec 25
}
$aiText = $(if ($aiRes) { [string]$aiRes.text } else { '' })
if ($aiText) {
  $md += $aiText
} else {
  $md += '> ⚠ AI 解读本次暂不可用,以下为源码确定性要点:'
  $md += ''
  if ($headNotes.Count -gt 0) { foreach ($h in ($headNotes | Select-Object -First 6)) { $md += ('- ' + $h) } }
  if ($calls.Count -gt 0) { $md += ('- 内部调用: ' + ($calls -join '、')) }
}
$md += ''
if ($calls.Count -gt 0 -and $aiText) {
  $md += ('**内部调用**: ' + ($calls -join '、'))
  $md += ''
}
# 确定性跳转/提交目标(2026-10-13):问「按钮跳哪/哪个报表」时附 SUBMIT/CALL TRANSACTION 清单。
# ★SUBMIT 前禁 \b——中文是 \w,中文SUBMIT 无词界必漏(与 _qa-prefill 同款教训),用 ASCII 负向断言
$jumpTargets = @()
if ($srcText) {
  foreach ($line in ($srcText -split "`r?`n")) {
    if ($jumpTargets.Count -ge 8) { break }
    if ($line -match "(?i)(?<![A-Z0-9_])SUBMIT\s+([A-Z0-9_]{4,})") {
      $jn = $Matches[1].ToUpper()
      if ($jumpTargets -notcontains $jn) { $jumpTargets += $jn }
    }
    if ($line -match "(?i)CALL\s+TRANSACTION\s+'([A-Z0-9_]{4,})'") {
      $jn = $Matches[1].ToUpper()
      if ($jumpTargets -notcontains $jn) { $jumpTargets += $jn }
    }
  }
}
if ($jumpTargets.Count -gt 0 -and ($wantsLogic -or $query -match '跳转|报表|按钮|事务')) {
  $md += ('**跳转/提交目标**: ' + ($jumpTargets -join '、'))
  $md += ''
}
if ($wantsParams -and -not $isProg) {
  $md += ('签名:入参 ' + $imports.Count + ' · 出参 ' + $exports.Count + ' · 变参 ' + $changings.Count + ' · 表参 ' + $tablesIf.Count)
  $md += ''
  foreach ($t in (ConvertTo-ParamTable -Items $imports -Title '入参 IMPORTING')) { $md += $t }
  foreach ($t in (ConvertTo-ParamTable -Items $tablesIf -Title '表参 TABLES' -MaxRows 8)) { $md += $t }
  foreach ($t in (ConvertTo-ParamTable -Items $exports -Title '出参 EXPORTING' -MaxRows 10)) { $md += $t }
  foreach ($t in (ConvertTo-ParamTable -Items $changings -Title '变参 CHANGING' -MaxRows 6)) { $md += $t }
}
$mdText = (($md -join $sep).TrimEnd())
if ($mdText.Length -gt 3800) {   # 解读是答案附录,不抢正文;超长截断如实注记
  $mdText = $mdText.Substring(0, 3800) + $sep + $sep + '> (内容超长已截断,完整信息用「接口排查」指令)'
}

# ---- ⑦ 落缓存(盘;6h TTL 由 Get-SapCacheMap -TtlDays 判定) ----
try { Save-SapCacheMap -Path $cachePath -Map @{ md = $mdText; fn = $funcName; sys = $system } } catch {}

return @{ ok = $true; result = @{ markdown = $mdText; function = $funcName; system = $system; ms = $sw.ElapsedMilliseconds } }
