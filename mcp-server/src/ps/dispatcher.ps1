# dispatcher.ps1 - generic multi-step SAP RFC executor (no business logic).
#
# stdin  (one JSON line, contains password — NEVER log/echo this): {
#   "system": "QAS",
#   "password": "...",
#   "steps": [ { "id":"step1", "function":"RFC_READ_TABLE",
#                "import":{...}, "tables":{ "OPTIONS":[ {"TEXT":"..."} ], "FIELDS":[ {"FIELDNAME":"..."} ] } } ]
# }
# stdout (one JSON line): { "ok":true, "system":"QAS", "results":{ "step1": <Invoke-SapRfc object> } }
#                     or   { "ok":false, "code":"...", "message":"..." }
#
# One process serves ONE system. This sidesteps the DConfig public-static field +
# single NCo RegisterDestinationConfiguration (a long-lived process cannot reliably
# serve multiple envs). Node-side governance decides what to call; this only runs it.

$ErrorActionPreference = 'Stop'
try {
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding           = [System.Text.Encoding]::UTF8
} catch {}

# --- helpers: PSCustomObject (from JSON) -> hashtable (Invoke-SapRfc wants hashtables) ---
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

function Fail([string]$code, [string]$message) {
    $e = [ordered]@{ ok = $false; code = $code; message = $message }
    $e | ConvertTo-Json -Depth 6 -Compress
    exit 1
}

# --- read stdin (single JSON line) ---
$line = [Console]::In.ReadLine()
if ([string]::IsNullOrWhiteSpace($line)) { Fail 'NO_STDIN' 'dispatcher got no stdin input' }
try { $req = $line | ConvertFrom-Json }
catch { Fail 'BAD_STDIN_JSON' "stdin is not valid JSON: $($_.Exception.Message)" }

$system   = ([string]$req.system).Trim().ToUpper()
$password = [string]$req.password
$steps    = @($req.steps)

if (-not $system)    { Fail 'NO_SYSTEM' 'system is required' }
if (-not $password)  { Fail 'NO_PASSWORD' 'password is required (memory-only, never persisted)' }
if ($steps.Count -eq 0) { Fail 'NO_STEPS' 'at least one step is required' }

# --- load systems.json + RFC bridge ---
$systemsFile = $env:SAP_MCP_SYSTEMS
$sapBin      = $env:SAP_MCP_BIN
if (-not $systemsFile -or -not (Test-Path $systemsFile)) { Fail 'SYSTEMS_FILE_MISSING' "SAP_MCP_SYSTEMS not set or missing: $systemsFile" }
$invokeSapRfc = Join-Path $sapBin 'Invoke-SapRfc.ps1'
if (-not (Test-Path $invokeSapRfc)) { Fail 'RFC_BRIDGE_MISSING' "Invoke-SapRfc.ps1 missing under SAP_MCP_BIN=$sapBin" }

try { $systems = Get-Content $systemsFile -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Fail 'SYSTEMS_BAD_JSON' "systems.json parse failed: $($_.Exception.Message)" }

. $invokeSapRfc   # defines Invoke-SapRfc

if (-not $systems.envs.$system) { Fail 'UNKNOWN_SYSTEM' "system $system not in systems.json envs" }
$cfg = $systems.envs.$system
# NOTE: Destination is NOT in this hashtable — it is passed explicitly on the
# Invoke-SapRfc call below. Putting it here too makes @conn splat a second
# -Destination, which PowerShell rejects as "parameter specified more than once".
$conn = @{
    AppServerHost = [string]$cfg.appServerHost
    SystemNumber  = [string]$cfg.systemNumber
    Client        = [string]$cfg.client
    User          = [string]$cfg.user
    Language      = [string]$cfg.language
}
# Client/User/Language override from sap_connect wins over systems.json.
$clientOverride = [string]$req.client
if ($clientOverride -match '^\d{3}$') { $conn['Client'] = $clientOverride }
$userOverride = [string]$req.user
if ($userOverride) { $conn['User'] = $userOverride }
$languageOverride = [string]$req.language
if ($languageOverride) { $conn['Language'] = $languageOverride }

# --- run each step serially (one process = one env => single registration is safe) ---
$results = [ordered]@{}
foreach ($s in $steps) {
    $sid = [string]$s.id
    try {
        $importHt = Convert-ToHashtable $s.import
        $tablesHt = Convert-ToHashtable $s.tables
        $r = Invoke-SapRfc -Destination $system -Function ([string]$s.function) `
              -Import $importHt -Tables $tablesHt @conn -Password $password
        $results[$sid] = $r
    } catch {
        $msg = $_.Exception.Message
        # NCo/RFC often nests the real reason in InnerException
        if ($_.Exception.InnerException) { $msg = "$msg | $($_.Exception.InnerException.Message)" }
        $results[$sid] = [pscustomobject]@{ _error = $msg }
    }
}

$out = [ordered]@{ ok = $true; system = $system; results = $results }
$out | ConvertTo-Json -Depth 16 -Compress
