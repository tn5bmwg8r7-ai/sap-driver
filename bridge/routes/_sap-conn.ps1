# ============================================================
# _sap-conn  -  SAP 环境连接配置单点(2026-08-31 对抗审查整合)。
# 文件名 _ 开头,_registry.ps1 不会当成路由暴露。
#
# 背景:同一套 host/client/User 表此前硬编码在 sap-interface-doc.ps1 与
# sap-test-report-worker.ps1 两处且已漂移 —— interface-doc 侧 DVP 还停在
# Client 800,后按部署者环境把默认 client 调整为各自值(见环境表,均为示例)。
# 此后加环境/改口令只动这里。
#
# 依赖:无(纯数据)。调用方自行 dot-source 本文件后调 Get-SapEnvCfg。
# Test-SapRfcLogin(验密 ping)已移至 _sap-rfclogin.ps1(本机部署专用,含本机 Bin 路径不分发;2026-09-21 V7)。
# 红线:密码不在此文件、不落任何盘,仅由调用方内存传递给 Invoke-SapRfc。
# ============================================================

# 环境表(开源版默认占位——部署者改这里或经环境表覆盖:DVP=开发机/QAS=测试机/PRD=生产机,
# 键名是治理体系的协议键。host/sysNr/client 按你的环境填;host 支持 [Environment]::ExpandEnvironmentVariables)
$script:SapEnvCfg = @{
  DVP = @{ host = '<开发机应用服务器地址>'; sysNr = '00'; client = '900' }
  QAS = @{ host = '<测试机应用服务器地址>'; sysNr = '00'; client = '800' }
  PRD = @{ host = '<生产机应用服务器地址>'; sysNr = '00'; client = '800' }
}
# 默认连接用户留空:分发包不该内置打包者个人账号(09-04 审查);唯一调用方
# sap-interface-doc 总是显式传 -User(前端 sapUser 表单值),留空仅作漏传时的明确报错。
$script:SapUser     = ''
$script:SapLanguage = 'ZH'

# 取某系统 Invoke-SapRfc 连接参数散列表。未知系统抛 UNKNOWN_SYSTEM(调用方直接透传前端)。
function Get-SapEnvCfg {
  param(
    [Parameter(Mandatory)][string]$System,
    [string]$User,       # 覆盖默认用户(一般不用)
    [string]$Language,   # 覆盖默认语言(如 interface-doc 允许调用方传)
    [string]$Client      # 覆盖该系统默认 client(2026-09-21 凭证合一:连接管理连的哪个 client,文档链就跑哪个)
  )
  $key = ([string]$System).Trim().ToUpper()
  $e = $script:SapEnvCfg[$key]
  if (-not $e) { throw "UNKNOWN_SYSTEM: $System(仅支持 DVP/QAS/PRD)" }
  $effUser = if ($User) { $User } else { $script:SapUser }
  # 缺用户名=配置错误,当场明确报错(空用户登录失败的报错长得像密码错,曾误导排查方向)
  if (-not $effUser) { throw "SAP 连接缺少用户名:调用方未传 -User,且 _sap-conn 未配置默认用户。调用方应显式传 -User(前端 sapUser 表单值传入)。" }
  return @{
    AppServerHost = $e.host
    SystemNumber  = $e.sysNr
    Client        = $(if ($Client) { $Client } else { $e.client })
    User          = $effUser
    Language      = if ($Language) { $Language } else { $script:SapLanguage }
    Destination   = $key
  }
}

# ============================================================
# SAP 会话凭证内存槽(2026-09-20 钉钉值守全自动接口文档配套;2026-09-21 v2 按系统分格+凭证合一)。
# 用途:小助理自动生成接口文档时,action-run 在表单密码为空时按【表单 system】从槽取对应格。
# 主通道(2026-09-21 用户定案「小助理和 SAP 副驾走一个通道,DVP QAS PRD 都是」):
#       连接管理 sap-tool sap_connect 成功即同值双写本槽、sap_disconnect 同清 —— 一处连接,两链同喂。
#       sap-session.ps1 注入保留为脚本化备用通道(set-sap-session.ps1)。
# 红线:密码仅 bridge 进程内存,绝不落盘/不进日志/不回显;bridge 重启即失效;TTL 到期自动失效。
# 作用域(2026-09-20 实测定案):bridge 每请求跑在新 runspace,$script:/​$global: 都是 runspace 级、
#       一请求一清(与 09-18 问答缓存 100% miss 同根因)→ 必须用 AppDomain 级存储:
#       [AppDomain]::CurrentDomain SetData/GetData 同进程所有 runspace 共享,纯内存,进程退出即失效。
# 消费端:action-run.ps1(表单密码为空时按系统兜底) → PW_ACTION_PWD/PW_ACTION_CLIENT env → worker。
# 注意:PRD 格允许存在(三系统同通道),但消费端闸门不动 —— interface-doc 照旧 PRD_FORBIDDEN。
# Client 字段:连接管理里【显式填了的 client】才存;空串=消费端用各系统默认(DVP=900/QAS=800/PRD=800)。
# ============================================================
$script:SapSessionSlotKey = 'PW_SAP_SESSION_CRED'

function Save-SapSessionCred {
  param(
    [Parameter(Mandatory)][string]$Password,
    [string]$System = 'DVP',
    [string]$User = '',
    [int]$TtlHours = 12,
    [string]$Client = ''
  )
  $key = ([string]$System).Trim().ToUpper()
  $store = [System.AppDomain]::CurrentDomain.GetData($script:SapSessionSlotKey)
  if ($store -isnot [System.Collections.IDictionary]) { $store = @{} }   # v1 单格旧形状/空 → 直接换新库
  $store[$key] = @{
    Password  = $Password
    User      = $User
    Client    = [string]$Client
    ExpiresAt = (Get-Date).AddHours($TtlHours)
  }
  [System.AppDomain]::CurrentDomain.SetData($script:SapSessionSlotKey, $store)
}

function Get-SapSessionCred {
  param([string]$System = '')
  # 带 -System:命中返回该格散列表(调用方只转传 env,不落任何处);未注入/已过期返回 $null(过期顺手清格)。
  # 不带:返回整库 IDictionary(可能为空),聚合展示用(sap-status/sap-session status)。
  $store = [System.AppDomain]::CurrentDomain.GetData($script:SapSessionSlotKey)
  if ($store -isnot [System.Collections.IDictionary]) { return $null }   # v1 单格旧形状不认,等重注
  if (-not $System) { return $store }
  $key = ([string]$System).Trim().ToUpper()
  $c = $store[$key]
  if (-not $c) { return $null }
  if ((Get-Date) -gt $c.ExpiresAt) {
    $store.Remove($key)
    [System.AppDomain]::CurrentDomain.SetData($script:SapSessionSlotKey, $store)
    return $null
  }
  return $c
}

function Clear-SapSessionCred {
  param([string]$System = '')
  $store = [System.AppDomain]::CurrentDomain.GetData($script:SapSessionSlotKey)
  if ($store -isnot [System.Collections.IDictionary]) {
    [System.AppDomain]::CurrentDomain.SetData($script:SapSessionSlotKey, $null)
    return
  }
  if (-not $System) {
    [System.AppDomain]::CurrentDomain.SetData($script:SapSessionSlotKey, $null)
    return
  }
  $store.Remove(([string]$System).Trim().ToUpper())
  [System.AppDomain]::CurrentDomain.SetData($script:SapSessionSlotKey, $store)
}
