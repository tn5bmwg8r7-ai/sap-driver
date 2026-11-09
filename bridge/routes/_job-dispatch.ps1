# ============================================================
# _job-dispatch.ps1 - shared hidden-worker spawn for async job dispatchers.
# 2026-08-31 consolidation: was 4 hand-copied ProcessStartInfo blocks
# (qa-from-chat.ps1, action-run.ps1, sap-test-report.ps1 x2).
# SECURITY-CRITICAL bits live HERE so they cannot drift per call site:
#   - UseShellExecute = $false : REQUIRED for -EnvVars to reach the worker's
#     environment block; the command line WOULD be WMI/task-manager readable
#     (that is why the SAP password travels via EnvVars, never via args)
#   - CreateNoWindow = $true   : no console flash; WMI Win32_Process.Create
#     flashes a window - do not switch
#   - args are CommandLineToArgvW-quoted (values with spaces, quotes, or EMPTY
#     strings must stay single tokens or -File mis-binds and the next token
#     gets consumed as the value) -> ConvertTo-WinArg in _proc-helpers.ps1
#     (2026-08-31 整合,含尾反斜杠缺陷修复)
# ============================================================

. (Join-Path $PSScriptRoot '_proc-helpers.ps1')

# dispatcher 侧「建目录 + jobId + running 占位」四份手抄的收敛
# (qa-from-chat.ps1 / action-run.ps1 / sap-test-report.ps1 ×2)。tmp+Move 原子写,
# 前端轮询不会读到半写占位;Depth 8 足够 dispatcher 浅载荷。返回 @{ JobId; JobFile }。
# F4(2026-09-29 深审):-DedupKey 非空时做同目标互斥——存在「同 key 且真在跑」的作业则
# 不新建,返回 @{ Duplicate=$true; JobId=<在跑id>; JobFile }(调用方原形状回+duplicate 标志,
# 前端拿 jobId 直接接续轮询,零前端改动)。防 sap start-run 双击双跑(两 worker 同写存档,
# 最后写者赢=先完成轮次留痕消失)。「真在跑」=status running 且(有 -JobId 活进程 或
# mtime<5min):崩溃残留(无进程)可立即重派,不用等 GC;长作业靠 F3a stage 打点续 mtime。
function New-BridgeJob {
  param(
    [Parameter(Mandatory)][string]$JobDir,
    [hashtable]$InitialPayload = @{},   # 不含 jobId/status/startedAt(本函数统一补)
    [string]$DedupKey = '',             # 非空=启用同目标互斥(键由调用方定义,如 sap-run:<reportId>)
    [hashtable]$Retry = $null,          # 自动重试(opt-in,默认关):@{max=2;backoffSec=60};平台硬顶 3 次
    [string]$WorkerScript = '',         # 重试重派需要 worker 启动信息(_job-poll 用);★走 -EnvVars 传
                                        # 凭证的派发器禁止启用 Retry(EnvVars 绝不落盘——红线)
    [hashtable]$WorkerArgs = @{},       # 重派用 -NamedArgs(明文落作业文件,不得含凭证)
    [string[]]$WorkerSwitches = @()     # 重派用 -SwitchArgs
  )
  if (-not (Test-Path $JobDir)) { New-Item -ItemType Directory -Force -Path $JobDir | Out-Null }
  if ($DedupKey) {
    # 只扫近 35min(>GC 视界)的 12hex 作业文件;进程反查一次收全部,避免逐文件查
    $cand = @(Get-ChildItem -Path $JobDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-35) -and $_.BaseName -match '^[0-9a-f]{12}$' })
    if ($cand.Count -gt 0) {
      $live = @{}
      foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
        if ($p.CommandLine -and $p.CommandLine -match '-JobId\s+([0-9a-f]{12})(\s|$)') { $live[$Matches[1]] = $true }
      }
      foreach ($c in $cand) {
        try { $j = Get-Content -LiteralPath $c.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ([string]$j.status -ne 'running' -or [string]$j.dedupKey -ne $DedupKey) { continue }
        if (-not ($c.LastWriteTime -gt (Get-Date).AddMinutes(-5)) -and -not $live.ContainsKey($c.BaseName)) { continue }
        return @{ Duplicate = $true; JobId = $c.BaseName; JobFile = $c.FullName }
      }
    }
  }
  $jobId = [guid]::NewGuid().ToString('N').Substring(0, 12)
  $jobFile = Join-Path $JobDir "$jobId.json"
  $payload = @{ jobId = $jobId; status = 'running'; startedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
  foreach ($k in @($InitialPayload.Keys)) { $payload[$k] = $InitialPayload[$k] }
  if ($DedupKey) { $payload['dedupKey'] = $DedupKey }
  # 自动重试元数据(2026-09-30):worker 启动信息明文落作业文件供 _job-poll 重派;EnvVars 不存,
  # 所以带凭证的派发器(如 sap-test-report 的 SAP 密码走 EnvVars)不得开 Retry
  if ($Retry -and $WorkerScript) {
    $maxR = 1; try { if ($Retry.max) { $maxR = [int]$Retry.max } } catch {}
    $backoff = 60; try { if ($Retry.backoffSec) { $backoff = [int]$Retry.backoffSec } } catch {}
    $payload['retry'] = @{ max = ([Math]::Min($maxR, 3)); backoffSec = $backoff; tries = 0 }
    $payload['worker'] = @{ script = $WorkerScript; args = $WorkerArgs; switches = @($WorkerSwitches) }
  }
  # 单源原子写(2026-10-14 审查漂移整合):原固定 tmp 名+无重试 Move 是 _io-helpers 已定案
  # 废弃的写法(2026-09-24 固定名互踩事故)——同 jobFile 的 worker 侧(_job-protocol)早走
  # Write-JsonFileAtomic guid 名,两代并存。-Bom 保 Out-File utf8(BOM)字节兼容,读侧零改动
  if (-not (Get-Command Write-TextFileAtomic -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '_io-helpers.ps1')
  }
  Write-TextFileAtomic -Path $jobFile -Text ($payload | ConvertTo-Json -Depth 8) -Bom | Out-Null
  return @{ JobId = $jobId; JobFile = $jobFile }
}

function Start-BridgeJob {
  param(
    [Parameter(Mandatory)][string]$WorkerScript,
    [Parameter(Mandatory)][string]$JobId,
    [Parameter(Mandatory)][string]$JobDir,
    [hashtable]$NamedArgs = @{},   # -Name <value>, auto-quoted (spaces/CJK/empty safe)
    [string[]]$SwitchArgs = @(),   # -Name (no value)
    [hashtable]$EnvVars = @{}      # worker process env block only (e.g. PW_ACTION_PWD)
  )

  $parts = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-WinArg $WorkerScript), '-JobId', $JobId, '-JobDir', (ConvertTo-WinArg $JobDir))
  foreach ($k in @($NamedArgs.Keys)) {
    $parts += ('-' + [string]$k)
    $parts += (ConvertTo-WinArg ([string]$NamedArgs[$k]))
  }
  foreach ($s in $SwitchArgs) { $parts += ('-' + [string]$s) }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = ($parts -join ' ')
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  foreach ($k in @($EnvVars.Keys)) { $psi.EnvironmentVariables[[string]$k] = [string]$EnvVars[$k] }
  $null = [System.Diagnostics.Process]::Start($psi)
}
