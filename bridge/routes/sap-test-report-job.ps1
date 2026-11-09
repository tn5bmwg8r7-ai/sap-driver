param([Parameter(Mandatory)][hashtable]$Body)

# ============================================================
# sap-test-report-job  -  SAP test-report async job polling route.
# Thin wrapper over the shared poll implementation (_job-poll.ps1):
# done/error read-and-delete (result delivered once) + 30min GC (time-gated).
# running-stage job files carry no password (worker strips + rewrites on
# start); this route never returns input fields.
# 2026-08-31: body consolidated with qa-chat-job / action-run-job.
# ============================================================

. (Join-Path $PSScriptRoot '_job-poll.ps1')
# 09-29 小项:原硬编码仓库绝对路径(d686f2c 同款雷),仓库一挪 poll/dispatch 静默分家——
# 与 dispatch 侧(sap-test-report.ps1:19)同款仓库相对形态
return Get-BridgeJobStatus -Body $Body -JobDir (Join-Path $PSScriptRoot '..\..\..\data\bridge\sap-test-jobs')
