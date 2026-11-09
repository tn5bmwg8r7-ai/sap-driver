# ============================================================
# _job-poll.ps1 - shared async-job polling implementation.
# qa-chat-job / action-run-job / sap-test-report-job are thin wrappers:
#   . (Join-Path $PSScriptRoot '_job-poll.ps1')
#   return Get-BridgeJobStatus -Body $Body -JobDir '<jobDir>'
# Protocol: done/error job files are deleted after read (result delivered
# once); stale jobs older than 30 min are GC'd on the way.
# 2026-08-31 consolidation: was 3 hand-copied route files drifting silently.
# GC runs at most once per minute (time-gated) - the frontend polls every
# 2.5-3 s and a full directory scan per poll was pure redundant I/O on the
# single-threaded bridge (240+ scans per 12-min job).
# ============================================================

. (Join-Path $PSScriptRoot '_job-dispatch.ps1')   # 自动重试重派要用 Start-BridgeJob(2026-09-30)

# 作业文件原子重写(重试状态机用)。2026-10-14 审查整合:换 _io-helpers 单源——
# 原「固定 tmp 名+无重试 Move」同 New-BridgeJob 旧款;9-30 加的自动重试让本函数会在
# 作业运行中重写 jobFile,与 worker 侧 Write-JobStage 打点并发,固定名互踩=sharing
# violation 直接抛。-Bom 保 Out-File utf8 字节兼容
if (-not (Get-Command Write-TextFileAtomic -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot '_io-helpers.ps1')
}
function Save-BridgeJobFile {
  param([Parameter(Mandatory)][string]$JobFile, [Parameter(Mandatory)]$Job)
  Write-TextFileAtomic -Path $JobFile -Text ($Job | ConvertTo-Json -Depth 8) -Bom | Out-Null
}

function Get-BridgeJobStatus {
  param([Parameter(Mandatory)][hashtable]$Body, [Parameter(Mandatory)][string]$JobDir)

  $in = $Body.input
  $jobId = if ($in -and $in.jobId) { [string]$in.jobId } else { '' }
  if ($jobId -notmatch '^[a-f0-9]{12}$') {
    return @{ ok = $false; error = @{ code = 'BAD_JOBID'; message = 'input.jobId required (12 hex chars)' } }
  }

  $jobFile = Join-Path $JobDir "$jobId.json"

  # GC (time-gated): drop stale jobs older than 30 min (orphaned 'running' etc.)
  try {
    $gate = Join-Path $JobDir '_gc-lastrun.txt'
    $now = [DateTime]::Now
    $run = $true
    if (Test-Path $gate) {
      try { if (($now - [DateTime]::Parse([IO.File]::ReadAllText($gate))).TotalMinutes -lt 1) { $run = $false } } catch { $run = $true }
    }
    if ($run) {
      $cutoff = $now.AddMinutes(-30)
      $stale = @(Get-ChildItem -Path $JobDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff })
      if ($stale.Count -gt 0) {
        # F3b(2026-09-29 深审):mtime 超龄 ≠ 死作业——sap autofix 两轮+RUN2 接力可 >30min
        # 不写盘,在跑文件曾被 GC 误删、前端轮询中途翻 not_found。删前反查进程:命令行含
        # -JobId <id> 的 powershell 还活着就豁免(jobs-stop.ps1 同款 12hex 匹配)。
        # 进程反查只在确有超龄文件时才做(GC 本有 1 分钟门控),常规路径零额外开销。
        $live = @{}
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
          if ($p.CommandLine -and $p.CommandLine -match '-JobId\s+([0-9a-f]{12})(\s|$)') { $live[$Matches[1]] = $true }
        }
        foreach ($f in $stale) {
          if ($f.BaseName -match '^[0-9a-f]{12}$' -and $live.ContainsKey($f.BaseName)) { continue }
          Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        }
      }
      [IO.File]::WriteAllText($gate, $now.ToString('o'))
    }
  } catch {}

  if (-not (Test-Path $jobFile)) {
    return @{ ok = $true; result = @{ jobId = $jobId; status = 'not_found' } }
  }

  $job = [IO.File]::ReadAllText($jobFile) | ConvertFrom-Json
  $status = [string]$job.status

  if ($status -eq 'done') {
    Remove-Item -LiteralPath $jobFile -Force -ErrorAction SilentlyContinue
    # Flatten scalar keys of the worker result to the top level (2026-09-09):
    # the JOB-panel result view renders only top-level keys, so deliverable
    # metadata (docxPath / reportId / pass / fail ...) must sit there to be
    # visible/copyable. The nested `result` is kept verbatim - runPollingJob
    # (frontend) returns it as-is, so consumers are unaffected. Oversized
    # fields (markdown etc.) are stripped downstream by Start-Bridge's
    # ResultBlocklist when the route-results archive is written.
    $res = $job.result
    $outer = [ordered]@{ jobId = $jobId; status = 'done' }
    if ($res -is [System.Management.Automation.PSCustomObject]) {
      foreach ($p in @($res.PSObject.Properties)) {
        $v = $p.Value
        if ($null -eq $v) { continue }
        $isScalar = ($v -is [string]) -or ($v -is [bool]) -or ($v -is [int]) -or ($v -is [long]) -or ($v -is [double]) -or ($v -is [decimal])
        if ($isScalar -and -not $outer.Contains($p.Name)) { $outer[$p.Name] = $v }
      }
    }
    $outer['result'] = $res
    return @{ ok = $true; result = $outer }
  }
  if ($status -eq 'error') {
    # ── 自动重试(2026-09-30):作业带 retry 元数据且未到硬顶 → 翻 retry-wait,到点重派 ──
    # 平台硬顶 3 次防雪崩;不在路由线程里 sleep(backoff 靠 retryAt,由下一次轮询触发重派)。
    # worker 启动信息来自 New-BridgeJob 落盘的 $job.worker(EnvVars 不存,带凭证的派发器不开重试)。
    $rt = $job.retry; $wk = $job.worker
    $tries = 0; try { $tries = [int]$rt.tries } catch {}
    $maxR = 0; try { $maxR = [int]$rt.max } catch {}
    $cap = [Math]::Min($maxR, 3)
    if ($rt -and $wk -and ($wk.script) -and $cap -gt 0 -and $tries -lt $cap) {
      $backoff = 60; try { if ($rt.backoffSec) { $backoff = [int]$rt.backoffSec } } catch {}
      $job | Add-Member -Force -NotePropertyName status -NotePropertyValue 'retry-wait'
      $rt.tries = $tries + 1
      $job | Add-Member -Force -NotePropertyName retryAt -NotePropertyValue ([DateTime]::Now.AddSeconds($backoff).ToString('yyyy-MM-dd HH:mm:ss'))
      $job | Add-Member -Force -NotePropertyName stage -NotePropertyValue ('自动重试待发({0}/{1}),{2}s 后' -f ($tries + 1), $cap, $backoff)
      Save-BridgeJobFile -JobFile $jobFile -Job $job
      return @{ ok = $true; result = @{ jobId = $jobId; status = 'running'; stage = [string]$job.stage; retry = @{ tries = ($tries + 1); max = $cap } } }
    }
    $err = $job.error
    # 09-09:错误作业文件"读后即删",错误详情只活在一次轮询响应里,事后无从排查
    # (ZREP001 排障实爆:错误被前端消费,服务端零痕迹)——删档前留一份侧车日志
    try {
      $errLog = Join-Path $JobDir '_errors.log'
      $line = "[{0}] job={1} code={2} msg={3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $jobId, ([string]$err.code), (([string]$err.message) -replace '\s+', ' ')
      [System.IO.File]::AppendAllText($errLog, $line + "`n", [System.Text.Encoding]::UTF8)
    } catch {}
    Remove-Item -LiteralPath $jobFile -Force -ErrorAction SilentlyContinue
    return @{ ok = $false; error = @{ code = $err.code; message = $err.message } }
  }
  if ($status -eq 'retry-wait') {
    # 重试等待:未到点原样回 running 态(前端继续轮询);到点重派 worker 翻回 running。
    # 前端关闭没人轮询时,本文件按 30min GC 兜底收走(重试仅在有人等待时续命,不产生僵尸重放)。
    $due = $true
    try { $due = ([DateTime]::Now -ge [DateTime]::Parse([string]$job.retryAt)) } catch { $due = $true }
    if (-not $due) {
      return @{ ok = $true; result = @{ jobId = $jobId; status = 'running'; stage = [string]$job.stage } }
    }
    try {
      $wk = $job.worker
      $wa = @{}
      if ($wk.args) { foreach ($p in @($wk.args.PSObject.Properties)) { $wa[$p.Name] = [string]$p.Value } }
      $ws = @(); if ($wk.switches) { $ws = @($wk.switches | ForEach-Object { [string]$_ }) }
      # 抢占标记(2026-10-14 审查 P2 竞态修复):桥 3 槽并行,两路轮询同夹「读到 retry-wait
      # 且到期」与「翻回 running 落盘」之间 → 同 jobId 双 worker 双跑(此路不过 New-BridgeJob
      # 的 dedupKey,踩 SAP 变更红线)。标准抢占:写唯一 claimId 落盘后重读验证,拿到自己的
      # claim 才准 Start,后来者看到别人 claim 只回 running
      $claim = [guid]::NewGuid().ToString('N')
      $job | Add-Member -Force -NotePropertyName status -NotePropertyValue 'running'
      $job | Add-Member -Force -NotePropertyName stage -NotePropertyValue ('自动重试排队派发({0}/{1})' -f ([int]$job.retry.tries), ([Math]::Min([int]$job.retry.max, 3)))
      $job | Add-Member -Force -NotePropertyName retryClaim -NotePropertyValue $claim
      Save-BridgeJobFile -JobFile $jobFile -Job $job
      $check = [IO.File]::ReadAllText($jobFile) | ConvertFrom-Json
      if ([string]$check.retryClaim -ne $claim) {
        # 别的并发轮询先落盘抢到了 → 它负责 Start,本请求只报 running
        return @{ ok = $true; result = @{ jobId = $jobId; status = 'running'; stage = [string]$check.stage } }
      }
      $job | Remove-Member -Force -NotePropertyName retryClaim -ErrorAction SilentlyContinue
      Start-BridgeJob -WorkerScript ([string]$wk.script) -JobId $jobId -JobDir $JobDir -NamedArgs $wa -SwitchArgs $ws
      $job | Add-Member -Force -NotePropertyName stage -NotePropertyValue ('自动重试执行中({0}/{1})' -f ([int]$job.retry.tries), ([Math]::Min([int]$job.retry.max, 3)))
      $job | Add-Member -Force -NotePropertyName startedAt -NotePropertyValue (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
      Save-BridgeJobFile -JobFile $jobFile -Job $job
      return @{ ok = $true; result = @{ jobId = $jobId; status = 'running'; stage = [string]$job.stage } }
    } catch {
      return @{ ok = $false; error = @{ code = 'RETRY_DISPATCH_FAIL'; message = $_.Exception.Message } }
    }
  }
  if ($status -eq 'aborted') {
    # 09-11:jobs-stop 作业模式(JOB 面板中止 / 问答批量「✖停止」)把作业标 aborted。等待方
    # 轮询到这里必须立刻终态返回,否则 runPollingJob 不认识 aborted 会白等到 maxMs 超时。
    # 同 done/error 读后即删(终态只交付一次);无人等待的 aborted 文件留给 30min GC 兜底。
    Remove-Item -LiteralPath $jobFile -Force -ErrorAction SilentlyContinue
    return @{ ok = $false; error = @{ code = 'ABORTED'; message = '作业已被手动中止' } }
  }
  return @{ ok = $true; result = @{ jobId = $jobId; status = $status; startedAt = [string]$job.startedAt; stage = [string]$job.stage } }
}
