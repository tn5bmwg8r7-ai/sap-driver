param(
  [Parameter(Mandatory)][hashtable]$Body,
  # 精简模式(action-run-worker 后台路径专用):跳过 docxBase64 编码与 factsJson 返回 ——
  # worker 会把这两个大字段剥掉,生成纯属浪费(~1-2MB 分配);docx 文件与 markdown 照常产出
  [switch]$Slim
)

# Get-FacadeProp:IDictionary/PSObject 双形状取值(versionedDoc 解析与 facade 段共用;
# 须在文件头定义,versionedDoc 解析在参数解析段先用到)。
function Get-FacadeProp($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) { return $Obj[$Name] }
  $pp = $Obj.PSObject.Properties[$Name]
  return $(if ($pp) { $pp.Value } else { $null })
}


# SAP 接口文档生成器：输入函数名(1+) + SAP 密码 → 连所选系统(默认 DVP)自动读 DDIC + AI 生成对外接口文档(md)。
# 流程：RPY_FUNCTIONMODULE_READ(源码→自动发现引用的 DDIC 结构) → DDIF_FIELDINFO_GET(字段目录)
#       → RFC_READ_TABLE DD07T(ZZ_* 域枚举) → 模板铺字段表骨架 → AI 补业务含义/取数来源/注意事项。
# 2026-11-04 P4 根治大字段表(源自真实工单案例:5 结构 101 字段,AI 整篇
# 生成必丢字段——CC 手搓成功而本路由扛不住,差距在触发形态不在能力):**字段表机器直出,AI 只写
# 散文段**;生成后机器断言(文中字段名 ⊇ DDIC 实读集);字段表加「转换例程」列(转码类需求命门,
# 如 MEINS 的 CUNIT);直连形态 RPY 拿不到源码时补 facade sap_fm_read 兜底(自带 ENLFDIR 绕行,
# 覆盖 RPY 抛 ERROR_MESSAGE 的 Z FM);新场景:versionedDoc(中途接入/改造已落库,沿老格式出
# V2 并标注变更点)。
# 红线：默认 DVP；PRD 拒绝；密码仅内存使用(传入 Invoke-SapRfc，绝不落盘/不 log)。

. (Join-Path $PSScriptRoot '_claude-helpers.ps1')
# 复用 md→docx(OOXML 直写,避 Word COM)。2026-09-01 拆分后函数库无 param,不再覆盖宿主 $Body,
# 原 $__routeBody 存取 hack 已拆除(见 _ooxml-office.ps1 头注释)。
. (Join-Path $PSScriptRoot '_ooxml-office.ps1')

$bodyInput = $Body.input
$functions = @($bodyInput.functions | Where-Object { $_ }) | ForEach-Object { [string]$_ }
$password  = ([string]$bodyInput.sapPassword).Trim()   # 表单粘贴尾随空格=登录失败惯犯(sap-test-report 09-09 同款;2026-11-04 补齐本路由)
$viaFacade = $false   # 三级回落第三级:表单密码/槽都没有 → facade 凭证活则整链走 facade 工具(下方判定)
$system    = if ($bodyInput.system) { [string]$bodyInput.system } else { 'DVP' }
$system    = $system.Trim().ToUpper()
# 凭证合一(2026-09-21):action-run 从槽带下来的显式 client(连接管理连接时填了才非空);
# 空=按 _sap-conn 各系统默认(见环境表)。
$client    = if ($bodyInput.sapClient) { ([string]$bodyInput.sapClient).Trim() } else { '' }
$language  = if ($bodyInput.language) { [string]$bodyInput.language } else { 'ZH' }
$extraHint = [string]$bodyInput.extraHint   # 可选：用户补充的业务背景，喂给 AI
# 2026-11-04 P4 新场景:versionedDoc——中途接入/改造已落库,文档要带「变更记录」章节并在受
# 影响字段/参数上标 V2 变更点(触发形如 BPM 中途接入补接口文档;某 SRM 接口转码+R_DATE 单
# 实跑证实 AI 全文模式沿不了老格式)。versionedDoc.version=新版本号(如 'V2'),versionedDoc.
# changes=变更点句数组(每条已含对象/字段/新旧语义),AI 按此生成变更记录章节+字段表标注列。
$versionedDoc = $null
if ($bodyInput.versionedDoc) {
  $vd = $bodyInput.versionedDoc
  $versionedDoc = [ordered]@{
    version = [string](Get-FacadeProp $vd 'version')
    changes = @()
  }
  foreach ($c in @(Get-FacadeProp $vd 'changes')) { $versionedDoc.changes += [string]$c }
}
# 可选：手工喂入的函数源码 { 'ZXXX' => 'abap source...' }。
#       RPY_FUNCTIONMODULE_READ 对部分 Z FM 抛 ERROR_MESSAGE 拿不到源码，此时用调用方提供的
#       (如 CC 已用 sap_prog_read 直读 REPOSRC 拿到)兜底，使"业务逻辑"章节基于真实源码而非 AI 推断。
$sources = @{}
if ($bodyInput.sources) {
  $srcEnum = if ($bodyInput.sources -is [System.Collections.IDictionary]) { $bodyInput.sources.GetEnumerator() } else { $bodyInput.sources.PSObject.Properties }
  foreach ($p in @($srcEnum)) { $sources[[string]$p.Name] = [string]$p.Value }
}

if ($system -eq 'PRD') {
  return @{ ok = $false; error = @{ code = 'PRD_FORBIDDEN'; message = 'PRD 生产机已禁用，仅支持 QAS / DVP。' } }
}
if ($functions.Count -eq 0) {
  return @{ ok = $false; error = @{ code = 'NEED_FUNCTIONS'; message = '请至少填写一个 SAP 函数名。' } }
}

# ---- 产物缓存(2026-09-20 钉钉值守全自动配套)----
# docx 文件名稳定不含时间戳(2026-09-04 定案,重名覆盖最新为准)→ 同函数 TTL 内直接回旧文档,
# 跳过 SAP RFC + AI + docx 三段(实测生成全程数十秒/次,高频索取场景开销省 100%)。
# 调用方传 cacheTtlDays>0 启用;forceRefresh=true 强制重生成(「重新生成」语义)。
# PW 人工路径不传 cacheTtlDays(=0)→ 行为不变,每次实读最新。
# 位置在密码校验【之前】:命中缓存连凭证都不需要——凭证过期的日子里同事仍可拿到
# TTL 内的旧文档(降级可用),而不是整个值守停摆。
$cacheTtlDays = 0
if ($bodyInput.cacheTtlDays) { $cacheTtlDays = [double]$bodyInput.cacheTtlDays }
$forceRefresh = ($bodyInput.forceRefresh -and ($bodyInput.forceRefresh -in @('1', 'true', $true)))
if (-not $forceRefresh -and $cacheTtlDays -gt 0) {
  $cNames = @($functions | ForEach-Object { $_.Trim().ToUpper() })
  $cBase  = if ($cNames.Count -eq 1) { $cNames[0] } else { $cNames -join '-' }
  $cDir   = if ($env:SAP_ARTIFACT_DOCS) { Join-Path $env:SAP_ARTIFACT_DOCS 'interface-doc' } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'artifacts\interface-doc' }
  $cPath  = Join-Path $cDir ($cBase + '.docx')
  if (Test-Path -LiteralPath $cPath -PathType Leaf) {
    $cItem = Get-Item -LiteralPath $cPath
    $ageDays = ((Get-Date) - $cItem.LastWriteTime).TotalDays
    if ($ageDays -le $cacheTtlDays) {
      return @{ ok = $true; result = [ordered]@{
        markdown    = $null
        docxBase64  = $null
        docxPath    = $cPath
        basename    = $cBase
        summary     = "命中 $($cacheTtlDays.ToString('0')) 天内缓存(生成于 $($cItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))),未重新生成;要最新版请说「重新生成」。"
        cached      = $true
        generatedAt = $cItem.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        structures  = @()
        enums       = @()
        tokens      = $null
        factsJson   = $null
      } }
    }
  }
}

if (-not $password) {
  # 凭证合一(2026-11-04,对齐 sap-test-report 同款):密码留空→回落连接管理槽
  # (sap-tool 连接成功即入槽,12h TTL)。槽内密码连接时已实际登录验证过。
  # 背景:sap-flow(CC 侧)直调本路由不带密码,无回落=NEED_PASSWORD 断链。
  . (Join-Path $PSScriptRoot '_sap-conn.ps1')
  $slot = Get-SapSessionCred -System ([string]$bodyInput.system).Trim().ToUpper()
  if ($slot -and $slot.Password) { $password = [string]$slot.Password }
}
if (-not $password) {
  # 三级回落(2026-11-04 凭证合一补完):表单密码 → bridge 槽 → facade 凭证。
  # 第三级解决「bridge 重启清槽但 facade 凭证还活着」的断链(facade 是独立进程,凭证在其
  # 内存;红线「密码不落盘/不导出」,bridge 拿不到原文,但可以让【facade 自己】干活)——
  # DDIC 采集改走 facade 工具链(sap_fm_read/sap_object_meta/sap_query,白名单内只读),
  # 拼出与 NCo 直连完全相同的数据形状,后续 AI/docx 零改动。facade 也没有才真 NEED_PASSWORD。
  . (Join-Path $PSScriptRoot '_sap-facade.ps1')
  . (Join-Path $PSScriptRoot '_sap-lib.ps1')
  $facadeUp = $null
  try { $facadeUp = Ensure-SapFacade } catch {}
  if ($facadeUp -and $facadeUp.running) {
    # facade 该系统是否有活凭证:sap_env_status 的 health.credCached(不回显任何值,只报系统名)
    $hh = Invoke-SapFacadeApi -Method GET -Path '/health' -TimeoutSec 5
    $credSys = @()
    if ($hh.ok -and $hh.data.credCached) { $credSys = @($hh.data.credCached | ForEach-Object { [string]$_ }) }
    if ($credSys -contains $system) {
      $viaFacade = $true   # 走 facade 采集(下方主循环分支);不再需要直连登录预检
    }
  }
  if (-not $viaFacade) {
    return @{ ok = $false; error = @{ code = 'NEED_PASSWORD'; message = "未填密码,且「$system」没有可用凭证——bridge 内存槽为空(bridge 重启会清),facade 也没连着该系统。请到「SAP Driver → 连接管理」连接一次(自动喂文档链),或本次填写密码。" } }
  }
}

# QAS / DVP 连接参数:单点收进 _sap-conn(2026-08-31 对抗审查:此处 DVP 曾停在 Client 800,
# 与 _sap-conn 默认 client 漂移;密码仅内存,见红线)
# 2026-09-04:_sap-conn 默认用户为空(开源版不内置个人账号)→ 调用方必须显式
# 传 -User,否则空用户登录必败(user= 空曾致当日全部接口文档/测试报告登录失败)
. (Join-Path $PSScriptRoot '_sap-conn.ps1')
if (-not $viaFacade) {
  # 直连形态(表单密码或槽密码):NCo 登录预检 + Invoke-SapRfc 采集
  . (Join-Path $PSScriptRoot '_sap-rfclogin.ps1')   # Test-SapRfcLogin(本机部署专用,2026-09-21 V7 拆出)
  # 登录预检(2026-09-04 用户要求:登录失败直接报错,不生成文档);引导链切 Test-SapRfcLogin(2026-09-21 审查收拢)。
  # 预检通过后,单个函数读不到才按"未部署"记函数级错误注记,不影响其他函数。
  $login = Test-SapRfcLogin -System $system -Password $password -Language $language -Client $client -PingTag 'pw-ping'
  if (-not $login.ok) {
      if ($login.code -eq 'SAP_LOGIN_FAILED') {
          return @{ ok = $false; error = @{ code = $login.code
              message = "SAP 登录/连接失败:$($login.message) —— 已停止,未生成任何文档。请核对密码/账号锁/网络后重试。" } }
      }
      return @{ ok = $false; error = @{ code = $login.code; message = $login.message } }
  }
  $conn = $login.conn
}

# ---- 判断类型名是否为 DDIC 结构/表类型(需读字段目录)，排除内置数据类型 ----
$script:builtinTypes = @('CHAR','NUMC','DATS','TIMS','DATUM','INT1','INT2','INT4','INT8','DEC','FLTP','STRING','INTTYPE','FLAG','BOOLE_D','CHAR1','CHAR2','CHAR4','CHAR10','CHAR20','CHAR30','CHAR40','CHAR60','CHAR255','ANY','DATA','STANDARD','TABLE')

$fmResults = @()
$domToQuery = New-Object System.Collections.Generic.HashSet[string]
$script:_facadeEnums = @()   # facade 形态:sap_object_meta 顺带查回的 ZZ_* 枚举(结构级,去重后进全局 enums)

foreach ($fm in $functions) {
  $fm = $fm.Trim().ToUpper()
  # 循环变量逐轮复位(2026-10-14 审查 P1):$r/$rp 不清则后位函数 FII/RPY 失败时继承前位函数
  # 的签名/源码 → 接口文档按错函数铺字段表、AI 照错源码写逻辑(外部交付物);$dfies 同款意识(下方有 $null)
  $r = $null; $rp = $null; $fiiErr = $null
  $fmInfo = @{ name = $fm; sections = @{ IMPORTING = @(); EXPORTING = @(); CHANGING = @(); TABLES = @() }; structures = @(); error = $null }

  if ($viaFacade) {
    # ---- facade 形态(2026-11-04 三级回落第三级):sap_fm_read 一把拿 签名+PTEXT+源码 ----
    # 返回 interface.{importing/exporting/changing/tables}(name/type/default/text)——
    # 拼回 FII 形状(TYP/DBSTRUCT 双字段都填,下方消费段零改动);CHANGING/TABLES 的 type
    # 在 sap_fm_read 里取自 TYP 字段,但 FII 对 CHANGING/TABLES 是 DBSTRUCT——sap_fm_read
    # 的 sect(typeField) 对这两段传的也是 TYP,与 FII 行为一致(值即结构名)。
    $fr = Invoke-FacadeTool -Tool 'sap_fm_read' -Args @{ system = $system; function = $fm; includeSource = $true; language = $language }
    if (-not $fr.ok) {
      $fmInfo.error = "facade 读接口失败:$($fr.error.message)"
      $fmResults += $fmInfo
      continue
    }
    $d = $fr.data
    $ifn = $d['interface']
    if ($null -eq $ifn) {
      $fmInfo.error = "facade 返回缺 interface 节(内部形状漂移?)"
      $fmResults += $fmInfo
      continue
    }
    # ★嵌套层是 PSCustomObject(ConvertTo-FlatHashtable 浅拍平,diag 路由同款实坑:['k'] 索引
    #   静默 null)——统一走顶部 Get-FacadeProp 取值。
    $r = @{ IMPORT_PARAMETER = @(); EXPORT_PARAMETER = @(); CHANGING_PARAMETER = @(); TABLES_PARAMETER = @() }
    foreach ($pair in @(@('importing','IMPORT_PARAMETER'), @('exporting','EXPORT_PARAMETER'), @('changing','CHANGING_PARAMETER'), @('tables','TABLES_PARAMETER'))) {
      $arr = @(Get-FacadeProp $ifn $pair[0])
      foreach ($p in $arr) {
        $pn = [string](Get-FacadeProp $p 'name'); if (-not $pn) { continue }
        $t = [string](Get-FacadeProp $p 'type')
        $dv = [string](Get-FacadeProp $p 'default')
        $tx = [string](Get-FacadeProp $p 'text')
        $r[$pair[1]] += @{ PARAMETER = $pn; TYP = $t; DBSTRUCT = $t; DEFAULT = $dv; FACADE_TEXT = $tx }
      }
    }
    $fmInfo.metaSource = 'facade'
    # 源码(sap_fm_read 已做 RPY→include 绕行,比 NCo 版覆盖更广)
    $srcF = [string]$d['source']
    if ($srcF) {
      $srcLines = @($srcF -split "`n")
      if ($srcLines.Count -gt 400) {
        $srcF = (($srcLines | Select-Object -First 400) -join "`n") + "`n*... (truncated, total $($srcLines.Count) lines)*"
      }
      $fmInfo.source = $srcF
    }
    # 调用方手工喂源码兜底(与直连形态同语义)
    if (-not ($fmInfo.source) -and $sources.ContainsKey($fm)) {
      $fmInfo.source = [string]$sources[$fm]
    }
  } else {
    # ---- 直连形态(NCo):FUNCTION_IMPORT_INTERFACE 拿接口签名 + 引用的 DDIC 结构名 ----
  # 1) FUNCTION_IMPORT_INTERFACE 拿接口签名 + 引用的 DDIC 结构名
  #    TABLES/CHANGING 参数 → DBSTRUCT 字段；IMPORT/EXPORT → TYP 字段(可能 Z 结构或内置如 SY-DATUM)
  try {
    $r = Invoke-SapRfc -Function FUNCTION_IMPORT_INTERFACE -Import @{ FUNCNAME = $fm } @conn -Password $password
  } catch {
    $fiiErr = $_.Exception.Message
  }
  if (-not $r) {
    # RPY 元数据兜底(2026-09-04:FII 对个别函数会拒,RPY 直读函数库元数据多数能过)。
    # 用 RPY 参数表拼 FII 形状的伪接口,后续处理零改动;参数类型字段名做 TYP/STRUCTURE/DBSTRUCT
    # 三重防御(不同表结构字段名不一)。RPY 仍拿不到才认失败,交给"全函数不可读"硬报错。
    try {
      $rp0 = Invoke-SapRfc -Function RPY_FUNCTIONMODULE_READ -Import @{ FUNCTIONNAME = $fm } @conn -Password $password
      $fake = @{ IMPORT_PARAMETER = @(); EXPORT_PARAMETER = @(); CHANGING_PARAMETER = @(); TABLES_PARAMETER = @() }
      foreach ($tbl in @('IMPORT_PARAMETER', 'EXPORT_PARAMETER', 'CHANGING_PARAMETER', 'TABLES_PARAMETER')) {
        foreach ($p in @($rp0.$tbl)) {
          if (-not $p.PARAMETER) { continue }
          $t = [string]$p.TYP; if (-not $t) { $t = [string]$p.STRUCTURE }; if (-not $t) { $t = [string]$p.DBSTRUCT }
          $fake[$tbl] += @{ PARAMETER = [string]$p.PARAMETER; TYP = $t; DBSTRUCT = $t; DEFAULT = [string]$p.DEFAULT }
        }
      }
      $cnt = 0; foreach ($k in @($fake.Keys)) { $cnt += @($fake[$k]).Count }
      if ($cnt -eq 0) { throw 'RPY 未返回任何参数(函数库元数据为空)' }
      $r = $fake
      $fmInfo.metaSource = 'rpy-fallback'
    } catch {
      $fmInfo.error = "FUNCTION_IMPORT_INTERFACE 失败：$fiiErr；RPY 元数据兜底也不可用：$($_.Exception.Message)（函数可能未部署到 $system，或当前账号无权限读取）"
      $fmResults += $fmInfo
      continue
    }
  }
  }   # end else(直连签名获取;自此以下 PTEXT/structNames/结构读取两形态共用)


  # 可选：RPY 补参数描述文本 PTEXT + 源码 SOURCE(对部分 Z FM 抛 ERROR_MESSAGE，失败静默不影响)
  # 2026-11-04 facade 形态:PTEXT 已随 FACADE_TEXT 键铺好(下方统一回填 ptextMap),源码
  # sap_fm_read 已带回(含 RPY→include 绕行)——本段直连 RPY 调用($conn/$password 为 null 会炸)整段跳过。
  $ptextMap = @{}
  $fmSource = $null
  if ($viaFacade) {
    foreach ($tbl in @('IMPORT_PARAMETER','EXPORT_PARAMETER','CHANGING_PARAMETER','TABLES_PARAMETER')) {
      foreach ($p in @($r[$tbl])) {
        $tx = [string]$p['FACADE_TEXT']
        if ($tx) { $ptextMap[[string]$p['PARAMETER']] = $tx }
      }
    }
  } else {
    try {
      $rp = Invoke-SapRfc -Function RPY_FUNCTIONMODULE_READ -Import @{ FUNCTIONNAME = $fm } @conn -Password $password
      foreach ($tbl in 'IMPORT_PARAMETER','EXPORT_PARAMETER','CHANGING_PARAMETER','TABLES_PARAMETER') {
        foreach ($p in $rp.$tbl) { if ($p.PARAMETER) { $ptextMap[[string]$p.PARAMETER] = [string]$p.PTEXT } }
      }
      if ($rp.SOURCE -and @($rp.SOURCE).Count -gt 0) {
        $fmSource = (@($rp.SOURCE) | ForEach-Object { [string]$_.LINE }) -join "`n"
      }
    } catch {}
  }
  # RPY 拿不到源码 → 2026-11-04 P4 补 facade sap_fm_read 兜底(自带 RPY→ENLFDIR→include 扫描
  # 绕行,ZIF_PR_ITF 这类 RPY 抛 ERROR_MESSAGE 的函数能拿到);再不行用调用方手工喂的 sources。
  # 超长源码只留前 400 行(prompt 保护)。
  if (-not $fmSource -and -not $viaFacade) {
    try {
      . (Join-Path $PSScriptRoot '_sap-facade.ps1') -ErrorAction Stop
      . (Join-Path $PSScriptRoot '_sap-lib.ps1') -ErrorAction Stop
      $up = $null; try { $up = Ensure-SapFacade } catch {}
      if ($up -and $up.running) {
        $fr2 = Invoke-FacadeTool -Tool 'sap_fm_read' -Args @{ system = $system; function = $fm; includeSource = $true; language = $language } -TimeoutSec 60
        if ($fr2.ok) { $fmSource = [string]$fr2.data['source'] }
      }
    } catch {}
  }
  if (-not $fmSource -and $sources.ContainsKey($fm)) { $fmSource = [string]$sources[$fm] }
  if ($fmSource) {
    $srcLines = @($fmSource -split "`n")
    if ($srcLines.Count -gt 400) {
      $fmSource = (($srcLines | Select-Object -First 400) -join "`n") + "`n*... (truncated, total $($srcLines.Count) lines)*"
    }
    $fmInfo.source = $fmSource
  }

  $structNames = New-Object System.Collections.Generic.HashSet[string]
  foreach ($p in $r.IMPORT_PARAMETER) {
    $t = [string]$p.TYP
    $fmInfo.sections['IMPORTING'] += [ordered]@{ name = [string]$p.PARAMETER; typ = $t; default = [string]$p.DEFAULT; text = $ptextMap[[string]$p.PARAMETER] }
    if ($t -and $t -notlike 'SY-*' -and $script:builtinTypes -notcontains $t) { [void]$structNames.Add($t) }
  }
  foreach ($p in $r.EXPORT_PARAMETER) {
    $t = [string]$p.TYP
    $fmInfo.sections['EXPORTING'] += [ordered]@{ name = [string]$p.PARAMETER; typ = $t; text = $ptextMap[[string]$p.PARAMETER] }
    if ($t -and $t -notlike 'SY-*' -and $script:builtinTypes -notcontains $t) { [void]$structNames.Add($t) }
  }
  foreach ($p in $r.CHANGING_PARAMETER) {
    $t = [string]$p.DBSTRUCT
    $fmInfo.sections['CHANGING'] += [ordered]@{ name = [string]$p.PARAMETER; typ = $t; text = $ptextMap[[string]$p.PARAMETER] }
    if ($t) { [void]$structNames.Add($t) }
  }
  foreach ($p in $r.TABLES_PARAMETER) {
    $t = [string]$p.DBSTRUCT
    $fmInfo.sections['TABLES'] += [ordered]@{ name = [string]$p.PARAMETER; typ = $t; text = $ptextMap[[string]$p.PARAMETER] }
    if ($t) { [void]$structNames.Add($t) }
  }

  # 2) 读每个引用结构的字段目录(表类型 Z*_T_* 读失败自动转行类型 Z*_S_* 兜底)
  # 2026-11-04 facade 形态:改走 sap_object_meta(内部同一 DDIF_FIELDINFO_GET+T→S 兜底+ZZ 枚举,
  # 返回 fields 数组形状与 DFIES 映射一致);枚举顺带收集,直连形态照旧原路。
  foreach ($sn in $structNames) {
    $sn = $sn.ToUpper()
    if ($viaFacade) {
      $mr = Invoke-FacadeTool -Tool 'sap_object_meta' -Args @{ system = $system; object = $sn; includeEnums = $true; language = $language }
      if ($mr.ok) {
        $fields = @()
        foreach ($f in @(Get-FacadeProp $mr.data 'fields')) {
          $fields += [ordered]@{
            name = [string](Get-FacadeProp $f 'name'); rollname = [string](Get-FacadeProp $f 'rollname')
            datatype = [string](Get-FacadeProp $f 'datatype'); leng = [string](Get-FacadeProp $f 'leng')
            domname = [string](Get-FacadeProp $f 'domname'); text = [string](Get-FacadeProp $f 'text')
            convexit = [string](Get-FacadeProp $f 'convexit')
          }
          $dom = [string](Get-FacadeProp $f 'domname')
          if ($dom -like 'ZZ_*') { [void]$domToQuery.Add($dom) }
        }
        if ($fields.Count -gt 0) { $fmInfo.structures += [ordered]@{ name = $sn; fields = $fields } }
        else { $fmInfo.structures += [ordered]@{ name = $sn; scalar = $true } }
        # 该结构自带的 ZZ_* 枚举顺带进全局 enums(去重:facades 已查过,直连段不再重复查)
        $script:_facadeEnums += @(Get-FacadeProp $mr.data 'enums')
      } else {
        # META_EMPTY(内置类型/标量数据元素)→ scalar;其余错误同样 scalar 不炸文档
        $fmInfo.structures += [ordered]@{ name = $sn; scalar = $true }
      }
      continue
    }
    $dfies = $null
    $fallback = if ($sn -like 'Z*_T_*') { $sn -replace '_T_', '_S_' } else { $null }
    foreach ($tryName in @($sn, $fallback)) {
      if (-not $tryName) { continue }
      try {
        $sr = Invoke-SapRfc -Function DDIF_FIELDINFO_GET -Import @{ TABNAME = $tryName; LANGU = $language } @conn -Password $password
        if ($sr.DFIES_TAB -and @($sr.DFIES_TAB).Count -gt 0) { $dfies = $sr.DFIES_TAB; break }
      } catch {}
    }
    if ($dfies) {
      $fields = @()
      foreach ($f in $dfies) {
        $fields += [ordered]@{
          name = [string]$f.FIELDNAME; rollname = [string]$f.ROLLNAME
          datatype = [string]$f.DATATYPE; leng = [string]$f.LENG
          domname = [string]$f.DOMNAME; text = [string]$f.FIELDTEXT
          convexit = [string]$f.CONVEXIT
        }
        $dom = [string]$f.DOMNAME
        if ($dom -like 'ZZ_*') { [void]$domToQuery.Add($dom) }
      }
      $fmInfo.structures += [ordered]@{ name = $sn; fields = $fields }
    } else {
      # 读不到字段目录的多为标量数据元素(如 BAPI_MSG)而非真结构——不算异常,
      # 标 scalar 让 AI 以签名表的 TYP 为准,勿在文档里渲染成"结构读取失败"
      $fmInfo.structures += [ordered]@{ name = $sn; scalar = $true }
    }
  }
  $fmResults += $fmInfo
}

# 2.5) 所有函数都读不到接口 → 硬报错不出文档(与登录预检同一哲学:失败要显式,不产垃圾)
$readable = @($fmResults | Where-Object { -not $_.error })
if ($readable.Count -eq 0) {
    $detail = (@($fmResults | ForEach-Object { "$($_.name)：$($_.error)" }) -join '；')
    return @{ ok = $false; error = @{ code = 'SAP_FN_UNREADABLE'
        message = "所选函数在 $system 全部无法读取接口,未生成文档。$detail 常见原因:函数未部署到 $system、未勾选「远程启用模块(RFC)」(SE37 属性页),或当前账号无权限。" } }
}

# 3) 查 ZZ_* 域固定值(DD07T，语言 1=中文)
# facade 形态:枚举已在结构读取时由 sap_object_meta 顺带查好(_facadeEnums),按域去重合并;
# 直连形态照旧 RFC_READ_TABLE 直查。两形态都不会对同一域查两次。
$enums = @()
if ($viaFacade) {
  $seenDom = @{}
  foreach ($e in $script:_facadeEnums) {
    $dn = [string](Get-FacadeProp $e 'domain')
    if (-not $dn -or $seenDom.ContainsKey($dn)) { continue }
    $seenDom[$dn] = $true
    $vals = @()
    foreach ($v in @(Get-FacadeProp $e 'values')) {
      $vals += [ordered]@{ code = [string](Get-FacadeProp $v 'code'); text = [string](Get-FacadeProp $v 'text') }
    }
    $enums += [ordered]@{ domain = $dn; values = $vals }
  }
  # 域收集了但 sap_object_meta 没回枚举的(单结构失败等)→ 兜底用 sap_query 直查 DD07T
  foreach ($dom in @($domToQuery)) {
    if ($seenDom.ContainsKey($dom)) { continue }
    try {
      $qr = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'DD07T'; maxRows = 200;
               where = @(@{ field = 'DOMNAME'; op = '='; value = $dom }, @{ field = 'DDLANGUAGE'; op = '='; value = '1' }, @{ field = 'AS4LOCAL'; op = '='; value = 'A' });
               fields = @('DOMVALUE_L', 'DDTEXT') }
      if ($qr.ok) {
        $rows = @(Get-FacadeProp $qr.data 'rows')
        $vals = @()
        foreach ($row in $rows) {
          $vals += [ordered]@{ code = [string](Get-FacadeProp $row 'DOMVALUE_L'); text = [string](Get-FacadeProp $row 'DDTEXT') }
        }
        $enums += [ordered]@{ domain = $dom; values = $vals }
      } else {
        $enums += [ordered]@{ domain = $dom; error = $qr.error.message }
      }
    } catch {
      $enums += [ordered]@{ domain = $dom; error = $_.Exception.Message }
    }
  }
} else {
foreach ($dom in @($domToQuery)) {
  try {
    $er = Invoke-SapRfc -Function RFC_READ_TABLE -Import @{ QUERY_TABLE = 'DD07T'; DELIMITER = '|' } @conn -Password $password `
      -Tables @{ OPTIONS = @(@{TEXT = "DOMNAME = '$dom'"}, @{TEXT = "AND DDLANGUAGE = '1'"}, @{TEXT = "AND AS4LOCAL = 'A'"}); FIELDS = @(@{FIELDNAME = 'DOMVALUE_L'}, @{FIELDNAME = 'DDTEXT'}) }
    $vals = @()
    foreach ($row in $er.DATA) {
      $parts = [string]$row.WA -split '\|'
      $vals += [ordered]@{ code = $parts[0].Trim(); text = ($parts[1] -as [string]).Trim() }
    }
    $enums += [ordered]@{ domain = $dom; values = $vals }
  } catch {
    $enums += [ordered]@{ domain = $dom; error = $_.Exception.Message }
  }
}
}   # end else(直连枚举)

# 4) DDIC facts → JSON 喂 AI
# 2026-11-04 P4:机器直出字段表(≥30 字段的大结构)。AI 整篇生成在大字段表场景必丢字段
# (ZIF_PR_ITF 单实证:5 结构 101 字段,CC 手搓 12288 token 也只能靠机器铺表)。做法:
# 大结构的字段表由本路由按 DDIC 实读直接铺 Markdown 表嵌进 factsJson.machineTables(结构名→
# 表文本),AI prompt 改为「大结构字段表已生成,原样粘贴」;小结构仍由 AI 生成(保持业务含义
# 推断能力)。AI 输出后再走 4.5) 断言兜底。
$facts = [ordered]@{
  meta = [ordered]@{ system = $system; language = $language; generatedAt = (Get-Date -Format 'yyyy-MM-dd') }
  functions = $fmResults
  enums = $enums
  extraHint = $extraHint
}
$factsJson = $facts | ConvertTo-Json -Depth 12 -Compress

$machineTables = [ordered]@{}
$bigStructs = @()
foreach ($fm in $fmResults) {
  foreach ($s in $fm.structures) {
    if ($s.scalar) { continue }
    $flds = @($s.fields)
    if ($flds.Count -lt 30) { continue }
    $bigStructs += $s.name
    $lines = @()
    $lines += '| 序号 | 字段名 | 类型 | 长度 | 数据元素 | 转换例程 | 业务含义 |'
    $lines += '| --- | --- | --- | --- | --- | --- | --- |'
    $i = 0
    foreach ($f in $flds) {
      $i++
      $desc = [string]$f.text
      $lines += "| $i | $($f.name) | $($f.datatype) | $([int]$f.leng) | $($f.rollname) | $([string]$f.convexit) | $desc |"
    }
    $machineTables[[string]$s.name] = ($lines -join "`n")
  }
}
if ($machineTables.Count -gt 0) {
  $facts['machineTables'] = $machineTables
}

# 5) AI 生成接口文档(规则 prompt 固化本次逻辑)
# 2026-11-04 P4:大结构字段表已由机器直出(facts.machineTables),AI 改为「原样粘贴+补业务列」;
# versionedDoc 场景(中途接入/沿老格式出新版)时追加变更记录章节要求。
$machineRule = ''
if ($machineTables.Count -gt 0) {
  $machineRule = @"

【大结构字段表——机器已生成,你只粘贴+补列】
JSON 顶层 machineTables 键(结构名→完整 Markdown 表文本,表头:序号|字段名|类型|长度|数据元素|转换例程|业务含义)。对这些结构:
- **必须把 machineTables 里的表原样嵌入文档对应位置(逐行逐字,一字不改不删)**;业务含义列机器填的是 DDIC 英文/德文原文,你在粘贴后可对业务含义列逐行改写为中文业务描述(只改含义列文字,其余列冻结)
- 不再自己生成这些大结构的字段表(防丢行);小结构(<30 字段)照旧自己生成
- 转换例程列(如 ALPHA/MATN1/CUNIT/ISOLA)含义务必在字段表下方加一句说明:ALPHA=前导零补足,MATN1=物料号外码,CUNIT=计量单位内外码转换(内码≠前台显示码,对接方要按前台显示码传值),ISOLA=语言代码 ISO 转换
"@
}
$versionRule = ''
if ($versionedDoc) {
  $chgList = ($versionedDoc.changes -join "`n")
  $versionRule = @"

【版本化文档(本次为 $versionedDoc 版)——中途接入/改造已落库场景】
- 文档开头加「变更记录」章节(表格:版本|日期|变更内容|备注),每行对应下方变更点,日期用 meta.generatedAt
- 受变更影响的字段/参数,在字段表该行业务含义列末尾追加「※$($versionedDoc.version) 变更:…」一句话标注;正文相应章节也要有变更点说明
- 变更点(逐条如实,不得增删改语义):
$chgList
"@
}
$sysPrompt = @"
你是资深 SAP 接口文档工程师，专为外部系统对接方撰写**中文**接口文档。

【任务】根据下方 $system 系统实读的 DDIC 数据(JSON) + 函数 ABAP 源码(各 function 的 source 字段，若有)，生成一份完整、可直接交付外部开发的 Markdown 接口文档。

【文档必须包含的章节(按此结构)】
1. 标题 + 文档信息(版本/日期/面向外部对接方)；**文档全文禁止出现「适用系统」字样或任何 SAP 系统标识/环境来源信息(如 DVP/QAS/生产/开发机等)**——文档面向外部对接方，与已方系统环境无关
2. 阅读须知：日期格式 YYYYMMDD、NUMC 前导零、**空值约定(强制)**、语言、版本差异提醒(若某结构与设计稿/常见版本有出入需指出)
   - **空值约定(强制)**：字段值为空(NULL)时，JSON 中**不传该字段，或传空字符串 '' **；文档必须明确写出此规则供对接方遵守，**禁止传 null、"null"、"NULL"**(易致 SAP 侧类型不匹配或 ABAP Dump)
3. 每个函数一节：
   - 接口用途(1-2 句业务化描述)
   - 接口性质：读接口 / 写接口——源码含 MODIFY/INSERT/UPDATE/DELETE/COMMIT 或 BAPI_*_CREATE/CHANGE/ASSIGN/DELETE 即为写接口，须醒目说明其落地动作(建/改/删什么数据、写哪些日志表)及重复调用后果(幂等性)
   - 接口签名表(方向/参数名/类型/说明)
   - 入参说明(每个入参含义 + 是否可空 + 空值语义；源码里声明了但实际未读取的入参，标注「当前版本代码未使用」)
   - 出参字段表(字段名/类型/长度/数据元素/转换例程/业务含义/取数来源)——字段名、类型、长度、数据元素、转换例程**必须严格照 JSON 里 DDIC 实读值，不可臆造**
4. 业务处理/取数逻辑说明：**有源码时必须照源码真实逻辑写**——处理顺序、分支条件、读哪些表、调哪些 BAPI、提前返回点(RETURN/CHECK)、日志表写入、COMMIT/ROLLBACK 时机，不可臆造；无源码才基于字段来源推断(如看到 PA0001/HRP1001 A008/RH_READ_OBJECT 等要解释关系)
5. 公共枚举字典：把 JSON 里 enums 的 ZZ_* 域固定值列成表(代码|名称)；空值的域标注"开放式编码无固定值"
6. JSON 调用示例（第三方照着写代码用，**每个函数必出**）：
   - **请求 JSON**：该函数所有 IMPORT 入参组成的**扁平** JSON 对象（结构型入参展开其字段，基本类型直接给值）；**严禁套 IMPORT/EXPORT/TABLES 等外层 key**——直接就是 {"MATERIAL":"0000000000012345","PLANT":"1000","GET_ITEM_DETAILS":"X"}，**绝不要** {"IMPORT":{...}} 这种包裹；
   - **响应 JSON**：所有 EXPORT 出参 + TABLES 表组成的**扁平** JSON 对象（TABLES 参数直接作为根级数组字段，放 1-2 条示例元素；结构型出参展开字段）；同样**严禁套 EXPORT/TABLES 外层 key**；
   - **按源码分支给多组成对的请求+响应示例**(至少：成功路径 + 业务拒绝路径(如记录已存在/无可处理数据)，有则再加 BAPI 失败路径)；CODE/MESSAGE 响应值照源码拼接逻辑**原样**给出(含全角标点/感叹号/斜杠)，源码未给 CODE 赋值的分支如实给空字符串 ''，不可杜撰「成功」字样
   - 两段各自用一个 markdown json 代码块包裹（三反引号开头）；**字段名必须严格照 JSON 里 DDIC 实读值，不可改不可漏不可臆造**（第三方照此写代码）；值给合理示意：PERNR→"00000001"、日期(DATS/DATUM)→"20260723"、ENDDA→"99991231"、NUMC→按长度前导零补足、FLAG/BOOLE_D→"X"、枚举字段→enums 里合法 code、金额/数量→合理数值、其他字符型→贴合字段含义的示例值(如 ENAME→"张三"、电话→"13800000000")；**空值字段→示例 JSON 中省略该字段不写，或给空字符串 '' (遵守空值约定，绝不写 null/"null")**
7. 注意事项：NUMC 前导零、日期 99991231、空表语义、权限、枚举废弃值等

【SAP 字段命名规律(用于推断"业务含义")】
- PERNR/EMPNO→员工号；ENAME/EMPNAME→姓名；GESCH→性别；GBDAT→生日
- PLANS/POSID→职位代码；ORGEH/ORGID→组织/部门代码；STEXT→对象名称(职位名/组织名)
- WERKS→人事范围；PERSG→员工组；PERSK→员工类别；ANSVH→雇佣类型；STAT2→在职状态(3=在职)
- BEGDA→开始日期；ENDDA→结束日期(99991231=无截止)；MASSN→变动原因；ICTYP/ICNUM→证件类型/号
- ZZ_ 前缀→客户自定义字段；ZZGRP→分组；ZZSEQ→序列；ZZCAT1→类别一；ZZCAT2→类别二；ZZLVL→级别；ZZLOC→地点(示例,以实际 DD04T 描述为准)
- 后缀 _T/_MS/_WB→对应名称/描述文本

【SAP HR 常见取数来源(用于填"取数来源"列)】
- PA0001 组织分配 / PA0000 人事事件 / PA0002 个人信息 / PA0185 证件 / PA0105 通讯
- HRP1001 OM 关系：A003 职位→部门、A005 职位→上级、A008 职位→持有人
- HRP9502 职位自定义属性；RH_READ_OBJECT 取 OM 对象名称；T500P/T503T/T529A 文本表；DD07T 域固定值文本

【输出要求】
- 纯 Markdown，不要包裹在代码块里
- 字段表用 Markdown 表格，表头：序号|字段名|类型|长度|数据元素|转换例程|业务含义|取数来源（机器直出的大结构表以 machineTables 内嵌文本的表头为准）
- 中文撰写，专业、准确、对外可直接交付
- 若 JSON 里某结构有 error 字段，在文档中如实标注"该结构读取失败"
- 如用户提供 extraHint(业务背景)，融入用途描述
$machineRule$versionRule
"@

$userPrompt = @"
请根据以下 $system 实读 DDIC 数据生成接口文档（JSON 数据位于下方边界标记之间）：

----- DDIC_JSON_START -----
$factsJson
----- DDIC_JSON_END -----
"@

$aiText = ''
$aiTokens = $null
try {
  # 主通道选型(2026-11-04 第三修):**首选 DeepSeek 直连(-Provider deepseek),失败降 GLM**。
  # 理由:①敏感口径——DDIC 字段目录+ABAP 源码属内部数据,按 26-10-26 定案敏感数据走公司
  # 内网 DeepSeek;②稳定口径——GLM anthropic 端点间歇把 glm-4.6 服务端映射成 5.3-flash,
  # 5.3-flash 对 thinking:disabled 静默忽略 → 思考税打满 12288 → 正文空(11:56/13:12/13:26
  # 三次实爆,单轮空跑 150-200s,截断后再降 DeepSeek 全程 400s+ 前端必超时);DeepSeek 经
  # reasoning_effort=none 关思考(实测零思考税),单轮 ~150s 内稳出全文。
  $resp = Invoke-KbClaude -UserPrompt $userPrompt -SystemPrompt $sysPrompt -MaxTokens 12288 -Temperature 0.2 -TimeoutSec 300 -NoThinking -Provider deepseek
  $aiText = $resp.text
  # DeepSeek 失败/空正文(内网抖动等)→ 降 GLM(NoThinking 传递;若 GLM 恰被映射成 5.3-flash
  # 吞配额,由下方空正文显式报错兜底,不再连环重试——单轮慢通道×2 比错误信息更伤体验)
  if ((-not ([string]$aiText).Trim()) -or $resp.truncated) {
    $resp = Invoke-KbClaude -UserPrompt $userPrompt -SystemPrompt $sysPrompt -MaxTokens 12288 -Temperature 0.2 -TimeoutSec 300 -NoThinking
    $aiText = $resp.text
  }
  if (-not ([string]$aiText).Trim()) {
    return @{ ok = $false; error = @{ code = 'AI_GEN_EMPTY'
        message = "DDIC 数据已读取成功，但两条 AI 通道均返回空正文(DeepSeek 内网可达性/或 GLM 被服务端映射 5.3-flash 吞配额)。请稍后重试或到「AI 设置」检查通道。" } }
  }
  $aiTokens = [ordered]@{ input = $resp.inputTokens; output = $resp.outputTokens; model = $resp.model }
} catch {
  return @{ ok = $false; error = @{ code = 'AI_GEN_FAILED'; message = "DDIC 数据已读取成功，但 AI 生成文档失败：$($_.Exception.Message)" } }
}

# 5.1) 机器断言兜底(2026-11-04 P4,源自手搓链的验尸式验证):AI 出的文档必须覆盖
#      每个大结构(≥30 字段)的全部 DDIC 实读字段名——缺任一 = AI 丢行,视为失败。
#      此时机器表回填硬拼(而非整篇报废重来):把缺失字段行直接补进文档尾部该结构表后,
#      summary 里如实注记「N 字段机器回填」。手搓单实证:python-docx 生成器也漏过
#      BSMNG_SND/BAUGR,靠解包断言才抓到——机器生成同样需要断言,AI 更需要。
$assertDetail = @()
$mendedCount  = 0
if ($machineTables.Count -gt 0 -and ([string]$aiText).Trim()) {
  foreach ($fm in $fmResults) {
    foreach ($s in $fm.structures) {
      if ($s.scalar) { continue }
      $flds = @($s.fields)
      if ($flds.Count -lt 30) { continue }
      $missing = @()
      foreach ($f in $flds) {
        if (([string]$f.name) -and ($aiText -notmatch [regex]::Escape([string]$f.name))) { $missing += [string]$f.name }
      }
      if ($missing.Count -gt 0) {
        # 机器回填:缺失字段逐行拼成标准表行,附到文档尾(该结构名小节下)
        $mendLines = @("`n`n> ⚠ 结构 $($s.name) 有 $($missing.Count) 个字段 AI 未覆盖,机器按 DDIC 实读回填如下:")
        $mendLines += '| 序号 | 字段名 | 类型 | 长度 | 数据元素 | 转换例程 | 业务含义 |'
        $mendLines += '| --- | --- | --- | --- | --- | --- | --- |'
        $i = 0
        foreach ($mn in $missing) {
          $ff = $flds | Where-Object { [string]$_.name -eq $mn }
          if ($ff) {
            $i++
            $mendLines += "| $i | $($ff[0].name) | $($ff[0].datatype) | $([int]$ff[0].leng) | $($ff[0].rollname) | $([string]$ff[0].convexit) | $([string]$ff[0].text) |"
          }
        }
        $aiText = $aiText + ($mendLines -join "`n")
        $mendedCount += $missing.Count
        $assertDetail += "$($s.name): $($missing.Count) 字段回填($($missing -join ','))"
      }
    }
  }
}

# 5.5) md -> docx (复用 office-md-convert 的 OOXML 直写，避开 Word COM 死锁)
#      生成 .docx 到产物目录(env SAP_ARTIFACT_DOCS,缺省=仓库 data/artifacts/interface-doc)并读 bytes
#      转 base64 给前端直接下载；失败不阻断(前端回退下载 md)。
$docxBase64 = $null
$docxPath   = $null
# 文件名:单函数=函数名;多函数=函数名用 - 拼接
$basename = if ($fmResults.Count -eq 1) { [string]$fmResults[0].name } else { (($fmResults | ForEach-Object { [string]$_.name }) -join '-') }
$docDir = if ($env:SAP_ARTIFACT_DOCS) { Join-Path $env:SAP_ARTIFACT_DOCS 'interface-doc' } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'artifacts\interface-doc' }
if (-not (Test-Path $docDir)) { New-Item -ItemType Directory -Force -Path $docDir | Out-Null }
try {
  # 2026-08-31 整合:md→docx 组装收进 Convert-MdToDocxFile。
  # 2026-09-04 用户要求:文件名不带日期时间(如 ZUTIL_004.docx),去掉 -Unique,
  # 重名直接覆盖(最新为准;与 SAP 测试报告的固定名策略一致)
  $docxPath = Convert-MdToDocxFile -Md $aiText -Dir $docDir -BaseName $basename
  if (-not $Slim) { $docxBase64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($docxPath)) }
} catch {
  $docxPath = $null   # docx 失败：前端回退下载 md
}

# 6) 汇总结构信息(给前端预览用)
$structSummary = @()
foreach ($fm in $fmResults) {
  foreach ($s in $fm.structures) {
    $structSummary += [ordered]@{ function = $fm.name; structure = $s.name; fieldCount = (@($s.fields).Count); error = $s.error }
  }
}

$fnList = ($fmResults | ForEach-Object { $_.name }) -join ', '

# 大结构机器直出+断言回填的事实必须进 summary(交付数字不虚报——断言兜底后仍要如实告知
# AI 丢了多少行,复核重点就是回填段)
$machineNote = ''
if ($machineTables.Count -gt 0) {
  $machineNote = "；大结构机器直出 $($machineTables.Count) 张表($($bigStructs -join ','))"
  if ($mendedCount -gt 0) {
    $machineNote += "，断言回填 $mendedCount 个 AI 丢失字段($($assertDetail -join '；'))"
  } else {
    $machineNote += '，字段覆盖断言全过(0 丢失)'
  }
}
if ($versionedDoc) { $machineNote += "；版本化文档($($versionedDoc.version),$( $versionedDoc.changes.Count ) 个变更点)" }

return @{
  ok = $true
  result = [ordered]@{
    markdown    = $aiText
    docxBase64  = $docxBase64   # 前端下载 .docx 用(失败为 $null，回退下载 md)
    docxPath    = $docxPath     # 配置的下载目录落盘路径
    basename    = $basename
    summary     = "已生成 $($fmResults.Count) 个函数($fnList)的接口文档；读取 $($structSummary.Count) 个结构、$($enums.Count) 个枚举域$machineNote"
    structures  = $structSummary
    enums       = $enums
    tokens      = $aiTokens
    machineTables = $(if (-not $Slim) { $machineTables } else { $null })  # 调试:机器直出的字段表原文
    factsJson   = $(if (-not $Slim) { $factsJson } else { $null })   # 调试用：原始 DDIC 数据(Slim 模式不返回)
  }
}
