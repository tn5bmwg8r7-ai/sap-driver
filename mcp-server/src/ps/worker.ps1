# worker.ps1 - long-lived per-system SAP RFC worker (pool mode).
# Reuses the expensive one-time setup (NCo GAC load + Add-Type DConfig compile
# + RegisterDestinationConfiguration) across many exec requests, so hot calls
# only pay the RFC itself (~0.1-0.3s) instead of full cold start (~1.5-2.5s).
# One worker serves ONE system (DConfig public-static + NCo single registration).
#
# Protocol (one JSON line per message; stdout is JSON-only, diagnostics -> stderr):
#   stdin  line 1 INIT : {"system","password","conn":{AppServerHost,SystemNumber,Client,User,Language}}
#   stdout line 1      : {"ready":true,"system"}  OR  {"ready":false,"code","message"}  then exit 1
#   stdin  line N EXEC : {"steps":[{id,function,import,tables}]}   (NO password)
#   stdout line N      : {"ok":true,"system","results":{id:<Invoke-SapRfc object>}}
#   EOF on stdin       : exit 0
#   single-step throw  : results[id]={_error:"..."}   (worker stays alive, loop continues)

$ErrorActionPreference = 'Stop'
try {
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

# Emit one compressed JSON line to stdout and flush immediately.
function Emit($o) {
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Depth 16 -Compress))
    [Console]::Out.Flush()
}

# PSCustomObject (from JSON) -> hashtable (Invoke-SapRfc wants hashtables).
function Convert-ToHashtable($o) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Array]) {
        $arr = @()
        foreach ($i in $o) { $arr += (Convert-ToHashtable $i) }
        return , $arr
    }
    if ($o -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($p in $o.PSObject.Properties) { $ht[$p.Name] = (Convert-ToHashtable $p.Value) }
        return $ht
    }
    return $o
}

# ---------------- INIT ----------------
$initLine = [Console]::In.ReadLine()
if ([string]::IsNullOrWhiteSpace($initLine)) { Emit @{ ready = $false; code = 'NO_INIT' }; exit 1 }
try { $init = $initLine | ConvertFrom-Json }
catch { Emit @{ ready = $false; code = 'BAD_INIT_JSON'; message = $_.Exception.Message }; exit 1 }

$system = ([string]$init.system).Trim().ToUpper()
$conn   = $init.conn
if (-not $system) { Emit @{ ready = $false; code = 'NO_SYSTEM' }; exit 1 }
if (-not $conn -or -not $conn.AppServerHost) { Emit @{ ready = $false; code = 'NO_CONN' }; exit 1 }

$sapBin       = $env:SAP_MCP_BIN
$invokeSapRfc = Join-Path $sapBin 'Invoke-SapRfc.ps1'
if (-not (Test-Path $invokeSapRfc)) {
    Emit @{ ready = $false; code = 'RFC_BRIDGE_MISSING'; message = "Invoke-SapRfc.ps1 missing under SAP_MCP_BIN=$sapBin" }
    exit 1
}

try {
    . $invokeSapRfc   # loads NCo (~0.5s) + Add-Type DConfig (~1s) - ONCE per worker
} catch { Emit @{ ready = $false; code = 'NCO_LOAD_FAILED'; message = $_.Exception.Message }; exit 1 }

# Store conn for Invoke-SapRfc's first-call registration. Invoke-SapRfc owns the
# DConfig statics + RegisterDestinationConfiguration (guarded by its per-process
# $script:_sapRfcDests cache). Calling Register ourselves here would collide
# with that guard on the first exec ("destination configuration already initialized").
$script:_conn = @{
    AppServerHost = [string]$conn.AppServerHost
    SystemNumber  = [string]$conn.SystemNumber
    Client        = [string]$conn.Client
    User          = [string]$conn.User
    Language      = [string]$conn.Language
}

Emit @{ ready = $true; system = $system }

# ---------------- EXEC loop ----------------
# $init.password is reused on every Invoke-SapRfc call: the param is mandatory
# (see Invoke-SapRfc.ps1 password guard) but its value is ignored after the
# first registration. It lives in worker process memory only.
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { exit 0 }                              # stdin EOF -> clean shutdown
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $req = $line | ConvertFrom-Json }
    catch { Emit @{ ok = $false; code = 'BAD_EXEC_JSON'; message = $_.Exception.Message }; continue }

    $results = [ordered]@{}
    foreach ($s in @($req.steps)) {
        $sid = [string]$s.id
        try {
            $importHt = Convert-ToHashtable $s.import
            $tablesHt = Convert-ToHashtable $s.tables
            $r = Invoke-SapRfc -Destination $system -Function ([string]$s.function) `
                  -Import $importHt -Tables $tablesHt @script:_conn -Password $init.password
            $results[$sid] = $r
        } catch {
            $msg = $_.Exception.Message
            if ($_.Exception.InnerException) { $msg = "$msg | $($_.Exception.InnerException.Message)" }
            $results[$sid] = [pscustomobject]@{ _error = $msg }   # don't kill the worker
        }
    }
    Emit @{ ok = $true; system = $system; results = $results }
}
