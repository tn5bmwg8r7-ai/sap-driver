param([Parameter(Mandatory)][hashtable]$Body)

# ============================================================
# sap-req-digest - 需求文档解读 dispatcher(2026-11-03,方案2,PROMANT思路落地)。
#   输入:文档/文件夹路径(Word docx / 图片文件夹 / 单图)+ 一句话需求(可选)
#   动作:后台 worker 逐图视觉识别(glm-5.3-flash 智谱 anthropic 端点,2026-11-03 实测
#         真实收图;原生端点 429 资源包用尽不可用)+ 文本抽取 → 生成 requirement-brief.md
#   落点:产物目录(env SAP_ARTIFACT_DOCS,缺省=仓库 data/artifacts)/req-digest/YYYY-MMDD-<slug>/requirement-brief.md
#         (用户定案:与接口文档/测试文档同款固定路径,产物页签可见)
#   为什么异步:逐图 AI 调用 ~4-12s/张,几十张图几分钟 = bridge 单线程会冻死 PW
#         (sap-test-report/qa-from-chat 同款教训)。dispatcher 秒回 jobId,前端轮询。
# 红线:只读输入文件;产物只写上述固定目录;不碰 SAP;无密码参与(纯本地+视觉通道)。
# ============================================================

$in = $Body.input
$op = if ($in -and $in.op) { [string]$in.op } else { 'start' }
# 09-29 同款仓库相对定位(d68f2c 教训:硬编码绝对路径仓库一挪静默分家)
$jobDir = Join-Path $PSScriptRoot '..\..\..\data\bridge\req-digest-jobs'
. (Join-Path $PSScriptRoot '_job-dispatch.ps1')

switch ($op) {

  'start' {
    $srcPath = ''
    if ($in -and $in.srcPath) { $srcPath = ([string]$in.srcPath).Trim() }
    if (-not $srcPath) {
      return @{ ok = $false; error = @{ code = 'NEED_PATH'; message = '请填写文档或文件夹路径(Word .docx / 图片文件夹 / 单张图片)。' } }
    }
    if (-not (Test-Path -LiteralPath $srcPath)) {
      return @{ ok = $false; error = @{ code = 'PATH_NOT_FOUND'; message = "路径不存在:$srcPath" } }
    }
    $item = Get-Item -LiteralPath $srcPath
    $isDir = $item.PSIsContainer
    # 输入合法性预检:目录须含至少一张图;文件须 docx 或图片
    if ($isDir) {
      $imgCount = @(Get-ChildItem -LiteralPath $srcPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.(png|jpe?g|gif|webp|bmp)$' }).Count
      if ($imgCount -eq 0) {
        return @{ ok = $false; error = @{ code = 'NO_IMAGES'; message = "文件夹里没有图片文件(png/jpg/gif/webp/bmp):$srcPath" } }
      }
    } else {
      if ($item.Extension -notmatch '^\.(docx|png|jpe?g|gif|webp|bmp)$') {
        return @{ ok = $false; error = @{ code = 'BAD_TYPE'; message = "仅支持 .docx(Word 自动解包内嵌图)或图片文件;收到:$($item.Extension)。老式 .doc 请先另存为 .docx。" } }
      }
    }
    $requirement = ''
    if ($in.requirement) { $requirement = [string]$in.requirement }
    if ($requirement.Length -gt 2000) { $requirement = $requirement.Substring(0, 2000) }
    # 预算上限:逐图调用真金白银,默认 40 张封顶(实测大文档够用;不够再说)
    $maxImages = 40
    if ($in.maxImages) {
      [void][int]::TryParse([string]$in.maxImages, [ref]$maxImages)
    }
    if ($maxImages -lt 1) { $maxImages = 1 } ; if ($maxImages -gt 100) { $maxImages = 100 }

    if (-not (Test-Path $jobDir)) { New-Item -ItemType Directory -Force -Path $jobDir | Out-Null }
    $job = New-BridgeJob -JobDir $jobDir -InitialPayload @{
      op   = 'digest'
      input = @{ srcPath = $srcPath; requirement = $requirement; maxImages = $maxImages }
    } -DedupKey ("req-digest:" + $item.FullName)
    if ($job.Duplicate) {
      return @{ ok = $true; result = [ordered]@{
        jobId = $job.JobId; status = 'running'; poll = 'sap-req-digest-job'; duplicate = $true
        hint = "同一路径已有解读在跑($($job.JobId)),已接续原作业,未重复派发" } }
    }
    $worker = Join-Path $PSScriptRoot '..\jobs\sap-req-digest-worker.ps1'
    Start-BridgeJob -WorkerScript $worker -JobId $job.JobId -JobDir $jobDir
    return @{ ok = $true; result = [ordered]@{
      jobId = $job.JobId; status = 'running'; poll = 'sap-req-digest-job'
      hint = "已提交后台解读,前端轮询 sap-req-digest-job 取结果" } }
  }

  default {
    return @{ ok = $false; error = @{ code = 'BAD_OP'; message = "op 须为 start: $op" } }
  }
}
