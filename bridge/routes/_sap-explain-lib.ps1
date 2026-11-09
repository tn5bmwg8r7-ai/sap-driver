# ============================================================
# _sap-explain-lib  -  接口/程序解读共用读取库(2026-09-20 整合,用户定案「一个功能只写一次」)。
#
# 消费方:sap-func-explain.ps1(问答速查 append)、sap-probe.ps1 explain(副驾概览卡)。
# 职责:目标读取全流程——函数优先→程序兜底(REPOSRC)→ 程序壳 INCLUDE 跟读 → 归一形状
#      (签名/源码/内部调用),以及统一 AI 解读 Invoke-SapExplainAi(分析规则一处,
#      输出长相分 chatty=速查大白话 / overview=副驾结构化概览 两款式)。
#      调用方自持的只剩:落缓存、md 组装、错误分流等产品形态差异。
#
# 依赖(调用方先 dot-source):_sap-facade.ps1(Invoke-FacadeTool)、_sap-lib.ps1(ConvertTo-FlatHashtable)。
# 红线沿用:全部经 facade 只读,NEED_CREDENTIAL 原样上报;零密码处理。
# ============================================================

# 浅拍平单个数组元素(PSCustomObject/Hashtable 混形统一)。2026-09-21 审查 P2 定名
# ConvertTo-ItemHashtable 为单源(func-explain/interface-diag 本地副本已删;
# ⚠ 有意区别于 _sap-lib 的 ConvertTo-FlatHashtable——那是顶层拍平,无 IDictionary 早退)。
function ConvertTo-ItemHashtable([object]$item) {
  if ($null -eq $item) { return @{} }
  if ($item -is [System.Collections.IDictionary]) { return $item }
  $h = @{}
  foreach ($p in $item.PSObject.Properties) { $h[$p.Name] = $p.Value }
  return $h
}

function Get-SapExplainTarget {
  param(
    [Parameter(Mandatory)][string[]]$Names,                        # 候选名(按序,≤3)
    [ValidateSet('auto', 'fm', 'prog')][string]$Kind = 'auto',     # auto=函数优先程序兜底;probe 显式指定
    [string[]]$Systems = @('QAS', 'DVP'),
    [int]$TimeoutSec = 15,                                         # 单次读取闸(append 在 QA 主链内,别吃默认 110s)
    [int]$MaxIncludes = 4,
    [int]$IncludeTimeoutSec = 10
  )

  $tried = @(); $credMiss = @(); $hit = $null

  # ① 函数:sap_fm_read(签名+源码)
  if ($Kind -in @('auto', 'fm')) {
    foreach ($sys in $Systems) {
      foreach ($c in $Names) {
        $r = Invoke-FacadeTool -Tool 'sap_fm_read' -Args @{ system = $sys; function = $c; includeSource = $true } -TimeoutSec $TimeoutSec
        if ($r.ok) { $hit = @{ kind = 'fm'; name = $c; system = $sys; data = $r.data }; break }
        $ec = [string]$r.error.code
        if ($ec -eq 'NEED_CREDENTIAL') { $credMiss += $sys; break }   # 同系统换候选结果相同
        $tried += ("$sys/$c($ec)")
      }
      if ($hit) { break }
    }
  }

  # ② 程序兜底:sap_prog_read(REPOSRC 直读)。★某系统缺凭证只跳过该系统,不放弃其余
  #    系统的兜底(2026-09-21 实爆:QAS 有凭证+DVP 缺凭证时,QAS 本可命中的程序被
  #    DVP credMiss 整段挡死——旧条件 $credMiss.Count -eq 0 过粗)
  if (-not $hit -and $Kind -in @('auto', 'prog')) {
    foreach ($sys in $Systems) {
      if ($credMiss -contains $sys) { continue }
      foreach ($c in $Names) {
        $r = Invoke-FacadeTool -Tool 'sap_prog_read' -Args @{ system = $sys; program = $c } -TimeoutSec $TimeoutSec
        if ($r.ok) { $hit = @{ kind = 'prog'; name = $c; system = $sys; data = $r.data }; break }
        $ec = [string]$r.error.code
        if ($ec -eq 'NEED_CREDENTIAL') { $credMiss += $sys; break }
        $tried += ("$sys/prog-$c($ec)")
      }
      if ($hit) { break }
    }
  }

  if (-not $hit) { return @{ ok = $false; tried = $tried; credMiss = $credMiss } }

  # ③ 源码;程序壳跟随 INCLUDE(主程序多为壳,真逻辑在 include;主源码 <200 行才跟读)
  $src = [string]$hit.data['source']
  $ifaceJson = '{}'
  if ($hit.kind -eq 'fm') {
    try { $ifaceJson = $hit.data['interface'] | ConvertTo-Json -Depth 8 -Compress } catch {}
  }
  if ($hit.kind -eq 'prog' -and $src -and (@($src -split "`r?`n").Count -lt 200)) {
    $incNames = @()
    # 正则口径与 sap-lint.ps1 同款(2026-09-21 审查 P1 对齐):行首锚定(排除 * / " 注释行)+
    # 排除 INCLUDE STRUCTURE/TYPE 数据声明——那不是程序 include,误抽会白烧读取并挤掉真 include
    foreach ($m2 in [regex]::Matches($src, '(?im)^\s*INCLUDE\s+(?!STRUCTURE\b|TYPE\b)([A-Z0-9_]{4,})')) {
      $n2 = $m2.Groups[1].Value.ToUpper()
      if ($n2 -ne $hit.name -and $incNames -notcontains $n2) { $incNames += $n2 }
      if ($incNames.Count -ge $MaxIncludes) { break }
    }
    foreach ($inc in $incNames) {
      try {
        $ri = Invoke-FacadeTool -Tool 'sap_prog_read' -Args @{ system = $hit.system; program = $inc } -TimeoutSec $IncludeTimeoutSec
        if ($ri.ok) {
          $i2 = [string]$ri.data['source']
          if ($i2.Trim()) { $src = $src + "`n`n*** INCLUDE $inc (源码) ***`n" + $i2 }
        }
      } catch {}
    }
  }

  # ④ 归一:签名四向(fm;prog 全空)+ 内部调用(CALL FUNCTION 去重 ≤8)
  $imports = @(); $exports = @(); $changings = @(); $tablesIf = @()
  if ($hit.kind -eq 'fm') {
    $ifn = $hit.data['interface']
    $iface = if ($null -ne $ifn) { ConvertTo-FlatHashtable $ifn } else { @{} }
    foreach ($k in @('importing', 'exporting', 'changing', 'tables')) {
      $lst = @()
      foreach ($i in @($iface[$k])) {
        $h = ConvertTo-ItemHashtable $i
        if ([string]$h['name']) { $lst += @{ name = [string]$h['name']; type = [string]$h['type']; text = [string]$h['text'] } }
      }
      switch ($k) {
        'importing' { $imports = $lst }
        'exporting' { $exports = $lst }
        'changing'  { $changings = $lst }
        'tables'    { $tablesIf = $lst }
      }
    }
  }
  $calls = @()
  if ($src) {
    foreach ($line in ($src -split "`r?`n")) {
      if ($line -match "(?i)CALL\s+FUNCTION\s+'([A-Z0-9_]+)'" -and $calls.Count -lt 8) {
        $cn = $Matches[1].ToUpper()
        if ($cn -ne $hit.name -and $calls -notcontains $cn) { $calls += $cn }
      }
      if ($calls.Count -ge 8) { break }
    }
  }

  return @{
    ok = $true; kind = $hit.kind; name = $hit.name; system = $hit.system
    source = $src; interfaceJson = $ifaceJson
    imports = $imports; exports = $exports; changings = $changings; tables = $tablesIf
    calls = $calls; tried = $tried; credMiss = $credMiss
  }
}

# 统一 AI 解读(2026-09-20 用户定案「分析逻辑也应整合」):分析规则一处,
# 输出长相分两款式——chatty=速查大白话附录(≤300字,MaxTokens 800)/overview=副驾结构化概览(≤350字,1200)。
# 依赖:Invoke-SapAi(_claude-helpers,调用方 dot-source)。返回 @{text;model} 或 $null。
function Invoke-SapExplainAi {
  param(
    [Parameter(Mandatory)]$Target,          # Get-SapExplainTarget 的返回(ok 可为 false→仅靠 ExtraContext)
    [ValidateSet('chatty', 'overview')][string]$Style = 'chatty',
    [string]$ExtraContext = '',             # 副驾选择屏幕等补充事实
    [string]$Question = '',                 # 用户原问(2026-10-13):给了就问题导向作答(答他问的那一点),不给=通用解读
    [int]$TimeoutSec = 25
  )
  $src = [string]$Target.source
  if ($src.Length -gt 15000) { $src = $src.Substring(0, 15000) + "`n*(源码过长已截断)*" }
  if (-not $src.Trim() -and -not $ExtraContext.Trim()) { return $null }
  $kindCn = if ($Target.kind -eq 'prog') { '程序' } else { '函数/接口' }
  $sig = ''
  if ($Target.kind -eq 'fm') {
    # 2026-09-21 整合二期:名字后带 DDIC 说明(截 40)——overview 款「输入」小表有据可依
    # (原 probe 版塞完整签名 JSON;chatty 款提示词已锁「勿复述」,信息增模型不增篇幅)
    $sigParts = @()
    foreach ($p in (@($Target.imports) + @($Target.tables) + @($Target.exports))) {
      $ph = ConvertTo-ItemHashtable $p
      $nm = [string]$ph['name']; if (-not $nm) { continue }
      $tx = (([string]$ph['text']).Trim() -replace '\s+', ' ')
      if ($tx.Length -gt 40) { $tx = $tx.Substring(0, 40) + '…' }
      $sigParts += ($nm + $(if ($tx) { '(' + $tx + ')' }))
    }
    $sig = '参数名一览(仅供对照,勿复述):' + ($sigParts -join ', ') + '.'
  }
  $fmt = if ($Question.Trim()) {
    # 问题导向款(2026-10-13):用户问的是具体一点(按钮跳哪/取哪张表),别再泛泛整体解读
    '输出 Markdown:第一行直接回答用户的问题(1-2 句,结论先行);然后「**依据**」给源码证据(关键语句/调用/事务目标,标注所在 include 或行号更佳);全文 ≤300 字。源码看不出答案就明说「源码中未见」,并给最接近的线索(相关变量/调用),严禁编造。'
  } elseif ($Style -eq 'overview') {
    '输出 Markdown 分节:「## 这个' + $kindCn + '做什么」1-3 句;「## 输入」小表(有选择屏幕/参数事实才列);「## 取数/处理逻辑」要点式;「## 使用注意」最多 3 条;总长 ≤350 字。'
  } else {
    '输出 Markdown:第一段「**一句话定位**:…」;然后「**核心逻辑**」3-6 个要点;确有依据时给「**注意点**」(提交/锁/权限/异常/特殊控制)1-3 点;全文不超过 300 字。'
  }
  $sysPrompt = if ($Question.Trim()) {
    ('你是资深 SAP ABAP 专家。根据给出的' + $kindCn + '源码,回答用户关于它的具体问题。只准依据源码可见的事实,禁止编造;看不懂的部分如实说,推测要标注「推断」。' + $fmt)
  } else {
    ('你是资深 SAP ABAP 专家。根据给出的' + $kindCn + '源码' + $(if ($Target.kind -eq 'fm') { '与签名' }) + ',用中文大白话向同事解读这个' + $kindCn + '是干嘛的、内部怎么实现。只准依据源码可见的事实,禁止编造;看不懂的部分如实说,推测要标注「推断」。' + $fmt)
  }
  # 反引号代码围栏用 [char]96 拼——双引号串里写反引号是转义地狱(首次落地即翻车)
  $fence = ([string][char]96) * 3
  $qLead = if ($Question.Trim()) { ('用户的问题:' + $Question.Trim() + ([string][char]10) + ([string][char]10)) } else { '' }
  $usrPrompt = ($qLead + $kindCn + ' ' + $Target.name + '(系统 ' + $Target.system + ')。' + $sig + $(if ($ExtraContext.Trim()) { ([string][char]10) + $ExtraContext }) + ([string][char]10) + 'ABAP 源码:' + ([string][char]10) + $fence + ([string][char]10) + $src + ([string][char]10) + $fence)

  $maxTok = if ($Style -eq 'overview') { 1200 } else { 800 }
  # Invoke-SapAi 内部已硬编码 NoThinking;此处不可再传 -NoThinking(简单函数未知命名参数
  # 会被 PS5.1 静默吞,恰无害但埋雷——2026-09-21 清理)
  $ai = Invoke-SapAi -UserPrompt $usrPrompt -SystemPrompt $sysPrompt -MaxTokens $maxTok -TimeoutSec $TimeoutSec
  if ($ai -and $ai.text) { return @{ text = ([string]$ai.text).Trim(); model = [string]$ai.model } }
  return $null
}
