# Bridge 共享：AI 调用辅助函数（GLM 主通道 + DeepSeek 内网备胎，失败自动降级）。
# 文件名 _ 开头，_registry.ps1 不会当成路由暴露。
#
# PWCrossRunspaceCache 自举护栏(2026-09-23 实爆:测试报告 worker 独立进程只点源本文件,
# AI 熔断缓存首次读写时「找不到类型 PWCrossRunspaceCache」即 WORKER_FAILED)。
# 正常由 security.ps1/_auth-ledger-cache 先行定义,但 worker 加载链不过它们——类型缺失时
# 在此自举,彻底消除加载顺序依赖(-as [type] 防重复编译,与 _auth-ledger-cache 同款)。
if (-not ('PWCrossRunspaceCache' -as [type])) {
  Add-Type -TypeDefinition @"
using System.Collections.Concurrent;
public static class PWCrossRunspaceCache {
    public static readonly System.Collections.Concurrent.ConcurrentDictionary<string, object> Store = new System.Collections.Concurrent.ConcurrentDictionary<string, object>();
}
"@
}
#
# 2026-08-27 配置化：主通道/模型/降级开关/熔断时长从 bridge.config.json 的 ai 段读
# （每次 AI 调用重读 → 前端设置「AI」tab 保存后即时生效，无需重启 bridge）；
# 配置文件无 ai 段时回退 $script:AiDefaults（= 原硬编码值，行为等价）。
# 运行时状态（熔断截止 / 最近一次调用实际走的通道与原因）存 PWCrossRunspaceCache 进程级缓存
# （2026-09-21 由 $Global: 迁入——bridge 重路由每请求新 runspace,$Global: 即失;见 Get/Set-KbBreaker）,
# 由 ai-config route 的 get 透出给前端展示「当前实际在用哪个」,bridge 重启即清。
#
# 本文件源自作者个人工作台与分发版共用的单一源,开源版保留双通道架构说明。
# - (开源版裁剪:原文件的钉钉 dws 防风暴点源已去,SAP 路由不消费钉钉搜索)
# - ai.localOverlayPath（机器级 overlay JSON（分发形态 =
#   %LOCALAPPDATA%\sap-driver\ai-config.json，「AI 设置」面板写、同机多副本共享），
#   {baseUrl,key,model} 映射到 deepseek* 三键，另接受 primary/glmModel/cooldownMinutes/
#   autoFallback 同名字段。**AI 通道/模型始终走当前配置，零硬编码**：PW 默认不配此键
#   （走 local+tracked），分发形态由生成的 bridge.config.json 配置 → 每次调用重读，改完即时生效。
# - Invoke-KbClaude 新增 -CfgOverride（表单值直发不落盘，「测试连接」用）；
#   Invoke-KbDeepSeek 相应支持 -Cfg。DeepSeek 通道失败文案人话化。

# (开源版裁剪:原文件的钉钉 dws-helpers 点源已去——SAP 路由不消费钉钉搜索)

# ---- 默认值（bridge.config.json 无 ai 段时的回退；语义 = 2026-08-27 之前的硬编码） ----
# 备胎通道 = 任意 OpenAI chat/completions 兼容端点（内网 DeepSeek / 自建 vLLM / 云服务均可）。
$script:AiDefaults = @{
  primary         = 'glm'
  autoFallback    = $true
  cooldownMinutes = 10
  # 2026-11-04 对齐实际:桥 GLM 走 User 级智谱 anthropic 凭证,端点把 glm-4.6 名义请求
  # 间歇映射成 5.3-flash(还带"关思考被忽略"坑)——名义值直接写真实模型。实测名义
  # glm-5.3-flash 请求智谱端点返回 model=glm-5.3,正文正常。
  glmModel        = 'glm-5.3-flash'
  deepseekBaseUrl = ''   # 开源版:留空,部署者在 bridge.config.local.json 的 ai 段配置自己的 OpenAI 兼容备胎
  deepseekKey     = ''   # 开源版:绝不内置凭证
  deepseekModel   = 'DeepSeek-V4.1'
  localOverlayPath = ''
}

function Get-AiDefaultSettings {
  # 默认值副本（ai-config route 的 reset 用；不直接引用 $script:AiDefaults 避免作用域依赖）。
  return @{} + $script:AiDefaults
}

function Get-BridgeAiLocalPath {
  # ai 段真源 = bridge.config.local.json(gitignored,2026-09-01 审计:原直接读写 git 跟踪的
  # bridge.config.json,「AI」tab 存 key 即改 tracked 文件,误提交即入库凭证)
  return (Join-Path $PSScriptRoot '..\bridge.config.local.json')
}

function Get-AiSettings {
  # 读 ai 段 overlay 到默认值上:local(gitignored)优先,缺失字段回退 tracked bridge.config.json
  #(兼容旧装机/老克隆);读失败/字段缺失回退默认。
  $s = @{} + $script:AiDefaults
  foreach ($cfgPath in @((Get-BridgeAiLocalPath), (Join-Path $PSScriptRoot '..\bridge.config.json'))) {
    try {
      $raw = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($raw.ai) {
        if ($raw.ai.primary)                   { $s.primary         = [string]$raw.ai.primary }
        if ($null -ne $raw.ai.autoFallback)    { $s.autoFallback    = [bool]$raw.ai.autoFallback }
        if ($null -ne $raw.ai.cooldownMinutes) { $s.cooldownMinutes = [int]$raw.ai.cooldownMinutes }
        if ($raw.ai.glmModel)                  { $s.glmModel        = [string]$raw.ai.glmModel }
        if ($raw.ai.deepseekBaseUrl)           { $s.deepseekBaseUrl = [string]$raw.ai.deepseekBaseUrl }
        if ($raw.ai.deepseekKey)               { $s.deepseekKey     = [string]$raw.ai.deepseekKey }
        if ($raw.ai.deepseekModel)             { $s.deepseekModel   = [string]$raw.ai.deepseekModel }
        if ($raw.ai.localOverlayPath)          { $s.localOverlayPath = [string]$raw.ai.localOverlayPath }
      }
    } catch {}
  }
  # 机器级 overlay：最后套一层，优先级最高（「AI 设置」面板写这里 → 即时生效）。
  # 支持环境变量展开（%LOCALAPPDATA%）；文件缺失/解析失败静默跳过（回退前面各层配置）。
  if ($s.localOverlayPath) {
    try {
      $overlayPath = [Environment]::ExpandEnvironmentVariables([string]$s.localOverlayPath)
      if (Test-Path $overlayPath) {
        $o = Get-Content $overlayPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($o.baseUrl)         { $s.deepseekBaseUrl = [string]$o.baseUrl }
        if ($o.key)             { $s.deepseekKey     = [string]$o.key }
        if ($o.model)           { $s.deepseekModel   = [string]$o.model }
        if ($o.primary)         { $s.primary         = [string]$o.primary }
        if ($o.glmModel)        { $s.glmModel        = [string]$o.glmModel }
        if ($null -ne $o.autoFallback)    { $s.autoFallback    = [bool]$o.autoFallback }
        if ($null -ne $o.cooldownMinutes) { $s.cooldownMinutes = [int]$o.cooldownMinutes }
      }
    } catch {}
  }
  if ($s.primary -ne 'glm' -and $s.primary -ne 'deepseek') { $s.primary = 'glm' }
  return $s
}

function Save-AiSettings {
  # 读-改-写 bridge.config.local.json 的 ai 段(2026-09-01 审计:原写 tracked bridge.config.json,
  # 设置弹窗存 key 即产生 tracked 文件脏改)。tracked json 里的 ai 段从此只作旧装机回退。
  # $Patch 里 null/空串 = 沿用已存值；bool $false 与 0 是有效值会写入。返回保存后的生效配置。
  param([hashtable]$Patch)
  $cfgPath = Get-BridgeAiLocalPath
  $raw = $null
  try { $raw = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $raw = $null }
  if (-not $raw) { $raw = [pscustomobject]@{} }
  $ai = @{}
  if ($raw.ai) {
    foreach ($p in $raw.ai.PSObject.Properties) { $ai[$p.Name] = $p.Value }
  }
  foreach ($k in $Patch.Keys) {
    $v = $Patch[$k]
    if ($null -ne $v -and "$v" -ne '') { $ai[$k] = $v }
  }
  if ($raw.PSObject.Properties['ai']) { $raw.PSObject.Properties.Remove('ai') }
  $raw | Add-Member -NotePropertyName ai -NotePropertyValue $ai
  $raw | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $cfgPath -Encoding UTF8
  return Get-AiSettings
}

function Get-KbBreaker {
  # 跨请求 AI 熔断时间戳(2026-09-21 审查 P2):原 $Global: 在子 runspace 每请求归零=熔断器
  # 失效,通道故障期每次调用都先撞满一次失败等待(数十秒级);迁 PWCrossRunspaceCache 后
  # 冷却窗口真正生效。ai-config.ps1 同款消费(读状态/实测通顺手清熔断)。
  param([string]$Key)
  $v = [PWCrossRunspaceCache]::Store[$Key]
  return $(if ($null -ne $v) { [datetime]$v } else { $null })
}
function Set-KbBreaker {
  param([string]$Key, $Value)   # $Value=$null 即解除熔断
  [PWCrossRunspaceCache]::Store[$Key] = $Value
}

function Set-KbAiStatus {
  # 最近一次 AI 调用的实际通道 + 备注（降级原因等），供 ai-config get 透出前端状态卡。
  # 状态同样走进程级缓存(2026-09-21):$Global: 版每请求丢失,状态卡常显「无记录」。
  param([string]$Provider, [string]$Note = '')
  [PWCrossRunspaceCache]::Store['KbLastAiStatus'] = @{
    provider = $Provider
    at       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    note     = $Note
  }
}

function Get-KbClaudeConfig {
  # GLM 凭证走环境变量（不落盘）；ai-config get 透出 envOk 供前端提示。
  $baseUrl = $env:ANTHROPIC_BASE_URL
  $token   = $env:ANTHROPIC_AUTH_TOKEN
  if (-not $baseUrl -or -not $token) {
    return $null
  }
  return @{ baseUrl = $baseUrl.TrimEnd('/'); token = $token }
}

# 非 2xx 的真实原因在响应体里，而 PS 5.1 的 WebException.Message 只有一句
# 「远程服务器返回错误: (429) Too Many Requests。」（2026-10-23 用户反馈：
# 前台只看到这句，实际是 GLM 套餐 5 小时限额 code 1308）。统一把 body 翻出来。
function Get-AiErrorDetail {
  param($ErrorRecord)
  $ex = $ErrorRecord.Exception
  $resp = $null; $status = 0; $raw = ''
  # PS 5.1 的 Invoke-WebRequest 会先把响应体缓冲进 ErrorDetails.Message，
  # 此时 Response.GetResponseStream() 已读到末尾（读到的是空串）——必须先看 ErrorDetails。
  try { if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $raw = [string]$ErrorRecord.ErrorDetails.Message } } catch {}
  try { if ($ex.Response) { $resp = $ex.Response } } catch {}
  if ($resp) {
    try { $status = [int]$resp.StatusCode } catch {}
    if (-not $raw) {
      try {
        $stream = $resp.GetResponseStream()
        if ($stream) {
          $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
          $raw = $reader.ReadToEnd()
          $reader.Close()
        }
      } catch {}
    }
  }
  $pMsg = ''; $pCode = ''
  if ($raw) {
    try {
      $j = ConvertFrom-Json -InputObject $raw
      if ($j.error) {
        $pCode = [string]$j.error.code
        $pMsg  = [string]$j.error.message
        if (-not $pMsg -and $j.error.error) { $pMsg = [string]$j.error.error.message }
      } elseif ($j.message) { $pMsg = [string]$j.message }
      if (-not $pMsg -and $j.msg) { $pMsg = [string]$j.msg }
    } catch { $pMsg = $raw.Trim() }
    if ($pMsg.Length -gt 300) { $pMsg = $pMsg.Substring(0, 300) + '…' }
  }
  $head = @(); if ($status) { $head += "HTTP $status" }; if ($pCode) { $head += "code $pCode" }
  $headStr = ($head -join ' / ')
  if ($pMsg) { if ($headStr) { return "${headStr}：$pMsg" } else { return $pMsg } }
  if ($headStr) { return "$headStr（响应体为空）" }
  return $ex.Message
}

# GLM 账号级限速退避重试（2026-10-26）：429/code 1302 = 账户并发/QPS 超限，属瞬时拥挤
# （多个桥实例 + 本机 Claude Code 会话共用同一 GLM 账号时，高峰互撞是常态），此前一击即败，
# 用户侧表现即「测试老是报错」。退避 2/5/10s±1s 抖动至多重试 3 次（抖动防两桥同步重试再撞）。
# code 1308 = 5 小时 token 额度耗尽，窗口内重试无意义 → 不重试，照旧快速失败走既有熔断→
# DeepSeek 降级。5xx 网关抖动一并重试；其余错误（超时/连接失败/4xx 业务错）原样抛出由调用方兜底。
# Invoke-KbGlmOnce / Invoke-KbGlmVision 两个 chokepoint 都套用，全部调用方（含 ai-config
# 测试按钮、钉钉截图问答）零改动受益。
function Invoke-GlmWithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$Attempt,
    [int]$MaxAttempts = 3
  )
  for ($i = 1; $i -le $MaxAttempts; $i++) {
    try {
      return & $Attempt
    } catch {
      if ($i -ge $MaxAttempts) { throw }
      $detail = ''
      try { $detail = Get-AiErrorDetail $_ } catch { $detail = $_.Exception.Message }
      # code 1302 在 HTTP 状态缺失/解析失败时也可能单独出现，双条件都认
      $isRateOrServer = ($detail -match 'HTTP (429|5\d\d)') -or ($detail -match '\b1302\b')
      $isQuotaWindow  = $detail -match '\b1308\b'
      if (-not $isRateOrServer -or $isQuotaWindow) { throw }
      $backoff = @(2, 5, 10)[[math]::Min($i - 1, 2)] + (Get-Random -Maximum 2)
      Start-Sleep -Seconds $backoff
    }
  }
}

# 用 Invoke-WebRequest 拿原始字节再 UTF-8 解码，
# 避开 PS 5.1 Invoke-RestMethod 默认按 Latin-1 解析 application/json 的坑。
# GLM 单次调用（Anthropic 协议；模型名缺省取 ai 段 glmModel）。
function Invoke-KbGlmOnce {
  param(
    [Parameter(Mandatory)][string]$UserPrompt,
    [string]$SystemPrompt = '',
    [string]$Model,
    [int]$MaxTokens = 4096,
    [double]$Temperature = 0.2,
    [int]$TimeoutSec = 300,
    [object[]]$Images,
    [switch]$NoThinking   # 关闭 glm 思考:思考 token 计入 max_tokens,结构化输出类调用开着极易 OUTPUT_TRUNCATED
  )
  $cfg = Get-KbClaudeConfig
  if (-not $cfg) {
    throw 'ANTHROPIC_BASE_URL or ANTHROPIC_AUTH_TOKEN not configured'
  }
  if (-not $Model) { $Model = (Get-AiSettings).glmModel }

  $url = "$($cfg.baseUrl)/v1/messages"
  $headers = @{
    'x-api-key'         = $cfg.token
    'anthropic-version' = '2023-06-01'
    'content-type'      = 'application/json; charset=utf-8'
    'accept'            = 'application/json'
  }

  # Build content: plain string by default; array of text+image blocks when $Images is given
  # (Anthropic multimodal format). Callers that don't pass $Images are unaffected.
  $content = $UserPrompt
  if ($Images) {
    $blocks = @(@{ type = 'text'; text = $UserPrompt })
    foreach ($img in $Images) {
      $blocks += @{ type = 'image'; source = @{ type = 'base64'; media_type = [string]$img.mediaType; data = [string]$img.data } }
    }
    $content = $blocks
  }
  $body = [ordered]@{
    model       = $Model
    max_tokens  = $MaxTokens
    temperature = $Temperature
    messages    = @(@{
      role    = 'user'
      content = $content
    })
  }
  if ($SystemPrompt) { $body.system = $SystemPrompt }
  if ($NoThinking) { $body.thinking = @{ type = 'disabled' } }

  $json = $body | ConvertTo-Json -Depth 12 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

  try {
    # 429/1302/5xx 自动退避重试（2026-10-26 限速优化），其余错误一击即败
    $webRsp = Invoke-GlmWithRetry -Attempt {
      Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $bytes -TimeoutSec $TimeoutSec -UseBasicParsing
    }
  } catch {
    # 把 GLM 的原始原因透出（限额 code 1308 / 并发超限 / 余额不足 / key 无该模型权限…）
    throw "GLM 调用失败（$url）：$(Get-AiErrorDetail $_)"
  }
  $rspJson = [System.Text.Encoding]::UTF8.GetString($webRsp.RawContentStream.ToArray())
  $r = ConvertFrom-Json -InputObject $rspJson

  $text = ''
  if ($r.content -is [array]) {
    foreach ($c in $r.content) {
      if ($c.type -eq 'text') { $text += $c.text }
    }
  } elseif ($r.content.text) {
    $text = [string]$r.content.text
  }
  return @{
    text         = $text
    inputTokens  = $r.usage.input_tokens
    outputTokens = $r.usage.output_tokens
    model        = $r.model
    provider     = 'glm'
    stopReason   = $r.stop_reason
    truncated    = ($r.stop_reason -eq 'max_tokens')
  }
}

# ---- DeepSeek 内网备胎（OpenAI chat/completions 协议；地址/密钥/模型取 ai 段） ----
# 返回结构与 Invoke-KbGlmOnce 对齐（text/inputTokens/outputTokens/model/provider/stopReason/truncated）。
# -Cfg：表单值直发（「测试连接」），不走 Get-AiSettings 配置链。
function Invoke-KbDeepSeek {
  param(
    [Parameter(Mandatory)][string]$UserPrompt,
    [string]$SystemPrompt = '',
    [int]$MaxTokens = 4096,
    [double]$Temperature = 0.2,
    [int]$TimeoutSec = 300,
    [hashtable]$Cfg,
    [switch]$NoThinking   # 2026-11-04:DeepSeek-V4.1 经公司网关实锤也是思考模型(四字回复产
                          # 428字符 reasoning≈100 token 思考税);网关支持 OpenAI 标准
                          # reasoning_effort=none(实测 reasoning_len=0,completion 108→3),
                          # 思考税在长文档场景会挤占正文配额(与 GLM 同款截断死法)。
  )
  if ($Cfg) {
    $url   = "$(([string]$Cfg.baseUrl).TrimEnd('/'))/chat/completions"
    $dsKey = [string]$Cfg.key
    $dsModel = if ($Model) { $Model } else { [string]$Cfg.model }
  } else {
    $s = Get-AiSettings
    $url   = "$($s.deepseekBaseUrl.TrimEnd('/'))/chat/completions"
    $dsKey = $s.deepseekKey
    $dsModel = if ($Model) { $Model } else { $s.deepseekModel }
  }
  $headers = @{
    'Authorization' = "Bearer $dsKey"
    'content-type'  = 'application/json; charset=utf-8'
    'accept'        = 'application/json'
  }
  $messages = @()
  if ($SystemPrompt) { $messages += @{ role = 'system'; content = $SystemPrompt } }
  $messages += @{ role = 'user'; content = $UserPrompt }
  $body = [ordered]@{
    model       = $dsModel
    max_tokens  = $MaxTokens
    temperature = $Temperature
    messages    = $messages
  }
  # 关思考:reasoning_effort=none(公司网关 2026-11-04 实测支持;不认识的网关会忽略或 400,
  # 400 则调用方按既有降级链处理,不会比不加更差)
  if ($NoThinking) { $body.reasoning_effort = 'none' }
  $json   = $body | ConvertTo-Json -Depth 12 -Compress
  $bytes  = [System.Text.Encoding]::UTF8.GetBytes($json)
  # AI 是最高频依赖，失败给人话（原始 .NET 英文黑话会原样透传到界面上）。
  # 失败文案人话化。
  try {
    $webRsp = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $bytes -TimeoutSec $TimeoutSec -UseBasicParsing
  } catch {
    $ex = $_.Exception
    $detail = Get-AiErrorDetail $_
    $zh = "AI 服务调用失败：$detail"
    try {
      if ($ex -is [System.Net.WebException]) {
        if ($ex.Status -eq [System.Net.WebExceptionStatus]::Timeout) {
          $zh = "AI 处理超时（超过 $TimeoutSec 秒）。内容可能太长或服务正忙，等 1-2 分钟再试；反复超时请截图反馈给工具提供者。"
        } elseif ($ex.Status -eq [System.Net.WebExceptionStatus]::ConnectFailure -or $ex.Status -eq [System.Net.WebExceptionStatus]::NameResolutionFailure) {
          $zh = "AI 服务连不上。若在用默认公司 DeepSeek，请确认电脑连着公司内网/VPN；若在「AI 设置」里改过接口，请检查接口地址；仍不行请截图反馈给工具提供者。"
        } elseif ($ex.Response) {
          $zh = "AI 网关返回错误：$detail"
        }
      }
    } catch {}
    throw $zh
  }
  $rspJson = [System.Text.Encoding]::UTF8.GetString($webRsp.RawContentStream.ToArray())
  $r = ConvertFrom-Json -InputObject $rspJson

  $text   = [string]@($r.choices)[0].message.content
  $finish = [string]@($r.choices)[0].finish_reason
  return @{
    text         = $text
    inputTokens  = $r.usage.prompt_tokens
    outputTokens = $r.usage.completion_tokens
    model        = $r.model
    provider     = 'deepseek'
    stopReason   = $finish
    truncated    = ($finish -eq 'length')
  }
}

# ---- GLM 视觉识别（2026-09-07）：智谱原生 OpenAI 端点，单图→文本 ----
# ★不能走 anthropic 兼容端点 /v1/messages：它静默丢弃 image block（返回 200 但模型收不到图，
#   输入≈纯文本量，照 prompt 幻觉编内容）——vision-probe-test 实测。原生端点 image_url data-URI 真实计费。
# ★glm-4.6v 是思考型：必须 thinking:disabled，否则思考 token 吃满 max_tokens（空正文）或长超时。
# 任何失败都抛异常，由调用方兜底（问答链路回落 [图片] 占位 + 防呆闸，行为与未接视觉时一致）。
function Invoke-KbGlmVision {
  param(
    [Parameter(Mandatory)][byte[]]$ImageBytes,
    [string]$MimeType = 'image/png',
    [string]$Prompt = '',
    [string]$Model = 'glm-4.6v',
    [int]$MaxTokens = 4096,
    [int]$TimeoutSec = 90
  )
  $token = $env:ANTHROPIC_AUTH_TOKEN
  if (-not $token) { throw '视觉识别不可用：ANTHROPIC_AUTH_TOKEN 未配置（GLM 凭证）' }
  # 原生端点与 anthropic 端点同域：由 ANTHROPIC_BASE_URL 推导域名，换网关只改环境变量
  $origin = ''
  try { $origin = ([uri]$env:ANTHROPIC_BASE_URL).GetLeftPart([System.UriPartial]::Authority) } catch {}
  if (-not $origin) { $origin = 'https://open.bigmodel.cn' }
  $url = "$origin/api/paas/v4/chat/completions"
  if (-not $Prompt) {
    $Prompt = '请完整、逐字精确地读出图片中的关键信息：标题、字段名、具体值（编号/数字/代码/路径等务必逐字精确），不要遗漏小字。型号类文字若不确定，在该词后标注(?)。'
  }
  $b64 = [Convert]::ToBase64String($ImageBytes)
  $headers = @{
    'authorization' = "Bearer $token"
    'content-type'  = 'application/json; charset=utf-8'
    'accept'        = 'application/json'
  }
  $body = [ordered]@{
    model      = $Model
    max_tokens = $MaxTokens
    thinking   = @{ type = 'disabled' }
    messages   = @(@{
      role    = 'user'
      content = @(
        @{ type = 'image_url'; image_url = @{ url = "data:$MimeType;base64,$b64" } },
        @{ type = 'text';      text = $Prompt }
      )
    })
  }
  $json  = $body | ConvertTo-Json -Depth 12 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  # 与 Invoke-KbDeepSeek 同款 UTF-8 解码（PS 5.1 Invoke-RestMethod Latin-1 坑）
  # 同款 429/1302/5xx 退避重试（2026-10-26）：钉钉截图问答与文本链路共用账号限速池
  $webRsp = Invoke-GlmWithRetry -Attempt {
    Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $bytes -TimeoutSec $TimeoutSec -UseBasicParsing
  }
  $r = ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($webRsp.RawContentStream.ToArray()))
  $text = [string]@($r.choices)[0].message.content
  if (-not $text.Trim()) { throw '视觉识别返回空正文' }
  return $text.Trim()
}

# ---- GLM 视觉识别·anthropic 端点版（2026-11-03 需求解读 skill 配套）----
# 与 Invoke-KbGlmVision(原生端点 glm-4.6v)并列的另一条视觉通道：
#   anthropic 协议 /api/anthropic + glm-5.3-flash。2026-11-03 实测:
#   - glm-5.3-flash 在 anthropic 端点**真实收图**(256×256 红蓝白测试图逐字读对,in=126-139
#     tokens vs 纯文本 37;无图对照组自答"没看到图"排除幻觉)——09-07「anthropic 端点丢图」
#     是 GLM-4.6V 时代的结论,对 5.3-flash 不成立(两模型两条通道,各有各的真实)。
#   - 智谱原生端点(paas/v4)2026-11 账号资源包用尽恒 429(纯文本也拒),Invoke-KbGlmVision
#     那条路当前不可用;本函数走 anthropic 端点不受影响。
#   - glm-5.3-flash anthropic 端点不收 thinking:disabled(400),不传 thinking 即默认行为。
# 返回 hashtable(text/inputTokens/outputTokens/model/ms),比原生版多计时与 token 数——
# 批量逐图调用要算预算。任何失败抛异常,由调用方兜底。
function Invoke-KbVisionAnthropic {
  param(
    [Parameter(Mandatory)][byte[]]$ImageBytes,
    [string]$MimeType = 'image/png',
    [string]$Prompt = '',
    [string]$Model = 'glm-5.3-flash',
    [int]$MaxTokens = 4096,
    [int]$TimeoutSec = 120
  )
  $token = $env:ANTHROPIC_AUTH_TOKEN
  if (-not $token) { throw '视觉识别不可用：ANTHROPIC_AUTH_TOKEN 未配置（GLM 凭证）' }
  # 与 Invoke-KbGlmOnce 同源：baseUrl 末段可能是 /api/anthropic、/v1 或裸域，统一取域再拼 anthropic 路径
  $origin = ''
  try { $origin = ([uri]$env:ANTHROPIC_BASE_URL).GetLeftPart([System.UriPartial]::Authority) } catch {}
  if (-not $origin) { $origin = 'https://open.bigmodel.cn' }
  $url = "$origin/api/anthropic/v1/messages"
  if (-not $Prompt) {
    $Prompt = '请完整、逐字精确地读出图片中的关键信息：标题、字段名、具体值（编号/数字/代码/路径等务必逐字精确），不要遗漏小字。型号类文字若不确定，在该词后标注(?)。'
  }
  $body = [ordered]@{
    model      = $Model
    max_tokens = $MaxTokens
    messages   = @(@{
      role    = 'user'
      content = @(
        @{ type = 'image';  source = @{ type = 'base64'; media_type = $MimeType; data = [Convert]::ToBase64String($ImageBytes) } },
        @{ type = 'text';   text   = $Prompt }
      )
    })
  }
  $json  = $body | ConvertTo-Json -Depth 12 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  $headers = @{
    'x-api-key'         = $token
    'authorization'     = "Bearer $token"
    'anthropic-version' = '2023-06-01'
    'content-type'      = 'application/json; charset=utf-8'
    'accept'            = 'application/json'
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  # 同款 429/1302/5xx 退避重试(与文本链路共用账号限速池)
  $webRsp = Invoke-GlmWithRetry -Attempt {
    Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $bytes -TimeoutSec $TimeoutSec -UseBasicParsing
  }
  $sw.Stop()
  $r = ConvertFrom-Json -InputObject ([System.Text.Encoding]::UTF8.GetString($webRsp.RawContentStream.ToArray()))
  $text = ''
  if ($r.content -is [array]) {
    foreach ($c in $r.content) { if ($c.type -eq 'text') { $text += $c.text } }
  } elseif ($r.content.text) { $text = [string]$r.content.text }
  if (-not $text.Trim()) { throw '视觉识别返回空正文' }
  return @{
    text         = $text.Trim()
    inputTokens  = $r.usage.input_tokens
    outputTokens = $r.usage.output_tokens
    model        = $r.model
    ms           = $sw.ElapsedMilliseconds
  }
}

# ---- 对外统一入口：按 ai 段 primary 分派主通道，失败按 autoFallback 降级另一通道 ----
# 调用方签名与返回字段不变（新增 provider / glmError / dsError 字段，旧调用方无感知）。
# -Provider deepseek：正向路由，敏感数据任务直接走内网备胎，不试 GLM。
# 熔断：主通道失败后 cooldownMinutes 分钟内跳过它直接走备胎，避免每次调用都先付一次失败等待。
# TOKEN 超额这类持续故障：前端设置「AI」tab 会显示降级状态与原因，人手动把 primary 切到
# deepseek（不再反复撞 GLM）；恢复后点「测试 GLM」验证再切回。
function Invoke-KbClaude {
  param(
    [Parameter(Mandatory)][string]$UserPrompt,
    [string]$SystemPrompt = '',
    [string]$Model,
    [int]$MaxTokens = 4096,
    [double]$Temperature = 0.2,
    [int]$TimeoutSec = 300,
    [object[]]$Images,
    [switch]$NoThinking,   # 透传给 GLM(thinking:disabled)与 DeepSeek(reasoning_effort=none)两通道:关思考省配额
    [ValidateSet('auto','deepseek')]
    [string]$Provider = 'auto',
    [hashtable]$CfgOverride   # 表单值直发不落盘(「测试连接」);给定即直走 DeepSeek
  )

  # -CfgOverride：绕过主备派单/熔断，直接用表单值打 DeepSeek（连通性验证语义）。
  if ($CfgOverride) {
    try {
      return Invoke-KbDeepSeek -UserPrompt $UserPrompt -SystemPrompt $SystemPrompt -MaxTokens $MaxTokens -Temperature $Temperature -TimeoutSec $TimeoutSec -NoThinking:$NoThinking -Cfg $CfgOverride
    } catch {
      throw "DeepSeek 调用失败：$($_.Exception.Message)"
    }
  }

  $s = Get-AiSettings

  # 带图调用：DeepSeek 无视觉能力，不存在备胎 → 永远走 GLM（即使 primary=deepseek），失败直接抛。
  # 必须放在熔断检查之前：熔断期跳过 GLM 会让带图调用静默丢图走 DeepSeek。
  if ($Images) {
    if ($Provider -eq 'deepseek') {
      throw 'DeepSeek 无视觉能力，带图调用不支持 -Provider deepseek'
    }
    try {
      $r = Invoke-KbGlmOnce -UserPrompt $UserPrompt -SystemPrompt $SystemPrompt -Model $Model -MaxTokens $MaxTokens -Temperature $Temperature -TimeoutSec $TimeoutSec -Images $Images -NoThinking:$NoThinking
      Set-KbAiStatus 'glm' '带图调用（仅 GLM 支持视觉）'
      return $r
    } catch {
      throw "GLM 调用失败（本次含图像，DeepSeek 无视觉能力，无法降级）：$($_.Exception.Message)"
    }
  }

  # -Provider deepseek：正向路由，直接走备胎，不试 GLM。
  if ($Provider -eq 'deepseek') {
    try {
      $r2 = Invoke-KbDeepSeek -UserPrompt $UserPrompt -SystemPrompt $SystemPrompt -MaxTokens $MaxTokens -Temperature $Temperature -TimeoutSec $TimeoutSec -NoThinking:$NoThinking
      Set-KbAiStatus 'deepseek' '正向路由（敏感数据直走内网）'
      return $r2
    } catch {
      throw "DeepSeek 调用失败：$($_.Exception.Message)（注：DeepSeek 仅公司内网可达）"
    }
  }

  if ($s.primary -eq 'deepseek') {
    # ---- 主通道 DeepSeek，失败降 GLM（在家连不上内网时 GLM 兜底）----
    $dsError = $null
    $kbDsCd = Get-KbBreaker 'KbDsUnhealthyUntil'
    $inCd = ($null -ne $kbDsCd) -and ($kbDsCd -gt [datetime]::Now)
    if (-not $inCd) {
      try {
        $r2 = Invoke-KbDeepSeek -UserPrompt $UserPrompt -SystemPrompt $SystemPrompt -MaxTokens $MaxTokens -Temperature $Temperature -TimeoutSec $TimeoutSec -NoThinking:$NoThinking
        Set-KbBreaker 'KbDsUnhealthyUntil' $null
        Set-KbAiStatus 'deepseek'
        return $r2
      } catch {
        $dsError = $_.Exception.Message
        Set-KbBreaker 'KbDsUnhealthyUntil' ([datetime]::Now.AddMinutes($s.cooldownMinutes))
      }
    } else {
      $dsError = "DeepSeek 处于熔断期（至 $kbDsCd）"
    }
    if (-not $s.autoFallback) { throw "DeepSeek 调用失败（autoFallback 已关闭，不降级）：$dsError" }
    try {
      $r = Invoke-KbGlmOnce -UserPrompt $UserPrompt -SystemPrompt $SystemPrompt -Model $Model -MaxTokens $MaxTokens -Temperature $Temperature -TimeoutSec $TimeoutSec -NoThinking:$NoThinking
      $r['dsError'] = $dsError
      Set-KbAiStatus 'glm' "主通道 DeepSeek 失败，已降级 GLM：$dsError"
      return $r
    } catch {
      throw "AI 双通道均失败。DeepSeek：$dsError | GLM：$($_.Exception.Message)"
    }
  }

  # ---- 主通道 GLM，失败降 DeepSeek（TOKEN 超额时降级原因会在设置「AI」tab 可见）----
  $glmError = $null
  $kbGlmCd = Get-KbBreaker 'KbGlmUnhealthyUntil'
  $inCooldown = ($null -ne $kbGlmCd) -and ($kbGlmCd -gt [datetime]::Now)
  if (-not $inCooldown) {
    try {
      $r = Invoke-KbGlmOnce -UserPrompt $UserPrompt -SystemPrompt $SystemPrompt -Model $Model -MaxTokens $MaxTokens -Temperature $Temperature -TimeoutSec $TimeoutSec -NoThinking:$NoThinking
      Set-KbBreaker 'KbGlmUnhealthyUntil' $null   # 成功即解除熔断
      Set-KbAiStatus 'glm'
      return $r
    } catch {
      $glmError = $_.Exception.Message
      Set-KbBreaker 'KbGlmUnhealthyUntil' ([datetime]::Now.AddMinutes($s.cooldownMinutes))
    }
  } else {
    $glmError = "GLM 处于熔断期（至 $kbGlmCd）"
  }
  if (-not $s.autoFallback) { throw "GLM 调用失败（autoFallback 已关闭，不降级）：$glmError" }
  try {
    $r2 = Invoke-KbDeepSeek -UserPrompt $UserPrompt -SystemPrompt $SystemPrompt -MaxTokens $MaxTokens -Temperature $Temperature -TimeoutSec $TimeoutSec -NoThinking:$NoThinking
    $r2['glmError'] = $glmError   # 降级原因透出，调用方可回传前端
    Set-KbAiStatus 'deepseek' "主通道 GLM 失败，已降级 DeepSeek：$glmError"
    return $r2
  } catch {
    throw "AI 双通道均失败。GLM：$glmError | DeepSeek：$($_.Exception.Message)（注：DeepSeek 仅公司内网可达）"
  }
}

# 修复 GLM 输出里字符串值内部的裸 ASCII 引号(中文引号写成半角 " 且不转义,
# 2026-09-22 qa-from-chat PARSE_FAILED 抓到现行,占偶发非 JSON 大头)。
# 状态机逐字符扫描跟踪 in-string 状态;字符串内的 " 判定为「内容引号」的条件:
# 前一字符是 CJK/全角标点 且 后一个非空白字符不是结构符(, : } ] ")→ 替换为 “/”(交替配对)。
# 局限:内容引号紧贴半角逗号/闭括号(如 都选"否",请确认)会误判为字符串边界,
# 修复后整体仍非法 → 调用方解析照旧失败回落既有失败路径,不会产生比现状更坏的错解析。
function Repair-ClaudeJsonQuotes {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text) -or -not $Text.Contains('"')) { return $Text }
  # \uXXXX 转义防编码环节损坏:CJK统一汉字 4E00-9FFF / CJK标点 3000-303F / 全角形 FF00-FFEF / 弯引号 2018-201D
  $cjkRe = '[一-鿿　-〿＀-￯“”‘’]'
  $structChars = [char[]](34, 44, 58, 125, 93)   # " , : } ]
  $sb = New-Object Text.StringBuilder($Text.Length)
  $inStr = $false; $openQuote = $true; $i = 0; $n = $Text.Length
  while ($i -lt $n) {
    $ch = $Text[$i]
    if (-not $inStr) {
      if ($ch -eq '"') { $inStr = $true }
      [void]$sb.Append($ch); $i++; continue
    }
    if ($ch -eq '\') {
      [void]$sb.Append($ch)
      if ($i + 1 -lt $n) { [void]$sb.Append($Text[$i + 1]); $i += 2 } else { $i++ }
      continue
    }
    if ($ch -eq '"') {
      $prevIsCjk = $i -gt 0 -and ([string]$Text[$i - 1]) -match $cjkRe
      $j = $i + 1
      while ($j -lt $n -and [char]::IsWhiteSpace($Text[$j])) { $j++ }
      $nextIsStruct = ($j -ge $n) -or ($structChars -contains $Text[$j])
      if ($prevIsCjk -and -not $nextIsStruct) {
        # 内容引号:还原成中文引号,交替配对还原开/闭语义
        if ($openQuote) { [void]$sb.Append([char]0x201C) } else { [void]$sb.Append([char]0x201D) }
        $openQuote = -not $openQuote
        $i++; continue
      }
      $inStr = $false
    }
    [void]$sb.Append($ch); $i++
  }
  return $sb.ToString()
}

# 期望模型返回严格 JSON。
# 仅当文本「整体」被 ```json ... ``` 包裹时才剥外层标记，
# 否则会误伤 JSON 字符串值里嵌入的 markdown 代码块。
function ConvertFrom-ClaudeJson {
  # 空回复(GLM 思考耗尽 max_tokens / 网关异常)返回 $null,调用方走既有 null 检查优雅失败;
  # 不再以 Mandatory 参数绑定异常炸穿整条链路(2026-09-03 09:10 日报即挂于此)。
  param([AllowEmptyString()][string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $t = $Text.Trim()
  # 1) 整体被 ```json ... ``` 包裹 → 剥外层代码块标记
  if ($t -match '(?s)^```(?:json)?\s*(.+?)\s*```$') {
    $t = $matches[1].Trim()
  }
  try { return (ConvertFrom-Json -InputObject $t) } catch {}
  # 2) 整体解析失败 → 提取首个 { 到末个 } 的片段再试（应对 AI 在 JSON 前后夹带解释文字 / 输出多个代码块）
  if ($t -match '(?s)\{.*\}') {
    try { return (ConvertFrom-Json -InputObject $matches[0]) } catch {}
  }
  # 3) 字符串值内部裸 ASCII 引号(GLM 把中文引号写成半角且不转义,2026-09-22 实锤)
  #    → 状态机修复内容引号后重试;仅当修复确实改变了文本才值得再解析一次
  $fixed = Repair-ClaudeJsonQuotes -Text $t
  if ($null -ne $fixed -and $fixed -ne $t) {
    try { return (ConvertFrom-Json -InputObject $fixed) } catch {}
    if ($fixed -match '(?s)\{.*\}') {
      try { return (ConvertFrom-Json -InputObject $matches[0]) } catch {}
    }
  }
  return $null
}
