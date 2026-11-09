# ============================================================
# _sap-rfclogin  -  直连验密 ping(2026-09-21 V7)。
# 依赖仓库 rfc-frontend/RfcCli/Invoke-SapRfc.ps1(NCo 3.1);路径经环境变量
# SAP_RFC_FRONTEND 指定,缺省回落本仓相对路径。通道不存在=SAP_RFC_NOT_FOUND 降级。
# 消费方:sap-session.ps1 / sap-interface-doc.ps1(均先 dot-source _sap-conn)。
# 红线:密码仅内存流转,不落盘不进日志。
# ============================================================

# Invoke-SapRfc 挂脚本作用域(2026-10-12 修):原只在 Test-SapRfcLogin 函数内 dot-source,
# 函数返回即丢作用域——函数内验密 ping 能过,但消费方(sap-interface-doc 等)随后在
# 自己脚本作用域调 Invoke-SapRfc 必报「无法识别为 cmdlet」(生成文档实测抓到)。
# 这里脚本级加载一次;SAP_RFC_FRONTEND 指定 RFC 前端目录,缺省 = 本仓 rfc-frontend/RfcCli。
function Get-SapRfcFrontendPath {
  if ($env:SAP_RFC_FRONTEND) { return $env:SAP_RFC_FRONTEND }
  # 桥位于 <repo>/bridge,前端位于 <repo>/rfc-frontend/RfcCli
  return (Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'rfc-frontend') 'RfcCli')
}
$sapDirLdr = Get-SapRfcFrontendPath
$__invokeSapRfcLdr = Join-Path $sapDirLdr 'Invoke-SapRfc.ps1'
if (Test-Path $__invokeSapRfcLdr) { . $__invokeSapRfcLdr }

function Test-SapRfcLogin {
  # 直连验密 ping(2026-09-21 审查 P3 收拢:interface-doc/sap-session 两处各写一份
  # 「Invoke-SapRfc 存在性→dot-source→Get-SapEnvCfg→STFC_CONNECTION」引导链)。
  # 返回 @{ ok=$true; conn } 或 @{ ok=$false; code; message };密码仅内存流转,不落日志。
  # -PingTag:STFC REQUTEXT 标来源(审计区分调用来源)。
  param([Parameter(Mandatory)][string]$System, [Parameter(Mandatory)][string]$Password,
        [string]$User = '', [string]$Language, [string]$PingTag = 'pw-ping',
        [string]$Client = '')   # 凭证合一(2026-09-21):槽里显式存了 client 就按它连,空=各系统默认
  $sapDir = Get-SapRfcFrontendPath
  $invokeSapRfc = Join-Path $sapDir 'Invoke-SapRfc.ps1'
  if (-not (Test-Path $invokeSapRfc)) {
    return @{ ok = $false; code = 'SAP_RFC_NOT_FOUND'; message = "Invoke-SapRfc.ps1 missing under $sapDir (set SAP_RFC_FRONTEND env var)" }
  }
  . $invokeSapRfc   # 定义 Invoke-SapRfc(幂等 dot-source)
  $conn = $null
  try {
    # -Language 空值安全:Get-SapEnvCfg 内部 if ($Language) 落默认,无需条件传参
    $conn = Get-SapEnvCfg -System $System -User $User -Client $Client -Language $Language
    Invoke-SapRfc -Function STFC_CONNECTION -Import @{ REQUTEXT = $PingTag } @conn -Password $Password | Out-Null
    return @{ ok = $true; conn = $conn }
  } catch {
    $cli = $(if ($conn) { $conn.Client } else { '?' })
    return @{ ok = $false; code = 'SAP_LOGIN_FAILED'; message = "验密失败($System client=$cli user=$User):$($_.Exception.Message)" }
  }
}
