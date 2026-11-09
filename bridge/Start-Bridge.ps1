param(
  [switch]$NoStart,
  [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

# ---- 禁用控制台 QuickEdit(快速编辑模式) ----
# QuickEdit 被鼠标点选会冻结控制台输出;bridge 是单线程 GetContext 同步循环,
# 一旦输出卡住 -> /health 全超时、前端 bridge.run 永久转圈("入库中…"假死)。
# 仅交互式控制台生效;被重定向/无控制台启动时静默跳过,不影响功能。
try {
  $script:PwK32 = Add-Type -Name 'PwK32' -Namespace 'Win32' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@ -PassThru
  $stdIn = $script:PwK32::GetStdHandle(-10)   # STD_INPUT_HANDLE
  $curMode = 0
  if ($script:PwK32::GetConsoleMode($stdIn, [ref]$curMode)) {
    # 清 ENABLE_QUICK_EDIT_MODE(0x0040);置 ENABLE_EXTENDED_MODE(0x0080) 让修改生效
    [void]$script:PwK32::SetConsoleMode($stdIn, ($curMode -band (-bnot 0x0040)) -bor 0x0080)
  }
} catch { Write-Host "[bridge] skip disable QuickEdit: $($_.Exception.Message)" -ForegroundColor DarkGray }

. $PSScriptRoot\bridge.config.json.ps1
. $PSScriptRoot\security.ps1
. $PSScriptRoot\routes\_registry.ps1

# ---- 请求级落盘日志(2026-08-26 审计) ----
# 排"bridge 卡死/慢"直接看 data\bridge\_run.log 不用复现;500 行滚动裁剪
# (同 tools\auto-daily-recap 约定)。写失败静默,绝不影响请求本身。
$script:BridgeRunLogPath = Join-Path $PSScriptRoot '..\..\data\bridge\_run.log'
$script:BridgeRunLogWrites = 0
function Write-BridgeRunLog {
  param([string]$Command, [long]$Ms, [bool]$Ok)
  try {
    $dir = Split-Path $script:BridgeRunLogPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $status = if ($Ok) { 'ok' } else { 'ERR' }
    Add-Content -Path $script:BridgeRunLogPath -Value ("[{0}] /run/{1} {2}ms {3}" -f [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'), $Command, $Ms, $status) -Encoding UTF8
    $script:BridgeRunLogWrites++
    if ($script:BridgeRunLogWrites % 50 -eq 1) {
      $lines = Get-Content $script:BridgeRunLogPath -ErrorAction SilentlyContinue
      if ($lines -and $lines.Count -gt 500) {
        $lines | Select-Object -Last 500 | Set-Content $script:BridgeRunLogPath -Encoding UTF8
      }
    }
  } catch { }
}

function Test-IsAdmin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $p = New-Object Security.Principal.WindowsPrincipal($id)
  return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-BridgeToken {
  $cfg = $script:BridgeConfig
  $tokenDir = Split-Path $cfg.tokenFile -Parent
  if (-not (Test-Path $tokenDir)) {
    New-Item -ItemType Directory -Force -Path $tokenDir | Out-Null
  }
  if (-not (Test-Path $cfg.tokenFile)) {
    $bytes = New-Object byte[] 32
    ([System.Security.Cryptography.RandomNumberGenerator]::Create()).GetBytes($bytes)
    $token = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
    Set-Content -Path $cfg.tokenFile -Value $token -NoNewline -Encoding Ascii
    Write-Host "[bridge] Generated new token at: $($cfg.tokenFile)" -ForegroundColor Yellow
  }
  return (Get-Content $cfg.tokenFile -Raw).Trim()
}

# 深转换收进 routes\_psvalue.ps1(2026-08-31 整合,四份副本并一;此处为请求体规范化调用点)
. (Join-Path $PSScriptRoot 'routes\_psvalue.ps1')

function Read-RequestBody {
  param($Request)
  # Force UTF-8 regardless of Content-Type charset — browsers send "application/json" with no
  # charset, and HttpListener's $Request.ContentEncoding falls back to Latin1 in that case,
  # corrupting Chinese/Unicode bytes in the JSON body.
  $encoding = [System.Text.Encoding]::UTF8
  $reader = New-Object System.IO.StreamReader($Request.InputStream, $encoding)
  $body = $reader.ReadToEnd()
  $reader.Close()
  if ([string]::IsNullOrEmpty($body)) { return @{} }
  $obj = $body | ConvertFrom-Json
  return ConvertTo-BridgeHashtable $obj
}

function Handle-Request {
  param($Context)

  $request = $Context.Request
  $response = $Context.Response

  if ($request.HttpMethod -eq 'OPTIONS') {
    Write-BridgeCORS -Response $response
    $response.StatusCode = 204
    $response.Close()
    return
  }

  $origin = $request.Headers['Origin']
  if (-not (Test-BridgeOrigin -Origin $origin)) {
    Write-BridgeError -Response $response -Code 'ORIGIN_DENIED' -Message "Origin not allowed: $origin" -Status 403
    $response.Close()
    return
  }

  if (-not (Test-BridgeToken -AuthorizationHeader $request.Headers['Authorization'])) {
    Write-BridgeError -Response $response -Code 'UNAUTHORIZED' -Message 'Invalid or missing bearer token' -Status 401
    $response.Close()
    return
  }

  if ($request.HttpMethod -ne 'POST') {
    Write-BridgeError -Response $response -Code 'METHOD_NOT_ALLOWED' -Message "Use POST" -Status 405
    $response.Close()
    return
  }

  $path = $request.Url.AbsolutePath.TrimEnd('/')
  if ($path -eq '/health') {
    Write-BridgeJson -Response $response -Payload @{ ok = $true; result = @{ status = 'healthy'; time = (Get-Date).ToString('o') } }
    $response.Close()
    return
  }

  if ($path -eq '/routes') {
    $routes = (Get-BridgeRoutes).Keys | Sort-Object
    Write-BridgeJson -Response $response -Payload @{ ok = $true; result = @{ routes = @($routes) } }
    $response.Close()
    return
  }

  if ($path -like '/run/*') {
    # 2026-09-04 并发化改造:路由执行挪进 worker runspace(原为单线程同步执行,一个慢路由
    # ——如 AI 生成的分钟级接口文档——会堵死整个 GetContext 循环,/health 一并失聪,
    # watchdog 4s 探活误判"桥死"→ 杀桥 → 前端 Failed to fetch,当日三连杀实锤)。
    # 主循环只做收包+鉴权+入队,秒级回到 GetContext;慢路由占用 worker 不再连坐全桥。
    $commandId = $path.Substring('/run/'.Length)
    Write-Host "[bridge] /run/$commandId" -ForegroundColor Cyan
    try {
      $body = Read-RequestBody -Request $request
    } catch {
      # 坏 JSON:立刻回错误并关闭,不能把没人应答的连接留在对端超时
      Write-BridgeError -Response $response -Code 'BAD_REQUEST' -Message "request body parse failed: $($_.Exception.Message)" -Status 400
      $response.Close()
      return
    }
    # 队列护栏:worker 全忙且积压过多时立即回 503,防止连点/重试把队列堆爆(前端 120s 也会放弃,
    # 与其让请求在队列里排到超时,不如立刻给明确错误)
    # 轻路由主线程直执行(09-04 晚补):worker 全忙时,面板 5s 轮询若也进队列,会把队列刷满
    # 触发 BRIDGE_BUSY——观测工具自己堵死观测通道(实踩:面板全盲 + 用户看到 BUSY 满天飞)。
    # jobs-live/jobs-history 只读小文件,主线程执行百毫秒级,可接受。
    if ($script:LightRoutes -contains $commandId) {
      try {
        $errBefore = $Error.Count   # 吞错洞封堵(09-17):先记错误基线,空输出≠成功
        $result = Invoke-BridgeRoute -CommandId $commandId -Body $body
        if ($null -eq $result) {
          $newErrs = @()
          if ($Error.Count -gt $errBefore) { $newErrs = @($Error | Select-Object -First ($Error.Count - $errBefore)) }
          $result = New-SilentRouteEnvelope -NewErrs $newErrs
        }
        Write-BridgeJson -Response $response -Payload $result
      } catch {
        Write-BridgeError -Response $response -Code 'ROUTE_ERROR' -Message $_.Exception.Message -Status 500
      }
      $response.Close()
      return
    }
    if ($script:RouteQueue.Count -ge 8) {
      Write-BridgeError -Response $response -Code 'BRIDGE_BUSY' -Message '并发路由已满且排队过多，请稍后重试' -Status 503
      $response.Close()
      return
    }
    $script:RouteQueue.Enqueue(@{ Context = $context; CommandId = $commandId; Body = $body })
    return   # response 归 worker 所有,主线程不再碰
  }

  Write-BridgeError -Response $response -Code 'NOT_FOUND' -Message "Unknown path: $path" -Status 404
  $response.Close()
}

$cfg = $script:BridgeConfig
$token = Ensure-BridgeToken
$base = "http://$($cfg.host):$($cfg.port)/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($base)

try {
  $listener.Start()
} catch {
  Write-Host "[bridge] Failed to bind $base : $($_.Exception.Message)" -ForegroundColor Red
  if (-not (Test-IsAdmin) -and ($cfg.host -eq '+' -or $cfg.host -eq '*')) {
    Write-Host ""
    Write-Host "[bridge] 监听全网卡 (+/*) 需要管理员权限。" -ForegroundColor Yellow
    Write-Host "  方案 A: 用管理员 PowerShell 跑本脚本" -ForegroundColor Yellow
    Write-Host "  方案 B: 一次性 urlacl 注册（管理员跑一次即可，之后非管理员可监听）:" -ForegroundColor Yellow
    Write-Host "    netsh http add urlacl url=http://+:$($cfg.port)/ user=`"$env:USERNAME`"" -ForegroundColor White
    Write-Host "  方案 C: 只本机使用，把 bridge.config.json 的 host 改回 127.0.0.1" -ForegroundColor Yellow
  } else {
    Write-Host "[bridge] Hint: 端口可能被占用，编辑 bridge.config.json 改成别的端口" -ForegroundColor Yellow
  }
  exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Personal Workspace Bridge" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Listening:  $base" -ForegroundColor White
Write-Host "  Token file: $($cfg.tokenFile)" -ForegroundColor White
Write-Host "  Routes:     $(((Get-BridgeRoutes).Keys | Sort-Object) -join ', ')" -ForegroundColor White
Write-Host "  Ctrl+C to stop" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if ($NoStart) { return }

# ---- 路由执行 worker 池(2026-09-04 并发化) ----
# 3 个常驻 STA runspace,各自循环从 ConcurrentQueue 取 /run 任务执行。STA 兼容个别
# 用 COM 的路由(kb 上传的 xls/ppt 转换);worker 与主线程共享同一 AppDomain,NCo 的
# 进程级 destination 注册/程序集加载不受多 runspace 影响(静态标志本就幂等)。
# AI 熔断等 $global: 状态退化为 worker 级(各线程独立学习冷却),可接受。
$workerMain = {
  param($Queue, $BridgeRoot, $BusyFile, $RunLogPath, $SlotId, $CancelFile)
  $ErrorActionPreference = 'Stop'
  # 槽位状态文件(「作业」TAB 实时区数据源):取件写 running、完工写 idle。
  # 与 _busy.json(watchdog 心跳,最后写者胜)不同,这是每槽一份的独立状态。
  # 首个 idle 占位在 dot-source 之前就写(共享层加载要几秒,晚写会让面板看到 unknown)
  $SlotFile = Join-Path (Split-Path -Parent $BusyFile) ('_slot-{0}.json' -f $SlotId)
  # 忙碌心跳每槽一份(2026-09-11 审计 #5):原 3 worker 共写 _busy.json「最后写者胜」,
  # B 覆写后 B 完工时双比对照样删——A 长任务心跳被误删,watchdog 护栏失真。分槽后各写各的。
  $SlotBusyFile = Join-Path (Split-Path -Parent $BusyFile) ('_busy-{0}.json' -f $SlotId)
  function Write-SlotState {
    param([hashtable]$State)
    try {
      $State.slot = $SlotId
      [System.IO.File]::WriteAllText($SlotFile, ($State | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
  }
  Write-SlotState @{ state = 'idle'; lastRoute = ''; lastMs = 0; lastOk = $true; finishedAt = (Get-Date).ToString('o'); queue = 0 }
  # 与主线程同款共享层(security.ps1 自带 bridge.config.json.ps1 加载)
  . (Join-Path $BridgeRoot 'security.ps1')
  . (Join-Path $BridgeRoot 'routes\_registry.ps1')

  # 重路由最长执行时长护栏(2026-09-04 批量拉取三槽全卡教训):子 runspace 可能起不来
  # (线程池饥饿)或路由卡死在永不返回的外呼里——不得永久占槽。到点 Stop,再给 10s 收尸
  # 宽限,仍未完成就弃 EndInvoke 放槽回 504。默认 600s(接口文档/会话分析分钟级远够),
  # bridge.config.json 可加顶层 "routeMaxSec" 覆盖(秒,测试降时长用)。
  $routeMaxMs = 600000
  try {
    $wcfg = Invoke-BridgeConfig
    if ($wcfg.routeMaxSec) { $routeMaxMs = [int]$wcfg.routeMaxSec * 1000 }
  } catch {}

  # 轻路由(作业面板自身的轮询)不点亮槽位:面板 5s 一次 jobs-live 若照写 running,
  # 用户会看到 W1/W2/W3 永远有个在"倒计时",分不清真活假活(09-04 用户反馈)。
  # 心跳 _busy.json 照写(watchdog 护栏不受影响)。
  $script:LightRoutes = @('jobs-live', 'jobs-history')

  # 可中止执行(09-04 用户反馈"不能中止"):非轻路由在**子 runspace**里跑,worker 主循环
  # 期间轮询 _cancel.json(jobs-stop 路由写入 {slot, requestedAt});命中本槽且请求时间
  # 晚于本次开始 → Stop() 子管道 → 响应回 ABORTED。诚实边界:Stop 是协作式的,若路由正
  # 卡在 .NET 外呼(SAP RFC/GLM HTTP)上,要等该次外呼返回才会停;PS 侧循环/分步逻辑立即停。
  $routeExec = {
    param($BRoot, $CmdId, $BodyArg)
    . (Join-Path $BRoot 'security.ps1')
    . (Join-Path $BRoot 'routes\_registry.ps1')
    return Invoke-BridgeRoute -CommandId $CmdId -Body $BodyArg
  }

  $script:BridgeRunLogPath = $RunLogPath
  $script:BridgeRunLogWrites = 0
  function Write-BridgeRunLog {
    param([string]$Command, [long]$Ms, [bool]$Ok, [string]$Ts)
    try {
      $dir = Split-Path $script:BridgeRunLogPath -Parent
      if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      $status = if ($Ok) { 'ok' } else { 'ERR' }
      $stamp = if ($Ts) { $Ts } else { [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss') }
      Add-Content -Path $script:BridgeRunLogPath -Value ("[{0}] /run/{1} {2}ms {3}" -f $stamp, $Command, $Ms, $status) -Encoding UTF8
      $script:BridgeRunLogWrites++
      if ($script:BridgeRunLogWrites % 50 -eq 1) {
        $lines = Get-Content $script:BridgeRunLogPath -ErrorAction SilentlyContinue
        if ($lines -and $lines.Count -gt 500) {
          $lines | Select-Object -Last 500 | Set-Content $script:BridgeRunLogPath -Encoding UTF8
        }
      }
    } catch { }
  }

  # 索引行追加(2026-09-09 流水索引化):与存档文件同行写入 index.jsonl,jobs-history 只读
  # 索引不再逐文件扫。3 worker 并发 + 主线程回填共用同一把命名互斥(同进程线程间 +
  # 重启共存窗口的跨进程都串行);WaitOne 超时弃写,漏行由 jobs-history 的 ts 差集回填自愈。
  $script:RrIndexMutex = 'PW_RR_Index_v1'
  function Write-IndexLine {
    param([string]$IndexPath, [string]$Line)
    $m = $null
    try { $m = New-Object System.Threading.Mutex($false, $script:RrIndexMutex) } catch { return }
    $owned = $false
    try { $owned = $m.WaitOne(300) } catch [System.Threading.AbandonedMutexException] { $owned = $true }   # 前持有者死亡=锁已到手
    if (-not $owned) { try { $m.Dispose() } catch {}; return }
    try { [System.IO.File]::AppendAllText($IndexPath, $Line + "`n", (New-Object System.Text.UTF8Encoding($false))) } catch {}
    try { $m.ReleaseMutex() } catch {}
    try { $m.Dispose() } catch {}
  }

  # 结果存档(JOB 管理回看用):worker 执行完把路由返回的轻量元数据落盘
  # data\bridge\route-results\<日期>\<路由>-<HHmmss>.json,文件名时间戳与 _run.log 行一致,
  # jobs-result 路由按 路由+时间戳 反查。大字段(markdown/docxBase64/factsJson 等)剥离,
  # 超长字符串截断 —— 存的是"产物在哪/摘要",不是全文。
  $script:ResultBlocklist = @('markdown', 'docxBase64', 'factsJson', 'sources', 'source', 'html', 'base64')
  function Write-ResultRecord {
    param([string]$Command, [string]$Ts, [long]$Ms, [bool]$Ok, $Result, [string]$ErrMsg, [string]$Src)
    try {
      if ($script:LightRoutes -contains $Command) { return }
      # -job 轮询心跳只落终态档(横幅「结果」反查用):2026-09-11 实测 3 天 4791 档中 77.5% 是
      # 2.5s/拍的心跳噪音(09-10 a318f2e 只挡了索引没挡文件洪流)。running/心跳拍直接跳过。
      if ($Command -match '-job$') {
        $jst = if ($Result -is [System.Collections.IDictionary] -and $Result.status) { [string]$Result.status } else { '' }
        if ($jst -notin @('done', 'error', 'aborted', 'timeout')) { return }
      }
      $dir = Split-Path $script:BridgeRunLogPath -Parent
      $recDir = Join-Path $dir (Join-Path 'route-results' $Ts.Substring(0, 10))
      if (-not (Test-Path $recDir)) { New-Item -ItemType Directory -Force -Path $recDir | Out-Null }
      $payload = [ordered]@{ route = $Command; ts = $Ts; ms = $Ms; ok = $Ok }
      if ($ErrMsg) { $payload.error = $ErrMsg }
      if ($Src) { $payload.src = $Src }
      if ($Result -is [System.Collections.IDictionary]) {
        $clean = [ordered]@{}
        foreach ($k in @($Result.Keys)) {
          $v = $Result[$k]
          if ($script:ResultBlocklist -contains $k) { $clean[$k] = "(已剥离,共 $((([string]$v)).Length) 字符)"; continue }
          if ($v -is [string] -and $v.Length -gt 1500) { $clean[$k] = $v.Substring(0, 200) + "…(共 $($v.Length) 字符)"; continue }
          # 瘦身(2026-09-09):数组/嵌套对象同样限尺寸——kb-image-export 的 items 1.3MB/档,
          # 曾把 3 天窗口撑到 279MB。非字符串统一序列化量尺,>1000 字符即剥离(小元数据不受影响)
          if ($null -ne $v -and $v -isnot [string]) {
            $vj = $null
            try { $vj = ConvertTo-Json -InputObject $v -Compress -Depth 3 } catch { $vj = $null }
            if ($vj -and $vj.Length -gt 1000) { $clean[$k] = "(已剥离,共 $($vj.Length) 字符)"; continue }
            if (-not $vj) { $clean[$k] = "(已剥离:序列化失败)"; continue }
          }
          $clean[$k] = $v
        }
        $payload.result = $clean
      }
      $file = Join-Path $recDir ("{0}-{1}.json" -f $Command, $Ts.Substring(11, 8).Replace(':', ''))
      [System.IO.File]::WriteAllText($file, ($payload | ConvertTo-Json -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding($false)))
      # 索引行:六字段定序全量输出(降级解析/差集回填都靠定序);err 截 500 防索引行失控
      # -job 轮询心跳(sap-test-report-job 等,runPollingJob 每 2.5s 一次)只落档不入索引:
      # 09-10 实测一次 SAP 报告刷 2800+ 行(当日 81%),流水/今日调用全失真;档保留给横幅「结果」反查
      if ($Command -match '-job$') { return }
      $idxErr = if ($ErrMsg) { $ErrMsg.Substring(0, [Math]::Min(500, $ErrMsg.Length)) } else { '' }
      $idx = [ordered]@{ route = $Command; ts = $Ts; ms = $Ms; ok = $Ok; src = $(if ($Src) { $Src } else { '' }); err = $idxErr }
      Write-IndexLine -IndexPath (Join-Path $recDir 'index.jsonl') -Line ($idx | ConvertTo-Json -Compress)
    } catch { }
  }

  while ($true) {
    $item = $null
    if (-not $Queue.TryDequeue([ref]$item)) { Start-Sleep -Milliseconds 80; continue }
    $ctx = $item.Context; $commandId = $item.CommandId; $body = $item.Body
    # 执行来源标记(快捷指令发起的带 _pwSrc=quick-cmd,由 command-runner 注入;定时任务/面板无)
    $src = ''
    try { if ($body -and $body.input -and $body.input._pwSrc) { $src = [string]$body.input._pwSrc } } catch {}
    # 忙碌心跳(watchdog 护栏):开跑即写 route+startedAt;探活失败但心跳新鲜(<10min)
    # = 慢路由正在跑而非桥死 → watchdog 跳过杀桥
    $startedIso = (Get-Date).ToString('o')
    try {
      [System.IO.File]::WriteAllText($SlotBusyFile, (@{ route = $commandId; startedAt = $startedIso } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
    # 轻路由(面板轮询)与 -job 心跳(2.5s/拍)都不点亮槽位:面板会看到假的「运行中」闪烁
    $isLight   = $script:LightRoutes -contains $commandId
    $isJobPoll = ($commandId -match '-job$')
    if (-not $isLight -and -not $isJobPoll) {
      Write-SlotState @{ state = 'running'; route = $commandId; startedAt = $startedIso; queue = $Queue.Count; src = $src }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $routeOk = $true
    $aborted = $false
    $timedOut = $false
    $lastErr = $null
    $errBefore = $Error.Count   # 吞错洞封堵(09-17):错误基线,空输出≠成功
    $childErrs = @()
    try {
      if ($isLight -or $isJobPoll) {
        # 轻路由/-job 轮询:直接本 runspace 执行(快,无需可中止)。-job 本体只是读一个小
        # JSON(09-11 审计 #8):原先也走子 runspace=每拍新建+slot 闪写+存档洪流。
        $result = Invoke-BridgeRoute -CommandId $commandId -Body $body
      } else {
        # 重路由:子 runspace 执行 + 轮询取消文件(诚实边界见 $routeExec 注释)。
        # 09-11 直传 RouteFile 实验回滚:子内路由输出被吞(285ms 空结果),根因待查,
        # 先恢复「双 dot-source + 常规调用」的稳定形态,P0-1 缓存问题另寻方案。
        $childRs = [runspacefactory]::CreateRunspace()
        try { $childRs.ApartmentState = 'STA' } catch {}
        $childRs.Open()
        $child = [powershell]::Create()
        $child.Runspace = $childRs
        [void]$child.AddScript($routeExec.ToString()).AddArgument($BridgeRoot).AddArgument($commandId).AddArgument($body)
        $handle = $child.BeginInvoke()
        $abandonChild = $false
        try {
          while (-not $handle.IsCompleted) {
            if (Test-Path -LiteralPath $CancelFile) {
              $creq = $null
              try { $creq = Get-Content -LiteralPath $CancelFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
              if ($creq -and [int]$creq.slot -eq $SlotId) {
                if ([string]$creq.requestedAt -gt $startedIso) {
                  $aborted = $true
                }
                Remove-Item -LiteralPath $CancelFile -Force -ErrorAction SilentlyContinue   # 消费/清陈旧
                if ($aborted) { $child.Stop(); break }
              }
            }
            if ($sw.ElapsedMilliseconds -ge $routeMaxMs) { $timedOut = $true; break }   # 不调 Stop():它同步等管线真停,卡在不可中断 .NET 外呼时会拖满管线时长(Thread.Sleep 实测 20s 护栏被拖成 120s);弃管由下方 abandon 路径处理
            Start-Sleep -Milliseconds 250
          }
          if ($aborted) { try { [void]$child.EndInvoke($handle) } catch {}; throw 'ABORTED_BY_USER' }
          if ($timedOut) {
            # 收尸宽限 10s:协作式 Stop 对卡在 .NET 外呼里的线程可能无效——完成则正常回收,
            # 未完成弃 EndInvoke(线程随进程遗留,可接受),槽必须放、桥必须活
            $grace = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $handle.IsCompleted -and $grace.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 200 }
            if ($handle.IsCompleted) { try { [void]$child.EndInvoke($handle) } catch {} }
            else { $abandonChild = $true }
            throw 'ROUTE_TIMEOUT_BY_GUARD'
          }
          $result = $child.EndInvoke($handle)[0]
          $childErrs = @($child.Streams.Error)   # 吞错洞封堵(09-17):Dispose 前抓子内错误证据(子 runspace EAP=Continue,非终止错误不抛只留痕迹)
        } finally {
          if ($abandonChild) {
            # 故意不 Dispose/Close(2026-09-04 实测):二者会同步等待仍在执行的管线结束,
            # 把 20s 护栏拖回管线真实时长(Thread.Sleep 测试路由被拖到 120s)。
            # 泄漏的 runspace/线程随管线终了由 GC 回收,worker 立即放槽。
          } else {
            try { $child.Dispose() } catch {}
            try { $childRs.Close() } catch {}
          }
        }
      }
      if ($null -eq $result) {
        # 路由零输出不再一律伪装成 ok:true+{}(09-17 吞错洞封堵):有错误证据=失败信封,干净静默才历史兜底
        $newErrs = $childErrs
        if (-not $newErrs.Count -and $Error.Count -gt $errBefore) { $newErrs = @($Error | Select-Object -First ($Error.Count - $errBefore)) }
        $result = New-SilentRouteEnvelope -NewErrs $newErrs
        if ($result.ok -eq $false) { $lastErr = $result.error.message }   # 进 result 记录/run log,排障有据
      }
      if ($result.ok -eq $false) { $routeOk = $false }
      Write-BridgeJson -Response $ctx.Response -Payload $result
    } catch {
      $routeOk = $false
      $lastErr = if ($aborted) { '已被用户中止(JOB 管理)' } elseif ($timedOut) { "路由执行超过 $([int]($routeMaxMs / 1000)) 秒,已被执行时长护栏强制中止" } else { $_.Exception.Message }
      # route 异常详情落盘(_run.log 只有 ERR 没有原因, 排障要靠这里)—— 2026-08-26 备份排障加
      try {
        $relLog = Join-Path $BridgeRoot '..\..\data\bridge\route-errors.log'
        # 2026-09-11 审计:append-only 无轮转 → 超 200KB 裁到尾 200 行(与主线程写入点同口径)
        try {
          $relFi = [System.IO.FileInfo]::new($relLog)
          if ($relFi.Exists -and $relFi.Length -gt 200KB) {
            $relLines = Get-Content $relLog -ErrorAction SilentlyContinue
            if ($relLines -and $relLines.Count -gt 200) { $relLines | Select-Object -Last 200 | Set-Content $relLog -Encoding UTF8 }
          }
        } catch {}
        $errLine = "[{0}] /run/{1}: {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $commandId, $lastErr
        [System.IO.File]::AppendAllText($relLog, $errLine + "`n", [System.Text.Encoding]::UTF8)
      } catch {}
      try {
        $errCode = 'ROUTE_ERROR'; $errStatus = 500
        if ($aborted) { $errCode = 'ABORTED'; $errStatus = 499 }
        elseif ($timedOut) { $errCode = 'ROUTE_TIMEOUT'; $errStatus = 504 }
        Write-BridgeError -Response $ctx.Response -Code $errCode -Message $lastErr -Status $errStatus
      } catch {}
    }
    $sw.Stop()
    $finishedTs = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-BridgeRunLog -Command $commandId -Ms $sw.ElapsedMilliseconds -Ok $routeOk -Ts $finishedTs
    Write-ResultRecord -Command $commandId -Ts $finishedTs -Ms $sw.ElapsedMilliseconds -Ok $routeOk -Result $(if ($routeOk -and $result) { $result.result } else { $null }) -ErrMsg $lastErr -Src $src
    try { $ctx.Response.Close() } catch {}
    # 清心跳:每槽一份 _busy-<slot>.json 只有本 worker 写 → 完工即删,无需双比对
    try { Remove-Item -LiteralPath $SlotBusyFile -Force -ErrorAction SilentlyContinue } catch {}
    if (-not $isLight -and -not $isJobPoll) {
      Write-SlotState @{ state = 'idle'; lastRoute = $commandId; lastMs = $sw.ElapsedMilliseconds; lastOk = $routeOk; lastSrc = $src; finishedAt = (Get-Date).ToString('o'); queue = $Queue.Count }
    }
  }
}

$script:RouteQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:BridgeBusyFile = Join-Path $PSScriptRoot '..\..\data\bridge\_busy.json'
# 旧共写心跳退役(2026-09-11 审计 #5 → 每槽 _busy-<slot>.json):清掉陈旧遗留,防误读
try { Remove-Item -LiteralPath $script:BridgeBusyFile -Force -ErrorAction SilentlyContinue } catch {}
$script:BridgeCancelFile = Join-Path $PSScriptRoot '..\..\data\bridge\_cancel.json'
$script:LightRoutes = @('jobs-live', 'jobs-history')   # 与 worker 内同名清单一致;主线程直执行不进队列
$script:BridgeWorkers = @()
1..3 | ForEach-Object {
  $slotId = $_
  $rs = [runspacefactory]::CreateRunspace()
  try { $rs.ApartmentState = 'STA' } catch {}   # 老版本不支持时静默 MTA
  $rs.Open()
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript($workerMain.ToString()).AddArgument($script:RouteQueue).AddArgument($PSScriptRoot).AddArgument($script:BridgeBusyFile).AddArgument($script:BridgeRunLogPath).AddArgument($slotId).AddArgument($script:BridgeCancelFile)
  [void]$ps.BeginInvoke()
  $script:BridgeWorkers += @{ Runspace = $rs; PS = $ps; Slot = $slotId }   # 持引用防 GC
}
Write-Host "[bridge] route workers: 3 (STA, queue=ConcurrentQueue, busy-heartbeat=$script:BridgeBusyFile)" -ForegroundColor DarkGray

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    try {
      Handle-Request -Context $context
    } catch {
      Write-Host "[bridge] Handler error: $($_.Exception.Message)" -ForegroundColor Red
    }
  }
} finally {
  $listener.Stop()
  $listener.Close()
}
