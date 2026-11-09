param([Parameter(Mandatory)][hashtable]$Body)

# sap-probe  -  SAP Driver「🔍 排查」编排路由(2026-09-14,v12 2026-09-15)。
# 场景:第三方报文复现 / SE37 变式载入 / 参数集管理 / 一次调用执行 / 程序+变式定点排查。
# 确定性链,零 AI(追问走「问 Agent」)。治理全在 facade 同源,本路由零第二套口径。
#
# 复用设计(用户定案:函数排查先行,程序排查后续,不做两套):
#   入参带 kind('fm' 本刀实现;'report' 预留 → UNKNOWN_KIND)。
#   未来程序排查 = 本路由加 SUBMIT 分支 + widget 复用连接条/参数集清单/结果区组件。
#
# action:
#   signature { system, fm }                     → fm_read 拿接口签名(前端生成表单)
#   list      { system?, function? }             → 参数集清单
#   load      { system, function, name }         → 读单个参数集
#   save      { system, function, name, note?, payload } → 存参数集(报文映射结果)
#   exec      { system, function, paramSet?, import?, tables? } → 参数集为底+表单覆盖合并→fm_exec
#   precheck  { system, report }                 → v12 副作用粗扫(ZLILY_REPORT_SCAN),PRD 确认框数据源
#   exec(report) { system, report, variant?, seltab?, force? } → v12 ZLILY_REPORT_RUN2:
#                 PRD 必须带 force:true(UI 逐次确认后才发),bridge 绝不自动补 force;
#                 RUNNING 时返回 jobname/jobcount,前端走 poll 接力
#   poll      { system, jobname, jobcount }      → v12 TBTCO 查状态,FINISHED 则取 spool 文本
# 凭证:不在本路由处理——未连接时 facade 报 NEED_CREDENTIAL 原样透传,前端弹连接面板。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_sap-convexit.ps1')
. (Join-Path $PSScriptRoot '_claude-helpers.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')   # v15 整合:facade工具/拍平/AI样板收敛到共享件
. (Join-Path $PSScriptRoot '_sap-explain-lib.ps1')   # v16 整合二期:explain 读取+AI 切共用库(2026-09-21)

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$action = ([string]$input_.action).Trim()
if (-not $action) { return (Fail 'BAD_ACTION' 'action required') }
$kind = ([string]$input_.kind).Trim()
if (-not $kind) { $kind = 'fm' }
if ($kind -ne 'fm' -and $kind -ne 'report') { return (Fail 'UNKNOWN_KIND' "kind '$kind' 暂未支持(仅 fm/report)。") }
Initialize-SapRoute | Out-Null   # v15:facade 死了 WMI 拉起

$system = ([string]$input_.system).Trim().ToUpper()
if ($system -notin @('DVP', 'QAS', 'PRD')) { return (Fail 'BAD_SYSTEM' "system 必须是 DVP/QAS/PRD,收到: '$system'") }

try {
  switch ($action) {

    'signature' {
      # v9 report 分支:ZLILY_REPORT_META ACTION=P → 选择屏幕参数清单(前端生成表单)
      if ($kind -eq 'report') {
        $rep = ([string]$input_.fm).Trim()
        if (-not $rep) { return (Fail 'BAD_FM' 'report 必填') }
        $r = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args @{
          system = $system; function = 'ZLILY_REPORT_META'
          import = @{ IV_REPORT = $rep; IV_ACTION = 'P' }
        }
        if (-not $r.ok) { return $r }
        $ex = ConvertTo-FlatHashtable $r.data.result
        if ([int]$ex.EV_SUBRC -ne 0) { return (Fail 'REPORT_META_FAILED' ([string]$ex.EV_MESSAGE)) }
        return @{ ok = $true; result = @{
          kind = 'report'; system = $system; report = $rep
          params = $ex.ET_PARAMS
          facadeHttpMs = $r.facadeHttpMs
        } }
      }
      $fm = ([string]$input_.fm).Trim()
      if (-not $fm) { return (Fail 'BAD_FM' 'fm 必填') }
      $r = Invoke-FacadeTool -Tool 'sap_fm_read' -Args @{ system = $system; function = $fm }
      if (-not $r.ok) { return $r }
      return @{ ok = $true; result = @{
        kind = 'fm'; system = $system; fm = $fm
        signature = $r.data.interface; source = $r.data.source
        facadeHttpMs = $r.facadeHttpMs
      } }
    }

    'variant' {
      # v9 report 分支:ZLILY_REPORT_META ACTION=C → 变式内容(RSPARAMS,含 SIGN/OPTION)
      if ($kind -eq 'report') {
        $rep = ([string]$input_.function).Trim()
        $vari = ([string]$input_.variant).Trim()
        if (-not $rep -or -not $vari) { return (Fail 'BAD_PARAM' 'function(report)/variant 必填') }
        $r = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args @{
          system = $system; function = 'ZLILY_REPORT_META'
          import = @{ IV_REPORT = $rep; IV_ACTION = 'C'; IV_VARIANT = $vari }
        }
        if (-not $r.ok) { return $r }
        $ex = ConvertTo-FlatHashtable $r.data.result
        if ([int]$ex.EV_SUBRC -ne 0) { return (Fail 'VARIANT_LOAD_FAILED' ([string]$ex.EV_MESSAGE)) }
        return @{ ok = $true; result = @{
          kind = 'report'; system = $system; report = $rep; variant = $vari
          params = $ex.ET_PARAMS
          facadeHttpMs = $r.facadeHttpMs
        } }
      }
      # SE37 测试变式入参读出(前端填表用):params = 参数名→值平铺对象
      $fm = ([string]$input_.function).Trim()
      $variant = ([string]$input_.variant).Trim()
      if (-not $fm -or -not $variant) { return (Fail 'BAD_PARAM' 'function/variant 必填') }
      $r = Invoke-FacadeTool -Tool 'sap_variant_read' -Args @{ system = $system; function = $fm; variant = $variant }
      if (-not $r.ok) { return $r }
      return @{ ok = $true; result = @{
        kind = 'fm'; system = $system; fm = $fm; variant = $r.data.variant
        params = $r.data.params; typedParams = $r.data.typedParams
        facadeHttpMs = $r.facadeHttpMs
      } }
    }

    'list' {
      $a = @{ system = $system }
      if ($input_.function) { $a['function'] = ([string]$input_.function).Trim() }
      $r = Invoke-FacadeTool -Tool 'sap_testdata_list' -Args $a
      if (-not $r.ok) { return $r }
      return @{ ok = $true; result = @{ kind = 'fm'; system = $system; sets = $r.data.paramSets; count = $r.data.count; facadeHttpMs = $r.facadeHttpMs } }
    }

    'load' {
      $fm = ([string]$input_.function).Trim()
      $name = ([string]$input_.name).Trim()
      if (-not $fm -or -not $name) { return (Fail 'BAD_PARAM' 'function/name 必填') }
      $r = Invoke-FacadeTool -Tool 'sap_testdata_load' -Args @{ system = $system; function = $fm; name = $name }
      if (-not $r.ok) { return $r }
      return @{ ok = $true; result = @{ kind = 'fm'; system = $system; set = $r.data; facadeHttpMs = $r.facadeHttpMs } }
    }

    'save' {
      $fm = ([string]$input_.function).Trim()
      $name = ([string]$input_.name).Trim()
      if (-not $fm -or -not $name) { return (Fail 'BAD_PARAM' 'function/name 必填') }
      $payload = $input_.payload
      if ($null -eq $payload) { return (Fail 'BAD_PARAM' 'payload 必填(import/tables)') }
      $a = @{ system = $system; function = $fm; name = $name
              import = $payload.import; tables = $payload.tables }
      if ($input_.note) { $a['note'] = [string]$input_.note }
      $r = Invoke-FacadeTool -Tool 'sap_testdata_save' -Args $a
      if (-not $r.ok) { return $r }
      return @{ ok = $true; result = @{ kind = 'fm'; system = $system; saved = $r.data; facadeHttpMs = $r.facadeHttpMs } }
    }

    'exec' {
      # v12 report 分支:ZLILY_REPORT_RUN2(标准+Z/Y 报表均可,PRD 逐次确认+副作用粗扫)。
      # 治理:PRD 必须 UI 逐次确认后带 force:true;bridge 绝不自动补 force——唯一闸口在这。
      if ($kind -eq 'report') {
        $rep = ([string]$input_.report).Trim()
        if (-not $rep) { return (Fail 'BAD_PARAM' 'report 必填') }
        $vari = ([string]$input_.variant).Trim()
        $force = ($input_.force -eq $true -or $input_.force -eq 'true')
        $imp = @{ IV_REPORT = $rep }
        if ($vari) { $imp['IV_VARIANT'] = $vari }
        if ($system -eq 'PRD') {
          if (-not $force) {
            return (Fail 'PRD_CONFIRM_REQUIRED' 'PRD 执行需逐次确认:预检副作用后由人工点「确认执行」重发。')
          }
          $imp['IV_ENFORCE'] = 'X'
          $imp['IV_FORCE'] = 'X'
        }
        $a = @{ system = $system; function = 'ZLILY_REPORT_RUN2'; import = $imp }
        if ($null -ne $input_.seltab) {
          $a['tables'] = @{ IT_SELTAB = @($input_.seltab) }
        }
        $r = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args $a -TimeoutSec 110
        if (-not $r.ok) { return $r }
        $ex = ConvertTo-FlatHashtable $r.data.result
        $status = ([string]$ex.EV_STATUS).Trim()
        if ($status -eq 'RUNNING') {
          # 后台作业还没跑完(RFC 等待预算用尽):交前端 poll 接力,作业本身不受断连影响
          return @{ ok = $true; result = @{
            kind = 'report'; system = $system; report = $rep; variant = $vari
            status = 'RUNNING'; jobname = [string]$ex.EV_JOBNAME; jobcount = [string]$ex.EV_JOBCOUNT
            risk = $ex.ET_RISK
            durationMs = $r.data.durationMs
            facadeHttpMs = $r.facadeHttpMs
          } }
        }
        return @{ ok = $true; result = @{
          kind = 'report'; system = $system; report = $rep; variant = $vari
          status = $(if ($status) { $status } else { 'DONE' })
          exec = $ex
          durationMs = $r.data.durationMs
          facadeHttpMs = $r.facadeHttpMs
        } }
      }
      $fm = ([string]$input_.function).Trim()
      if (-not $fm) { return (Fail 'BAD_FM' 'function 必填') }
      $import = $null; $tables = $null
      $mergedFrom = $null

      # 1) 参数集为底(可选):load 出 import/tables
      $psName = ([string]$input_.paramSet).Trim()
      if ($psName) {
        $lr = Invoke-FacadeTool -Tool 'sap_testdata_load' -Args @{ system = $system; function = $fm; name = $psName }
        if (-not $lr.ok) { return $lr }
        $set = $lr.data
        if ($set.import) { $import = $set.import }
        if ($set.tables) { $tables = $set.tables }
        $mergedFrom = $psName
      }

      # 2) 显式表单值覆盖(顶层键级:同名键整值替换,结构以表单为准)
      if ($input_.import) { $import = $input_.import }
      if ($input_.tables) { $tables = $input_.tables }

      # 3) 内外码转换(2026-09-15):变式/报文/手输的值是**外码**(物料 10000000000),
      #    RFC 直调不走转换出口 → ALPHA/MATN1 类在咽喉点统一转内码(补零到域长)。
      #    转不动/不该转的一律原样并记 skipped,绝不阻塞执行主链。
      $conv = $null
      if ($null -ne $import -or $null -ne $tables) {
        $import = ConvertTo-MutHashTable $import
        $tables = ConvertTo-MutHashTable $tables
        # RANGE 形状归一(2026-09-15 ZIF_SRM_MAT 实爆):TABLES 值单对象→包数组、null→空表;
        # 原样传对象给 NCo 会产出空 OPTION 行,ABAP `IN itab` 校验炸。TABLES 参数永远是 itab,归一零风险。
        if ($tables -is [System.Collections.IDictionary]) {
          foreach ($k in @($tables.Keys)) {
            if ($null -eq $tables[$k]) { $tables[$k] = @() }
            elseif ($tables[$k] -is [System.Collections.IDictionary]) { $tables[$k] = @($tables[$k]) }
          }
        }
        $hasVals = (($import -is [System.Collections.IDictionary] -and $import.Count) -or
                    ($tables -is [System.Collections.IDictionary] -and $tables.Count))
        if ($hasVals) {
          try {
            # v15 接口短缓存(10 分钟):exec→诊断→改参→再exec 动线里同一 FM 反复全价读接口。
            # 2026-09-21 审查 P2 迁 PWCrossRunspaceCache($global: 子 runspace 化后每请求归零=缓存死)
            $sigStore = [PWCrossRunspaceCache]::Store['SapProbeSigCache']
            if (-not $sigStore) { $sigStore = @{}; [PWCrossRunspaceCache]::Store['SapProbeSigCache'] = $sigStore }
            $sigKey = "$system/$($fm.ToUpper())"
            $nowMs = [long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $cSig = $sigStore[$sigKey]
            if ($cSig -and ($nowMs - [long]$cSig.at) -lt 600000) { $sr = $cSig.r }
            else {
              $sr = Invoke-FacadeTool -Tool 'sap_fm_read' -Args @{ system = $system; function = $fm; includeSource = $false }
              $sigStore[$sigKey] = @{ r = $sr; at = $nowMs }
            }
            if ($sr.ok -and $sr.data.interface) {
              $conv = Add-SapConvexit -System $system -Sig (ConvertTo-FlatHashtable $sr.data.interface) `
                -Import $(if ($import -is [System.Collections.IDictionary]) { $import } else { @{} }) `
                -Tables $(if ($tables -is [System.Collections.IDictionary]) { $tables } else { @{} }) `
                -FetchQuery { param($Tool, $A) Invoke-FacadeTool -Tool $Tool -Args $A } `
                -FetchStruct { param($Tool, $A) Invoke-FacadeTool -Tool $Tool -Args $A }
            }
          } catch { $conv = $null }   # 接口读不到 → 不转,照常执行
        }
      }

      $a = @{ system = $system; function = $fm }
      if ($null -ne $import) { $a['import'] = $import }
      if ($null -ne $tables) { $a['tables'] = $tables }

      $r = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args $a -TimeoutSec 110
      if (-not $r.ok) { return $r }
      return @{ ok = $true; result = @{
        kind = 'fm'; system = $system; fm = $fm
        paramSetMerged = $mergedFrom
        conv = $(if ($conv) { $conv } else { $null })
        exec = $r.data.result
        durationMs = $r.data.durationMs
        facadeHttpMs = $r.facadeHttpMs
      } }
    }

    'precheck' {
      # v12 定点排查预检:ZLILY_REPORT_SCAN 副作用粗扫(只读,不动程序)。
      # PRD 确认框的数据源;DVP/QAS 也用于黄色提示。风险分级:HIGH/MEDIUM/CLEAN。
      $rep = ([string]$input_.report).Trim()
      if (-not $rep) { return (Fail 'BAD_PARAM' 'report 必填') }
      $r = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args @{
        system = $system; function = 'ZLILY_REPORT_SCAN'
        import = @{ IV_REPORT = $rep }
      }
      if (-not $r.ok) { return $r }
      $ex = ConvertTo-FlatHashtable $r.data.result
      if ([int]$ex.EV_SUBRC -ne 0) { return (Fail 'REPORT_SCAN_FAILED' ([string]$ex.EV_MESSAGE)) }
      return @{ ok = $true; result = @{
        kind = 'report'; system = $system; report = $rep
        riskLevel = ([string]$ex.EV_RISK_LEVEL).Trim()
        message = [string]$ex.EV_MESSAGE
        risks = $ex.ET_RISK
        facadeHttpMs = $r.facadeHttpMs
      } }
    }

    'poll' {
      # v12 RUNNING 接力:TBTCO 查后台作业状态(纯读);F=完成 / A=取消 → 取 spool 文本。
      # 终态代码为本系统实测定案(2026-09-15:DVP702 无 S 态,F 即完成,worker 同款判定)。
      $job = ([string]$input_.jobname).Trim().ToUpper()
      $jc = ([string]$input_.jobcount).Trim()
      if (-not $job -or -not $jc) { return (Fail 'BAD_PARAM' 'jobname/jobcount 必填') }
      $qr = Invoke-FacadeTool -Tool 'sap_query' -Args @{
        system = $system; table = 'TBTCO'; maxRows = 1
        fields = @('JOBNAME', 'JOBCOUNT', 'STATUS')
        where = @(
          @{ field = 'JOBNAME'; op = '='; value = $job },
          @{ field = 'JOBCOUNT'; op = '='; value = $jc }
        )
      }
      if (-not $qr.ok) { return $qr }
      $row = $null
      $qrows = @($qr.data.rows)
      if ($qrows.Count) { $row = ConvertTo-FlatHashtable $qrows[0] }
      $st = ''; if ($row) { $st = ([string]$row.STATUS).Trim() }
      if ($st -ne 'F' -and $st -ne 'A') {
        if (-not $st) {
          return (Fail 'JOB_NOT_FOUND' "后台作业 $job($jc)在 TBTCO 无记录——可能已被删除或作业号有误。")
        }
        return @{ ok = $true; result = @{
          kind = 'report'; system = $system; status = 'RUNNING'
          jobStatus = $st; jobname = $job; jobcount = $jc
          facadeHttpMs = $qr.facadeHttpMs
        } }
      }
      $r = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args @{
        system = $system; function = 'ZLILY_REPORT_SPOOL'
        import = @{ IV_JOBNAME = $job; IV_JOBCOUNT = $jc }
      } -TimeoutSec 60
      if (-not $r.ok) { return $r }
      $ex = ConvertTo-FlatHashtable $r.data.result
      return @{ ok = $true; result = @{
        kind = 'report'; system = $system
        status = $(if ($st -eq 'F') { 'DONE' } else { 'CANCELLED' })
        jobname = $job; jobcount = $jc
        exec = $ex
        durationMs = $r.data.durationMs
        facadeHttpMs = $r.facadeHttpMs
      } }
    }

    'explain' {
      # 📐 接口/程序解读:签名(或选择屏幕)+源码 → AI 快速概览。勾选后读接口时触发。
      # 2026-09-21 整合二期:读取+AI 全切共用库(_sap-explain-lib,与问答速查同一实现,
      # 用户定案「一个功能只写一次」)。本 action 只管 probe 形态差异:指定单名/单系统/
      # overview 款/前端错误分流(NEED_CREDENTIAL 字样→自动弹连接面板,勿改字面)。
      $fm = ([string]$input_.fm).Trim()
      if (-not $fm) { return (Fail 'BAD_FM' 'fm 必填') }
      $isRep = ($kind -eq 'report')

      # report:选择屏幕参数先行(META 只读)。源码读不到时它是唯一解读依据→ExtraContext
      $selTxt = ''
      if ($isRep) {
        try {
          $mr = Invoke-FacadeTool -Tool 'sap_fm_exec' -Args @{ system = $system; function = 'ZLILY_REPORT_META'
            import = @{ IV_REPORT = $fm; IV_ACTION = 'P' } }
          if ($mr.ok) {
            $ex0 = ConvertTo-FlatHashtable $mr.data.result
            $selDesc = @()
            foreach ($row in @($ex0.ET_PARAMS)) { $selDesc += ("$($row.SELNAME)($($row.KIND)) 默认=$($row.LOW)") }
            if ($selDesc.Count) { $selTxt = '选择屏幕: ' + ($selDesc -join '; ') }
          }
        } catch {}
      }

      $t = Get-SapExplainTarget -Names @($fm) -Kind $(if ($isRep) { 'prog' } else { 'fm' }) -Systems @($system) -TimeoutSec 15
      if (-not $t.ok) {
        if ($isRep -and $selTxt) {
          # 源码不可得但选择屏幕在手:沿用 v11 行为,仅凭选择屏幕解读(hasSource=false,
          # 前端自动标「源码不可得,基于签名推断」)
          $t = @{ ok = $false; kind = 'prog'; name = $fm; system = $system; source = ''
                  imports = @(); exports = @(); changings = @(); tables = @(); calls = @() }
        } elseif ($t.credMiss.Count -gt 0) {
          return (Fail 'NEED_CREDENTIAL' (($t.credMiss | ForEach-Object { "$_ 未注入凭证" }) -join ','))
        } else {
          $why = $(if ($t.tried.Count) { ($t.tried -join ', ') } else { 'facade 无响应' })
          return (Fail 'EXPLAIN_FAILED' "未读取到目标:$why。请确认名称拼写。")
        }
      }

      $aiRes = Invoke-SapExplainAi -Target $t -Style 'overview' -ExtraContext $selTxt -TimeoutSec 30
      if (-not $aiRes) { return (Fail 'EXPLAIN_FAILED' 'AI 解读失败,请重试。') }
      $res = @{ ok = $true; result = @{
        kind = $(if ($isRep) { 'report' } else { 'fm' }); system = $system
        explain = [string]$aiRes.text
        hasSource = [bool](([string]$t.source).Trim())
        model = [string]$aiRes.model
      } }
      if ($isRep) { $res.result['report'] = $fm } else { $res.result['fm'] = $fm }
      return $res
    }

    default { return (Fail 'BAD_ACTION' "未知 action: $action") }
  }
} catch {
  return (Fail 'PROBE_FAILED' $_.Exception.Message)
}
