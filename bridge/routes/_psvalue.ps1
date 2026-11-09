# ============================================================
# _psvalue.ps1 - shared accessors for the IDictionary | PSCustomObject duality.
# Why both shapes exist: bridge request bodies arrive as HASHTABLES
# (Start-Bridge.ps1 Read-RequestBody -> ConvertTo-BridgeHashtable; dot access
# works but .PSObject.Properties does NOT enumerate entries), while job files
# re-read via ConvertFrom-Json arrive as PSCustomObject. Routes and workers
# therefore need both - keep ONE implementation (was 2 copies with drifted
# missing-key semantics: '' vs $null, 2026-08-31 adversarial review).
# ============================================================

function Get-ValueByKey {
  param($Obj, [string]$Key, $Default = $null)
  if ($null -eq $Obj) { return $Default }
  if ($Obj -is [System.Collections.IDictionary]) {
    foreach ($k in @($Obj.Keys)) {
      if ([string]$k -ieq $Key) { return $Obj[$k] }
    }
    return $Default
  }
  $p = $Obj.PSObject.Properties[$Key]
  if ($p) { return $p.Value }
  return $Default
}

function Remove-ValueByKey {
  param($Obj, [string]$Key)
  if ($null -eq $Obj) { return }
  if ($Obj -is [System.Collections.IDictionary]) {
    foreach ($k in @($Obj.Keys)) {
      if ([string]$k -ieq $Key) { $Obj.Remove($k); return }
    }
    return
  }
  $p = $Obj.PSObject.Properties[$Key]
  if ($p) { $Obj.PSObject.Properties.Remove($Key) }
}

# PSCustomObject/嵌套数组 -> hashtable 深转换,2026-08-31 整合(此前 4 份逐字近似副本:
# Start-Bridge.ps1 / ppt-selfcheck.ps1 / ppt-diagnose.ps1(ConvertTo-BridgeHashtable2)/
# sap-test-report-worker.ps1(ConvertTo-HtDeep))。Invoke-SapRfc -Tables 行、job 载荷等
# 要求 hashtable/.Keys 形态时用。IDictionary 原样深拷贝,IList 出数组,标量原样返回。
function ConvertTo-BridgeHashtable {
  param($Obj)
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    $h = @{}
    foreach ($k in @($Obj.Keys)) { $h[[string]$k] = ConvertTo-BridgeHashtable $Obj[$k] }
    return $h
  }
  if ($Obj -is [System.Collections.IList] -or
      ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string] -and $Obj -isnot [pscustomobject])) {
    $arr = @()
    foreach ($e in @($Obj)) { $arr += , (ConvertTo-BridgeHashtable $e) }
    return $arr
  }
  if ($Obj -is [System.Management.Automation.PSCustomObject]) {
    $h = @{}
    foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-BridgeHashtable $p.Value }
    return $h
  }
  return $Obj
}
