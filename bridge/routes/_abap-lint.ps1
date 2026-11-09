# _abap-lint.ps1 — ABAP SQL 五关静态分析引擎(纯文本,零 SAP 依赖,可离线单测)
# 设计规格:见仓库 docs/ 目录(开源版收敛)
# 入口:
#   Get-AbapSqlFacts     -Lines <string[]> -IncludeName <s>  → @{ Include; Findings; Audit; Stats; DistinctTables; Anomalies; SelectCount }
#   Complete-AbapSqlLint -FactsList <obj[]> -TableIndex <h> -Program <s> → 最终报告 hashtable(路由直接塞 result)
# 约定:PS 5.1;全 hashtable(便于 ConvertTo-Json);大小写不敏感依赖 PS 默认 -eq/-match

# ============ 1. 行扫描:注释剥离 + 语句终止符定位 ============
function Read-AbapLine {
    param([string]$Line)
    # 返回 @{ Code=去注释文本; Dots=@(语句终止符在 Code 中的偏移) }
    $trimmed = $Line.TrimStart()
    if ($trimmed.StartsWith('*')) { return @{ Code = ''; Dots = @() } }   # 整行 * 注释
    if ($Line -notmatch "['`"]") {
        # 快路径:行内无引号 → 不可能有行内注释,直接找终止符
        return @{ Code = $Line; Dots = @(Get-DotOffsets -Code $Line) }
    }
    # 慢路径:逐字符状态机(剥离行内 " 注释,屏蔽字面量内的 . 与 ")
    $sb = New-Object System.Text.StringBuilder
    $dots = New-Object System.Collections.Generic.List[int]
    $state = 'code'   # code | sq | bt | tpl
    $n = $Line.Length; $i = 0
    while ($i -lt $n) {
        $c = $Line[$i]
        if ($state -eq 'code') {
            if ($c -eq "'") { [void]$sb.Append($c); $state = 'sq' }
            elseif ($c -eq '`') { [void]$sb.Append($c); $state = 'bt' }
            elseif ($c -eq '|') { [void]$sb.Append($c); $state = 'tpl' }
            elseif ($c -eq '"') { break }   # 行内注释,其后全丢
            elseif ($c -eq '.') {
                [void]$sb.Append($c)
                $isEnd = ($i + 1 -ge $n) -or ($Line[$i + 1] -eq ' ') -or ($Line[$i + 1] -eq "`t")
                if ($isEnd) { [void]$dots.Add($sb.Length - 1) }
            }
            else { [void]$sb.Append($c) }
        }
        elseif ($state -eq 'sq') {
            [void]$sb.Append($c)
            if ($c -eq "'") {
                if ($i + 1 -lt $n -and $Line[$i + 1] -eq "'") { [void]$sb.Append("'"); $i++ }  # '' 转义仍在串内
                else { $state = 'code' }
            }
        }
        elseif ($state -eq 'bt') { [void]$sb.Append($c); if ($c -eq '`') { $state = 'code' } }
        else { [void]$sb.Append($c); if ($c -eq '|') { $state = 'code' } }   # tpl:字面量内 ' " 不生效
        $i++
    }
    return @{ Code = $sb.ToString(); Dots = $dots.ToArray() }
}

function Get-DotOffsets {
    param([string]$Code)
    $list = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $Code.Length; $i++) {
        if ($Code[$i] -ne '.') { continue }
        $isEnd = ($i + 1 -ge $Code.Length) -or ($Code[$i + 1] -eq ' ') -or ($Code[$i + 1] -eq "`t")
        if ($isEnd) { [void]$list.Add($i) }
    }
    return $list.ToArray()
}

# ============ 2. 语句切分(跨行拼接,保行号) ============
function Build-Statements {
    param([object[]]$LineInfos)
    $stmts = New-Object System.Collections.Generic.List[object]
    $buf = New-Object System.Collections.Generic.List[string]
    $startLine = 0; $anomalies = 0
    foreach ($li in $LineInfos) {
        $code = [string]$li.Code
        if ($code.Trim().Length -eq 0) { continue }
        $cur = 0
        foreach ($k in @($li.Dots)) {
            if ($startLine -eq 0) { $startLine = $li.Line }
            [void]$buf.Add($code.Substring($cur, $k - $cur + 1))
            $text = (($buf.ToArray() -join ' ') -replace '\s+', ' ').Trim()
            $stmts.Add(@{ Text = $text; StartLine = $startLine; EndLine = $li.Line })
            $buf.Clear(); $cur = $k + 1
        }
        if ($cur -lt $code.Length) {
            $rest = $code.Substring($cur).Trim()
            if ($rest.Length -gt 0) {
                if ($buf.Count -eq 0) { $startLine = $li.Line }
                [void]$buf.Add($rest)
            }
        }
        if ($buf.Count -eq 0) { $startLine = $li.Line }
    }
    if ($buf.Count -gt 0) {   # 尾部无终止符残段:容错收尾
        $text = (($buf.ToArray() -join ' ') -replace '\s+', ' ').Trim()
        if ($text.Length -gt 0) { $stmts.Add(@{ Text = $text; StartLine = $startLine; EndLine = 0 }); $anomalies++ }
    }
    return @{ Stmts = $stmts; Anomalies = $anomalies }
}

# ============ 3. 词法小工具 ============
function Get-FirstToken {
    param([string]$Text)
    $m = [regex]::Match($Text, '^\s*([A-Za-z_\/][\w\/-]*)')
    if ($m.Success) { return $m.Groups[1].Value.ToUpperInvariant() }
    return ''
}
function Get-Kw2 {
    param([string]$Text)
    $m = [regex]::Match($Text, '^\s*([A-Za-z_\/][\w\/-]*)\.?\s+([A-Za-z_\/][\w\/-]*)\.?')
    if ($m.Success) { return ($m.Groups[1].Value.ToUpperInvariant() + ' ' + $m.Groups[2].Value.ToUpperInvariant()) }
    return ''
}
function Get-Snippet {
    param([string[]]$Lines, [int]$Line, [int]$EndLine)
    if ($Line -le 0) { return '' }
    $from = [Math]::Max(1, $Line - 2)
    $to = $Line; if ($EndLine -gt $Line) { $to = $EndLine }
    $to = $to + 2
    $max = $Lines.Count; if ($to -gt $max) { $to = $max }
    if ($to - $from -gt 9) { $to = $from + 9 }   # 片段最多 10 行
    $parts = New-Object System.Collections.Generic.List[string]
    for ($i = $from; $i -le $to; $i++) { [void]$parts.Add(('{0}|{1}' -f $i, $Lines[$i - 1])) }
    return ($parts.ToArray() -join "`n")
}

# G3 守卫配套:From+1 起 2 条内出现 RETURN/EXIT/CONTINUE 视为「空表早退」成立
function Test-KillAfter {
    param([object[]]$Stmts, [int]$From, [int]$Upto)
    for ($k = $From + 1; $k -lt [Math]::Min($From + 3, $Upto); $k++) {
        if ((Get-FirstToken ([string]$Stmts[$k].Text)) -in @('RETURN', 'EXIT', 'CONTINUE')) { return $true }
    }
    return $false
}

# ============ 4. SELECT 语句解析(关2/关4/关5 底料) ============
function Parse-Select {
    param([string]$Text)
    $a = [ordered]@{
        Kind = 'SELECT'; Tables = @(); TableStatus = 'static'; IsSelectSingle = ([regex]::IsMatch($Text, '(?i)\bSELECT\s+SINGLE\b'))
        HasWhere = $false; WhereStatus = 'none'; WhereFields = @(); Unresolved = 0
        HasSeltab = $false; HasSubquery = ([regex]::IsMatch($Text, '(?i)\(\s*SELECT\b'))
        IsDynamic = ([regex]::IsMatch($Text, '(?i)\b(?:WHERE|AND|OR)\s*\(\s*@?\w+\s*\)'))
        HasIntoTable = $false; IntoTable = ''; HasFullTableScan = $false
        WeakFields = @()
        HasFae = $false; FaeItab = $null; Aggregates = @(); GroupBy = ([regex]::IsMatch($Text, '(?i)\bGROUP\s+BY\b'))
        UpToRows = $null
    }
    $mFae = [regex]::Match($Text, '(?i)\bFOR\s+ALL\s+ENTRIES\s+IN\s+@?(?:DATA\(\s*)?(\w+)')
    if ($mFae.Success) { $a.HasFae = $true; $a.FaeItab = $mFae.Groups[1].Value.ToUpperInvariant() }
    $mInto = [regex]::Match($Text, '(?i)\b(?:INTO|APPENDING)\s+(?:CORRESPONDING\s+FIELDS\s+OF\s+)?TABLE\s+@?(\w+)')
    if ($mInto.Success) { $a.HasIntoTable = $true; $a.IntoTable = $mInto.Groups[1].Value.ToUpperInvariant() }
    foreach ($am in [regex]::Matches($Text, '(?i)\b(COUNT|SUM|MIN|MAX|AVG)\s*\(')) {
        $u = $am.Groups[1].Value.ToUpperInvariant()
        if ($a.Aggregates -notcontains $u) { $a.Aggregates = @($a.Aggregates) + $u }
    }
    $mUp = [regex]::Match($Text, '(?i)\bUP\s+TO\s+(\S+)\s+ROWS\b')
    if ($mUp.Success) { $a.UpToRows = $mUp.Groups[1].Value }

    # FROM 片段 → 基表 + 别名
    $reFrom = '(?i)\bFROM\s+(?<from>.+?)(?=\s+(?:WHERE\b|FOR\s+ALL\b|INTO\b|APPENDING\b|UP\s+TO\b|ORDER\s+BY\b|GROUP\s+BY\b|HAVING\b|BYPASSING\b|CLIENT\b|%_HINTS\b|OPTIONS?\b)|$)'
    $mFrom = [regex]::Match($Text, $reFrom)
    $aliasMap = @{}
    if ($mFrom.Success) {
        $frag = $mFrom.Groups['from'].Value
        # frag 是 FROM 之后的内容:首表用 ^ 锚定,后续 JOIN 逐个收
        foreach ($tm in [regex]::Matches($frag, '(?i)(?:^|\bFROM\b|\bJOIN\b)\s*(?<tab>\/\w+\/[\w~]*|\w+|\(\s*@?\w+\s*\)|@\w+)')) {
            $tv = $tm.Groups['tab'].Value.ToUpperInvariant()
            if ($tv.StartsWith('(') -or $tv.StartsWith('@')) { $a.TableStatus = 'unknown' }
            elseif ($a.Tables -notcontains $tv) { $a.Tables = @($a.Tables) + $tv }
        }
        foreach ($am in [regex]::Matches($frag, '(?i)(?<tab>\/\w+\/[\w~]*|\w+)\s+AS\s+(?<al>\w+)')) {
            $aliasMap[$am.Groups['al'].Value.ToUpperInvariant()] = $am.Groups['tab'].Value.ToUpperInvariant()
        }
    }
    # WHERE 片段 → 条件字段
    $reWhere = '(?i)\bWHERE\s+(?<w>.+?)(?=\s+(?:GROUP\s+BY\b|ORDER\s+BY\b|UP\s+TO\b|%_HINTS\b|OPTIONS?\b)|$)'
    $mWhere = [regex]::Match($Text, $reWhere)
    if ($mWhere.Success) {
        $a.HasWhere = $true; $a.WhereStatus = 'static'
        $wtxt = $mWhere.Groups['w'].Value
        $fields = New-Object System.Collections.Generic.List[string]
        $fieldOps = @{}   # field → List[string]:每字段的操作符形态(弱条件判定底料)
        foreach ($atom in @(Split-WhereAtoms -W $wtxt)) {
            if ($atom.StartsWith("'") -or $atom.StartsWith('(')) { continue }   # 字面量在左/括号组:弃
            $mA = [regex]::Match($atom, '^\s*(?<f>[A-Za-z_\/][\w\/~\-]*)\s*(?<op>=|<>|<=|>=|EQ\b|NE\b|GT\b|LT\b|GE\b|LE\b|LIKE\b|NOT\s+LIKE\b|IN\b|NOT\s+IN\b|BETWEEN\b|NOT\s+BETWEEN\b|IS\b|CP\b|CL\b)')
            if (-not $mA.Success) { continue }
            $f = $mA.Groups['f'].Value; $op = $mA.Groups['op'].Value.ToUpperInvariant()
            $fTarget = ''
            if ($f.Contains('~')) {
                $seg = $f.Split('~'); $al = $seg[0].ToUpperInvariant(); $fld = $seg[$seg.Count - 1].ToUpperInvariant()
                if ($aliasMap.ContainsKey($al)) { [void]$fields.Add($fld); $fTarget = $fld } else { $a.Unresolved++ }
            }
            elseif ($f.Contains('-')) { $a.Unresolved++ }   # 结构-字段等无法归属 → unknown 桶
            else {
                if ($op -eq 'IN') {
                    $rhs = $atom.Substring($mA.Index + $mA.Length).Trim()
                    if ($rhs -match '^\(?\s*(S_|P_|SO_|GT_)' -or $rhs.EndsWith('[]')) { $a.HasSeltab = $true }
                }
                $fTarget = $f.ToUpperInvariant()
                [void]$fields.Add($fTarget)
            }
            if ($fTarget) {
                $opRec = $op
                if ($op -eq 'LIKE') {
                    $rhsL = $atom.Substring($mA.Index + $mA.Length).Trim()
                    if ($rhsL -match "^'\s*%") { $opRec = 'WEAK_LIKE' }   # 前通配 LIKE:索引前缀用不上
                }
                if (-not $fieldOps.ContainsKey($fTarget)) { $fieldOps[$fTarget] = New-Object System.Collections.Generic.List[string] }
                [void]$fieldOps[$fTarget].Add($opRec)
            }
        }
        $a.WhereFields = @($fields.ToArray() | Select-Object -Unique)
        # 弱条件字段:该字段全部 atom 均为弱算符才算弱(有一个强 atom 即保持强,不收紧)
        $weakList = New-Object System.Collections.Generic.List[string]
        foreach ($k0 in $fieldOps.Keys) {
            $allWeak = $true
            foreach ($o in $fieldOps[$k0]) { if ($o -notin @('<>', 'NE', 'NOT IN', 'NOT BETWEEN', 'NOT LIKE', 'WEAK_LIKE')) { $allWeak = $false; break } }
            if ($allWeak) { [void]$weakList.Add($k0) }
        }
        $a.WeakFields = @($weakList.ToArray())
    }
    if ($a.IsDynamic) { $a.WhereStatus = 'dynamic' }
    elseif ($a.HasSeltab) { $a.WhereStatus = 'seltab' }
    elseif ($a.HasSubquery) { $a.WhereStatus = 'subquery' }
    elseif (-not $a.HasWhere) { $a.WhereStatus = 'none' }
    $a.HasFullTableScan = ((-not $a.HasWhere) -or ($a.WhereFields.Count -eq 0 -and $a.WhereStatus -eq 'static' -and $a.Unresolved -eq 0))
    return $a
}

# WHERE 按括号感知拆 AND/OR 原子(引号内/括号内不切)
function Split-WhereAtoms {
    param([string]$W)
    $atoms = New-Object System.Collections.Generic.List[string]
    $cur = New-Object System.Text.StringBuilder
    $depth = 0; $inQ = $false; $i = 0; $n = $W.Length
    while ($i -lt $n) {
        $c = $W[$i]
        if ($inQ) {
            [void]$cur.Append($c)
            if ($c -eq "'") { if ($i + 1 -lt $n -and $W[$i + 1] -eq "'") { [void]$cur.Append("'"); $i++ } else { $inQ = $false } }
            $i++; continue
        }
        if ($c -eq "'") { $inQ = $true; [void]$cur.Append($c); $i++; continue }
        if ($c -eq '(') { $depth++; [void]$cur.Append($c); $i++; continue }
        if ($c -eq ')') { if ($depth -gt 0) { $depth-- }; [void]$cur.Append($c); $i++; continue }
        if ($depth -eq 0) {
            $rest = $W.Substring($i)
            if ($rest -match '^(?i)(AND|OR)\s') {
                $t = $cur.ToString().Trim()
                if ($t.Length -gt 0) { [void]$atoms.Add($t) }
                [void]$cur.Clear(); $i += $Matches[1].Length; continue
            }
        }
        [void]$cur.Append($c); $i++
    }
    $t2 = $cur.ToString().Trim()
    if ($t2.Length -gt 0) { [void]$atoms.Add($t2) }
    return $atoms.ToArray()
}

# ============ 5. 主分析:例程边界 + 循环深度 + 五关提取 ============
function Get-AbapSqlFacts {
    param([string[]]$Lines, [string]$IncludeName)

    $lineInfos = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $r = Read-AbapLine -Line $Lines[$i]
        [void]$lineInfos.Add(@{ Line = $i + 1; Code = $r.Code; Dots = @($r.Dots) })
    }
    $built = Build-Statements -LineInfos $lineInfos.ToArray()
    $stmts = $built.Stmts
    $anomalies = [int]$built.Anomalies

    $findings = New-Object System.Collections.Generic.List[object]
    $audit = New-Object System.Collections.Generic.List[object]
    $stats = @{ statementCount = $stmts.Count; selectCount = 0; openCursorCount = 0; fetchCursorCount = 0
        selectInLoop = 0; faeSites = 0; chainedSelectsSkipped = 0; anomalies = $anomalies }
    $tableCounts = @{}
    $fullScanTargets = New-Object System.Collections.Generic.List[object]   # G5-A @{itab;line;routine}
    $loopWhereList = New-Object System.Collections.Generic.List[object]     # G5-A
    $describeList = New-Object System.Collections.Generic.List[object]      # G5-B
    $atBreakList = New-Object System.Collections.Generic.List[object]       # G5-C
    $collectList = New-Object System.Collections.Generic.List[object]       # G5-C

    $loopStack = New-Object System.Collections.Generic.List[object]   # @{Kind;Line[;Itab]}
    $ifStack = New-Object System.Collections.Generic.List[object]     # @{Cond;Branch;Idx} G3 守卫帧
    $depth = 0
    $routine = '_GLOBAL'; $routineStart = 0

    # ---- L0 声明解析:覆盖四形态(10-10 某结构 实爆补全) ----
    # ①DATA x TYPE/LIKE ddic ②DATA BEGIN OF x(组件 LIKE 表-字段,记 组-组件→表-字段)
    # ③FORM ... TABLES/USING/CHANGING p STRUCTURE/LIKE ddic ④TABLES: ddic
    $varTypes = @{}                                                        # var → ddic名;组件级键 '组-组件' → '表-字段'
    $beginGrp = ''                                                         # 当前 DATA BEGIN OF 组名
    $reBeginOf = '(?i)^DATA\s+BEGIN\s+OF\s+(\w+)'
    $reEndOf = '(?i)^DATA\s+END\s+OF\b'
    $reCompLike = "(?i)^@?(\w+)\s+(?:TYPE|LIKE)\s+(\w+)-(\w+)"             # 组件级:zsfhwtr LIKE ztab-zfld
    $reFormParam = '(?i)\b(?:TABLES|USING|CHANGING)\s+(\w+)\s+(?:STRUCTURE|LIKE)\s+(\w+)'
    $logicSuspects = New-Object System.Collections.Generic.List[object]    # @{Var;Field;Type;MsgText;Line;MsgLine;Routine;Snippet}
    $msgRecords = New-Object System.Collections.Generic.List[object]       # L2 素材 @{Routine;MsgText;Sig;Line}(Sig=条件字段签名,空=无条件可判)
    $reMsgAssign = "(?i)(?:^|[\s>])([\w\/\-]+-)?(message|msg|msgtx)\s*=\s*'([^']+)'"
    $reCondAtom = "(?i)(?:^|[\s(])@?(\w+)-(\w+)\s*(?:NE|EQ|<>|=|<=|>=|<|>|CP|LIKE|IN)\s*'([^']*)'"
    $reSigField = "(?i)(?:^|[\s(])@?(\w+)\s*(?:NE|EQ|<>|=|<=|>=|<|>|CP|LIKE|IN)\s*'"   # L2 签名用:纯变量条件也算(L1 仍限 var-field,DDIC 解析需要结构上下文)

    for ($i = 0; $i -lt $stmts.Count; $i++) {
        $st = $stmts[$i]; $text = [string]$st.Text
        $kw = Get-FirstToken $text
        $kw2 = Get-Kw2 $text

        # ---- 例程边界(先赋当前值再处理边界,语句归属:开边界语句归新例程) ----
        $isRoutineOpen = $false
        if ($kw -in @('FUNCTION', 'FORM', 'MODULE', 'METHOD')) {
            $nameM = [regex]::Match($text, '^\s*\w+\s+([\w\/-]+)')
            $routine = ('{0} {1}' -f $kw, $nameM.Groups[1].Value.ToUpperInvariant()); $routineStart = $i; $isRoutineOpen = $true
        }
        elseif ($kw -in @('INITIALIZATION', 'LOAD-OF-PROGRAM', 'START-OF-SELECTION', 'END-OF-SELECTION', 'TOP-OF-PAGE', 'END-OF-PAGE')) {
            $routine = $kw; $routineStart = $i; $isRoutineOpen = $true
        }
        elseif ($kw -eq 'AT' -and ($kw2 -in @('AT SELECTION-SCREEN', 'AT LINE-SELECTION', 'AT USER-COMMAND') -or $kw2.StartsWith('AT PF'))) {
            $routine = $kw2; $routineStart = $i; $isRoutineOpen = $true
        }
        if ($isRoutineOpen) { $ifStack.Clear() }   # 例程边界清 IF 帧:防上例程不平衡 IF 泄漏成漏报
        if ($kw -in @('ENDFORM', 'ENDFUNCTION', 'ENDMETHOD', 'ENDMODULE', 'END-OF-DEFINITION')) { $ifStack.Clear() }   # 双保险(宏可致不平衡)

        # ---- 循环栈:先处理关闭 ----
        if ($kw -in @('ENDLOOP', 'ENDDO', 'ENDWHILE', 'ENDSELECT')) {
            $wantKind = @{ ENDLOOP = 'LOOP'; ENDDO = 'DO'; ENDWHILE = 'WHILE'; ENDSELECT = 'SELECT' }[$kw]
            if ($loopStack.Count -gt 0 -and $loopStack[$loopStack.Count - 1].Kind -eq $wantKind) { $loopStack.RemoveAt($loopStack.Count - 1); $depth-- }
            else { $anomalies++ }
            $st.LoopDepth = $depth; $st.Routine = $routine
            continue
        }
        elseif ($kw -eq 'ENDIF') {
            if ($ifStack.Count -gt 0) { $ifStack.RemoveAt($ifStack.Count - 1) }   # 不平衡静默忽略(宏可致),不进 anomalies
            $st.LoopDepth = $depth; $st.Routine = $routine
            continue
        }
        $st.LoopDepth = $depth; $st.Routine = $routine

        $isSelect = ($kw -eq 'SELECT')
        $isOpenCursor = ($kw2 -eq 'OPEN CURSOR')
        $isFetch = ($kw -eq 'FETCH' -and $text -match '(?i)\bCURSOR\b')
        if ($isSelect -and $text -match '(?i)^SELECT\s*:') { $stats.chainedSelectsSkipped++; continue }   # 冒号链跳过

        # ---- 关1:循环内 DB 访问 ----
        if ($depth -ge 1 -and ($isSelect -or $isOpenCursor)) {
            $top = $loopStack[$loopStack.Count - 1]
            $tagged = @()
            if ($isSelect -and [regex]::IsMatch($text, '(?i)\bSELECT\s+SINGLE\b')) { $tagged = @('selectSingle') }
            $sug1 = '一次性取数:JOIN / FOR ALL ENTRIES(先判空+SORT+去重)/ 循环前读入内表后 READ TABLE'
            if ($top.Kind -eq 'LOOP' -and $top.Itab -and $top.Itab -ne 'SCREEN') {
                $sug1 = ('把第 {0} 行 LOOP AT {1} 内的 SELECT 改为循环前一次 FOR ALL ENTRIES IN {1}(判空+SORT+去重)' -f $top.Line, $top.Itab)
            }
            # 2026-10-10 用户定案:LOOP 内 SELECT 在小数据量场景属可接受模式,降 HIGH→MED
            # (连带:仅此类问题的程序从「不通过」变「有条件通过」;OPEN CURSOR 同级同理)
            [void]$findings.Add(@{
                Rule = 'G1'; Subtype = $(if ($isOpenCursor) { 'OPEN_CURSOR_IN_LOOP' } else { 'SELECT_IN_LOOP' })
                Severity = 'MED'; Tags = $tagged
                Line = $st.StartLine; EndLine = $st.EndLine; Routine = $routine
                LoopKind = $top.Kind; LoopLine = $top.Line
                Message = ('{0} 位于第 {1} 行 {2} 循环体内,每次迭代一次 DB 往返' -f $(if ($isOpenCursor) { 'OPEN CURSOR' } else { 'SELECT' }), $top.Line, $top.Kind)
                Suggestion = $sug1
                Snippet = (Get-Snippet -Lines $Lines -Line $st.StartLine -EndLine $st.EndLine)
            })
            if ($isSelect) { $stats.selectInLoop++ }
        }
        elseif ($depth -ge 1 -and $isFetch) {
            $top = $loopStack[$loopStack.Count - 1]
            [void]$findings.Add(@{
                Rule = 'G1'; Subtype = 'FETCH_IN_LOOP'; Severity = 'MED'; Tags = @('ext')
                Line = $st.StartLine; EndLine = $st.EndLine; Routine = $routine
                LoopKind = $top.Kind; LoopLine = $top.Line
                Message = ('FETCH NEXT CURSOR 位于第 {0} 行 {1} 循环体内(分批取数属已知模式,请人工确认必要)' -f $top.Line, $top.Kind)
                Suggestion = '确认是否必须分批;能一次取尽则改为单次 SELECT INTO TABLE'
                Snippet = (Get-Snippet -Lines $Lines -Line $st.StartLine -EndLine $st.EndLine)
            })
        }

        # ---- L0:声明入 varTypes(DATA 四形态 + TABLES;TYPES 本地结构不收) ----
        if ($kw -eq 'FORM') {
            foreach ($mF in [regex]::Matches($text, $reFormParam)) {
                $varTypes[$mF.Groups[1].Value.ToUpperInvariant()] = $mF.Groups[2].Value.ToUpperInvariant()
            }
        }
        if ($kw -in @('DATA', 'TABLES')) {
            $mB = [regex]::Match($text, $reBeginOf)
            if ($mB.Success) { $beginGrp = $mB.Groups[1].Value.ToUpperInvariant() }
            elseif ([regex]::IsMatch($text, $reEndOf)) { $beginGrp = '' }
            else {
                foreach ($seg in ($text -split ',')) {
                    $mD = [regex]::Match($seg, '(?i)(?:^|\b)(?:(?:DATA|TABLES)\s*:?\s*)?@?(\w+)\s+(?:TYPE|LIKE)\s+(?:STANDARD\s+TABLE\s+OF\s+|SORTED\s+TABLE\s+OF\s+|HASHED\s+TABLE\s+OF\s+|LINE\s+OF\s+)?(\w+)')
                    if ($mD.Success) { $varTypes[$mD.Groups[1].Value.ToUpperInvariant()] = $mD.Groups[2].Value.ToUpperInvariant() }
                }
            }
        }
        elseif ($beginGrp -and $text -match $reCompLike) {
            # BEGIN OF 块内组件声明:zsfhwtr LIKE zfitfykm_02-zsfhwtr → '组-组件'→'表-字段'(L0 组件级直判)
            # $Matches[1] 是字符串无 .Value 属性(直接取值,取错=静默 null)
            $varTypes[('{0}-{1}' -f $beginGrp, ([string]$Matches[1]).ToUpperInvariant())] = ('{0}-{1}' -f ([string]$Matches[2]).ToUpperInvariant(), ([string]$Matches[3]).ToUpperInvariant())
        }

        # ---- L0:报错文案落点(IF 帧内 message 赋值 / MESSAGE '字面量')→ 与顶帧条件配对 ----
        # 消息类文案 message class 编号形态(MESSAGE e001(zx))不取 T100,v1 只认字面量
        $msgLit = ''
        if (-not $isOpenCursor -and -not $isFetch) {
            $mMsg = [regex]::Match($text, $reMsgAssign)
            if ($mMsg.Success) { $msgLit = $mMsg.Groups[3].Value }
            elseif ($kw -eq 'MESSAGE') {
                $mM2 = [regex]::Match($text, "(?i)^MESSAGE\s+'([^']+)'")
                if ($mM2.Success) { $msgLit = $mM2.Groups[1].Value }
            }
        }
        if ($msgLit) {
            $condTxt = ''; $condIdx = -1; $condLine = 0
            if ($ifStack.Count -gt 0) {
                $fr0 = $ifStack[$ifStack.Count - 1]
                $condTxt = [string]$fr0.Cond; $condIdx = [int]$fr0.Idx
                if ($condIdx -ge 0 -and $condIdx -lt $stmts.Count) { $condLine = [int]$stmts[$condIdx].StartLine }
            }
            $atoms = @(); $sig = ''
            if ($condTxt) {
                $seenF = @{}
                foreach ($mA0 in [regex]::Matches($condTxt, $reCondAtom)) {
                    $fv0 = $mA0.Groups[2].Value.ToUpperInvariant()
                    if (-not $seenF.ContainsKey($fv0)) { $seenF[$fv0] = 1; $atoms += ,@{ Var = $mA0.Groups[1].Value.ToUpperInvariant(); Field = $fv0 } }
                }
                foreach ($mS0 in [regex]::Matches($condTxt, $reSigField)) {
                    $fs0 = $mS0.Groups[1].Value.ToUpperInvariant()
                    if (-not $seenF.ContainsKey($fs0)) { $seenF[$fs0] = 1 }
                }
                $sig = (@($seenF.Keys) | Sort-Object) -join '+'
            }
            [void]$msgRecords.Add(@{ Routine = $routine; MsgText = $msgLit; Sig = $sig; Line = $st.StartLine })
            if ($atoms.Count -gt 0) {
                $snip0 = (Get-Snippet -Lines $Lines -Line $st.StartLine -EndLine $st.EndLine)
                foreach ($a0 in $atoms) {
                    $t0 = ''
                    if ($varTypes.ContainsKey($a0.Var)) { $t0 = [string]$varTypes[$a0.Var] }
                    [void]$logicSuspects.Add(@{ Var = $a0.Var; Field = $a0.Field; Type = $t0; MsgText = $msgLit
                        Line = $condLine; MsgLine = $st.StartLine; Routine = $routine; Snippet = $snip0 })
                }
            }
        }

        # ---- 开块(SELECT 先判定再入栈) ----
        if ($kw -in @('LOOP', 'DO', 'WHILE')) {
            $lItab = $null
            if ($kw -eq 'LOOP') {
                $mL = [regex]::Match($text, '(?i)^LOOP\s+AT\s+@?(\w+)')
                if ($mL.Success) { $lItab = $mL.Groups[1].Value.ToUpperInvariant() }   # 立即取组,防后续 -match 覆盖 $Matches
            }
            $loopStack.Add(@{ Kind = $kw; Line = $st.StartLine; Itab = $lItab }); $depth++
        }
        elseif ($isSelect) {
            # SELECT…ENDSELECT 是循环体包裹:多行 SELECT(非 SINGLE/非 INTO TABLE/非聚合标量)即入栈,
            # 不能用「下一条是否 ENDSELECT」前瞻——那只在空循环体时成立
            $opensLoop = (-not [regex]::IsMatch($text, '(?i)\bSELECT\s+SINGLE\b')) -and
                         (-not [regex]::IsMatch($text, '(?i)\b(?:INTO|APPENDING)\s+(?:CORRESPONDING\s+FIELDS\s+OF\s+)?TABLE\b')) -and
                         (-not [regex]::IsMatch($text, '(?i)\b(COUNT|SUM|MIN|MAX|AVG)\s*\('))
            if ($opensLoop) { $loopStack.Add(@{ Kind = 'SELECT'; Line = $st.StartLine }); $depth++ }
        }

        # ---- IF 块栈(G3 守卫用):IF 压帧/ELSEIF 换帧/ELSE 翻分支;条件剥字符串字面量防伪命中 ----
        if ($kw -eq 'IF') {
            $cond = [regex]::Replace(($text -replace '^(?i)IF\s+', ''), "'[^']*'", "''")
            $ifStack.Add(@{ Cond = $cond; Branch = 'THEN'; Idx = $i })
        }
        elseif ($kw -eq 'ELSEIF') {
            $cond = [regex]::Replace(($text -replace '^(?i)ELSEIF\s+', ''), "'[^']*'", "''")
            if ($ifStack.Count -gt 0) { $ifStack[$ifStack.Count - 1].Cond = $cond; $ifStack[$ifStack.Count - 1].Branch = 'THEN'; $ifStack[$ifStack.Count - 1].Idx = $i }
            else { $ifStack.Add(@{ Cond = $cond; Branch = 'THEN'; Idx = $i }) }   # 不平衡容错
        }
        elseif ($kw -eq 'ELSE') {
            if ($ifStack.Count -gt 0) { $ifStack[$ifStack.Count - 1].Branch = 'ELSE' }   # Cond/Idx 保留 IF/ELSEIF 原值
        }

        # ---- SELECT 解析入审计 ----
        if ($isSelect -or $isOpenCursor) {
            if ($isOpenCursor) { $stats.openCursorCount++ } else { $stats.selectCount++ }
            $parseSrc = $text
            if ($isOpenCursor) {
                $p = $text.ToUpperInvariant().IndexOf(' FOR ')
                if ($p -ge 0) { $parseSrc = $text.Substring($p + 5) }
            }
            $sel = Parse-Select -Text $parseSrc
            $sel.Kind = $(if ($isOpenCursor) { 'OPEN CURSOR' } else { 'SELECT' })
            $sel.Line = $st.StartLine; $sel.EndLine = $st.EndLine
            $sel.LoopDepth = $depth; $sel.Routine = $routine; $sel.Include = $IncludeName
            $sel.Stmt = $(if ($text.Length -gt 200) { $text.Substring(0, 200) + '…' } else { $text })
            if ($sel.HasFae) { $stats.faeSites++ }
            foreach ($t in $sel.Tables) {
                if (-not $tableCounts.ContainsKey($t)) { $tableCounts[$t] = New-Object System.Collections.Generic.List[int] }
                [void]$tableCounts[$t].Add($st.StartLine)
            }
            # G5 素材(全表拉取目标,依赖 $sel,须留在 SELECT 块内)
            if ($sel.HasFullTableScan -and $sel.HasIntoTable -and $sel.TableStatus -eq 'static') {
                [void]$fullScanTargets.Add(@{ Itab = $sel.IntoTable; Line = $st.StartLine; Routine = $routine })
            }
            [void]$audit.Add($sel)
        }
        # G5 素材(任意语句:循环内过滤/计数/组 break/collect —— 不能放 SELECT 块内)
        if ($depth -ge 1 -and $text -match '(?i)^LOOP\s+AT\s+@?(\w+)') {
            [void]$loopWhereList.Add(@{ Itab = $Matches[1].ToUpperInvariant(); Line = $st.StartLine; Routine = $routine
                HasWhere = [regex]::IsMatch($text, '(?i)\bWHERE\b') })
        }
        if ($text -match '(?i)^DESCRIBE\s+TABLE\s+@?(\w+)') {
            [void]$describeList.Add(@{ Itab = $Matches[1].ToUpperInvariant(); Line = $st.StartLine; Routine = $routine })
        }
        if ($depth -ge 1 -and $text -match '(?i)^AT\s+(END\s+OF|NEW|FIRST|LAST)\b') {
            [void]$atBreakList.Add(@{ Line = $st.StartLine; Routine = $routine; What = $Matches[1].ToUpperInvariant() })
        }
        if ($kw -eq 'COLLECT') { [void]$collectList.Add(@{ Line = $st.StartLine; Routine = $routine }) }
        if ($isFetch) { $stats.fetchCursorCount++ }

        # ---- 关3:FAE 三要素回看(限同例程)。守卫=旧回看 ∨ 新回看形态 ∨ IF栈帧 ∨ LOOP AT 帧 ----
        if ($isSelect -and $text -match '(?i)\bFOR\s+ALL\s+ENTRIES\s+IN\s+@?(?:DATA\(\s*)?(\w+)') {
            $itab = $Matches[1].ToUpperInvariant()
            $hasGuard = $false; $hasSort = $false; $sortUnspec = $false; $hasDup = $false
            $invalidated = $false; $clearIdx = -1   # 回看途中遇 CLEAR/REFRESH/FREE itab:更深处守卫作废(表可能已清空)
            $descVars = New-Object System.Collections.Generic.List[string]   # DESCRIBE/LINES 计数变量(数据流)
            $esc = [regex]::Escape($itab)
            $reGuard = ('(?i)^(IF|CHECK)\s+@?' + $esc + '\s*(\[\s*\])?\s+IS\s+NOT\s+INITIAL\b')
            $reGuardInv = ('(?i)^IF\s+@?' + $esc + '\s*(\[\s*\])?\s+IS\s+INITIAL\b')
            $reNotInitChk = ('(?i)^CHECK\s+NOT\s+@?' + $esc + '\s*(\[\s*\])?\s+IS\s+INITIAL\b')          # CHECK NOT … INITIAL:CHECK 流安全;IF NOT 形态只走栈帧(ELSE 分支会漏)
            $reChkInit = ('(?i)^CHECK\s+@?' + $esc + '\s*(\[\s*\])?\s+IS\s+INITIAL\b')                   # 反向 CHECK:后续仅在非空时执行
            $reLinesZero = ('(?i)^(IF|CHECK)\s+LINES\s*\(\s*@?' + $esc + '\s*\)\s*(?:=|<=|EQ|LE)\s*0\b') # LINES()=0 早退
            $reDescVar = ('(?i)^DESCRIBE\s+TABLE\s+@?' + $esc + '\s+LINES\s+(\w+)')
            $reAssignVar = ('(?i)^@?(\w+)\s*=\s*LINES\s*\(\s*@?' + $esc + '\s*\)')
            $reClear = ('(?i)^(CLEAR|REFRESH|FREE)\s*:?\s*@?' + $esc + '\s*(\[\s*\])?\s*(\.|,|$)')
            $reSort = ('(?i)^SORT\s+@?' + $esc + '(\[\])?(\s+BY\b|\s*\.|$)')
            $reDup = ('(?i)^DELETE\s+ADJACENT\s+DUPLICATES\s+FROM\s+@?' + $esc)
            # 预扫计数变量:回看是倒序,DESCRIBE/LINES 定义在 IF 之前会「晚看到」→ 先收全再判
            for ($p = $i - 1; $p -ge $routineStart; $p--) {
                $ptp = [string]$stmts[$p].Text
                if ($ptp -match $reDescVar) { $v = $Matches[1].ToUpperInvariant(); if (-not $descVars.Contains($v)) { [void]$descVars.Add($v) } }
                elseif ($ptp -match $reAssignVar) { $v = $Matches[1].ToUpperInvariant(); if (-not $descVars.Contains($v)) { [void]$descVars.Add($v) } }
            }
            $j = $i - 1
            while ($j -ge $routineStart) {
                $pt = [string]$stmts[$j].Text
                if ($pt -match $reClear) { if ($clearIdx -lt 0) { $clearIdx = $j }; $invalidated = $true }   # 走下来的第一个=离 FAE 最近
                if ($pt -match $reDescVar) { $v = $Matches[1].ToUpperInvariant(); if (-not $descVars.Contains($v)) { [void]$descVars.Add($v) } }
                elseif ($pt -match $reAssignVar) { $v = $Matches[1].ToUpperInvariant(); if (-not $descVars.Contains($v)) { [void]$descVars.Add($v) } }
                if (-not $invalidated) {
                    if ($pt -match $reGuard) { $hasGuard = $true }
                    elseif ($pt -match $reGuardInv -and (Test-KillAfter -Stmts $stmts -From $j -Upto $i)) { $hasGuard = $true }
                    elseif ($pt -match $reNotInitChk) { $hasGuard = $true }
                    elseif ($pt -match $reChkInit) { $hasGuard = $true }
                    elseif ($pt -match $reLinesZero -and (Test-KillAfter -Stmts $stmts -From $j -Upto $i)) { $hasGuard = $true }
                    elseif ($descVars.Count -gt 0) {
                        foreach ($v in $descVars) {
                            $ve = [regex]::Escape($v)
                            if (($pt -match ('(?i)^IF\s+@?' + $ve + '\s*(IS\s+INITIAL\b|\s*(?:=|<=|EQ|LE)\s*0\b)')) -and (Test-KillAfter -Stmts $stmts -From $j -Upto $i)) { $hasGuard = $true; break }
                            if ($pt -match ('(?i)^CHECK\s+@?' + $ve + '\s*(IS\s+INITIAL\b|\s*(?:=|<=|EQ|LE)\s*0\b)')) { $hasGuard = $true; break }
                        }
                    }
                }
                if ($pt -match $reSort) { $hasSort = $true; if ($pt -notmatch '(?i)\bBY\b') { $sortUnspec = $true } }
                if ($pt -match $reDup) { $hasDup = $true }
                $j--
            }
            # IF 栈帧守卫:THEN 帧非空才进 THEN / ELSE 帧空才进 ELSE。
            # 镜像错开:THEN 拒含 OR 条件(guard OR x 可带空表进 THEN)、ELSE 拒含 AND 且显式排除 NOT 前缀。
            # CLEAR 失效按帧 Idx 精判:帧开在 CLEAR 之后(Idx > clearIdx)→ 守卫在清空后求值,仍有效
            $stackGuard = $false
            foreach ($fr in $ifStack) {
                $c = [string]$fr.Cond
                $frValid = ($clearIdx -lt 0) -or ([int]$fr.Idx -gt $clearIdx)
                if (-not $frValid) { continue }
                $hasNotInit = ($c -match ('NOT\s+@?' + $esc + '\s*(\[\s*\])?\s+IS\s+INITIAL\b'))
                $hasPos = $false; $hasZero = $false
                if ($c -match ('@?' + $esc + '\s*(\[\s*\])?\s+IS\s+NOT\s+INITIAL\b')) { $hasPos = $true }
                if ($c -match ('LINES\s*\(\s*@?' + $esc + '\s*\)\s*(?:>|>=|GT|GE)\s*(?:0|1)\b')) { $hasPos = $true }
                foreach ($v in $descVars) {
                    $ve = [regex]::Escape($v)
                    if (($c -match ('\b@?' + $ve + '\s*(?:>|>=|GT|GE)\s*(?:0|1)\b')) -or ($c -match ('\b@?' + $ve + '\s*(?:<>|NE)\s*0\b'))) { $hasPos = $true }
                    if (($c -match ('\b@?' + $ve + '\s*(?:=|<=|EQ|LE)\s*0\b')) -or ($c -match ('\b@?' + $ve + '\s+IS\s+INITIAL\b'))) { $hasZero = $true }
                }
                if ($fr.Branch -eq 'THEN') {
                    if (($c -notmatch '\bOR\b') -and ($hasPos -or $hasNotInit)) { $stackGuard = $true }
                }
                else {
                    if (($c -notmatch '\bAND\b') -and (-not $hasNotInit) -and (($c -match ('@?' + $esc + '\s*(\[\s*\])?\s+IS\s+INITIAL\b')) -or ($c -match ('LINES\s*\(\s*@?' + $esc + '\s*\)\s*(?:=|<=|EQ|LE)\s*0\b')) -or $hasZero)) { $stackGuard = $true }
                }
            }
            # LOOP AT itab 帧守卫:空表循环体零次执行,FAE 根本到不了(天然安全,不受 CLEAR 失效影响)
            $loopGuard = $false
            foreach ($lf in $loopStack) { if ($lf.Kind -eq 'LOOP' -and $lf.Itab -eq $itab) { $loopGuard = $true } }
            $hasGuard = $hasGuard -or $stackGuard -or $loopGuard
            $missing = @()
            if (-not $hasGuard) { $missing += 'IS NOT INITIAL 判空守卫' }
            if (-not $hasSort) { $missing += 'SORT BY 排序' }
            elseif ($sortUnspec) { $missing += 'SORT 未指定 BY 字段(建议 BY 条件字段)' }
            if (-not $hasDup) { $missing += 'DELETE ADJACENT DUPLICATES 去重' }
            if ($missing.Count -gt 0) {
                $sev = 'MED'; if (-not $hasGuard) { $sev = 'HIGH' }
                # 修改方向具体化:给可抄语句(判空/SORT BY 条件字段/去重)
                $sg = New-Object System.Collections.Generic.List[string]
                if (-not $hasGuard) { $sg.Add(('在 SELECT 前补:IF {0}[] IS NOT INITIAL.' -f $itab)) }
                if ((-not $hasSort) -or $sortUnspec) {
                    $byF = @($sel.WhereFields | Select-Object -First 3)
                    if ($byF.Count -gt 0) { $sg.Add(('SORT {0} BY {1}.' -f $itab, ($byF -join ' '))) }
                }
                if (-not $hasDup) { $sg.Add(('DELETE ADJACENT DUPLICATES FROM {0}.' -f $itab)) }
                $sug3 = $(if ($sg.Count -gt 0) { ($sg.ToArray() -join ' ') } else { 'FAE 三要素:①先判内表非空(空表 FAE 等于全表扫)②SORT BY 条件字段③DELETE ADJACENT DUPLICATES 去重' })
                [void]$findings.Add(@{
                    Rule = 'G3'; Subtype = 'FAE_MISSING'; Severity = $sev; Tags = @($itab)
                    Line = $st.StartLine; EndLine = $st.EndLine; Routine = $routine
                    Missing = $missing
                    Message = ('FOR ALL ENTRIES IN {0} 缺: {1}' -f $itab, ($missing -join '、'))
                    Suggestion = $sug3
                    Snippet = (Get-Snippet -Lines $Lines -Line $st.StartLine -EndLine $st.EndLine)
                })
            }
        }
    }

    # ---- 关4:同 include 同表 SELECT ≥3 次 ----
    foreach ($t in $tableCounts.Keys) {
        $lns = $tableCounts[$t]
        if ($lns.Count -ge 3) {
            $show = @($lns.ToArray() | Select-Object -First 10)
            [void]$findings.Add(@{
                Rule = 'G4'; Subtype = 'REPEAT_TABLE'; Severity = 'LOW'; Tags = @($t)
                Line = $show[0]; EndLine = 0; Routine = ''
                Message = ('表 {0} 在本 include 内被 SELECT {1} 次(第 {2} 行)' -f $t, $lns.Count, ($show -join '/'))
                Suggestion = '同表多次取数建议合并:扩 WHERE 一次取全 / FOR ALL ENTRIES / 缓存到内表复用'
                Snippet = ''
            })
        }
    }

    # ---- 关5:聚合下推建议(advisory) ----
    foreach ($fs in $fullScanTargets) {
        $hit = $null
        foreach ($lw in $loopWhereList) { if ($lw.Itab -eq $fs.Itab -and $lw.Routine -eq $fs.Routine -and $lw.HasWhere) { $hit = $lw; break } }
        if ($hit) {
            [void]$findings.Add(@{
                Rule = 'G5'; Subtype = 'FILTER_IN_LOOP'; Severity = 'LOW'; Tags = @($fs.Itab)
                Line = $fs.Line; EndLine = 0; Routine = $fs.Routine
                Message = ('第 {0} 行无 WHERE 全取到内表 {1},第 {2} 行起又 LOOP AT … WHERE 过滤 → 建议把过滤条件下推到 WHERE' -f $fs.Line, $fs.Itab, $hit.Line)
                Suggestion = '过滤条件下推 WHERE / 改聚合函数(COUNT/SUM/GROUP BY)在 DB 层完成'
                Snippet = ''
            })
            continue
        }
        foreach ($d in $describeList) {
            if ($d.Itab -eq $fs.Itab -and $d.Routine -eq $fs.Routine) {
                [void]$findings.Add(@{
                    Rule = 'G5'; Subtype = 'COUNT_LOCAL'; Severity = 'LOW'; Tags = @($fs.Itab)
                    Line = $fs.Line; EndLine = 0; Routine = $fs.Routine
                    Message = ('第 {0} 行全取内表 {1} 后仅 DESCRIBE LINES 计数 → 建议 SELECT COUNT(*)' -f $fs.Line, $fs.Itab)
                    Suggestion = '改 SELECT COUNT(*) FROM … WHERE …,行数统计不下载数据'
                    Snippet = ''
                })
                break
            }
        }
    }
    if ($atBreakList.Count -gt 0 -or $collectList.Count -gt 0) {
        $first = $(if ($atBreakList.Count -gt 0) { $atBreakList[0] } else { $collectList[0] })
        [void]$findings.Add(@{
            Rule = 'G5'; Subtype = 'AGG_IN_APP'; Severity = 'LOW'; Tags = @()
            Line = $first.Line; EndLine = 0; Routine = $first.Routine
            Message = ('检测到应用层聚合(AT {0} {1} 处/COLLECT {2} 处)→ 建议下推 DB 聚合' -f $(if ($atBreakList.Count -gt 0) { $atBreakList[0].What } else { '—' }), $atBreakList.Count, $collectList.Count)
            Suggestion = 'SUM/COUNT/GROUP BY 在 SELECT 里完成,减少内表搬运'
            Snippet = ''
        })
    }

    # ---- L0-L2:同例程报错文案雷同(同文案+条件字段签名不同 → 疑复制粘贴漏改,LOW) ----
    # 过短/无 CJK 文案无判别意义;Sig 空(顶帧无条件或无条件字段)不参与,防合法的通用报错互咬
    $msgGroups = @{}
    foreach ($mr in $msgRecords) {
        if ((Get-CjkCore ([string]$mr.MsgText)).Length -lt 4) { continue }
        $gk = ('{0}|{1}' -f $mr.Routine, $mr.MsgText)
        if (-not $msgGroups.ContainsKey($gk)) { $msgGroups[$gk] = New-Object System.Collections.Generic.List[object] }
        [void]$msgGroups[$gk].Add($mr)
    }
    foreach ($gk in $msgGroups.Keys) {
        $grp = $msgGroups[$gk]
        if ($grp.Count -lt 2) { continue }
        $sigs = @(); $lines = @()
        foreach ($mr2 in $grp) {
            if (-not $mr2.Sig) { continue }
            if ($sigs -notcontains $mr2.Sig) { $sigs += $mr2.Sig }
            $lines += [int]$mr2.Line
        }
        if ($sigs.Count -ge 2) {
            $lnShow = @($lines | Sort-Object | Select-Object -First 6)
            [void]$findings.Add(@{
                Rule = 'L0'; Subtype = 'MSG_DUP'; Severity = 'LOW'; Tags = @()
                Line = $lnShow[0]; EndLine = 0; Routine = $grp[0].Routine
                Message = ('报错文案「{0}」在第 {1} 行等 {2} 个分支重复但条件字段不同({3}),疑复制粘贴漏改' -f $grp[0].MsgText, ($lnShow -join '/'), $grp.Count, ($sigs -join ' vs '))
                Suggestion = '逐分支核对文案与被校验字段是否对应'
                Snippet = ''
            })
        }
    }

    $distinct = @($tableCounts.Keys | Sort-Object)
    $stats.anomalies = $anomalies   # int 快照陷阱:循环里 ++ 过,回填再入 hashtable
    return @{
        Include = $IncludeName; Findings = $findings.ToArray(); Audit = $audit.ToArray()
        Stats = $stats; DistinctTables = $distinct; Anomalies = $anomalies
        LogicSuspects = $logicSuspects.ToArray(); MsgSites = $msgRecords.Count
        VarTypes = $varTypes   # 本 include 的 DATA/TABLES 声明(Complete 家族级合并:TOP 声明喂到使用 include)
    }
}

# ============ 6. L0 判定核心:CJK 核心提取 + 2-gram 语义重叠(纯文本,离线可单测) ============
# 通用词剔除表(长词在前,防部分剥离残留):是否/只能/必输 这类词在字段描述与报错文案里
# 都高频出现,不剔会把「是否海外投入 vs 是否远期收益」误判为有重叠
$script:SapMsgGenericVocab = @(
    '不能为空', '不能为初始', '不为空', '不能', '是否', '只能为', '只能', '必须', '必输', '必填',
    '不合法', '不存在', '已存在', '存在', '不正确', '正确', '不允许', '允许', '无效', '非法',
    '失败', '成功', '异常', '错误', '请输入', '请传入', '请选择', '输入', '传入', '传值', '传输',
    '选择', '格式', '参数', '字段', '标志', '标识', '需要', '该', '此', '请', '值'
)
function Get-CjkCore {
    param([string]$Text)
    foreach ($v in $script:SapMsgGenericVocab) { $Text = $Text.Replace($v, '') }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if ($c -ge 0x4E00 -and $c -le 0x9FFF) { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}
# 真值=疑似错位:两侧 CJK 核心都 ≥2 字且 2-gram 零共享(有一处共享即认为语义相关,不报)
function Test-MsgLabelMismatch {
    param([string]$Label, [string]$Msg)
    $lc = Get-CjkCore $Label; $mc = Get-CjkCore $Msg
    if ($lc.Length -lt 2 -or $mc.Length -lt 2) { return $false }
    $mg = @()
    for ($i = 0; $i -lt $mc.Length - 1; $i++) { $mg += $mc.Substring($i, 2) }
    for ($i = 0; $i -lt $lc.Length - 1; $i++) { if ($mg -contains $lc.Substring($i, 2)) { return $false } }
    return $true
}

# ============ 7. 关2 终判 + 报告组装 ============
function Complete-AbapSqlLint {
    param([object[]]$FactsList, [hashtable]$TableIndex, [string]$Program,
        [hashtable]$FieldLabels = @{}, [hashtable]$VarTypes = @{})

    $limit = @(
        '不跟踪 PERFORM/METHOD 调用:循环内经子程序间接执行的 SELECT 不会被发现',
        '宏(DEFINE…END-OF-DEFINITION)不展开,宏体内 SQL 不分析',
        'EXEC SQL / ADBC / 原生 SQL 不在本工具范围',
        'WHERE 含子查询的语句仅标「待人工评审」,不做索引命中判定',
        '动态要素(动态表/动态 WHERE)标 UNKNOWN:不误报、也不放行',
        'IN s_matnr 等 SELECT-OPTION 条件视为无法判定,不计入索引命中',
        '索引命中按「条件字段覆盖索引最左前缀」判断存在性,不校验操作符强弱,≠性能达标',
        '跨 include 不联动:FAE 三要素写在其他 include 会被判缺失(宁误报不漏报)',
        '冒号链语句不展开;SELECT: 链式查询跳过并计数',
        '视图按其 DDIC 主键判定;WITH…AS/CDS 内部访问路径不识别',
        'FETCH NEXT CURSOR 循环内属扩展检查(MED),非五关原文',
        '行首 * 一律按注释:跨行续写且下一行以 * 起始的表达式会误判(极罕见)',
        'FAE 守卫识别:IF 栈帧/DESCRIBE 计数变量为文本近似,条件含顶层 OR(THEN)/AND(ELSE) 或 CASE 分支时不判守卫',
        '守卫回看遇 CLEAR/REFRESH/FREE 清空目标内表后,更早的守卫不再放行(LOOP AT 体内除外)',
        'L0 逻辑检查仅覆盖 var-field 形态条件+字面量报错文案:变量类型来自源码 DATA/TABLES 声明与函数接口参数,解析不到即跳过不误报;MESSAGE 编号形态(消息类)不取 T100',
        'L0 字段↔文案比对为通用词剔除+2-gram 启发式,「无语义重叠」仅代表疑似错位,需人工确认',
        'L0 同例程文案雷同按「同文案+条件字段签名不同」判定,合法的相似分支校验可能误报(LOW)'
    )

    $allFindings = New-Object System.Collections.Generic.List[object]
    $allAudit = New-Object System.Collections.Generic.List[object]
    $allTables = New-Object System.Collections.Generic.List[string]
    $stats = @{ statementCount = 0; selectCount = 0; openCursorCount = 0; fetchCursorCount = 0; selectInLoop = 0
        faeSites = 0; chainedSelectsSkipped = 0; anomalies = 0; includeCount = $FactsList.Count
        repeatTableHints = 0; truncatedPerRule = @{}; bySeverity = @{} }
    $g2Skipped = 0
    $l0 = @{ suspects = 0; noType = 0; noLabel = 0; flagged = 0; msgSites = 0 }
    # L0 类型家族级合并:全局量常声明在 TOP include、使用在 UXX include,单 include 视角必漏(10-10 某结构 实爆)
    $familyTypes = @{}
    foreach ($f in $FactsList) {
        foreach ($kv in @($f.VarTypes.Keys)) { if (-not $familyTypes.ContainsKey($kv)) { $familyTypes[$kv] = [string]$f.VarTypes[$kv] } }
    }
    foreach ($f in $FactsList) {
        $stats.statementCount += $f.Stats.statementCount
        $stats.selectCount += $f.Stats.selectCount
        $stats.openCursorCount += $f.Stats.openCursorCount
        $stats.fetchCursorCount += $f.Stats.fetchCursorCount
        $stats.selectInLoop += $f.Stats.selectInLoop
        $stats.faeSites += $f.Stats.faeSites
        $stats.chainedSelectsSkipped += $f.Stats.chainedSelectsSkipped
        $stats.anomalies += $f.Stats.anomalies
        foreach ($fd in $f.Findings) {
            $fd.Include = $f.Include
            [void]$allFindings.Add($fd)
        }
        foreach ($au in $f.Audit) { [void]$allAudit.Add($au) }
        foreach ($t in $f.DistinctTables) { if ($allTables -notcontains $t) { [void]$allTables.Add($t) } }

        # ---- L0-L1:字段 DDIC 描述 ↔ 报错文案 语义错位(标签由路由注入,引擎保持离线可单测) ----
        # 变量类型三级来源:引擎源码声明 → 路由注入的函数接口参数(VarTypes)→ 解析不到跳过不误报
        $l0.msgSites += [int]$f.MsgSites
        foreach ($sp in @($f.LogicSuspects)) {
            $l0.suspects++
            $typ = [string]$sp.Type
            if (-not $typ -and $familyTypes.ContainsKey([string]$sp.Var)) { $typ = [string]$familyTypes[[string]$sp.Var] }
            if (-not $typ -and $VarTypes.ContainsKey([string]$sp.Var)) { $typ = [string]$VarTypes[[string]$sp.Var] }
            # 组件级直判:'组-组件'→'表-字段'(DATA BEGIN OF 块内 LIKE 表-字段 的老式声明,10-10 ZFI 实爆补)
            $lbl = ''
            if (-not $typ -or $typ -match '-') {
                $ck = ('{0}-{1}' -f $sp.Var, $sp.Field)
                $cv = ''
                if ($familyTypes.ContainsKey($ck)) { $cv = [string]$familyTypes[$ck] }
                elseif ($VarTypes.ContainsKey($ck)) { $cv = [string]$VarTypes[$ck] }
                if ($cv -match '^-?[\w\/]+-[\w\/]+$') { $cvSeg = $cv.Split('-'); $lk2 = ('{0}|{1}' -f $cvSeg[0], $cvSeg[$cvSeg.Count - 1]); if ($FieldLabels.ContainsKey($lk2)) { $lbl = [string]$FieldLabels[$lk2] } }
            }
            if (-not $lbl) {
                if (-not $typ) { $l0.noType++; continue }
                $lk = ('{0}|{1}' -f $typ, $sp.Field)
                if ($FieldLabels.ContainsKey($lk)) { $lbl = [string]$FieldLabels[$lk] }
                if (-not $lbl) { $l0.noLabel++; continue }
            }
            if (Test-MsgLabelMismatch -Label $lbl -Msg ([string]$sp.MsgText)) {
                $l0.flagged++
                [void]$allFindings.Add(@{ Rule = 'L0'; Subtype = 'MSG_FIELD_MISMATCH'; Severity = 'MED'; Tags = @([string]$sp.Field)
                    Line = $sp.MsgLine; EndLine = $sp.Line; Include = $f.Include; Routine = $sp.Routine
                    Message = ('第 {0} 行报错文案「{1}」与第 {2} 行校验字段 {3}-{4}(DDIC:「{5}」)无语义重叠,疑文案错位' -f $sp.MsgLine, $sp.MsgText, $sp.Line, $sp.Var, $sp.Field, $lbl)
                    Suggestion = '核对报错文案与被校验字段是否对应(常见:复制报错模板漏改文字);若文案正确请忽略'
                    Snippet = [string]$sp.Snippet })
            }
        }
    }
    $stats.l0 = $l0

    # ---- 关2 终判 ----
    $cap = 15
    $g2High = 0; $g2Med = 0
    foreach ($au in $allAudit) {
        $g2 = @{ Status = 'NA'; MatchedIndex = ''; Note = '' }
        if ($au.TableStatus -ne 'static') {
            $g2.Status = 'UNKNOWN'; $g2.Note = '动态表,无法判定'
        }
        elseif ($au.WhereStatus -eq 'dynamic') { $g2.Status = 'UNKNOWN'; $g2.Note = '动态 WHERE,无法判定' }
        elseif ($au.WhereStatus -eq 'subquery') { $g2.Status = 'REVIEW'; $g2.Note = 'WHERE 含子查询,待人工评审' }
        elseif ($au.WhereStatus -eq 'seltab') { $g2.Status = 'SELTAB'; $g2.Note = '含 SELECT-OPTION 条件,范围可全可空,不判定' }
        elseif ($au.WhereStatus -eq 'none' -or $au.HasFullTableScan) {
            $g2.Status = 'FULL_SCAN'; $g2.Note = '无有效 WHERE,全表扫描'
            $g2Med++
            $sugG2 = '补 WHERE 收窄到业务键;确需全表考虑分块或确认表体量'
            if (@($au.Tables).Count -gt 0 -and $TableIndex -and $TableIndex.ContainsKey([string]$au.Tables[0])) {
                $hint = Get-IndexHint -Ti $TableIndex[[string]$au.Tables[0]] -Fields @()
                if ($hint) { $sugG2 = ('表 {0} 主键为{1};建议 WHERE 至少覆盖主键最左前缀(MANDT 隐式带出可省,自 {2} 起)' -f $au.Tables[0], $hint.Pk, $hint.PkNoMandt) }
            }
            [void]$allFindings.Add(@{ Rule = 'G2'; Subtype = 'FULL_TABLE_SCAN'; Severity = 'MED'; Tags = @($au.Tables[0])
                Line = $au.Line; EndLine = $au.EndLine; Include = $au.Include; Routine = $au.Routine
                Message = ('{0} {1} 无有效 WHERE,全表扫描' -f $au.Kind, ($au.Tables -join '+'))
                Suggestion = $sugG2
                Snippet = '' })
        }
        elseif (@($au.Tables).Count -eq 0) { $g2.Status = 'NA'; $g2.Note = 'FROM 片段未解析出表名' }
        elseif ($allTables.Count -gt 0 -and $TableIndex) {
            $hit = $null; $metaMissing = $false
            foreach ($t in $au.Tables) {
                $ti = $null
                if ($TableIndex.ContainsKey($t)) { $ti = $TableIndex[$t] }
                if (-not $ti) { $metaMissing = $true; $g2.Status = 'NA'; $g2.Note = '表索引元数据未取到(超上限或查询失败)'; continue }
                $flds = @($au.WhereFields | ForEach-Object { $_ })
                $best = Get-IndexHit -Ti $ti -Fields $flds -WeakFields @($au.WeakFields | Where-Object { $_ })
                if ($best) { if (-not $hit -or $best.K -gt $hit.K) { $hit = $best } }
            }
            if ($hit) {
                $g2.Status = $(if ($hit.Name -eq 'PRIMARY KEY') { 'PK' } else { 'INDEX' })
                $g2.MatchedIndex = ('{0}({1}字段前缀)' -f $hit.Name, $hit.K)
                $g2.Note = ('条件字段 {0} 命中 {1}' -f (($au.WhereFields | Select-Object -First 6) -join ','), $hit.Name)
            }
            elseif (-not $metaMissing) {   # 修复:表缺索引元数据时保持 NA,不再被 MISS 覆盖(此前超缓存上限的表被假报 INDEX_MISS)
                $g2.Status = 'MISS'; $g2.Note = '条件字段未命中任何主键/二级索引前缀'
                $missSev = 'MED'; if ($au.IsSelectSingle) { $missSev = 'LOW' } else { $g2Med++ }   # SELECT SINGLE 量级小,未命中降为建议
                $sugG2 = '按主键或二级索引最左前缀补条件;确认该表索引设计'
                if (@($au.Tables).Count -gt 0 -and $TableIndex.ContainsKey([string]$au.Tables[0])) {
                    $hint = Get-IndexHint -Ti $TableIndex[[string]$au.Tables[0]] -Fields @($au.WhereFields)
                    if ($hint -and ($hint.Shared -ge 1) -and $hint.Next) {
                        $sugG2 = ('表 {0} 主键为{1};条件字段与{2}{3}共享 {4} 字段最接近,建议补 WHERE 前缀字段 {5}' -f $au.Tables[0], $hint.Pk, $hint.IxName, $hint.IxFields, $hint.Shared, $hint.Next)
                    }
                    elseif ($hint) {
                        $sugG2 = ('表 {0} 主键为{1};建议 WHERE 至少覆盖主键最左前缀(自 {2} 起)' -f $au.Tables[0], $hint.Pk, $hint.PkNoMandt)
                    }
                }
                [void]$allFindings.Add(@{ Rule = 'G2'; Subtype = 'INDEX_MISS'; Severity = $missSev; Tags = @($au.Tables[0])
                    Line = $au.Line; EndLine = $au.EndLine; Include = $au.Include; Routine = $au.Routine
                    Message = ('{0} {1} WHERE({2})未命中主键/二级索引前缀' -f $au.Kind, ($au.Tables -join '+'), (($au.WhereFields | Select-Object -First 6) -join ','))
                    Suggestion = $sugG2
                    Snippet = '' })
            }
        }
        if ($g2.Status -eq 'NA' -and -not $g2.Note) { $g2Skipped++ }
        $au.G2 = $g2
    }

    # ---- 封顶与去重(severity 优先:HIGH>MED>LOW → 行号 → include,截断先保高危) ----
    $seen = @{}
    $deduped = New-Object System.Collections.Generic.List[object]
    $perRule = @{}
    $totalCap = 100
    $sevRank = @{ HIGH = 0; MED = 1; LOW = 2 }
    foreach ($fd in ($allFindings.ToArray() | Sort-Object -Property @(
        @{ e = { $r = 9; if ($sevRank.ContainsKey([string]$_.Severity)) { $r = $sevRank[[string]$_.Severity] }; $r } },
        @{ e = { [int]$_.Line } },
        @{ e = { [string]$_.Include } }))) {
        $key = ('{0}|{1}|{2}|{3}' -f $fd.Include, $fd.Rule, $fd.Line, $fd.Subtype)
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = 1
        $c = 0; if ($perRule.ContainsKey($fd.Rule)) { $c = $perRule[$fd.Rule] }
        if ($c -ge 20) {
            $stats.truncatedPerRule[$fd.Rule] = [int]$stats.truncatedPerRule[$fd.Rule] + 1
            continue
        }
        $perRule[$fd.Rule] = $c + 1
        if ($deduped.Count -ge $totalCap) { $stats.truncatedPerRule['TOTAL'] = [int]$stats.truncatedPerRule['TOTAL'] + 1; continue }
        [void]$deduped.Add($fd)
    }

    # ---- severity 计数与五关卡 ----
    $bySev = @{ HIGH = 0; MED = 0; LOW = 0 }
    $ruleSev = @{}
    foreach ($fd in $deduped) {
        $bySev[$fd.Severity]++
        if (-not $ruleSev.ContainsKey($fd.Rule)) { $ruleSev[$fd.Rule] = @{ HIGH = 0; MED = 0; LOW = 0 } }
        $ruleSev[$fd.Rule][$fd.Severity]++
    }
    $stats.bySeverity = $bySev
    $stats.repeatTableHints = [int]$perRule['G4']

    function New-Pass {
        param([string]$Id, [string]$Title, [hashtable]$Sev, [string]$AdviseNote)
        $status = 'PASS'
        if ($Sev.HIGH -gt 0) { $status = 'FAIL' } elseif ($Sev.MED -gt 0) { $status = 'WARN' }
        elseif ($AdviseNote) { $status = 'ADVISE' }
        return @{ id = $Id; title = $Title; status = $status; high = $Sev.HIGH; med = $Sev.MED; low = $Sev.LOW; note = $AdviseNote }
    }
    $zero = @{ HIGH = 0; MED = 0; LOW = 0 }
    $g1s = $zero.Clone(); $g2s = $zero.Clone(); $g3s = $zero.Clone(); $g4s = $zero.Clone(); $g5s = $zero.Clone(); $l0s = $zero.Clone()
    foreach ($pair in @(@('G1', $g1s), @('G2', $g2s), @('G3', $g3s), @('G4', $g4s), @('G5', $g5s), @('L0', $l0s))) {
        if ($ruleSev.ContainsKey($pair[0])) {
            $pair[1].HIGH = $ruleSev[$pair[0]].HIGH
            $pair[1].MED = $ruleSev[$pair[0]].MED
            $pair[1].LOW = $ruleSev[$pair[0]].LOW
        }
    }
    # L0 note:可判/跳过口径如实展示(类型或 DDIC 标签解析不到的组不参与判定)
    $l0Note = $null
    if ($l0.suspects -gt 0) {
        $l0Note = ('文案对 {0} 组:可判 {1},类型解析不到 {2},DDIC 无描述 {3}' -f $l0.suspects, ($l0.suspects - $l0.noType - $l0.noLabel), $l0.noType, $l0.noLabel)
    }
    $passes = @(
        (New-Pass 'L0' '基础逻辑盲区' $l0s $l0Note)
        (New-Pass 'G1' '零循环内SELECT' $g1s $null)
        (New-Pass 'G2' '命中索引' $g2s $(if ($g2Skipped -gt 0) { ($g2Skipped.ToString() + ' 条 SELECT 未判定(表元数据缺)') } else { $null }))
        (New-Pass 'G3' 'FAE三要素' $g3s $null)
        (New-Pass 'G4' '交互次数最小化' $g4s $(if ($g4s.LOW -gt 0) { '存在同表多次取数建议' } else { $null }))
        (New-Pass 'G5' '聚合下推' $g5s $(if ($g5s.LOW -gt 0) { '存在聚合/过滤下推建议' } else { $null }))
    )
    $verdict = 'PASS'; $verdictText = '通过'
    if ($bySev.HIGH -gt 0) { $verdict = 'FAIL'; $verdictText = '不通过' }
    elseif ($bySev.MED -gt 0) { $verdict = 'WARN'; $verdictText = '有条件通过' }
    $summaryParts = New-Object System.Collections.Generic.List[string]
    if ($bySev.HIGH -gt 0) { [void]$summaryParts.Add(('高危 {0} 处' -f $bySev.HIGH)) }
    if ($bySev.MED -gt 0) { [void]$summaryParts.Add(('中等 {0} 处' -f $bySev.MED)) }
    if ($bySev.LOW -gt 0) { [void]$summaryParts.Add(('建议 {0} 处' -f $bySev.LOW)) }
    if ($summaryParts.Count -eq 0) { [void]$summaryParts.Add('未发现五关违规') }

    return [ordered]@{
        tool = 'sql_lint'; program = $Program
        verdict = $verdict; verdictText = $verdictText
        summary = (('发现:' + ($summaryParts.ToArray() -join ',') + '(SELECT {0} 条/语句 {1} 条/include {2} 个)' -f $stats.selectCount, $stats.statementCount, $FactsList.Count))
        passes = $passes
        findings = $deduped.ToArray()
        selectAudit = $allAudit.ToArray()
        stats = $stats
        limitations = $limit
    }
}

# 索引字段归一:pk/idx 元素必须落成字符串数组。历史 ddix 缓存曾有 pk 被写成空对象
# ({}→读回空 Hashtable,@(空Hashtable)=1元素数组而非空数组→.ToUpperInvariant 炸,
# 2026-09-17 ZUTIL_004@DVP 实爆);坏形态一律降级空数组,宁缺毋假。
function Get-IndexFieldNames {
    param($V)
    if ($null -eq $V) { return @() }
    if ($V -is [System.Collections.IDictionary]) { return @() }
    if ($V -is [string]) { return @([string]$V) }
    if ($V -is [System.Collections.IEnumerable]) { return @(@($V) | ForEach-Object { [string]$_ }) }
    return @([string]$V)
}

# 关2 索引命中判定:字段集是否覆盖主键/某二级索引的最左前缀(存在性判断)。
# WeakFields:弱条件字段(<> / NOT IN / 前通配 LIKE 等,索引前缀用不上)→ 视为前缀链断裂
function Get-IndexHit {
    param($Ti, [string[]]$Fields, [string[]]$WeakFields = @())
    $best = $null
    $fset = @{}
    foreach ($f in $Fields) { if ($f) { $fset[[string]$f.ToUpperInvariant()] = 1 } }
    $wset = @{}
    foreach ($w in $WeakFields) { if ($w) { $wset[[string]$w.ToUpperInvariant()] = 1 } }
    $cands = New-Object System.Collections.Generic.List[object]
    [void]$cands.Add(@{ Name = 'PRIMARY KEY'; Fields = (Get-IndexFieldNames $Ti.pk) })
    foreach ($ix in @($Ti.idx)) { [void]$cands.Add(@{ Name = ('索引{0}' -f $ix.n); Fields = (Get-IndexFieldNames $ix.f) }) }
    foreach ($c in $cands) {
        $cf = @($c.Fields)
        # MANDT 由 ABAP 隐式带出,WHERE 不写也视为命中 → 从前缀链剔除
        # 仅剩 MANDT 一个元素时 $cf[1..0]=@($null,'MANDT') 会让下轮 $null.ToUpperInvariant() 炸整场
        # lint(2026-10-14 审查潜伏 BUG);先清空再出循环
        while ($cf.Count -gt 0 -and $cf[0].ToUpperInvariant() -eq 'MANDT') { if ($cf.Count -eq 1) { $cf = @() } else { $cf = @($cf[1..($cf.Count - 1)]) } }
        if ($cf.Count -eq 0) { continue }
        $k = 0
        foreach ($f in $cf) {
            $fu = $f.ToUpperInvariant()
            if ($fset.ContainsKey($fu) -and -not $wset.ContainsKey($fu)) { $k++ } else { break }
        }
        if ($k -ge 1) { if (-not $best -or $k -gt $best.K) { $best = @{ Name = $c.Name; K = $k } } }
    }
    return $best
}

# 关2 修改方向:找与条件字段「最接近」的主键/二级索引(全字段交集最大,平手 PK 优先),
# 返回 @{Pk;PkNoMandt;IxName;IxFields;Shared;Next} 或 $null。Next = MANDT 剥离后前缀链第一个缺失字段
function Get-IndexHint {
    param($Ti, [string[]]$Fields)
    $pkFlds = @()
    if ($Ti) { $pkFlds = Get-IndexFieldNames $Ti.pk }
    if ($pkFlds.Count -eq 0) { return $null }
    $fset = @{}
    foreach ($f in $Fields) { if ($f) { $fset[[string]$f.ToUpperInvariant()] = 1 } }
    $cands = New-Object System.Collections.Generic.List[object]
    [void]$cands.Add(@{ Name = 'PRIMARY KEY'; Fields = $pkFlds })
    foreach ($ix in @($Ti.idx)) { [void]$cands.Add(@{ Name = ('索引{0}' -f $ix.n); Fields = (Get-IndexFieldNames $ix.f) }) }
    $best = $null; $bestShared = -1
    foreach ($c in $cands) {
        $shared = 0
        foreach ($f in @($c.Fields)) { if ($fset.ContainsKey(([string]$f).ToUpperInvariant())) { $shared++ } }
        if ($shared -gt $bestShared) { $bestShared = $shared; $best = $c }
    }
    $cf = @($best.Fields)
    while ($cf.Count -gt 0 -and $cf[0].ToUpperInvariant() -eq 'MANDT') { if ($cf.Count -eq 1) { $cf = @() } else { $cf = @($cf[1..($cf.Count - 1)]) } }   # 单元素 MANDT 清空防 @($null,'MANDT') 炸(同上)
    $next = ''
    foreach ($f in $cf) { if (-not $fset.ContainsKey(([string]$f).ToUpperInvariant())) { $next = [string]$f; break } }
    $pkNoMandt = ''
    foreach ($f in $pkFlds) { if ($f.ToUpperInvariant() -ne 'MANDT') { $pkNoMandt = [string]$f; break } }
    return @{
        Pk = ('({0})' -f ($pkFlds -join ',')); PkNoMandt = $pkNoMandt
        IxName = $best.Name; IxFields = ('({0})' -f (@($best.Fields) -join ','))
        Shared = $bestShared; Next = $next
    }
}
