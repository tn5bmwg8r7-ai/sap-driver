param([Parameter(Mandatory)][hashtable]$Body)

# ============================================================
# sap-test-report — SAP 测试报告生成器 dispatcher。
#   op=start-analyze : 新建测试(读码+AI 功能说明+场景建议)→ 异步 worker,秒回 jobId
#   op=start-run     : 执行场景(FM 直调 / PROG SUBMIT 包装器)+ AI 判定 → 异步 worker
#   op=export        : 存档报告 md → docx(base64)同步(秒级,不占线程)
#   op=list / load   : 报告清单 / 单份存档回显,同步轻量
# 重活全在 jobs\sap-test-report-worker.ps1 独立进程(bridge 单线程,重路由=PW 冻死,
# 2026-08-28 qa-from-chat 同款模式)。前端轮询 sap-test-report-job 取结果。
# 密码红线:密码经 worker 进程 env 块(PW_SAP_PWD)传递,job 文件/命令行/日志/存档均不含
# (2026-08-31 对抗审查:原走 job 文件明文+worker 读完剥离,存在落盘窗口;action-run 同款闭环)。
# ============================================================

$in = $Body.input
$op = if ($in -and $in.op) { [string]$in.op } else { '' }
$reportsDir = if ($env:SAP_TEST_REPORT_DIR) { $env:SAP_TEST_REPORT_DIR } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'sap-test-reports' }
# 2026-09-11 审计:jobDir 硬编码绝对路径违反 d686f2c 教训(仓库移动后 jobs-stop 相对路径反查不到同一目录),改随仓库定位
$jobDir = Join-Path $PSScriptRoot '..\..\..\data\bridge\sap-test-jobs'
# 2026-08-31 整合:隐藏起 worker 的 ProcessStartInfo 细节收进 _job-dispatch.ps1(四调用点共用)
. (Join-Path $PSScriptRoot '_job-dispatch.ps1')

function Test-ReportId {
  param([string]$Id)
  if ($Id -notmatch '^[A-Za-z0-9_\-]+$') {
    return @{ ok = $false; error = @{ code = 'BAD_REPORT_ID'; message = "对象名不合法:$Id(只允许字母/数字/下划线)" } }
  }
  return $null
}

# 报告标识=对象名(存档 <对象名>.json);兼容旧式带时间戳命名:取该对象最新一份
function Resolve-ArcPath {
  param([string]$Id)
  $p = Join-Path $reportsDir "$Id.json"
  if (Test-Path $p) { return $p }
  $cand = Get-ChildItem -Path $reportsDir -Filter "$Id-*.json" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($cand) { return $cand.FullName }
  return $null
}

switch ($op) {

  # ---------------- 新建测试(异步) ----------------
  'start-analyze' {
    $objType = ([string]$in.objectType).Trim().ToUpper()
    $objName = ([string]$in.objectName).Trim().ToUpper()
    $system  = ([string]$in.system).Trim().ToUpper()
    # 09-09:密码 Trim——表单粘贴尾随空格/换行会导致登录失败,且报错看不出真因
    $password = ([string]$in.sapPassword).Trim()
    if ($objType -notin @('FM','PROG')) {
      return @{ ok = $false; error = @{ code = 'BAD_OBJECT_TYPE'; message = '对象类型仅支持 FM(函数)/ PROG(程序)' } }
    }
    if (-not $objName -or $objName -notmatch '^[A-Z0-9_]+$') {
      return @{ ok = $false; error = @{ code = 'NEED_OBJECT_NAME'; message = '请填写 SAP 对象名(函数名或程序名)' } }
    }
    if ($system -notin @('DVP','QAS','PRD')) {
      return @{ ok = $false; error = @{ code = 'BAD_SYSTEM'; message = '环境仅支持 DVP / QAS / PRD' } }
    }
    if (-not $password) {
      # 凭证合一(2026-09-23):表单密码留空→回落连接管理槽(sap-tool 连接成功即入槽,12h TTL)。
      # 槽内密码在连接时已实际登录验证过,结构性消灭「手输旧密码反复喂失败计数」。
      . (Join-Path $PSScriptRoot '_sap-conn.ps1')
      $slot = Get-SapSessionCred -System $system
      if ($slot -and $slot.Password) { $password = [string]$slot.Password }
    }
    if (-not $password) {
      return @{ ok = $false; error = @{ code = 'NEED_PASSWORD'; message = "未填密码,且连接管理没有 $system 的有效凭证(未连接或已超12小时)。请到「SAP Driver → 连接管理」连接一次,或本次在表单填写密码。" } }
    }
    if (-not (Test-Path $jobDir)) { New-Item -ItemType Directory -Force -Path $jobDir | Out-Null }
    $extraHint = [string]$in.extraHint
    # running 占位(不含密码;密码走 env 块 PW_SAP_PWD);建目录/jobId/原子占位收进 New-BridgeJob
    # F4(09-29):同对象分析互斥,双击/重发接续原作业不重复派发
    $job = New-BridgeJob -JobDir $jobDir -InitialPayload @{
      op = 'analyze'
      input = @{ objectType = $objType; objectName = $objName; system = $system; extraHint = $extraHint }
    } -DedupKey "sap-analyze:$objType/$objName@$system"
    if ($job.Duplicate) {
      return @{ ok = $true; result = [ordered]@{
        jobId = $job.JobId; status = 'running'; poll = 'sap-test-report-job'; duplicate = $true
        hint = "同对象已有分析在跑($($job.JobId)),已接续原作业,未重复派发" } }
    }
    $jobId = $job.JobId
    $worker = Join-Path $PSScriptRoot '..\jobs\sap-test-report-worker.ps1'
    Start-BridgeJob -WorkerScript $worker -JobId $jobId -JobDir $jobDir -EnvVars @{ PW_SAP_PWD = $password }
    return @{ ok = $true; result = [ordered]@{
      jobId = $jobId; status = 'running'; poll = 'sap-test-report-job'
      hint = "已提交后台分析($objType $objName @$system),前端轮询 sap-test-report-job 取结果" } }
  }

  # ---------------- 执行场景 / 续测(异步) ----------------
  'start-run' {
    $reportId = ([string]$in.reportId).Trim()
    $err = Test-ReportId $reportId
    if ($err) { return $err }
    $arcPath = Resolve-ArcPath $reportId
    if (-not $arcPath) {
      return @{ ok = $false; error = @{ code = 'REPORT_NOT_FOUND'; message = "找不到对象 $reportId 的报告(先用「新建测试」生成;续测模式留空对象名会列出全部)" } }
    }
    # 凭证合一(2026-09-23):密码=表单优先;留空→按报告所属系统回落连接管理槽(12h TTL)
    $password = ([string]$in.sapPassword).Trim()
    $arcSys = ''
    try {
      $arcPre = Get-Content -LiteralPath $arcPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $arcSys = ([string]$arcPre.object.system).Trim().ToUpper()
    } catch { }
    if (-not $password -and $arcSys) {
      . (Join-Path $PSScriptRoot '_sap-conn.ps1')
      $slot = Get-SapSessionCred -System $arcSys
      if ($slot -and $slot.Password) { $password = [string]$slot.Password }
    }
    if (-not $password) {
      $sysTxt = $(if ($arcSys) { $arcSys } else { '该系统' })
      return @{ ok = $false; error = @{ code = 'NEED_PASSWORD'; message = "未填密码,且连接管理没有 $sysTxt 的有效凭证(未连接或已超12小时)。请到「SAP Driver → 连接管理」连接一次,或本次在表单填写密码。" } }
    }
    # PRD 授权闸(2026-09-17 用户红线):PRD 上 SUBMIT 执行报表=允许一次性后台作业,
    # 但必须用户本人在表单「PRD 执行确认」输入「确认」才放行——调度层拦截,不进 worker 不建作业
    try {
      $arc0 = Get-Content -LiteralPath $arcPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ([string]$arc0.object.system -eq 'PRD' -and [string]$arc0.object.type -eq 'PROG') {
        $prdOk = ([string]$in.prdConfirm).Trim() -eq '确认'
        if (-not $prdOk) {
          return @{ ok = $false; error = @{ code = 'PRD_CONFIRM_REQUIRED'
            message = 'PRD 执行需你本人确认:请在「PRD 执行确认」框输入「确认」后再执行(PRD 允许一次性后台 SUBMIT,严禁定期作业;PRD 权限从严)' } }
        }
      }
    } catch { }
    if (-not (Test-Path $jobDir)) { New-Item -ItemType Directory -Force -Path $jobDir | Out-Null }
    # scenariosJson 期望 JSON 字符串;调用方直接给数组/对象时规范化为 JSON 文本
    $sj = $in.scenariosJson
    $sjson = ''
    if ($sj -is [string]) { $sjson = $sj }
    elseif ($sj) { $sjson = $sj | ConvertTo-Json -Depth 8 -Compress }
    $note = [string]$in.note
    $autoFix = $false; if ($in.autoFix -eq $true -or $in.autoFix -eq 'true') { $autoFix = $true }
    $userFeedback = [string]$in.userFeedback
    # 回归重测(2026-09-17):上一轮场景原样克隆为新轮重跑,报告出回归对比
    $regression = $false; if ($in.regression -eq $true -or $in.regression -eq 'true') { $regression = $true }
    $prdConfirm = [string]$in.prdConfirm
    # F4(09-29):同报告执行互斥——双击「执行」曾双跑双写存档(最后写者赢,先完成轮次留痕消失)
    $job = New-BridgeJob -JobDir $jobDir -InitialPayload @{
      op = 'run'
      input = @{ reportId = $reportId; scenariosJson = $sjson; note = $note; autoFix = $autoFix; userFeedback = $userFeedback; regression = $regression; prdConfirm = $prdConfirm }
    } -DedupKey "sap-run:$reportId"
    if ($job.Duplicate) {
      return @{ ok = $true; result = [ordered]@{
        jobId = $job.JobId; status = 'running'; poll = 'sap-test-report-job'; duplicate = $true
        hint = "该报告已有执行在跑($($job.JobId)),已接续原作业,未重复派发" } }
    }
    $jobId = $job.JobId
    $worker = Join-Path $PSScriptRoot '..\jobs\sap-test-report-worker.ps1'
    Start-BridgeJob -WorkerScript $worker -JobId $jobId -JobDir $jobDir -EnvVars @{ PW_SAP_PWD = $password }
    return @{ ok = $true; result = [ordered]@{
      jobId = $jobId; status = 'running'; poll = 'sap-test-report-job'
      hint = "已提交后台执行($reportId),前端轮询 sap-test-report-job 取结果" } }
  }

  # ---------------- 导出报告(同步,秒级) ----------------
  'export' {
    $reportId = ([string]$in.reportId).Trim()
    $err = Test-ReportId $reportId
    if ($err) { return $err }
    $arcPath = Resolve-ArcPath $reportId
    if (-not $arcPath) {
      return @{ ok = $false; error = @{ code = 'REPORT_NOT_FOUND'; message = "找不到对象 $reportId 的报告" } }
    }
    $arc = Get-Content -LiteralPath $arcPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $md = [string]$arc.reportMd
    if (-not $md) {
      return @{ ok = $false; error = @{ code = 'NO_REPORT_MD'; message = '存档里还没有报告正文(先执行一轮场景测试)' } }
    }
    # md → docx(OOXML 直写,避 Word COM)。2026-09-01 拆分后 _ooxml-office.ps1 无 param,
    # 不再覆盖宿主 $Body,原 $__routeBody hack 已拆除。落盘目录:env SAP_TEST_REPORT_DIR,缺省=仓库 data/sap-test-reports
    # (2026-08-28 用户指定默认目录)
    . (Join-Path $PSScriptRoot '_ooxml-office.ps1')
    $docxBase64 = $null
    $docxPath = $null
    $docDir = if ($env:SAP_TEST_REPORT_DIR) { $env:SAP_TEST_REPORT_DIR } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'sap-test-reports' }
    if (-not (Test-Path $docDir)) { New-Item -ItemType Directory -Force -Path $docDir | Out-Null }
    # 文件名=对象名(2026-08-28 用户指定:不带时间戳不带后缀);重名自动加序号不覆盖
    $baseName = [string]$arc.object.name
    if (-not $baseName) { $baseName = $reportId }
    try {
      # 2026-08-31 整合:md→docx 组装收进 Convert-MdToDocxFile
      # 固定文件名 <对象名>.docx:复测/续测导出直接覆盖同一路径(版本号在报告内容里递增)
      $docxPath = Convert-MdToDocxFile -Md $md -OutPath (Join-Path $docDir ((Get-SafeBaseName -Path $baseName) + '.docx'))
      $docxBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($docxPath))
    } catch { $docxPath = $null }
    return @{ ok = $true; result = [ordered]@{
      reportId = $reportId; markdown = $md; docxBase64 = $docxBase64; docxPath = $docxPath
      basename = $baseName } }
  }

  # ---------------- 报告清单(同步) ----------------
  # 2026-09-11 审计 #14:原每次 list 整读+解析最多 50 份全存档(实测 4.2MB/21 份,单份含全文
  # reportMd/scenarios/rounds 20-260KB)只为取 10 个 brief 字段。改 _briefs.jsonl 增量索引:
  # mtime 未变的档直接命中,新档/改动档才整读并追加索引行;旧档首次访问自愈补登。
  'list' {
    $items = @()
    if (Test-Path $reportsDir) {
      $briefsPath = Join-Path $reportsDir '_briefs.jsonl'
      $briefById = @{}
      if (Test-Path $briefsPath) {
        try {
          foreach ($ln in @(Get-Content $briefsPath -Encoding UTF8)) {
            if (-not $ln) { continue }
            try { $e = $ln | ConvertFrom-Json; if ($e.id) { $briefById[[string]$e.id] = $e } } catch {}
          }
        } catch {}
      }
      $files = Get-ChildItem -Path $reportsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '_*' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 50
      $sb = New-Object System.Text.StringBuilder
      foreach ($f in $files) {
        $id = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
        $hit = $briefById[$id]
        if ($hit -and $hit.mtimeTicks -eq $f.LastWriteTimeUtc.Ticks) {
          $j = $hit
        } else {
          try {
            $full = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $b = $full.brief
            $j = [ordered]@{
              id          = [string]$full.id
              objName     = if ($full.object) { "$($full.object.name)($(if ($full.object.type -eq 'FM') {'函数'} else {'程序'}))" } else { '' }
              system      = if ($full.object) { [string]$full.object.system } else { '' }
              total       = if ($b) { [int]$b.total } else { 0 }
              pass        = if ($b) { [int]$b.pass } else { 0 }
              fail        = if ($b) { [int]$b.fail } else { 0 }
              pending     = if ($b) { [int]$b.pending } else { 0 }
              conclusion  = if ($b) { [string]$b.conclusion } else { 'none' }
              updatedAt   = if ($b) { [string]$b.updatedAt } else { [string]$full.updatedAt }
              mtimeTicks  = $f.LastWriteTimeUtc.Ticks
            }
            [void]$sb.Append(($j | ConvertTo-Json -Compress -Depth 4)); [void]$sb.Append("`n")
          } catch { continue }
        }
        $items += [ordered]@{
          id = $j.id; object = $j.objName; system = $j.system
          total = $j.total; pass = $j.pass; fail = $j.fail
          blocked = $(if ($null -ne $j.blocked) { [int]$j.blocked } else { 0 })
          pending = $j.pending
          conclusion = $j.conclusion; updatedAt = $j.updatedAt
        }
      }
      if ($sb.Length -gt 0) {
        try { [System.IO.File]::AppendAllText($briefsPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false))) } catch {}
      }
      # 09-29 小项:每次变更都追加新行、同 id 旧行永不清理,重测多了 _briefs.jsonl 无限涨。
      # >400 行整文件压实一次(同 id 取最后一行=最新 mtime 版),低频摊销读放大。
      try {
        $lc = @(Get-Content $briefsPath -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ })
        if ($lc.Count -gt 400) {
          $latest = @{}
          foreach ($ln in $lc) { try { $e = $ln | ConvertFrom-Json; if ($e.id) { $latest[[string]$e.id] = $ln } } catch {} }
          if ($latest.Count -gt 0) {
            [System.IO.File]::WriteAllText($briefsPath, (($latest.Values | ForEach-Object { [string]$_ }) -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
          }
        }
      } catch {}
    }
    return @{ ok = $true; result = [ordered]@{ items = $items; count = $items.Count } }
  }

  # ---------------- 单份存档回显(同步) ----------------
  'load' {
    $reportId = ([string]$in.reportId).Trim()
    $err = Test-ReportId $reportId
    if ($err) { return $err }
    $arcPath = Join-Path $reportsDir "$reportId.json"
    if (-not (Test-Path $arcPath)) {
      return @{ ok = $false; error = @{ code = 'REPORT_NOT_FOUND'; message = "找不到对象 $reportId 的报告" } }
    }
    $arc = Get-Content -LiteralPath $arcPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return @{ ok = $true; result = [ordered]@{
      reportId = $arc.id; object = $arc.object; feature = $arc.feature
      scenarios = $arc.scenarios; rounds = $arc.rounds; conclusion = $arc.conclusion
      reportMd = [string]$arc.reportMd } }
  }

  default {
    return @{ ok = $false; error = @{ code = 'BAD_OP'; message = "未知 op:$op(支持 start-analyze/start-run/export/list/load)" } }
  }
}
