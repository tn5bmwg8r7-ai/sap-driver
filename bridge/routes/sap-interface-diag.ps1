param([Parameter(Mandatory)][hashtable]$Body)

# sap-interface-diag  -  🔌 接口定位一键链(2026-09-17,计划 plans/zany-percolating-wilkes:智能问答↔SAP副驾衔接)
# 场景:对方贴接口报错+报文 → 读接口结构 + 解析报文 + 落 SE37 变式 + 回读逐字段比对,一键出排查报告。
# 链:①sap_fm_read(签名+源码;RPY 读不到源码时工具侧已回退仅接口) ②sap_object_meta(报文涉及的结构体检,≤5 个)
#    ③报文解析(JSON 或 KV 行「KEY: value」;STRUCT-FIELD 嵌套进结构;表行需 JSON)
#    ④【确认闸】confirm=true 且显式变式号才写 sap_variant_write(仅 DVP/QAS)→ sap_variant_read 回读比对,不一致不交付
# 红线:计划原文「变式号自动取号」按工具实锤从紧——SE37 只认自建变式,直写新号=SE37 永远看不见的孤儿
#       数据(违反「不产生垃圾冗余数据」),故必须用户 SE37 建空变式后显式给号;写操作必经确认闸。
# 凭证:优先 facade 内存凭证;表单给 sapPassword 时先 sap_connect 注入(仅内存,不落盘/不进日志)。

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_sap-facade.ps1')
. (Join-Path $PSScriptRoot '_sap-lib.ps1')
. (Join-Path $PSScriptRoot '_sap-explain-lib.ps1')   # ConvertTo-ItemHashtable 单源(2026-09-21 审查收拢)

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }


# ============ 入参 ============
$input_ = $Body.input
if (-not $input_) { return (Fail 'BAD_INPUT' 'input required') }
$funcName = ([string]$input_.function).Trim().ToUpper()
if (-not $funcName) { return (Fail 'NEED_FUNCTION' '请填写函数名(如 ZIF_HR_001)') }
$system = ([string]$input_.system).Trim().ToUpper()
if (-not $system) { $system = 'QAS' }
if ($system -notin @('DVP', 'QAS', 'PRD')) { return (Fail 'BAD_SYSTEM' "system 必须是 DVP/QAS/PRD,收到: '$system'") }
$payloadText = [string]$input_.payloadText
$variant = ([string]$input_.variant).Trim()
$confirm = ($input_.confirm -eq $true) -or (([string]$input_.confirm).Trim().ToLower() -eq 'true')
$sapPassword = ([string]$input_.sapPassword).Trim()   # 表单粘贴尾随空格=登录失败惯犯(2026-11-04 补齐)

Initialize-SapRoute | Out-Null
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# ---- 可选凭证注入(facade 内存;失败不挡主链) ----
$credNote = ''
if ($sapPassword) {
  $c = Invoke-FacadeTool -Tool 'sap_connect' -Args @{ system = $system; password = $sapPassword }
  $credNote = $(if ($c.ok) { "已用表单密码连接 $system" } else { "密码连接失败($($c.error.message)),沿用已有凭证继续" })
}

# ---- ① 读接口(签名+源码) ----
$iface = $null; $srcText = ''; $srcErr = ''
$fm = Invoke-FacadeTool -Tool 'sap_fm_read' -Args @{ system = $system; function = $funcName; includeSource = $true }
if ($fm.ok) {
  $iface = $fm.data
  # facade 实际形状:result.{ok,system,function,isCustomerNamespace,interface:{importing,...},sourceError}——签名在 interface 子键、
  # source/sourceError 在外层(实测 09-18);ConvertTo-FlatHashtable 是浅拍平,嵌套层仍是 PSCustomObject(['k'] 索引静默 null),必须逐层再拍
  $srcText = [string]$iface['source']
  if (-not $srcText) { $srcErr = [string]$iface['sourceError'] }
  $ifn = $iface['interface']
  if ($null -ne $ifn) { $iface = ConvertTo-FlatHashtable $ifn }
} else {
  # 凭证闸原样透传(前端弹连接面板,判据=code 字面,不能包壳——v8/2026-09-14 实爆教训)
  if ($fm.error.code -eq 'NEED_CREDENTIAL') {
    return @{ ok = $false; error = @{ code = [string]$fm.error.code; message = [string]$fm.error.message } }
  }
  # 降级:TFDIR 确认函数存在 → 组主程序源码兜底(接口结构缺席,报告如实说明)
  try {
    $tfd = Invoke-FacadeTool -Tool 'sap_query' -Args @{ system = $system; table = 'TFDIR'; maxRows = 1; where = "FUNCNAME = '$funcName'" }
    if ($tfd.ok -and @($tfd.data.rows).Count -gt 0) {
      $tfdRow = ConvertTo-ItemHashtable @($tfd.data.rows)[0]
      $pname = ([string]$tfdRow['PNAME']).Trim()
      if ($pname) {
        $pr = Invoke-FacadeTool -Tool 'sap_prog_read' -Args @{ system = $system; program = $pname }
        if ($pr.ok) { $srcText = [string]$pr.data.source; $srcErr = "接口签名读取失败($($fm.error.code)),已降级读组主程序 $pname" }
      }
    }
  } catch {}
  if (-not $srcText -and -not $iface) {
    return (Fail 'IFACE_FAILED' "读接口失败: $($fm.error.message)")
  }
}

# 归一接口清单
$imports = @(); $tablesIf = @()
if ($iface) {
  $imports = @(foreach ($i in @($iface.importing)) { $h = ConvertTo-ItemHashtable $i; if ([string]$h['name']) { @{ name = [string]$h['name']; type = [string]$h['type']; text = [string]$h['text'] } } })
  $tablesIf = @(foreach ($i in @($iface.tables)) { $h = ConvertTo-ItemHashtable $i; if ([string]$h['name']) { @{ name = [string]$h['name']; type = [string]$h['type']; text = [string]$h['text'] } } })
}
if ($imports.Count -eq 0 -and $tablesIf.Count -eq 0) {
  return (Fail 'IFACE_EMPTY' "$funcName 无类型化入参/表参数,无需落变式。请确认函数名是否正确。")
}
$known = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($p in $imports) { [void]$known.Add($p.name.ToUpper()) }
foreach ($t in $tablesIf) { [void]$known.Add($t.name.ToUpper()) }

# ---- ② 报文解析(JSON 或 KV 行) ----
$parsed = @{}                                        # 参数名→ 标量string / hashtable结构 / object[](表)
$unknown = New-Object System.Collections.Generic.List[string]
$textMode = 'none'
$parseNote = ''
if ($payloadText.Trim()) {
  $t = $payloadText.Trim()
  if ($t.StartsWith('{')) {
    try {
      $jsonObj = $t | ConvertFrom-Json
      foreach ($p in $jsonObj.PSObject.Properties) {
        $v = $p.Value
        if ($v -is [System.Management.Automation.PSCustomObject]) {
          $h = @{}; foreach ($f in $v.PSObject.Properties) { $h[[string]$f.Name] = [string]$f.Value }
          $parsed[[string]$p.Name] = $h
        } else { $parsed[[string]$p.Name] = $v }
      }
      $textMode = 'json'
    } catch { return (Fail 'BAD_PAYLOAD' "报文 JSON 解析失败: $($_.Exception.Message)") }
  } else {
    $textMode = 'kv'
    foreach ($line in ($t -split "`r?`n")) {
      $lt = $line.Trim()
      if ($lt -eq '' -or $lt.StartsWith('#') -or $lt.StartsWith('//')) { continue }
      if ($lt -match '^([\w%\/\-\.]+)\s*[:：=]\s*(.*)$') {
        $k = $Matches[1].Trim().ToUpper(); $v = $Matches[2].Trim()
        $sep = $k.IndexOf('-'); if ($sep -lt 0) { $sep = $k.IndexOf('.') }
        if ($sep -gt 0) {
          $par = $k.Substring(0, $sep); $fld = $k.Substring($sep + 1)
          if (-not $parsed[$par] -or $parsed[$par] -isnot [System.Collections.IDictionary]) { $parsed[$par] = @{} }
          $parsed[$par][$fld] = $v                  # KV 行嵌套:STRUCT-FIELD 进结构(表行不支持,报告注明)
        } else { $parsed[$k] = $v }
      } else { $parseNote = "$(if ($parseNote) { $parseNote + ';' })无法解析行: $lt" }
    }
  }
  foreach ($k in $parsed.Keys) { if (-not $known.Contains([string]$k)) { $unknown.Add([string]$k) } }
}

# ---- ③ 结构体检(报文里有值的结构参数才查,≤5) ----
$metaNotes = @()   # PS5.1 实测 List[object] 在本链 @() 枚举抛 ArgumentException「参数类型不匹配」,用纯数组
$metaBudget = 5
foreach ($p in $imports) {
  if ($metaBudget -le 0) { break }
  $v = $parsed[$p.name]
  if ($v -is [System.Collections.IDictionary] -and $p.type) {
    $m = Invoke-FacadeTool -Tool 'sap_object_meta' -Args @{ system = $system; object = $p.type }
    $metaBudget--
    if ($m.ok) {
      $md = $m.data
      $flds = @()
      # object_meta 字段键=小写 name(实测 09-18;兼容大写 FIELDNAME 双读)
      foreach ($f in @($md.fields)) { $fh = ConvertTo-ItemHashtable $f; $fn = [string]$fh['name']; if (-not $fn) { $fn = [string]$fh['FIELDNAME'] }; if ($fn) { $flds += $fn } }
      $metaNotes = @($metaNotes + @{ param = $p.name; type = $p.type; fieldCount = $flds.Count; fields = @($flds | Select-Object -First 40) })
    } else {
      $metaNotes = @($metaNotes + @{ param = $p.name; type = $p.type; error = [string]$m.error.message })
    }
  }
}

# ---- 报告 markdown ----
function Format-ReportMd {
  param($System, $Func, $Iface, $TablesIf, $Imports, $SrcHas, $SrcLines, $SrcErr, $Mode, $UnknownList, $Metas, $WriteInfo, $CredNote, $ParseNote)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("## 🔌 接口排查报告 — $Func($System)")
  [void]$sb.AppendLine('')
  if ($CredNote) { [void]$sb.AppendLine("> $CredNote") }
  $impTxt = (@($Imports) | ForEach-Object { $tx = $_.name; if ($_.type) { $tx += "($($_.type))" }; $tx }) -join ', '
  $tabTxt = (@($TablesIf) | ForEach-Object { $tx = $_.name; if ($_.type) { $tx += "($($_.type))" }; $tx }) -join ', '
  [void]$sb.AppendLine("- **入参**: $(if ($impTxt) { $impTxt } else { '(无)' })")
  [void]$sb.AppendLine("- **表参数**: $(if ($tabTxt) { $tabTxt } else { '(无)' })")
  [void]$sb.AppendLine("- **源码**: $(if ($SrcHas) { "已读取($SrcLines 行)" } else { "未取到$(if ($SrcErr) { " — $SrcErr" })" })")
  if ($Mode -ne 'none') {
    [void]$sb.AppendLine("- **报文**: 已解析($Mode 形态,共 $(@($WriteInfo.ParsedKeys).Count) 个参数键)")
    if (@($UnknownList).Count -gt 0) { [void]$sb.AppendLine("- **⚠ 报文中接口没有的字段**(已忽略): $(@($UnknownList) -join ', ')") }
    if ($ParseNote) { [void]$sb.AppendLine("- **⚠ 解析备注**: $ParseNote") }
  } else {
    [void]$sb.AppendLine('- **报文**: 未提供(仅结构分析)')
  }
  foreach ($m in @($Metas)) {
    if ($m.error) { [void]$sb.AppendLine("- 结构 $($m.type)($($m.param))体检失败: $($m.error)") }
    else { [void]$sb.AppendLine("- 结构 **$($m.type)**($($m.param))共 $($m.fieldCount) 字段: $(@($m.fields) -join ', ')") }
  }
  if ($WriteInfo) {
    [void]$sb.AppendLine('')
    if ($WriteInfo.executed) {
      [void]$sb.AppendLine("### ✅ 变式 $($WriteInfo.variant) 已写入并回读验证")
      [void]$sb.AppendLine("- 写入参数: $(@($WriteInfo.writtenImports) -join ', ')$(if (@($WriteInfo.writtenTables).Count) { ';表: ' + (@($WriteInfo.writtenTables) -join ', ') })")
      if (@($WriteInfo.ignoredExtraKeys).Count -gt 0) { [void]$sb.AppendLine("- 忽略的额外键: $(@($WriteInfo.ignoredExtraKeys) -join ', ')") }
      [void]$sb.AppendLine("- 回读比对: **$($WriteInfo.compared) 项一致**$(if ($WriteInfo.normalizedCount) { "(其中 $($WriteInfo.normalizedCount) 项按数字等价归一:SE37 变式存显示值,NUMC/ALPHA 前导零被剥)" })$(if ($WriteInfo.tableRows) { ";表 $($WriteInfo.tableRows) 行" })")
      [void]$sb.AppendLine("- SE37 操作:对该函数 F8 → 菜单「测试变式」→ 选变式 **$($WriteInfo.variant)** → DEBUG/执行即可看到报文值")
    } else {
      [void]$sb.AppendLine('### 📋 预览模式(未写任何数据)')
      [void]$sb.AppendLine('落变式步骤:① SE37 打开该函数 → F8 进测试屏 → 菜单「测试变式」→「创建」命名并**保存空变式**(不填值);② 把变式号填进表单并勾选确认 → 重跑即写入+回读验证。')
    }
  }
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("> 生成于 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') · 个人工作台 · AI 生成仅供参考")
  return $sb.ToString()
}

# ---- ④⑤ 确认闸 → 写变式 + 回读比对 ----
$writeInfo = $null
if ($confirm) {
  if (-not $payloadText.Trim()) { return (Fail 'NEED_PAYLOAD' '确认写变式需要报文:请粘贴报文(JSON 或每行 KEY: VALUE)后再确认。') }
  if (-not $variant) { return (Fail 'NEED_VARIANT' '写变式需要变式号:请先在 SE37 打开该函数 → F8 → 测试变式 → 创建空变式(命名+保存,不填值),再把变式号填进表单确认。') }
  if ($system -notin @('DVP', 'QAS')) { return (Fail 'PRD_FORBIDDEN' '写变式仅限 DVP/QAS(PRD 只读红线)。') }
  $w = Invoke-FacadeTool -Tool 'sap_variant_write' -Args @{ system = $system; function = $funcName; variant = $variant; params = $parsed }
  if (-not $w.ok) { return (Fail 'WRITE_FAILED' "写变式失败: $($w.error.message)") }
  $wd = $w.data
  # 回读逐字段比对(sap_variant_read → params:导入参数名→值/表名→行数组)
  # ★比对语义两档(09-18 实爆:PERNR 写 00000001 回读=1):①CHAR 尾空格 TrimEnd;②两侧纯数字按数值
  #   等价(decimal 防长卡号精度丢)——SE37 变式存显示值,NUMC/ALPHA 前导零被显示层剥掉,功能等价;
  #   归一项计数进报告如实展示。日期等价不做(保持严格,写报文时按 YYYYMMDD 给)。
  function Test-ValEqual([string]$e, [string]$a) {
    $et = $e.TrimEnd(); $at = $a.TrimEnd()
    if ($et -eq $at) { return @{ eq = $true; norm = $false } }
    if ($et -match '^\d+$' -and $at -match '^\d+$' -and ([decimal]$et -eq [decimal]$at)) { return @{ eq = $true; norm = $true } }
    return @{ eq = $false; norm = $false }
  }
  $compared = 0; $tableRows = 0; $normCount = 0
  $mismatches = @()
  $rd = Invoke-FacadeTool -Tool 'sap_variant_read' -Args @{ system = $system; function = $funcName; variant = $variant }
  if ($rd.ok) {
    $rp = ConvertTo-ItemHashtable $rd.data
    $actual = ConvertTo-ItemHashtable $rp['params']
    foreach ($key in @($parsed.Keys)) {
      if (-not $known.Contains([string]$key)) { continue }
      $exp = $parsed[$key]; $act = $actual[[string]$key]
      if ($exp -is [System.Collections.IDictionary]) {
        $actH = ConvertTo-ItemHashtable $act
        foreach ($f in $exp.Keys) {
          $compared++
          $eq = Test-ValEqual ([string]$exp[$f]) ([string]$actH[[string]$f])
          if ($eq.norm) { $normCount++ }
          if (-not $eq.eq) { $mismatches = @($mismatches + "${key}-${f}: 期望'$($exp[$f])' 实际'$($actH[[string]$f])'") }
        }
      } elseif ($exp -is [System.Collections.IEnumerable] -and $exp -isnot [string]) {
        $rows = @($exp); $actRows = @($act)
        $tableRows = $rows.Count
        if ($actRows.Count -ne $rows.Count) { $mismatches = @($mismatches + "${key}: 期望 $($rows.Count) 行,实际 $($actRows.Count) 行") }
        for ($ri = 0; $ri -lt [Math]::Min($rows.Count, $actRows.Count); $ri++) {
          $er = ConvertTo-ItemHashtable $rows[$ri]; $ar = ConvertTo-ItemHashtable $actRows[$ri]
          foreach ($f in $er.Keys) {
            $compared++
            $eq = Test-ValEqual ([string]$er[$f]) ([string]$ar[[string]$f])
            if ($eq.norm) { $normCount++ }
            if (-not $eq.eq) { $mismatches = @($mismatches + "${key}[$ri]-${f}: 期望'$($er[$f])' 实际'$($ar[[string]$f])'") }
          }
        }
      } else {
        $compared++
        $eq = Test-ValEqual ([string]$exp) ([string]$act)
        if ($eq.norm) { $normCount++ }
        if (-not $eq.eq) { $mismatches = @($mismatches + "${key}: 期望'$exp' 实际'$act'") }
      }
    }
  } else {
    $mismatches = @($mismatches + "回读失败: $($rd.error.message)")
  }
  if ($mismatches.Count -gt 0) {
    return (Fail 'WRITE_VERIFY_FAILED' "变式 $variant 写入后回读不一致,不交付: $(@($mismatches) -join '; ')")
  }
  $writeInfo = @{
    executed = $true; variant = $variant; area = [string]$wd.area
    writtenImports = @($wd.written.imports); writtenTables = @($wd.written.tables)
    ignoredExtraKeys = @($wd.ignoredExtraKeys)
    compared = $compared; tableRows = $tableRows; normalizedCount = $normCount
    ParsedKeys = @($parsed.Keys)
  }
} else {
  $writeInfo = @{ executed = $false; ParsedKeys = @($parsed.Keys) }
}

# ---- ⑥ 报告 ----
$srcLines = 0; if ($srcText) { $srcLines = @($srcText -split "`n").Count }
$md = Format-ReportMd -System $system -Func $funcName -Imports $imports -TablesIf $tablesIf `
  -SrcHas:([bool]$srcText) -SrcLines $srcLines -SrcErr $srcErr -Mode $textMode `
  -UnknownList @($unknown) -Metas @($metaNotes) -WriteInfo $writeInfo -CredNote $credNote -ParseNote $parseNote

return @{
  ok = $true
  result = [ordered]@{
    system = $system; function = $funcName
    stage = $(if ($confirm) { 'write' } else { 'preview' })
    interface = [ordered]@{
      importing = @($imports); tables = @($tablesIf)
      importingCount = $imports.Count; tablesCount = $tablesIf.Count
    }
    source = [ordered]@{ has = [bool]$srcText; lines = $srcLines; error = $srcErr }
    payload = [ordered]@{ mode = $textMode; keys = @($parsed.Keys); unknown = @($unknown); note = $parseNote }
    meta = @($metaNotes)
    write = $writeInfo
    markdown = $md
    basename = "接口排查-$funcName"
    generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    durMs = $sw.ElapsedMilliseconds
  }
}
