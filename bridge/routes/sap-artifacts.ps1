param([Parameter(Mandatory)][hashtable]$Body)

# sap-artifacts  -  SAP Driver「📦 产物」页签路由(P2,2026-09-14)。
# 扫已知产物落点(交付物 docx),返回 {name,path,sizeKB,mtime,kind} 供前端列出 +
# 复用既有 file-open 路由打开/定位。设计:
# - 落点写死并与生成方源码同源核对:sap-interface-doc.ps1 的 $docDir(接口文档)、
#   sap-test-report.ps1 的 $docDir(测试文档附件)、sap-req-digest-worker 的 $docRoot
#   (需求解读简报,2026-11-03;该落点按日期子文件夹一层,故对 req-digest 递归一层)。全部
#   目录经 env SAP_ARTIFACT_DOCS / SAP_DELIVERY_ROOT 配置(缺省=仓库 data/ 下)。
# - 只扫顶层非递归(接口/测试/交付三目录交付物都在顶层;数据增长防线)。
#   不读文件内容,纯元数据枚举(接口文档144+测试附件57 实测毫秒级)。
# - 排序全局按 mtime 新→旧,limit 截断(默认 200,上限 500)。

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Fail([string]$code, [string]$message) { return @{ ok = $false; error = @{ code = $code; message = $message } } }

$input_ = $Body.input
$kind = 'all'
$limit = 200
if ($input_) {
  if ($input_.kind) { $kind = ([string]$input_.kind).Trim() }
  if ($input_.limit) { [void][int]::TryParse([string]$input_.limit, [ref]$limit) }
}
if ($limit -lt 1) { $limit = 1 } ; if ($limit -gt 500) { $limit = 500 }

# 产物根目录:env SAP_ARTIFACT_DOCS(文档类总根)可整体覆盖;缺省 = 仓库 data/artifacts/ 下分类子目录
$__artDocs = if ($env:SAP_ARTIFACT_DOCS) { $env:SAP_ARTIFACT_DOCS } else { Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'artifacts' }
$__artData = Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'data') 'delivery'
$roots = @(
  @{ kind = 'interface-doc'; label = '接口文档'; dir = (Join-Path $__artDocs 'interface-doc') },
  @{ kind = 'test-report';   label = '测试报告'; dir = (Join-Path $__artDocs 'test-report') },
  @{ kind = 'delivery';      label = '交付台账'; dir = $__artData },
  @{ kind = 'req-digest';    label = '需求解读'; dir = (Join-Path $__artDocs 'req-digest') }
)
if ($kind -ne 'all') {
  $hit = @($roots | Where-Object { $_.kind -eq $kind })
  if ($hit.Count -eq 0) { return (Fail 'BAD_KIND' "kind 须为 all / interface-doc / test-report / delivery / req-digest: $kind") }
  $roots = $hit
}

# ---------- 枚举(顶层非递归,LiteralPath 防特殊字符) ----------
$all = New-Object System.Collections.Generic.List[object]
$rootStatus = New-Object System.Collections.Generic.List[object]
$total = 0
foreach ($r in $roots) {
  $count = 0
  if (Test-Path -LiteralPath $r.dir -PathType Container) {
    # req-digest 落点按日期子文件夹一层(YYYY-MMDD-<slug>\requirement-brief.md),递归一层收齐
    $scanOpt = if ($r.kind -eq 'req-digest') { 'TopOnlyAndOneLevel' } else { 'TopOnly' }
    $files = @()
    if ($scanOpt -eq 'TopOnly') {
      $files = @(Get-ChildItem -LiteralPath $r.dir -File)
    } else {
      $files = @(Get-ChildItem -LiteralPath $r.dir -File) +
               @(Get-ChildItem -LiteralPath $r.dir -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue })
    }
    foreach ($f in $files) {
      $count++
      # 构造时一次成型 pscustomobject(Sort-Object -Property 对 hashtable 静默失效的已知坑;
      # 不做事后属性赋值,避开 IRM 反序列化 SetValueInvocationException 坑)
      $all.Add([pscustomobject]@{
        name  = [string]$f.Name
        path  = [string]$f.FullName
        sizeKB = [Math]::Round($f.Length / 1KB, 1)
        mtime = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        stamp = $f.LastWriteTime.ToString('yyyyMMddHHmmssfff')   # 稳定排序键(字符串,免强转)
        kind  = $r.kind
        label = $r.label
      })
    }
  }
  $total += $count
  $rootStatus.Add(@{ kind = $r.kind; label = $r.label; dir = $r.dir; exists = (Test-Path -LiteralPath $r.dir); count = $count })
}

# ---------- 全局新→旧排序 + 截断 ----------
$sorted = @($all | Sort-Object -Property stamp -Descending)
$items = New-Object System.Collections.Generic.List[object]
foreach ($it in $sorted) {
  if ($items.Count -ge $limit) { break }
  $items.Add($it)
}

$sw.Stop()
# 房子约定(bridge-client.run 只取 data.result):负载必须嵌在 result 键里
return @{
  ok = $true
  result = [ordered]@{
    kind = $kind; limit = $limit
    items = $items; total = $total; truncated = ($total -gt $items.Count)
    roots = $rootStatus
    elapsedMs = $sw.ElapsedMilliseconds
  }
}
