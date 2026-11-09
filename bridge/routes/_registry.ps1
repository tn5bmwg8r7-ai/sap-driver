function Get-BridgeRoutes {
  # 启动后路由清单不变（加新路由要重启 bridge），首次扫描后缓存，避免每个 /run/ 请求重扫目录。
  # 代码自查 kb-2026-08-07-pwaudit 重构 5。
  # 缓存用 $global:（2026-09-02 分发收敛⑥：bridge 以 & 逐请求调 route，$script: 每请求被重置
  # → 缓存失效永远重扫；$global: 才是进程级。与 _qa-cache/_claude-helpers 同约定）。
  if ($global:RouteCache) { return $global:RouteCache }
  $routesDir = Join-Path $PSScriptRoot '..\routes'
  $routes = @{}
  Get-ChildItem -Path $routesDir -Filter '*.ps1' -File | Where-Object { $_.Name -notlike '_*' } | ForEach-Object {
    $routeFile = $_.FullName
    $commandId = $_.BaseName
    $routes[$commandId] = $routeFile
  }
  $global:RouteCache = $routes
  return $routes
}

function Get-BridgeLockedRoutes {
  # 未分发路由名单（可选闸门）：存在 routes.locked.json 时生效(数组=未分发路由名)。
  # 本仓无此文件 → 空名单，闸门零效果。
  # 调用名单内路由 → Invoke-BridgeRoute 返回 FEATURE_LOCKED「功能解锁中」，不影响其他功能。
  if ($null -ne $global:BridgeLockedRoutes) { return $global:BridgeLockedRoutes }
  $f = Join-Path $PSScriptRoot 'routes.locked.json'
  $global:BridgeLockedRoutes = @()
  if (Test-Path $f) {
    try { $global:BridgeLockedRoutes = @(Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $global:BridgeLockedRoutes = @() }
  }
  return $global:BridgeLockedRoutes
}

function Get-BridgePkgLockedRoutes {
  # 按包锁定名单(2026-09-21):Build-Package 打包时按勾选 tabs 从 routes.pkg-lockable.json(Sync
  # 生成的 feature→routes 原料)算出「本包未勾选功能」的路由并集,写 routes.pkg-locked.json。
  # 适用对象=文件恒带的 [ui] 功能(kb/chat/todo/intl 群):文件随包、启用与否只看这道闸。
  # 旧包无此文件 → 空名单,行为与无闸完全一致(优雅降级,分发锁同名惯例)。
  if ($null -ne $global:BridgePkgLockedRoutes) { return $global:BridgePkgLockedRoutes }
  $f = Join-Path $PSScriptRoot 'routes.pkg-locked.json'
  $global:BridgePkgLockedRoutes = @()
  if (Test-Path $f) {
    try { $global:BridgePkgLockedRoutes = @(Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $global:BridgePkgLockedRoutes = @() }
  }
  return $global:BridgePkgLockedRoutes
}

function Invoke-BridgeRoute {
  param(
    [string]$CommandId,
    [hashtable]$Body,
    [string]$RouteFile = ''
  )
  # 2026-09-11 审计 P0:#1 重路由在子 runspace 里跑,而 $global: 是 runspace 级——子内每次
  # dot-source 本文件 + Get-BridgeRoutes 重扫路由目录,各 $global: 缓存(RouteCache、_ozkb 会话、
  # kb 摘要、auth-ledger、cn-workday)在重路径上全灭,qa-answer 类每请求重新登录。
  # worker 侧现在用自己的热缓存解析好 routeFile 传入,子内跳过目录扫描直接执行;
  # 主线程/worker 自身调用不传该参,行为不变。worker 只在自家 Get-BridgeRoutes 命中时才传,
  # 未命中(=未分发路由)走原路径,FEATURE_LOCKED 闸门语义不受影响。
  if ($RouteFile -and (Test-Path -LiteralPath $RouteFile)) {
    $result = & $RouteFile -Body $Body
    return $result
  }
  $routes = Get-BridgeRoutes
  # 按包锁定闸门(2026-09-21):被锁路由的文件在包里([ui] 恒带),ContainsKey 会命中,
  # 必须在路由执行之前拦,不能放下方「未分发」分支。热路径($RouteFile worker 直执行)不拦——
  # 保留功能对锁内路由的依赖已由打包侧排除清单归零(recap-my-todos=bpm/todo 日报页写入待办依赖、
  # bpm-todo-login=设置登录 pane 依赖,两条例外永不锁;全量调用方普查 2026-09-21)。
  if ((Get-BridgePkgLockedRoutes) -contains $CommandId) {
    return @{ ok = $false; locked = $true
              error = @{ code = 'FEATURE_LOCKED'
                         message = "功能「$CommandId」未随本包启用（打包时未勾选）" } }
  }
  if (-not $routes.ContainsKey($CommandId)) {
    # 未分发功能兜底闸门：文件层已硬隐藏（Sync 不复制），这里是"万一被调到"的软兜底。
    # HTTP 仍 200 + ok:false：走前端既有错误通道（run() 抛 err.code），调用方 catch 无需改动。
    # 带上路由名：否则同事看到提示不知道是哪个功能没解锁（2026-09-02 用户反馈）。
    if ((Get-BridgeLockedRoutes) -contains $CommandId) {
      return @{ ok = $false; locked = $true
                error = @{ code = 'FEATURE_LOCKED'
                           message = "功能「$CommandId」未作分发，功能解锁中，敬请期待" } }
    }
    throw "Unknown command: $CommandId"
  }
  $routeFile = $routes[$CommandId]
  $result = & $routeFile -Body $Body
  return $result
}
