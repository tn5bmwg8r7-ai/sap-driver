# ============================================================
# _ooxml-office.ps1 - WORD/EXCEL <-> MD 转换函数库(2026-09-01 由 office-md-convert.ps1 拆出)。
# 【无 param】—— 原 route 文件 param([hashtable]$Body=@{}) 被 dot-source 时会覆盖宿主路由的
# $Body,sap-interface-doc / sap-test-report 不得不用 $__routeBody 存取 hack(时刻炸弹:
# 谁改 route 的 param 签名两个 SAP 路由一起断)。函数全部收进来后,消费方直接点源本文件。
# 消费方:office-md-convert.ps1(薄路由,4 方向 dispatch)/ sap-interface-doc / sap-test-report。
# ============================================================
. (Join-Path $PSScriptRoot '_claude-helpers.ps1')

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_config-helpers.ps1')
$DownloadsDir = Get-BridgeConfigValue -Section 'office' -Key 'downloadsDir' -Default (Join-Path $env:TEMP 'pw-office')
if (-not (Test-Path $DownloadsDir)) {
  New-Item -ItemType Directory -Force -Path $DownloadsDir | Out-Null
}

# Load zip + io for OOXML
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------- shared helpers ----------

function Get-SafeBaseName {
  param([string]$Path)
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  if ([string]::IsNullOrEmpty($base)) { $base = 'converted' }
  $safe = $base -replace '[^\w\-.]+', '_'
  $safe = $safe.Trim('_-.')
  if ([string]::IsNullOrEmpty($safe)) { $safe = 'converted' }
  return $safe
}

function Sanitize-Cell {
  param([string]$s)
  if ($null -eq $s) { return '' }
  return ($s -replace '\r?\n', ' ' -replace '\|', '\|').Trim()
}

function Split-MdTableRow {
  param([string]$line)
  $l = $line.Trim()
  if ($l.StartsWith('|')) { $l = $l.Substring(1) }
  if ($l.EndsWith('|')) { $l = $l.Substring(0, $l.Length - 1) }
  return ($l -split '\|') | ForEach-Object { $_.Trim() }
}

function Convert-PlainTextToMd {
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $lines = $Text -split "`r?`n"
  $out = New-Object System.Text.StringBuilder
  $inList = $false
  foreach ($raw in $lines) {
    $line = $raw.TrimEnd()
    if ([string]::IsNullOrWhiteSpace($line)) {
      [void]$out.AppendLine('')
      $inList = $false
      continue
    }
    if ($line -match '^\d+[.)]\s+(.*)$') {
      [void]$out.AppendLine("1. $($matches[1])")
      $inList = $true
    } elseif ($line -match '^[-*]\s+(.*)$') {
      [void]$out.AppendLine("- $($matches[1])")
      $inList = $true
    } elseif ($line -match '^(第[一二三四五六七八九十百千]+[章节条]|[一二三四五六七八九十]+[、.])\s*(.*)$') {
      [void]$out.AppendLine("## $($matches[2])")
      $inList = $false
    } else {
      if (-not $inList) { [void]$out.AppendLine('') }
      [void]$out.AppendLine($line)
      $inList = $false
    }
  }
  return $out.ToString().Trim()
}

function Get-UniqueOutPath {
  param([string]$Dir, [string]$BaseName, [string]$Ext)
  $try = Join-Path $Dir "$BaseName$Ext"
  if (-not (Test-Path $try)) { return $try }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  return Join-Path $Dir "${BaseName}-${stamp}$Ext"
}

# ---------- OOXML: docx -> md ----------

function Read-DocxText {
  # Read word/document.xml from a .docx zip and return list of paragraph hashtables.
  # Each hashtable: @{ style="<styleId or $null>"; text="<concatenated runs>" }
  # Tables are returned as a paragraph with style='__TABLE__' and a 'rows' field (2D array).
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path $Path)) {
    throw "File not found: $Path"
  }

  $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $docEntry = $zip.GetEntry('word/document.xml')
    if (-not $docEntry) {
      throw 'word/document.xml not found in archive'
    }
    $stream = $docEntry.Open()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $xml = $reader.ReadToEnd()
    $reader.Dispose()
    $stream.Dispose()
  } finally {
    $zip.Dispose()
  }

  # Parse with XmlDocument, walk namespace-aware.
  $doc = New-Object System.Xml.XmlDocument
  $doc.LoadXml($xml)
  $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $ns.AddNamespace('w','http://schemas.openxmlformats.org/wordprocessingml/2006/main')

  $body = $doc.SelectSingleNode('//w:body', $ns)
  if (-not $body) { return @() }

  $paragraphs = New-Object System.Collections.Generic.List[hashtable]
  $useNamespace = $ns

  function Get-ParaStyle {
    param($pNode)
    $styleId = $null
    $pStyleNode = $pNode.SelectSingleNode('w:pPr/w:pStyle', $useNamespace)
    if ($pStyleNode) {
      $val = $pStyleNode.GetAttribute('val', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
      if ($val) { $styleId = $val }
    }
    return $styleId
  }

  function Get-ParaText {
    param($pNode)
    $sb = New-Object System.Text.StringBuilder
    foreach ($t in $pNode.SelectNodes('.//w:t', $useNamespace)) {
      [void]$sb.Append($t.InnerText)
    }
    foreach ($br in $pNode.SelectNodes('.//w:br', $useNamespace)) {
      [void]$sb.Append("`n")
    }
    foreach ($tab in $pNode.SelectNodes('.//w:tab', $useNamespace)) {
      [void]$sb.Append("`t")
    }
    return $sb.ToString()
  }

  function Get-TableCells {
    param($tblNode)
    $rows = New-Object System.Collections.Generic.List[array]
    foreach ($tr in $tblNode.SelectNodes('w:tr', $useNamespace)) {
      $cells = New-Object System.Collections.Generic.List[string]
      foreach ($tc in $tr.SelectNodes('w:tc', $useNamespace)) {
        $cellText = New-Object System.Text.StringBuilder
        foreach ($p in $tc.SelectNodes('w:p', $useNamespace)) {
          $t = Get-ParaText -pNode $p
          if ($cellText.Length -gt 0) { [void]$cellText.Append("`n") }
          [void]$cellText.Append($t)
        }
        $cells.Add((Sanitize-Cell -s $cellText.ToString()))
      }
      $rows.Add(($cells.ToArray())) | Out-Null
    }
    return $rows.ToArray()
  }

  foreach ($child in $body.ChildNodes) {
    if ($child.LocalName -eq 'p') {
      $paragraphs.Add(@{
        style = (Get-ParaStyle -pNode $child)
        text  = (Get-ParaText -pNode $child)
      }) | Out-Null
    } elseif ($child.LocalName -eq 'tbl') {
      $paragraphs.Add(@{
        style = '__TABLE__'
        rows  = (Get-TableCells -tblNode $child)
      }) | Out-Null
    }
  }

  return $paragraphs
}

function Convert-DocxParagraphsToMd {
  param([Parameter(Mandatory)][array]$Paragraphs)

  $sb = New-Object System.Text.StringBuilder
  $lastWasList = $false

  foreach ($p in $Paragraphs) {
    if ($p.style -eq '__TABLE__') {
      $rows = $p.rows
      if ($rows.Count -lt 1) { continue }
      $cols = $rows[0].Length
      if ($cols -lt 1) { continue }
      # header
      [void]$sb.AppendLine('')
      [void]$sb.Append('| ')
      [void]$sb.Append(($rows[0] -join ' | '))
      [void]$sb.AppendLine(' |')
      [void]$sb.Append('| ')
      [void]$sb.AppendLine(((@('---') * $cols) -join ' | ') + ' |')
      for ($r = 1; $r -lt $rows.Count; $r++) {
        # pad row to cols length
        $cells = @($rows[$r])
        while ($cells.Length -lt $cols) { $cells += '' }
        [void]$sb.Append('| ')
        [void]$sb.AppendLine(($cells -join ' | ') + ' |')
      }
      [void]$sb.AppendLine('')
      $lastWasList = $false
      continue
    }

    $text = $p.text
    if ([string]::IsNullOrWhiteSpace($text)) {
      [void]$sb.AppendLine('')
      $lastWasList = $false
      continue
    }

    $styleId = $p.style
    if ($styleId -and $styleId -match '^Heading(\d)$') {
      $level = [int]$matches[1]
      if ($level -lt 1) { $level = 1 }
      if ($level -gt 6) { $level = 6 }
      [void]$sb.AppendLine('')
      [void]$sb.AppendLine(('#' * $level) + ' ' + $text.Trim())
      $lastWasList = $false
    } elseif ($styleId -and ($styleId -match '^List' -or $styleId -eq 'ListParagraph')) {
      # crude: detect bullet vs numbered from style name
      if ($styleId -match 'Bullet') {
        [void]$sb.AppendLine('- ' + $text.Trim())
      } else {
        [void]$sb.AppendLine('1. ' + $text.Trim())
      }
      $lastWasList = $true
    } else {
      if (-not $lastWasList) { [void]$sb.AppendLine('') }
      [void]$sb.AppendLine($text.TrimEnd())
      $lastWasList = $false
    }
  }

  return $sb.ToString().Trim()
}

# ---------- OOXML: md -> docx ----------

function Escape-XmlText {
  param([string]$s)
  if ($null -eq $s) { return '' }
  return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;')
}

function Convert-MdInlineToRunsXml {
  # Parse **bold**, *italic*, `code` inline and return OOXML runs XML.
  # 2026-09-17: -Size(半磅)可选——表格单元格 9pt(18)等密集场景用,缺省不写 sz(跟随正文)
  param([string]$text, [double]$Size = 0)
  if ([string]::IsNullOrEmpty($text)) { return '<w:r><w:t xml:space="preserve"></w:t></w:r>' }
  $szXml = ''
  if ($Size -gt 0) { $szXml = "<w:sz w:val=`"$([int]$Size)`"/><w:szCs w:val=`"$([int]$Size)`"/>" }
  $pattern = '(\*\*[^*]+?\*\*|\*[^*]+?\*|`[^`]+?`)'
  $parts = [regex]::Split($text, $pattern)
  $sb = New-Object System.Text.StringBuilder
  foreach ($part in $parts) {
    if ([string]::IsNullOrEmpty($part)) { continue }
    if ($part -match '^\*\*(.+)\*\*$') {
      $t = Escape-XmlText $matches[1]
      [void]$sb.Append("<w:r><w:rPr><w:b/>$szXml</w:rPr><w:t xml:space=`"preserve`">$t</w:t></w:r>")
    } elseif ($part -match '^\*(.+)\*$') {
      $t = Escape-XmlText $matches[1]
      [void]$sb.Append("<w:r><w:rPr><w:i/>$szXml</w:rPr><w:t xml:space=`"preserve`">$t</w:t></w:r>")
    } elseif ($part -match '^`(.+)`$') {
      $t = Escape-XmlText $matches[1]
      [void]$sb.Append("<w:r><w:rPr><w:rFonts w:ascii=`"Consolas`" w:hAnsi=`"Consolas`"/><w:shd w:val=`"clear`" w:color=`"auto`" w:fill=`"F2F2F2`"/>$szXml</w:rPr><w:t xml:space=`"preserve`">$t</w:t></w:r>")
    } else {
      $t = Escape-XmlText $part
      $rpr = if ($szXml) { "<w:rPr>$szXml</w:rPr>" } else { '' }
      [void]$sb.Append("<w:r>$rpr<w:t xml:space=`"preserve`">$t</w:t></w:r>")
    }
  }
  return $sb.ToString()
}

function Convert-MdToDocumentXmlBody {
  # Convert md text to OOXML body XML (sequence of <w:p> and <w:tbl>).
  param([Parameter(Mandatory)][string]$Md)

  $lines = $Md -split "`r?`n"
  $sb = New-Object System.Text.StringBuilder
  $i = 0
  while ($i -lt $lines.Length) {
    $line = $lines[$i]
    if ([string]::IsNullOrWhiteSpace($line)) { $i++; continue }

    # fenced code block
    if ($line -match '^```') {
      $buf = @()
      $i++
      while ($i -lt $lines.Length -and $lines[$i] -notmatch '^```') {
        $buf += $lines[$i]; $i++
      }
      $i++
      foreach ($codeLine in $buf) {
        $t = Escape-XmlText $codeLine
        [void]$sb.AppendLine("<w:p><w:pPr><w:spacing w:after=`"0`" w:line=`"240`" w:lineRule=`"auto`"/><w:shd w:val=`"clear`" w:color=`"auto`" w:fill=`"F2F2F2`"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii=`"Consolas`" w:hAnsi=`"Consolas`"/><w:sz w:val=`"16`"/><w:szCs w:val=`"16`"/></w:rPr><w:t xml:space=`"preserve`">$t</w:t></w:r></w:p>")
      }
      continue
    }

    # heading
    if ($line -match '^(#{1,6})\s+(.*)$') {
      $level = $matches[1].Length
      $runsXml = Convert-MdInlineToRunsXml -text $matches[2]
      [void]$sb.AppendLine("<w:p><w:pPr><w:pStyle w:val=`"Heading$level`"/></w:pPr>$runsXml</w:p>")
      $i++; continue
    }

    # GFM table
    # 2026-09-09:分隔行单元格支持百分比列宽(如 |-16%|-26%|-30%|-8%|-20%|,总和不必=100 会归一化);
    # 不带 % 的表走等分(原行为,office-md-convert 互转等老消费者不受影响)
    if ($line -match '^\s*\|.*\|\s*$' -and $i + 1 -lt $lines.Length -and $lines[$i+1] -match '^\s*\|[\s:|%\-.\d]+\|\s*$') {
      $headers = @(Split-MdTableRow -line $line)
      $sepCells = @(Split-MdTableRow -line $lines[$i+1])
      $pcts = @()
      foreach ($sc in $sepCells) {
        $m = [regex]::Match($sc, '(\d+(?:\.\d+)?)\s*%')
        $pcts += $(if ($m.Success) { [double]$m.Groups[1].Value } else { 0.0 })
      }
      $i += 2
      $rows = @()
      while ($i -lt $lines.Length -and $lines[$i] -match '^\s*\|.*\|\s*$') {
        $rows += ,(Split-MdTableRow -line $lines[$i])
        $i++
      }
      $colCount = $headers.Length
      # column width: 2026-09-17 自适应修正——A4(11906)减 1440×2 页边距 = 9026 dxa 可用宽,
      # 原值 8800 且 tblW=auto 无 fixed layout → Word 自动重排按内容挤列,百分比计划失效,
      # 长文本列被挤到极窄(用户实爆「有的格太窄转行收缩厉害」)。现:用满可用宽+固定布局
      $totalDxa = 9026
      $sumPct = 0.0
      foreach ($p in $pcts) { $sumPct += $p }
      $colWs = New-Object System.Collections.Generic.List[int]
      if ($sumPct -gt 0 -and @($pcts).Count -eq $colCount) {
        foreach ($p in $pcts) {
          $w = if ($p -gt 0) { [int][Math]::Floor($totalDxa * $p / $sumPct) } else { 600 }
          if ($w -lt 450) { $w = 450 }
          $colWs.Add($w)
        }
      } else {
        $eqW = [Math]::Floor($totalDxa / [Math]::Max(1, $colCount))
        for ($c = 0; $c -lt $colCount; $c++) { $colWs.Add($eqW) }
      }
      $sumW = 0
      foreach ($w2 in $colWs) { $sumW += $w2 }
      [void]$sb.Append('<w:tbl>')
      [void]$sb.Append('<w:tblPr>')
      [void]$sb.Append("<w:tblW w:w=`"$sumW`" w:type=`"dxa`"/>")
      [void]$sb.Append('<w:tblLayout w:type="fixed"/>')
      [void]$sb.Append('<w:tblCellMar><w:left w:w="80" w:type="dxa"/><w:right w:w="80" w:type="dxa"/><w:top w:w="20" w:type="dxa"/><w:bottom w:w="20" w:type="dxa"/></w:tblCellMar>')
      [void]$sb.Append('<w:tblBorders>')
      [void]$sb.Append('<w:top w:val="single" w:sz="4" w:space="0" w:color="999999"/>')
      [void]$sb.Append('<w:left w:val="single" w:sz="4" w:space="0" w:color="999999"/>')
      [void]$sb.Append('<w:bottom w:val="single" w:sz="4" w:space="0" w:color="999999"/>')
      [void]$sb.Append('<w:right w:val="single" w:sz="4" w:space="0" w:color="999999"/>')
      [void]$sb.Append('<w:insideH w:val="single" w:sz="4" w:space="0" w:color="999999"/>')
      [void]$sb.Append('<w:insideV w:val="single" w:sz="4" w:space="0" w:color="999999"/>')
      [void]$sb.Append('</w:tblBorders>')
      [void]$sb.Append('</w:tblPr>')
      [void]$sb.Append('<w:tblGrid>')
      for ($c = 0; $c -lt $colCount; $c++) {
        [void]$sb.Append("<w:gridCol w:w=`"$($colWs[$c])`"/>")
      }
      [void]$sb.Append('</w:tblGrid>')
      # header row(9pt 紧凑:单元格段落 spacing after=0 line=240,表格密集可读)
      [void]$sb.Append('<w:tr>')
      [void]$sb.Append('<w:trPr><w:tblHeader/></w:trPr>')
      for ($c = 0; $c -lt $colCount; $c++) {
        $h = if ($c -lt $headers.Length) { $headers[$c] } else { '' }
        $runsXml = Convert-MdInlineToRunsXml -text $h -Size 18
        [void]$sb.Append("<w:tc><w:tcPr><w:tcW w:w=`"$($colWs[$c])`" w:type=`"dxa`"/><w:shd w:val=`"clear`" w:color=`"auto`" w:fill=`"EEEEEE`"/></w:tcPr><w:p><w:pPr><w:spacing w:after=`"0`" w:line=`"240`" w:lineRule=`"auto`"/><w:rPr><w:b/><w:sz w:val=`"18`"/><w:szCs w:val=`"18`"/></w:rPr></w:pPr>$runsXml</w:p></w:tc>")
      }
      [void]$sb.Append('</w:tr>')
      # data rows
      foreach ($r in $rows) {
        [void]$sb.Append('<w:tr>')
        for ($c = 0; $c -lt $colCount; $c++) {
          $cellVal = if ($c -lt $r.Length) { $r[$c] } else { '' }
          $runsXml = Convert-MdInlineToRunsXml -text $cellVal -Size 18
          [void]$sb.Append("<w:tc><w:tcPr><w:tcW w:w=`"$($colWs[$c])`" w:type=`"dxa`"/></w:tcPr><w:p><w:pPr><w:spacing w:after=`"0`" w:line=`"240`" w:lineRule=`"auto`"/><w:rPr><w:sz w:val=`"18`"/><w:szCs w:val=`"18`"/></w:rPr></w:pPr>$runsXml</w:p></w:tc>")
        }
        [void]$sb.Append('</w:tr>')
      }
      [void]$sb.AppendLine('</w:tbl>')
      continue
    }

    # unordered list
    if ($line -match '^\s*[-*+]\s+(.*)$') {
      while ($i -lt $lines.Length -and $lines[$i] -match '^\s*[-*+]\s+(.*)$') {
        $runsXml = Convert-MdInlineToRunsXml -text $matches[1]
        [void]$sb.AppendLine("<w:p><w:pPr><w:ind w:left=`"420`" w:hanging=`"240`"/></w:pPr><w:r><w:t xml:space=`"preserve`">• </w:t></w:r>$runsXml</w:p>")
        $i++
      }
      continue
    }

    # ordered list
    if ($line -match '^\s*\d+[.)]\s+(.*)$') {
      while ($i -lt $lines.Length -and $lines[$i] -match '^\s*(\d+)[.)]\s+(.*)$') {
        $marker = $matches[1] + '. '
        $runsXml = Convert-MdInlineToRunsXml -text $matches[2]
        $mEsc = Escape-XmlText $marker
        [void]$sb.AppendLine("<w:p><w:pPr><w:ind w:left=`"480`" w:hanging=`"300`"/></w:pPr><w:r><w:t xml:space=`"preserve`">$mEsc</w:t></w:r>$runsXml</w:p>")
        $i++
      }
      continue
    }

    # paragraph (default)
    $runsXml = Convert-MdInlineToRunsXml -text $line
    [void]$sb.AppendLine("<w:p>$runsXml</w:p>")
    $i++
  }

  return $sb.ToString()
}

function Get-MinimalContentTypesXml {
  $ct = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
</Types>
'@
  return $ct
}

function Get-MinimalRelsXml {
  $r = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
'@
  return $r
}

function Get-MinimalDocRelsXml {
  $r = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
'@
  return $r
}

function Get-MinimalStylesXml {
  $s = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults>
    <w:rPrDefault>
      <w:rPr>
        <w:rFonts w:ascii="Microsoft YaHei" w:hAnsi="Microsoft YaHei" w:eastAsia="Microsoft YaHei" w:cs="Microsoft YaHei"/>
        <w:sz w:val="22"/>
        <w:szCs w:val="22"/>
      </w:rPr>
    </w:rPrDefault>
    <w:pPrDefault>
      <w:pPr>
        <w:spacing w:after="120" w:line="276" w:lineRule="auto"/>
      </w:pPr>
    </w:pPrDefault>
  </w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
    <w:name w:val="Normal"/>
    <w:qFormat/>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading1">
    <w:name w:val="heading 1"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="480" w:after="240"/><w:outlineLvl w:val="0"/></w:pPr>
    <w:rPr><w:b/><w:bCs/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading2">
    <w:name w:val="heading 2"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="360" w:after="180"/><w:outlineLvl w:val="1"/></w:pPr>
    <w:rPr><w:b/><w:bCs/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading3">
    <w:name w:val="heading 3"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="320" w:after="160"/><w:outlineLvl w:val="2"/></w:pPr>
    <w:rPr><w:b/><w:bCs/><w:color w:val="1F3864"/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading4">
    <w:name w:val="heading 4"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="280" w:after="140"/><w:outlineLvl w:val="3"/></w:pPr>
    <w:rPr><w:b/><w:bCs/><w:color w:val="2E74B5"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading5">
    <w:name w:val="heading 5"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="4"/></w:pPr>
    <w:rPr><w:b/><w:bCs/><w:color w:val="2E74B5"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr>
  </w:style>
  <w:style w:type="paragraph" w:styleId="Heading6">
    <w:name w:val="heading 6"/>
    <w:basedOn w:val="Normal"/>
    <w:next w:val="Normal"/>
    <w:qFormat/>
    <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="200" w:after="100"/><w:outlineLvl w:val="5"/></w:pPr>
    <w:rPr><w:b/><w:bCs/><w:color w:val="1F3864"/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr>
  </w:style>
</w:styles>
'@
  return $s
}

function Write-ZipEntry {
  param(
    [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Zip,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Content
  )
  $entry = $Zip.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
  $stream = $entry.Open()
  try {
    $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
    $writer.Write($Content)
    $writer.Flush()
  } finally {
    $writer.Dispose()
    $stream.Dispose()
  }
}

function Write-DocxFile {
  param(
    [Parameter(Mandatory)][string]$OutPath,
    [Parameter(Mandatory)][string]$BodyXml
  )
  $documentXml = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
$BodyXml
    <w:sectPr>
      <w:pgSz w:w="11906" w:h="16838"/>
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/>
    </w:sectPr>
  </w:body>
</w:document>
"@

  $tmpDir = Join-Path $env:TEMP ("office-md-{0}" -f [System.Guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  try {
    # ensure parent dir of OutPath exists
    $parent = Split-Path -Parent $OutPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if (Test-Path $OutPath) { Remove-Item $OutPath -Force }

    $fs = [System.IO.File]::Open($OutPath, [System.IO.FileMode]::CreateNew)
    try {
      $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
      try {
        Write-ZipEntry -Zip $zip -Name '[Content_Types].xml' -Content (Get-MinimalContentTypesXml)
        Write-ZipEntry -Zip $zip -Name '_rels/.rels' -Content (Get-MinimalRelsXml)
        Write-ZipEntry -Zip $zip -Name 'word/document.xml' -Content $documentXml
        Write-ZipEntry -Zip $zip -Name 'word/_rels/document.xml.rels' -Content (Get-MinimalDocRelsXml)
        Write-ZipEntry -Zip $zip -Name 'word/styles.xml' -Content (Get-MinimalStylesXml)
      } finally {
        $zip.Dispose()
      }
    } finally {
      $fs.Dispose()
    }
  } finally {
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

# ---------- Excel COM helpers (xlsx still uses COM, works fine in bridge) ----------

function Invoke-WithExcel {
  param([scriptblock]$Action)
  $xl = $null
  $xlPid = 0
  try {
    $xl = New-Object -ComObject Excel.Application
    # F2(2026-09-29 深审):精确记下本 COM 服务进程 PID(HWND→GetWindowThreadProcessId)。
    # finally 里只清自己的——Quit 失败残留的 EXCEL.EXE 逐次累积,而按映像名/PID差集杀
    # 会误杀窗口期用户自己开的 Excel(Word 通道同款取舍:精确锁定,零误伤)。
    # 已知边界:Action 内部若真挂死(模态弹窗),finally 不可达——结构性子进程隔离缓行,
    # 挂死态靠消费点的 Test-FileWritable 占用预探测前置拦(变有限失败)。
    try {
      if (-not ('Win32.ExcelPid' -as [type])) {
        Add-Type -Namespace Win32 -Name ExcelPid -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);'
      }
      $procId = 0
      [void][Win32.ExcelPid]::GetWindowThreadProcessId([IntPtr]$xl.HWND, [ref]$procId)
      $xlPid = [int]$procId
    } catch { $xlPid = 0 }
    $xl.Visible = $false
    $xl.DisplayAlerts = $false
    return & $Action $xl
  } finally {
    if ($xl) {
      try { $xl.Quit() } catch {}
      [System.Runtime.InteropServices.Marshal]::ReleaseComObject($xl) | Out-Null
      [System.GC]::Collect()
      [System.GC]::WaitForPendingFinalizers()
      if ($xlPid -gt 0) {
        $linger = Get-Process -Id $xlPid -ErrorAction SilentlyContinue
        if ($linger) { Stop-Process -Id $xlPid -Force -ErrorAction SilentlyContinue }
      }
    }
  }
}

# ---------- dispatchers ----------

function Convert-DocxToMd {
  if (-not (Test-Path $inputPath)) {
    return @{ ok = $false; error = @{ code = 'INPUT_NOT_FOUND'; message = "File not found: $inputPath" } }
  }
  $ext = [System.IO.Path]::GetExtension($inputPath).ToLower()
  if ($ext -ne '.docx') {
    return @{ ok = $false; error = @{ code = 'UNSUPPORTED_FORMAT'; message = "Only .docx is supported (got: $ext). Legacy .doc not supported." } }
  }

  $paragraphs = $null
  $plainText = $null
  try {
    $paragraphs = Read-DocxText -Path $inputPath
  } catch {
    return @{ ok = $false; error = @{ code = 'DOCX_PARSE_FAILED'; message = "Failed to read docx: $($_.Exception.Message)" } }
  }

  # Plain text concat for fallback or Claude input
  $plainSb = New-Object System.Text.StringBuilder
  foreach ($p in $paragraphs) {
    if ($p.style -eq '__TABLE__') {
      $rows = $p.rows
      if ($rows.Count -ge 1) {
        [void]$plainSb.AppendLine(($rows[0] -join "`t"))
        for ($r = 1; $r -lt $rows.Count; $r++) {
          [void]$plainSb.AppendLine(($rows[$r] -join "`t"))
        }
      }
      [void]$plainSb.AppendLine('')
    } else {
      if (-not [string]::IsNullOrEmpty($p.text)) {
        [void]$plainSb.AppendLine($p.text)
      }
    }
  }
  $plainText = $plainSb.ToString()
  $fullLen = $plainText.Length

  if ($fullLen -eq 0) {
    return @{ ok = $false; error = @{ code = 'EMPTY_TEXT'; message = 'Word document has no extractable text' } }
  }

  $truncated = $false
  $tokensUsed = $null
  $md = $null
  if ($useClaude) {
    $chunk = $plainText
    if ($chunk.Length -gt 6000) { $chunk = $chunk.Substring(0, 6000); $truncated = $true }
    $sys = 'You are a document conversion assistant. Convert the plain text extracted from a Word document into clean Markdown. Preserve heading hierarchy (infer from layout/context), lists, tables (reconstruct as GFM tables when content looks tabular), bold/italic if intent is clear. Output ONLY the markdown, no explanations, no code fences.'
    $userLines = @(
      'Convert the text below into Markdown. Rules:',
      '- Infer heading levels from context (document title = #, sections = ##, sub-sections = ###).',
      '- Reconstruct lists (- or 1.) when lines look like list items.',
      '- If you see repeated key:value or aligned columns, output a GFM table.',
      '- Drop page numbers, headers/footers, table-of-contents page references.',
      '- Keep the original language (Chinese stays Chinese).',
      '',
      '--- TEXT START ---',
      $chunk,
      '--- TEXT END ---'
    )
    $user = ($userLines -join "`n")
    try {
      # -NoThinking(09-18 审查):本文件 16 处直调唯一漏网;思考吃光 MaxTokens 时 text 为空
      $resp = Invoke-KbClaude -UserPrompt $user -SystemPrompt $sys -MaxTokens 4000 -Temperature 0.1 -TimeoutSec 120 -NoThinking
      $md = $resp.text
      # 空文本与异常同待遇:走结构化 fallback,绝不落空 .md 还报 ok
      if (-not $md) { throw 'AI 返回空文本(可能被截断)' }
      $tokensUsed = @{ input = $resp.inputTokens; output = $resp.outputTokens }
    } catch {
      # Claude failed -> fallback to direct OOXML-to-md (structured)
      $md = Convert-DocxParagraphsToMd -Paragraphs $paragraphs
      $tokensUsed = @{ fallback = $true; error = $_.Exception.Message }
    }
  } else {
    # Direct OOXML-to-md (structured, no Claude)
    $md = Convert-DocxParagraphsToMd -Paragraphs $paragraphs
  }

  $baseName = Get-SafeBaseName -Path $inputPath
  $outPath = Get-UniqueOutPath -Dir $DownloadsDir -BaseName $baseName -Ext '.md'
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($outPath, $md, $utf8NoBom)

  $previewLen = [Math]::Min(500, $md.Length)
  return @{
    ok = $true
    result = @{
      savedTo    = $outPath
      mdPreview  = $md.Substring(0, $previewLen)
      sourceChars = $fullLen
      truncated  = $truncated
      usedClaude = $useClaude
      tokensUsed = $tokensUsed
    }
  }
}

function Convert-MdToDocx {
  if ([string]::IsNullOrEmpty($mdText)) {
    return @{ ok = $false; error = @{ code = 'MD_REQUIRED'; message = 'mdText is required for from-md direction' } }
  }
  try {
    $bodyXml = Convert-MdToDocumentXmlBody -Md $mdText
  } catch {
    return @{ ok = $false; error = @{ code = 'MD_PARSE_FAILED'; message = "Failed to parse md: $($_.Exception.Message)" } }
  }
  $outPath = Get-UniqueOutPath -Dir $DownloadsDir -BaseName ('md-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Ext '.docx'
  try {
    Write-DocxFile -OutPath $outPath -BodyXml $bodyXml
  } catch {
    if (Test-Path $outPath) { Remove-Item $outPath -Force -ErrorAction SilentlyContinue }
    return @{ ok = $false; error = @{ code = 'DOCX_WRITE_FAILED'; message = "Failed to write docx: $($_.Exception.Message)" } }
  }
  $sizeBytes = (Get-Item $outPath).Length
  return @{ ok = $true; result = @{ savedTo = $outPath; sizeBytes = $sizeBytes } }
}

function Convert-XlsxToMd {
  if (-not (Test-Path $inputPath)) {
    return @{ ok = $false; error = @{ code = 'INPUT_NOT_FOUND'; message = "File not found: $inputPath" } }
  }
  $result = $null
  try {
    $result = Invoke-WithExcel -Action {
      param($xl)
      $wb = $null
      try {
        $wb = $xl.Workbooks.Open($inputPath, 0, $true)
        $sheetCount = $wb.Worksheets.Count
        $sheet1 = $wb.Worksheets.Item(1)
        $used = $sheet1.UsedRange
        $rows = $used.Rows.Count
        $cols = $used.Columns.Count
        if ($rows -lt 1 -or $cols -lt 1) {
          return @{ ok = $false; error = @{ code = 'EMPTY_SHEET'; message = 'First sheet is empty' } }
        }
        $sb = New-Object System.Text.StringBuilder
        $hdr = @()
        for ($c = 1; $c -le $cols; $c++) {
          $hdr += (Sanitize-Cell -s $sheet1.Cells(1, $c).Text)
        }
        [void]$sb.AppendLine('| ' + ($hdr -join ' | ') + ' |')
        [void]$sb.AppendLine('| ' + (($hdr | ForEach-Object { '---' }) -join ' | ') + ' |')
        for ($r = 2; $r -le $rows; $r++) {
          $rowVals = @()
          for ($c = 1; $c -le $cols; $c++) {
            $rowVals += (Sanitize-Cell -s $sheet1.Cells($r, $c).Text)
          }
          [void]$sb.AppendLine('| ' + ($rowVals -join ' | ') + ' |')
        }
        return @{ ok = $true; md = $sb.ToString(); rows = $rows; cols = $cols; sheetCount = $sheetCount }
      } finally {
        if ($wb) {
          try { $wb.Close($false) } catch {}
          [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) | Out-Null
        }
      }
    }
  } catch {
    return @{ ok = $false; error = @{ code = 'EXCEL_COM_FAILED'; message = "Excel COM error: $($_.Exception.Message)" } }
  }
  if (-not $result.ok) { return $result }

  $baseName = Get-SafeBaseName -Path $inputPath
  $outPath = Get-UniqueOutPath -Dir $DownloadsDir -BaseName $baseName -Ext '.md'
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($outPath, $result.md, $utf8NoBom)

  $previewLen = [Math]::Min(500, $result.md.Length)
  return @{
    ok = $true
    result = @{
      savedTo       = $outPath
      mdPreview     = $result.md.Substring(0, $previewLen)
      rows          = $result.rows
      cols          = $result.cols
      sheetCount    = $result.sheetCount
      ignoredSheets = $result.sheetCount - 1
    }
  }
}

function Convert-MdToXlsx {
  if ([string]::IsNullOrEmpty($mdText)) {
    return @{ ok = $false; error = @{ code = 'MD_REQUIRED'; message = 'mdText is required for from-md direction' } }
  }
  $lines = $mdText -split "`r?`n"
  $tableStart = -1
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -match '^\s*\|.*\|\s*$' -and $i + 1 -lt $lines.Length -and $lines[$i+1] -match '^\s*\|[\s:|-]+\|\s*$') {
      $tableStart = $i
      break
    }
  }
  if ($tableStart -lt 0) {
    return @{ ok = $false; error = @{ code = 'NO_TABLE_FOUND'; message = 'No GFM table found in mdText' } }
  }
  $headers = Split-MdTableRow -line $lines[$tableStart]
  $dataRows = @()
  $r = $tableStart + 2
  while ($r -lt $lines.Length -and $lines[$r] -match '^\s*\|.*\|\s*$') {
    $dataRows += ,(Split-MdTableRow -line $lines[$r])
    $r++
  }

  $outPath = Get-UniqueOutPath -Dir $DownloadsDir -BaseName ('md-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Ext '.xlsx'
  try {
    Invoke-WithExcel -Action {
      param($xl)
      $wb = $null
      try {
        $wb = $xl.Workbooks.Add()
        $sheet = $wb.Worksheets.Item(1)
        for ($c = 0; $c -lt $headers.Length; $c++) {
          $sheet.Cells(1, $c + 1) = $headers[$c]
        }
        for ($rowIdx = 0; $rowIdx -lt $dataRows.Length; $rowIdx++) {
          $row = $dataRows[$rowIdx]
          for ($c = 0; $c -lt $row.Length; $c++) {
            $v = $row[$c]
            $num = 0
            if ($v -match '^-?\d+(\.\d+)?$' -and [double]::TryParse($v, [ref]$num)) {
              $sheet.Cells($rowIdx + 2, $c + 1) = $num
            } else {
              $sheet.Cells($rowIdx + 2, $c + 1) = $v
            }
          }
        }
        try { $sheet.UsedRange.EntireColumn.AutoFit() | Out-Null } catch {}
        $wb.SaveAs($outPath, 51) | Out-Null
      } finally {
        if ($wb) {
          try { $wb.Close($true) } catch {}
          [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) | Out-Null
        }
      }
    }
  } catch {
    return @{ ok = $false; error = @{ code = 'EXCEL_COM_FAILED'; message = "Excel COM error: $($_.Exception.Message)" } }
  }

  return @{
    ok = $true
    result = @{
      savedTo = $outPath
      rows    = $dataRows.Length + 1
      cols    = $headers.Length
    }
  }
}
# md -> docx 一步到位(2026-08-31 对抗审查整合:sap-interface-doc / sap-test-report 两个消费方
# 此前各抄一遍 Convert-MdToDocumentXmlBody+Get-SafeBaseName+Write-DocxFile 组装,第三个消费者
# 必然再踩一次)。命名策略由调用方定:
#   -OutPath            显式全路径,直接覆盖写(sap-test-report:复测导出覆盖同名)
#   -Dir -BaseName [-Unique]  目录+名;-Unique 时重名自动加序号(sap-interface-doc),否则直接写
# 返回 docx 全路径;失败抛错(调用方自行降级,如回退下载 md)。
function Convert-MdToDocxFile {
  param(
    [Parameter(Mandatory)][string]$Md,
    [string]$OutPath,
    [string]$Dir,
    [string]$BaseName,
    [switch]$Unique
  )
  if (-not $OutPath) {
    if (-not $Dir -or -not $BaseName) { throw 'Convert-MdToDocxFile: need -OutPath or -Dir+-BaseName' }
    $safe = Get-SafeBaseName -Path $BaseName
    $OutPath = if ($Unique) { Get-UniqueOutPath -Dir $Dir -BaseName $safe -Ext '.docx' } else { Join-Path $Dir ($safe + '.docx') }
  }
  $bodyXml = Convert-MdToDocumentXmlBody -Md $Md
  Write-DocxFile -OutPath $OutPath -BodyXml $bodyXml
  return $OutPath
}
