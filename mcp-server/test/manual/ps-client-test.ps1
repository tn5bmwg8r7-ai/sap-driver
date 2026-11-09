$ErrorActionPreference = 'Stop'
$pw = [Console]::In.ReadLine()
. (Join-Path (Get-Item (Join-Path $PSScriptRoot '../../../rfc-frontend/RfcCli')).FullName 'Invoke-SapRfc.ps1')
$r = Invoke-SapRfc -Destination DVPTEST -Function ZLILY_DIAG_Q3 `
     -AppServerHost '<DVP_IP>' -SystemNumber '00' -Client '800' `
     -User '<你的SAP用户名>' -Password $pw `
     -Import @{ IV_TABLE = 'EKKO'; IV_MAX_ROWS = '5' } `
     -Tables @{ IT_WHERE = @(@{ TEXT = "EBELN = '0000450001'" }) }
Write-Output ("EV_ROW_COUNT=" + $r.EV_ROW_COUNT)
Write-Output ("EV_RESULT=" + $r.EV_RESULT)
