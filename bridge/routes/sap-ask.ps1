param([Parameter(Mandatory)][hashtable]$Body)

# sap-ask  -  SAP Driver AI 编排引擎(P2 核心,2026-09-14)。
# 一句话 → AI 出执行计划(13个facade工具的实时清单)→ bridge 按计划串行调 facade
# (参数支持 {{sN.路径}} 引用上一步结果)→ AI 汇总成带证据的结论。
# 每一步都经 facade /run → 治理+审计同源,自动进统一总账(channel=pw)。
#
# 设计取舍(v1):
#   - 计划一次成型,不做执行中重规划(步失败如实呈现,AI 在结论里解释缺口);重规划留 v1.1
#   - 引用语法仅支持「整值引用」:args 值 = "{{s1.rows.0.MATNR}}" 整体替换为解析对象
#   - 敏感数据防护:sap_deepseek 在工具清单里,规划器被明确引导薪酬/绩效类走它;PRD 只读硬闸在 facade

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_claude-helpers.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')   # v15: progress/AI shared helpers

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$question = ([string]$input_.question).Trim()
if (-not $question) { return (Fail 'NEED_QUESTION' '请输入你的问题。') }
if ($question.Length -gt 2000) { $question = $question.Substring(0, 2000) }
$context = [string]$input_.context
$system = if ($input_.system) { ([string]$input_.system).Trim().ToUpper() } else { 'DVP' }
if (@('DVP','QAS','PRD') -notcontains $system) { return (Fail 'BAD_SYSTEM' "system 仅支持 DVP/QAS/PRD: $system") }

# ---------- 进度文件(widget 轮询 sap-ask-progress 实时读;结束时删除=自然终止信号) ----------
$script:AskProgressFile = $null
$callId = [string]$input_.callId
if ($callId -match '^[a-f0-9-]{8,40}$') {
  $script:AskProgressFile = Join-Path $global:SapProgressDir ("ask-$callId.json")
}
function Write-AskProgress([string]$Phase, [int]$Step, [int]$Total, [string]$Tool) {
  Write-SapProgress -File $script:AskProgressFile -Phase $Phase -Step $Step -Total $Total -Tool $Tool   # v15: shared (atomic replace)
}
# 多轮追问:widget 传最近几轮 {question, answer, tools},供规划器衔接代词
$historyBlock = ''
$hist = $input_.history
if ($hist) {
  $hLines = @()
  foreach ($h in @($hist) | Select-Object -First 3) {
    if (-not $h -or -not $h.question) { continue }
    $ans = [string]$h.answer
    if ($ans.Length -gt 260) { $ans = $ans.Substring(0, 260) + '…' }
    $ans = ($ans -replace '\r?\n', ' ')
    $tls = (@($h.tools) | Where-Object { $_ }) -join ','
    $hLines += ("- 问: $([string]$h.question)`n  答: $ans`n  用过的工具: $tls")
  }
  if ($hLines.Count) {
    $historyBlock = "`n最近对话(当前问题里的代词如「它/那个/刚才」指这里):`n" + ($hLines -join "`n")
  }
}

# ---------- 合成模式(v6):多轮跑完后,把各轮结论整合成一份最终交付物 ----------
# input.synthesizeFrom = [{question, answer}, …≤5]。纯 AI 汇总:不拉 facade、不规划、
# 不执行(工具缺口该在前几轮解决);进度照报 synth,前端轮询零改动。
$synthFrom = $input_.synthesizeFrom
if ($synthFrom) {
  Write-AskProgress 'synth' 0 0 ''
  $swSynth = [System.Diagnostics.Stopwatch]::StartNew()
  $roundLines = @()
  $ri = 0
  foreach ($r in @($synthFrom) | Select-Object -First 5) {
    if (-not $r -or -not $r.answer) { continue }
    $ri++
    $a = [string]$r.answer
    if ($a.Length -gt 3000) { $a = $a.Substring(0, 3000) + '…(截断)' }
    $roundLines += ("【第$ri 轮】问: $([string]$r.question)`n$a")
  }
  if ($roundLines.Count -lt 2) {
    return (Fail 'NEED_ROUNDS' '合成至少要有 2 轮已有结论(单轮直接用当前结论即可)。')
  }
  $mergeSys = @"
你是资深 SAP 顾问。用户围绕同一目标跑了几轮查证,现在把各轮结论**整合成一份最终交付物**,要求:
- 以最终交付为导向重排结构:结论/答案 → 关键数据(表格) → 遗留缺口与建议;去重、消解各轮矛盾(以更晚轮次为准),不要逐轮复述
- 只依据各轮给出的信息,不臆造新数据;引用具体表名/字段/数字
- 中文,紧凑专业;能用 markdown 表格就用表格
- 结尾如仍有明确的、可一句话执行的后续动作,输出一行 <!--NEXT:动作描述-->;没有就完全不输出该标记
"@
  $mergeUser = "合成目标: $question`n`n各轮结论:`n" + ($roundLines -join "`n`n")
  $mergeAi = Invoke-SapAi -UserPrompt $mergeUser -SystemPrompt $mergeSys -MaxTokens 3000
  $answer = $(if ($mergeAi) { $mergeAi.text } else { '' })
  $swSynth.Stop()
  if (-not $answer) { return (Fail 'AI_GEN_FAILED' 'AI 合成失败,请重试(各轮结论仍完好保留)。') }
  $nextHint = ''
  $nh = Get-SapNextHint -Answer $answer
  $answer = $nh.answer; $nextHint = $nh.nextHint
  if ($script:AskProgressFile) { Remove-Item $script:AskProgressFile -Force -ErrorAction SilentlyContinue }
  $model = $(if ($mergeAi) { $mergeAi.model } else { '' })
  return @{
    ok = $true
    result = [ordered]@{
      question = $question; system = $system; answer = $answer; nextHint = $nextHint
      synthesized = $true; steps = @(); planRaw = $null
      timings = [ordered]@{ planMs = 0; execMs = 0; synthMs = [long]$swSynth.ElapsedMilliseconds; totalMs = [long]$swTotal.ElapsedMilliseconds }
      model = $model
    }
  }
}

# ---------- 0) facade 就绪 + 动态工具清单(与白名单永远同步,零漂移) ----------
try {
  $up = Ensure-SapFacade
  if (-not $up.running) { return (Fail 'FACADE_DOWN' 'facade 拉起失败,无法执行工具。') }
} catch {
  return (Fail 'FACADE_ENSURE_FAILED' $_.Exception.Message)
}
$toolsResp = Invoke-SapFacadeApi -Method GET -Path '/tools' -TimeoutSec 10
if (-not $toolsResp.ok) { return (Fail 'FACADE_TOOLS_FAILED' $toolsResp.error) }
$toolLines = @()
foreach ($t in @($toolsResp.data.tools)) {
  $ps = @(@($t.params) | ForEach-Object { $_.name + ($(if ($_.optional) { '?' } else { '' })) }) -join ','
  $envs = (@($t.allowedEnvs) -join '/')
  $desc = [string]$t.description
  if ($desc.Length -gt 90) { $desc = $desc.Substring(0, 90) }
  $toolLines += "- $($t.name)($ps) [$envs] $desc"
}
$toolManifest = ($toolLines -join "`n")

# v15.1 暴露工具名集合 + 常见幻觉工具别名(09-18 实爆:规划器编造 sap_ddic_read → UNKNOWN_TOOL)
# 命中别名且真身在清单里 → 执行前纠正;救不了才原样下发,facade UNKNOWN_TOOL 如实回报。
$sapAskExposed = @{}
foreach ($_t in @($toolsResp.data.tools)) { $sapAskExposed[[string]$_t.name] = $true }
$sapAskToolAliases = @{
  'sap_ddic_read'      = 'sap_object_meta'; 'sap_ddic'    = 'sap_object_meta'; 'sap_meta'       = 'sap_object_meta'
  'sap_read_table'     = 'sap_query';       'sap_table_read' = 'sap_query';   'sap_table_query' = 'sap_query'
  'sap_prog_source'    = 'sap_prog_read';   'sap_source_read' = 'sap_prog_read'
  'sap_function_read'  = 'sap_fm_read';     'sap_fm_interface' = 'sap_fm_read'
  'sap_fm_call'        = 'sap_fm_exec';     'sap_fm_run'   = 'sap_fm_exec'
}

# ---------- 1) 引用解析:{{sN.a.b[0].c}} 整值替换 + v15.2 串内插 ----------
# v15.2:路径解析抽成 Resolve-RefPath(整值与内插共用);字段不存在时附可用字段清单帮 AI 自纠
function Resolve-RefPath {
  param([string]$Path, $StepResults)
  $m = [regex]::Match($Path, '^s(\d+)(.*)$')
  if (-not $m.Success) { return @{ err = "引用格式非法: $Path(应为 {{sN.路径}})" } }
  $idx = [int]$m.Groups[1].Value - 1
  if ($idx -lt 0 -or $idx -ge @($StepResults).Count) { return @{ err = "引用步不存在: $Path" } }
  $cur = $StepResults[$idx].result
  if ($null -eq $cur) { return @{ err = "引用步 $Path 无结果(该步可能失败)" } }
  $rest = $m.Groups[2].Value.Trim('.', ' ')
  if ($rest) {
    foreach ($seg in ($rest -split '\.')) {
      $ix = $null; $name = $seg
      if ($seg -match '^(.+?)\[(\d+)\]$') { $name = $matches[1]; $ix = [int]$matches[2] }
      # v15.2 修复:先下钻属性再下标(旧码把 [i] 直接应用在当前节点上,rows[0] 永远取不到行)
      if ($name -match '^\d+$') {
        $arr = @($cur)
        if ([int]$name -ge $arr.Count) { return @{ err = "引用越界: $Path" } }
        $cur = $arr[[int]$name]
      } elseif ($name) {
        $prop = $cur.PSObject.Properties[$name]
        if (-not $prop) {
          $avail = (@($cur.PSObject.Properties.Name) | Select-Object -First 10) -join ','
          return @{ err = "引用字段不存在: $Path(断在 $seg;可用字段: $avail)" }
        }
        $cur = $prop.Value
      }
      if ($null -ne $ix) {
        $arr = @($cur)
        if ($ix -ge $arr.Count) { return @{ err = "引用越界: $Path" } }
        $cur = $arr[$ix]
      }
      if ($null -eq $cur) { return @{ err = "引用路径中断(null): $Path" } }
    }
  }
  return @{ val = $cur }
}
function Resolve-RefValue {
  param($Value, $StepResults)
  if ($Value -is [string]) {
    if ($Value -match '^\{\{([^}]+)\}\}$') {
      return (Resolve-RefPath -Path $matches[1].Trim() -StepResults $StepResults)
    }
    # v15.2 串内插:"L{{s2.rows[0].AREA}}U01" —— 引用嵌字符串中间也替换(09-18 实爆:PRD 取函数组拼 include 名)
    if ($Value -match '\{\{') {
      $out = [string]$Value; $guard = 0
      while ($out -match '\{\{([^{}]+)\}\}' -and $guard -lt 10) {
        $guard++
        $r = Resolve-RefPath -Path $matches[1].Trim() -StepResults $StepResults
        if ($r.err) { return @{ err = $r.err } }
        $rv = $r.val
        if ($rv -isnot [string] -and $rv -isnot [ValueType]) { $rv = ($rv | ConvertTo-Json -Compress -Depth 6) }
        $out = $out.Replace($matches[0], [string]$rv)
      }
      return @{ val = $out }
    }
    return @{ val = $Value }
  }
  if ($Value -is [System.Collections.IDictionary]) {
    $out = @{}
    foreach ($k in @($Value.Keys)) {
      $r = Resolve-RefValue -Value $Value[$k] -StepResults $StepResults
      if ($r.err) { return $r }
      $out[$k] = $r.val
    }
    return @{ val = $out }
  }
  # v15.2 关键修复:PS5.1 ConvertFrom-Json 产 PSCustomObject——string/IDictionary/IEnumerable
  # 三条全不命中,原样返回导致引用从未被解析(09-18 E2E 实爆:args 带着原始 {{sN}} 直打 facade)
  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    $out = [ordered]@{}
    foreach ($prop in @($Value.PSObject.Properties)) {
      $r = Resolve-RefValue -Value $prop.Value -StepResults $StepResults
      if ($r.err) { return $r }
      $out[$prop.Name] = $r.val
    }
    return @{ val = $out }
  }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    $list = @()
    foreach ($v in @($Value)) {
      $r = Resolve-RefValue -Value $v -StepResults $StepResults
      if ($r.err) { return $r }
      $list += ,$r.val
    }
    return @{ val = $list }
  }
  return @{ val = $Value }
}

# ---------- 2) AI 规划 ----------
$swPlan = [System.Diagnostics.Stopwatch]::StartNew()
$planSys = @"
你是 SAP 工作编排规划器。把用户的一句话问题规划成对下列工具的 1~6 步串行调用,输出 STRICT JSON(无 markdown 无解释)。

可用工具(参数名带?=可选;[环境]=允许的系统):
$toolManifest

规划规则:
- 每步 {"tool":"工具名","args":{...},"why":"一句话目的"};步序即执行序,后步可用前步结果
- 参数引用:"{{sN.路径}}" 整值替换;引用嵌在字符串中间也行(如 "L{{s2.rows[0].AREA}}U01");sap_query 的数据行在 .rows 数组(没有 .results);路径用点号,数组用 [i]
- 不编造表名/函数名/参数值;拿不准结构时先跑 meta 类工具(sap_object_meta/sap_fm_read)再定后续参数
- 工具名必须逐字用清单里的名字,一个字不能改(没有 sap_ddic_read 这种工具;查表/结构/字段元信息用 sap_object_meta)
- PRD 上 sap_fm_read 常拿不到源码(sourceError,权限边界,签名仍有效);任何系统下 fm_read 的 sourceError 非 null 且确实需要源码,就绕行:sap_query 查 ENLFDIR(FUNCNAME=函数名,fields 取 FUNCNAME/AREA)拿 AREA(函数组)→ sap_prog_read **从 L<AREA>U01 起逐个顺序扫**:读到的 include 里没有目标 FUNCTION 名就读下一个(U02/U03…),找到即停;一个 include 可能装多个函数,绝不能拿第一个 include 冒充目标;扫 5 个仍没有就如实报告已扫范围
- sap_fm_exec 的 paramSet 只在用户明确给出参数集名时才用(没存过的参数集必报 PARAMSET_NOT_FOUND);缺省执行直接给 import 参数;不确定存没存过就先 sap_testdata_list
- 读表默认 maxRows 20 以内;"有哪些/列表"类给足 maxRows(≤100)
- system 参数一律用 "$system"
- 涉薪酬/绩效等敏感个人数据 → 用 sap_deepseek(intent 写清分析目的),不要用 sap_query 拉明细
- 能 1 步完成就不用 2 步;凡查 SAP 数据/对象的问题必须给步骤
- 只有不涉及任何 SAP 系统数据的寒暄/闲聊才给空步骤数组
- 绝不需要密码;PRD 只读
- PRD 上绝不规划 sap_fm_exec 真跑 Z/Y 函数(须用户逐次批准,不在自动编排内);查数据用 sap_query 读表

示例:问题"QAS 的 T001 表里有哪些公司代码?" →
{"steps":[{"tool":"sap_query","args":{"system":"QAS","table":"T001","maxRows":20},"why":"读公司代码主数据"}]}
示例:问题"看看 DVP 上 Z_MM_DOC_CREATE 是干嘛的" →
{"steps":[{"tool":"sap_fm_read","args":{"system":"DVP","function":"Z_MM_DOC_CREATE"},"why":"读函数接口和源码"}]}

输出 JSON: {"steps":[{"tool":"...","args":{},"why":"..."}]}
"@
$planUser = "系统: $system`n问题: $question$historyBlock" + $(if ($context) { "`n补充材料:`n$context" } else { '' })
Write-AskProgress 'plan' 0 0 ''
$planAi = Invoke-SapAi -UserPrompt $planUser -SystemPrompt $planSys -MaxTokens 1500 -Temperature 0.1
try {
  if (-not $planAi) { throw 'AI empty' }
  $plan = ConvertFrom-ClaudeJson -Text $planAi.text
} catch {
  return (Fail 'PLAN_FAILED' "AI 规划失败:$($_.Exception.Message)")
}
$swPlan.Stop()
$planRaw = ''
if ($planAi -and $planAi.text) { $planRaw = [string]$planAi.text; if ($planRaw.Length -gt 600) { $planRaw = $planRaw.Substring(0, 600) } }
if (-not $plan) { return (Fail 'PLAN_EMPTY' "AI 未返回有效计划。raw=$planRaw") }
$steps0 = @($plan.steps) | Where-Object { $_ -and $_.tool }
if ($steps0.Count -gt 6) { $steps0 = @($steps0 | Select-Object -First 6) }
# 空步骤(寒暄类/纯知识类)不再走 canned 兜底:顺流进第 4 段 AI 汇总,基于模型自身 SAP 知识回答

# ---------- 3) 串行执行(每步 facade /run,治理审计同源) ----------
$swExec = [System.Diagnostics.Stopwatch]::StartNew()
$stepResults = @()   # @{ tool; args; ms; ok; error?; result? }(本轮;引用 {{sN}} 按它从 1 解析)
$pooledResults = @() # 前几轮(replan 前)已执行结果——replan 清空 stepResults 后,汇总证据仍要带上它们
$stepReports = @()   # 前端/汇总用
$replans = 0         # 自愈重规划次数(≤1;NEED_CREDENTIAL 类不重试,重试也没用)
$abortNoRetry = $false
$pendingSteps = @($steps0)
:replanLoop while ($true) {
  $stepNo = $stepResults.Count
  $stepTotal = ($stepResults.Count + $pendingSteps.Count)
  foreach ($s in $pendingSteps) {
    $stepNo++
    $tool = ([string]$s.tool).Trim()
    $why = [string]$s.why
    # v15.1 幻觉工具名兜底(见上方别名表)
    if (-not $sapAskExposed.ContainsKey($tool) -and $sapAskToolAliases.ContainsKey($tool)) {
      $aliased = [string]$sapAskToolAliases[$tool]
      if ($sapAskExposed.ContainsKey($aliased)) {
        $why = ("别名纠正 {0}→{1}: {2}" -f $tool, $aliased, $why)
        $tool = $aliased
      }
    }
    Write-AskProgress 'exec' $stepNo $stepTotal $tool
    $argsRaw = $s.args
    $rArgs = Resolve-RefValue -Value $argsRaw -StepResults $stepResults
    $rec = [ordered]@{ n = $stepNo; tool = $tool; why = $why; ms = 0; ok = $false }
    if ($rArgs.err) {
      $rec.error = "REF_ERROR: $($rArgs.err)"
    } else {
      $argsObj = $rArgs.val
      # v18.1 PRD 真跑硬闸(09-18 用户定案「每次执行须本人同意,不能随便拿」):
      # Agent 编排绝不自动真跑 PRD 的 Z/Y 函数;标准只读巡检 FM(ENQUEUE_READ 等)不受影响。
      # Z/Y 函数真跑必须用户在 Claude Code 会话逐次批准后由 CC 直发 facade。
      if ($tool -eq 'sap_fm_exec' -and $system -eq 'PRD') {
        $fnName = ''
        try { $fnName = ([string]$argsObj.function).ToUpper().Trim() } catch {}
        if ($fnName -match '^[ZY]' -or $fnName -like '/NSP/*') {
          $rec.error = 'PRD_ZTEST_NEEDS_CONFIRM: PRD 真跑 Z/Y 函数须用户逐次批准,Agent 编排不自动执行(09-18 用户定案)。请在 Claude Code 会话申请执行。'
          $stepReports += [pscustomobject]$rec
          $abortNoRetry = $true
          break
        }
      }
      $rec.args = $argsObj
      $json = '{}'
      try { if ($null -ne $argsObj) { $json = $argsObj | ConvertTo-Json -Depth 24 -Compress } } catch { $json = '{}' }
      $r = Invoke-SapFacadeApi -Method POST -Path "/run/$tool" -JsonBody $json -TimeoutSec 100
      if (-not $r.ok) {
        $rec.error = "FACADE_HTTP: $($r.error)"
      } else {
        $d = $r.data
        if ($d.ok) {
          $rec.ok = $true; $rec.ms = [long]$d.durationMs; $rec.result = $d.result
        } else {
          $rec.error = "$($d.code): $($d.message)"
          if ($rec.error.Length -gt 300) { $rec.error = $rec.error.Substring(0, 300) }
          $rec.ms = [long]($d.durationMs + $r.httpMs)
        }
        $stepResults += @{ tool = $tool; args = $argsObj; ms = $rec.ms; ok = [bool]$rec.ok
                           error = $rec.error; result = $(if ($d.ok) { $d.result } else { $null }) }
      }
    }
    $stepReports += [pscustomobject]$rec
    if (-not $rec.ok) {
      # 凭证/权限类失败:重规划无意义,如实交给汇总
      if ($rec.error -match '^(NEED_CREDENTIAL|PRD_FORBIDDEN|ENV_NOT_ALLOWED|TOOL_NOT_EXPOSED|UNKNOWN_TOOL|FACADE_DOWN|FACADE_HTTP|REF_ERROR)') {
        $abortNoRetry = $true
      }
      break   # 中断本轮剩余步骤(引用链已断)
    }
  }
  # ---------- 自愈重规划:步失败且值得救 → AI 带错误上下文改计划,补跑 ≤3 步 ----------
  $lastErr = ''
  $lastFailRec = @($stepReports | Where-Object { -not $_.ok }) | Select-Object -Last 1
  if ($lastFailRec) { $lastErr = [string]$lastFailRec.error }
  if (-not $abortNoRetry -and $lastErr -and $replans -lt 1) {
    $replans++
    Write-AskProgress 'replan' 0 0 ''
    $doneLines = @()
    foreach ($sr in $stepResults) {
      $aj = '{}'
      try { $aj = ($sr.args | ConvertTo-Json -Depth 8 -Compress) } catch {}
      if ($aj.Length -gt 200) { $aj = $aj.Substring(0, 200) }
      $doneLines += ("- $($sr.tool) args=$aj → " + $(if ($sr.ok) { '成功' } else { "失败: $($sr.error)" }))
    }
    $replanSys = @"
你是 SAP 工作编排规划器。此前为完成用户问题排了工具计划,但某一步失败了。请根据已执行步骤和失败原因,给出**补充计划**(0~3 步)完成剩余工作。
规则:若失败不可挽回(对象不存在/无法访问),给空步骤数组;能换路径(改用 meta 工具先摸结构、换表、修参数)就修;引用语法同前({{sN.路径}},N 按补跑步骤重新从 1 计)。
输出 STRICT JSON: {"steps":[{"tool":"...","args":{},"why":"..."}]}
"@
    $replanUser = "系统: $system`n问题: $question`n`n已执行:`n" + ($doneLines -join "`n") + "`n`n失败步骤: $lastErr"
    $rpAi = Invoke-SapAi -UserPrompt $replanUser -SystemPrompt $replanSys -MaxTokens 800 -Temperature 0.1
    $rp = $null
    try { if ($rpAi) { $rp = ConvertFrom-ClaudeJson -Text $rpAi.text } } catch { $rp = $null }
    $newSteps = @()
    if ($rp -and $rp.steps) { $newSteps = @($rp.steps) | Where-Object { $_ -and $_.tool } | Select-Object -First 3 }
    if ($newSteps.Count) {
      # 补跑步骤引用重新编号:注入结果映射,使 {{s1..}} 指向补跑序列自身。
      # 前轮结果移入 pooledResults——evidence 只读 stepResults,直接清空会把首轮成功证据
      # 静默丢出汇总(09-16 审查实爆,原注释「保留在汇总证据里」与行为不符)。
      $pooledResults += $stepResults
      $pendingSteps = $newSteps
      $stepResults = @()
      continue replanLoop
    }
  }
  break
}
$swExec.Stop()

# ---------- 4) AI 汇总(带证据,给结论) ----------
Write-AskProgress 'synth' 0 0 ''
$swSynth = [System.Diagnostics.Stopwatch]::StartNew()
function Trim-StepForSynth([hashtable]$sr) {
  $cap = 3500
  if (-not $sr.ok) { return @{ tool = $sr.tool; error = $sr.error } }
  $res = $sr.result
  # 查询结果只带前 15 行,省上下文
  try {
    $props = @($res.PSObject.Properties)
    foreach ($p in $props) {
      if ($p.Name -eq 'rows' -and $p.Value) {
        $rows = @($p.Value)
        if ($rows.Count -gt 15) {
          $res = $res | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
          $res.rows = @($res.rows | Select-Object -First 15)
          $res | Add-Member -NotePropertyName rowsOmitted -NotePropertyValue ($rows.Count - 15) -Force
        }
      }
    }
  } catch {}
  $j = $null
  try { $j = $res | ConvertTo-Json -Depth 12 -Compress } catch { $j = '{}' }
  if ($j.Length -gt $cap) { $j = $j.Substring(0, $cap) + '...(截断)' }
  return @{ tool = $sr.tool; result = $j }
}
$evidence = @()
$allResults = @($pooledResults) + @($stepResults)
for ($i = 0; $i -lt $allResults.Count; $i++) {
  $t = Trim-StepForSynth $allResults[$i]
  $evidence += "步骤$($i+1) [$($t.tool)]:" + $(if ($t.error) { " 失败: $($t.error)" } else { " `n$($t.result)" })
}
if (-not $evidence.Count) { $evidence += '(规划器未安排任何工具步骤——该问题无需查 SAP 系统数据,基于你的 SAP 知识直接回答)' }
$synthSys = @"
你是资深 SAP 顾问助理。基于给定的工具执行结果回答用户问题,要求:
- 只依据结果说话;结果为空/失败就直说,并给出下一步排查建议(最多 2 条)
- 引用具体数字、表名、字段、代码片段;能用小表格就用小表格(markdown)
- 结论先行,再给证据;紧凑,不写废话
- 涉薪酬/绩效等敏感个人数据只给统计性结论
- 中文回答
- 结尾如存在**一个明确的、用户一句话就能让你接着执行**的下一步,在该行输出 <!--NEXT:动作描述-->(如 <!--NEXT:查 T001T 取这些公司代码的中文名-->);多个动作挑最关键的;没有就完全不输出该标记
"@
$synthUser = "问题: $question`n`n工具执行结果:`n" + ($evidence -join "`n`n")
$synthAi = Invoke-SapAi -UserPrompt $synthUser -SystemPrompt $synthSys -MaxTokens 2500
$answer = $(if ($synthAi) { $synthAi.text } else { '' })
$swSynth.Stop()
if (-not $answer) {
  $answer = 'AI 汇总失败,但工具已执行完毕——下方步骤区可看每步原始结果。'
}
# 提取并剥离 NEXT 标记 → nextHint(前端「⚡ 执行下一步」按钮直读,免手工打字)
$nh = Get-SapNextHint -Answer $answer
$answer = $nh.answer; $nextHint = $nh.nextHint

$swTotal.Stop()
if ($script:AskProgressFile) { Remove-Item $script:AskProgressFile -Force -ErrorAction SilentlyContinue }   # 删除=完成信号
$model = $(if ($synthAi) { $synthAi.model } else { '' })
# 房子约定(bridge-client.run 只取 data.result):负载必须嵌在 result 键里
return @{
  ok = $true
  result = [ordered]@{
    question = $question
    system = $system
    answer = $answer
    nextHint = $nextHint
    steps = $stepReports
    planRaw = $planRaw
    timings = [ordered]@{
      planMs = [long]$swPlan.ElapsedMilliseconds
      execMs = [long]$swExec.ElapsedMilliseconds
      synthMs = [long]$swSynth.ElapsedMilliseconds
      totalMs = [long]$swTotal.ElapsedMilliseconds
    }
    model = $model
  }
}
