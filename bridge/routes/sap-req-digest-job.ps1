param([Parameter(Mandatory)][hashtable]$Body)

# sap-req-digest-job - 需求解读异步作业轮询路由(2026-11-03)。
# 薄壳同 sap-test-report-job:done/error 读后即删(结果只送一次)+ 30min GC(_job-poll 统一)。
. (Join-Path $PSScriptRoot '_job-poll.ps1')
return Get-BridgeJobStatus -Body $Body -JobDir (Join-Path $PSScriptRoot '..\..\..\data\bridge\req-digest-jobs')
