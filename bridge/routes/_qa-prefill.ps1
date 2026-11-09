# _qa-prefill.ps1 — 建议动作表单确定性预填(2026-09-02)
# 会话/问题原文里能可靠提取的表单值不靠 LLM:函数名=正则扫原文,人名=提问人称呼。
# 与 LLM 的 extracted 合并:确定性值优先;functions 这类多值字段取并集(确定性在前)。
# 调用方:jobs\_qa-from-chat-worker.ps1(动作校验段)、routes\qa-answer.ps1(单题 suggest-action)。
# 纯函数文件,无 bridge 依赖,可被测试直接 dot-source。

# 提取 SAP 函数名(Z*/Y* 大写段 + BAPI_*,区分大小写防误吞英文单词;编译 + 200ms 超时防 ReDoS)
# 边界必须用 ASCII 前后断言而非 \b(2026-09-20 实爆,与 09-18 fastMatch 同坑第二处):
# .NET 里中文属 \w,「把ZUTIL_004接口文档给我」函数名贴中文时 \b 判不出边界 → 必漏;
# (?<![A-Za-z0-9_]) / (?![A-Za-z0-9_]) 只排除 ASCII 词字符,CJK 相邻照常命中。
function Get-QaFmNames {
  param([string[]]$Texts = @())
  $pats = @(
    [System.Text.RegularExpressions.Regex]::new('(?<![A-Za-z0-9_])[ZY][A-Z][A-Z0-9_]{3,}(?![A-Za-z0-9_])', [System.Text.RegularExpressions.RegexOptions]::Compiled, [TimeSpan]::FromMilliseconds(200)),
    [System.Text.RegularExpressions.Regex]::new('(?<![A-Za-z0-9_])BAPI_[A-Z0-9_]{4,}(?![A-Za-z0-9_])', [System.Text.RegularExpressions.RegexOptions]::Compiled, [TimeSpan]::FromMilliseconds(200)),
    # 通用标准命名空间名(2026-09-21 长名函数实爆放开,用户定案「标准的也是需要解读的」):
    # 全大写+至少一个下划线——超长自定义名命中;SE37/EKKO/纯数字单号不命中(无下划线/非大写开头)。
    [System.Text.RegularExpressions.Regex]::new('(?<![A-Za-z0-9_])[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+(?![A-Za-z0-9_])', [System.Text.RegularExpressions.RegexOptions]::Compiled, [TimeSpan]::FromMilliseconds(200))
  )
  $minLen = @(5, 5, 6)   # 各模式最小长度:ZY=5(Z+字母+3);BAPI 模式自带≥5;通用 6 压噪音
  $seen = @{}
  $out = @()
  foreach ($t in $Texts) {
    if (-not $t) { continue }
    for ($pi = 0; $pi -lt $pats.Count; $pi++) {
      $rx = $pats[$pi]
      try { $ms = $rx.Matches([string]$t) } catch { continue }
      foreach ($m in $ms) {
        $n = $m.Value.TrimEnd('_')
        if (-not $n) { continue }
        if ($n.Length -lt $minLen[$pi]) { continue }
        $k = $n.ToUpperInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out += $n
      }
    }
  }
  return $out
}

# 确定性预填 + LLM extracted 合并,返回 ordered hashtable(键=formSchema key)。
# 直接赋值接($ex = Get-ActionPrefill ...),调用方不要用 @() 包(约定见 _qa-intents.ps1)。
function Get-ActionPrefill {
  param(
    [Parameter(Mandatory=$true)][string]$ActionId,
    [string[]]$Texts = @(),
    [string]$Asker = '',
    $LlmExtracted = $null
  )
  $pref = [ordered]@{}
  switch ($ActionId) {
    'interface-doc' {
      $names = @(Get-QaFmNames -Texts $Texts)
      if ($names.Count -gt 0) { $pref['functions'] = ($names -join ',') }
    }
    'mood-distribute' {
      $n = ([string]$Asker).Trim()
      if ($n) { $pref['name'] = $n }
    }
    'interface-diag' {
      $names = @(Get-QaFmNames -Texts $Texts)
      if ($names.Count -gt 0) { $pref['function'] = $names[0] }
      # 报文块提取(09-18 重写,旧版整段带入=闲聊塞满表单):扫「连续报文形态行」取最长块。
      # 形态=JSON 行({ } "key": )或 KV 行(键[:：=]值);全大写键单行即可立块,
      # 块内宽松续行;纯闲聊行断块。找不到块=payloadText 留空(宁缺毋假,表单里手动贴)。
      foreach ($t in $Texts) {
        $s = ([string]$t).Trim()
        if (-not $s) { continue }
        $lines = @($s -split "`r?`n")
        $best = @(); $cur = @()
        foreach ($l in $lines) {
          $lt = $l.Trim()
          $isP = $false
          if ($lt) {
            if ($lt -match '^["{}\[\]]' -or $lt -match '^"[A-Za-z0-9_\-]+"\s*:') { $isP = $true }
            elseif ($lt -match '^([A-Za-z][A-Za-z0-9_\-\.]{0,30})\s*[:：=]\s*(\S.*)$') {
              $key = $Matches[1]
              if ($key -cmatch '^[A-Z][A-Z0-9_\-\.]*$') { $isP = $true }
              elseif ($cur.Count -gt 0) { $isP = $true }   # 块内宽松续行(小写键/混合键)
            }
          }
          if ($isP) { $cur = @($cur + $lt) } else {
            if ($cur.Count -gt $best.Count) { $best = $cur }
            $cur = @()
          }
        }
        if ($cur.Count -gt $best.Count) { $best = $cur }
        if ($best.Count -ge 2) { $pref['payloadText'] = ($best -join "`n"); break }
        if ($best.Count -eq 1 -and ($best[0] -cmatch '^[A-Z][A-Z0-9_\-\.]{1,30}\s*[:：=]' -or $best[0].StartsWith('{'))) { $pref['payloadText'] = $best[0]; break }
      }
    }
  }
  # LLM extracted:多值字段取并集(确定性在前、去重),其余确定性未覆盖的键透传
  $arrKeys = @('functions')
  if ($LlmExtracted) {
    $props = @()
    if ($LlmExtracted -is [System.Collections.IDictionary]) { $props = @($LlmExtracted.Keys) }
    else { $props = @($LlmExtracted.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($k in $props) {
      if (-not $k) { continue }
      $v = $null
      if ($LlmExtracted -is [System.Collections.IDictionary]) { $v = $LlmExtracted[$k] }
      else { $p = $LlmExtracted.PSObject.Properties[$k]; if (-not $p) { continue }; $v = $p.Value }
      $v = ([string]$v).Trim()
      if (-not $v) { continue }
      if (($arrKeys -contains $k) -and $pref.Contains($k)) {
        $have = @{}
        foreach ($x in ($pref[$k] -split '[,，、;；\s]+')) { if ($x) { $have[$x.ToUpperInvariant()] = $true } }
        $add = @()
        foreach ($x in ($v -split '[,，、;；\s]+')) {
          if ($x -and -not $have.ContainsKey($x.ToUpperInvariant())) { $have[$x.ToUpperInvariant()] = $true; $add += $x }
        }
        if ($add.Count -gt 0) { $pref[$k] = [string]$pref[$k] + ',' + ($add -join ',') }
      } elseif (-not $pref.Contains($k)) {
        $pref[$k] = $v
      }
    }
  }
  return $pref
}
