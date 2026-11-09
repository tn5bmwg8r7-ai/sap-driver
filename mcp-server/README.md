# SAP MCP Server(SAP Driver 的 MCP 层)

本机 MCP(Model Context Protocol)服务器:让 Claude 等 MCP 客户端通过 RFC 直接读/诊断 SAP 系统(开发/测试/生产三环境),带强治理。

> 本目录是 [sap-driver](../README.md) 仓库的 MCP 层,源自作者自用的 sap-mcp 项目,开源时做了配置外置与脱敏。

## 能做什么

- 把 SAP 读/诊断动作暴露成 MCP 工具,Claude 直接调用(日常读取不再走慢速的 SE16N/SE37 GUI 桥)。
- 三环境治理:**开发机**(读 + 只读 FM 执行)、**测试机**(读 + 仅 GET 类 FM)、**生产机**(只读,镜像测试机治理——仅 GET 类 FM;一切写操作禁止,多层锁死)。
- 所有调用走 环境锁 → 操作类别 → FM 白/黑名单 检查;全量 JSONL 审计;密码仅内存(绝不落盘)。

## 工具清单(19 个 —— 读 + 开发 CRUD + 变式读写)

**读/诊断(13)**

| 工具 | 类别 | 环境 | 用途 |
|---|---|---|---|
| `sap_connect` | meta | 三环境 | 注入+验证凭证(ping `STFC_CONNECTION`),缓存进内存 |
| `sap_deepseek` | read | 三环境 | 敏感数据分析外送(进程内拉真值→外部 LLM→只回脱敏结论) |
| `sap_env_status` | read | 三环境 | 可达性 + 凭证缓存 + 24h 审计计数 |
| `sap_help` | read | 三环境 | 静态工具目录 + 意图启发 |
| `sap_query` | read | 三环境 | 读表——**自动探测 `ZLILY_DIAG_Q3`(二层引擎,无512截断,支持括号/OR完整WHERE);回退 `RFC_READ_TABLE`**(见下注) |
| `sap_object_meta` | read | 三环境 | 表/结构/数据元素 DDIC 元信息(`DDIF_FIELDINFO_GET` + 域固定值) |
| `sap_fm_read` | read | 三环境 | 函数接口 + 源码(`FUNCTION_IMPORT_INTERFACE` + `RPY_FUNCTIONMODULE_READ`) |
| `sap_fm_exec` | exec-readonly | 开发(任意只读FM)/测试·生产(仅GET白名单) | 跑一个只读 FM,返回 EXPORT/TABLES + 消息 |
| `sap_testdata_save` / `sap_testdata_load` / `sap_testdata_list` | read | 三环境 | 本地参数集(变式替代)——存一份报文经 `sap_fm_exec paramSet` 秒级复现 |
| `sap_prog_read` | read | 三环境 | 读任意程序/include/函数 include 源码(直读 REPOSRC 解压;绕开 RPY `S_DEVELOP`) |
| `sap_variant_read` | read | 三环境 | 把 SE37 测试变式入参读成 JSON——Node 读接口 → 拼 GENERATE SUBROUTINE POOL 源码 → `ZLILY_DIAG_GEN_EXEC` 执行 `IMPORT FROM EUFUNC` + ZCL_JSON |
| `sap_variant_write` | **写** | 开发/测试 | **把一份报文覆盖写进 SE37 已注册变式的簇**(FT-form 策略):用户先在 SE37 建空变式 → 本工具读 FT 源码(`ZLILY_DIAG_UNPACK`)→ GENERATE FT + 设 `%_I`* 值 + 调 FT 自己的 `EXPORT_IMPORT('IO')` + UPDATE AUTOR → `ZLILY_DIAG_GEN_EXEC` 执行 |

**开发/CRUD(4,仅开发机)—— Z/Y 命名空间双层硬护栏**

| 工具 | 类别 | 环境 | 用途 |
|---|---|---|---|
| `sap_dev_create` | dev-write | 仅开发机 | 建 Z/Y TABL/FUNC/FUNCGROUP(`RPY_FUNCTIONMODULE_INSERT`/`RS_FUNCTION_POOL_INSERT`/`DDIF_TABL_PUT` 包装);`SOURCE_UPDATE` 就地改已建 Z/Y 源码(函数→自动解析 include;程序→直写),底层 `ZLILY_DIAG_SRC_PUT8`(本地 `INSERT REPORT`)。每次调用必传 TR+包 |
| `sap_dev_delete` | dev-write | 仅开发机 | 删 Z/Y 函数模块(`ZLILY_DIAG_DEL` → 本地 `FUNCTION_DELETE`)。**硬规则:每次删除必须先经用户确认**(不可逆)。标准程序/增强硬拒绝 |
| `sap_dev_tr` | dev-write | 仅开发机 | 把已有 Z/Y 对象挂到传输请求(`TR_OBJECT_INSERT`) |
| `sap_dev_tr_put` | dev-write | 仅开发机 | 经 `ZLILY_DEV_TR_PUT` 包装器挂对象,以包装器内置 E071 实查终判 |

## 二层查询引擎 `ZLILY_DIAG_Q3`

`sap_query` 的真正引擎是部署在 SAP 侧的 RFC `ZLILY_DIAG_Q3`(函数组 `ZFG_LILY_DIAG4`)。它执行 `SELECT * FROM (table) WHERE (动态)` 并序列化成 JSON STRING——同时绕开 `RFC_READ_TABLE` 的 512 字符截断和 WHERE 限制。

> **`RFC_READ_TABLE` 在加固过的系统上基本不可用。** SAP 加固(Note 1469041 一类)会让它对所有表抛 `TABLE_NOT_AVAILABLE`——连 `T000`/`MARA` 都不行。`ZLILY_DIAG_Q3`(直接 SELECT)是唯一可靠读径,这就是它存在的原因。`sap_query` 里的 `RFC_READ_TABLE` 回退路径实际处于备用状态。

## 架构

```
Claude(MCP 客户端, stdio JSON-RPC)
  └─ Node MCP 服务器(src/server.js,常驻,x64)
       └─ 每次工具调用: spawn powershell.exe -File dispatcher.ps1
            └─ stdin: {system, password, steps:[{function, import, tables}...]}
            └─ dot-source rfc-frontend/Invoke-SapRfc.ps1(NCo 3.1)
            └─ 一个进程跑完全部步骤(一环境一进程 = 规避 DConfig 静态陷阱)
            └─ stdout: {ok, results:{stepId:...}}
```

- **常驻 worker 池**(`src/ps/workerpool.js`——每环境一个长驻 PS worker):每环境首次调用付一次性开销(NCo GAC 加载 + `Add-Type` DConfig 编译 + destination 注册 + 首次 TCP,约 1.5-2.5s);后续调用只跑 RFC(约 0.1-0.3s)。同环境串行队列,跨环境并行。worker 任一步失败自动回退 spawn-per-call;设 **`SAP_MCP_POOL=0`** 强制走老路。一环境一 worker 正是绕开 `DConfig` 静态字段 + NCo 单次注册约束的关键。
- **时延**:冷 ~1.5-2.5s(worker 初始化),热 ~0.1-0.3s(纯 RFC)。
- **密码**:工具入参 → Node 内存 Map → dispatcher stdin → `Invoke-SapRfc -Password`。绝不进命令行参数(tasklist 可见)、绝不落盘、绝不进日志(审计清洗器剥离凭证键)。

## 首次配置

1. `npm install`(依赖 `@modelcontextprotocol/sdk`)。
2. `cp systems.example.json systems.json`,填你的三环境 IP/实例号/客户端/用户名。**密码绝不写这里**——每次会话经 `sap_connect` 注入。
3. 需要 PowerShell 侧 RFC 前端:见仓库 `rfc-frontend/README.md`(NCo 3.1 DLL 自行下载 + GAC 注册)。
4. 在 MCP 客户端(如 Claude Code 的 `.claude.json`)注册:
   ```json
   "sap": {
     "command": "powershell.exe",
     "args": ["-NoProfile","-ExecutionPolicy","Bypass","-File","<本仓路径>\\mcp-server\\Start-SapMcp.ps1"],
     "env": {
       "SAP_MCP_NODE": "<node.exe 路径,需 Node ≥ 20>",
       "SAP_MCP_SERVER": "<本仓路径>\\mcp-server\\src\\server.js",
       "SAP_MCP_SYSTEMS": "<本仓路径>\\mcp-server\\systems.json",
       "SAP_MCP_AUDIT_DIR": "<审计 JSONL 落盘目录>",
       "SAP_MCP_BIN": "<含 Invoke-SapRfc.ps1 的目录,即本仓 rfc-frontend/RfcCli>"
     },
     "type": "stdio"
   }
   ```
5. 重启 MCP 客户端,`/mcp` → `sap` 应显示已连接。
6. 每会话首次使用:`sap_connect({system:'QAS', password:'…'})`(密码仅内存)。

### HTTP facade 模式(给 PW bridge 这类 HTTP 消费方)

除 stdio 外还提供 HTTP facade(`src/http-facade.js`,只绑 127.0.0.1 + Bearer):

```bash
cp facade.local.example.json facade.local.json
# 生成 64 位随机 hex token(PowerShell):
#   -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })
# 写进 facade.local.json 的 token 字段
```

启动:`wscript Start-SapFacade.vbs`(隐藏窗口)或 `node src/http-facade.js`。

## 治理配置

`systems.json` —— 环境(不含密码)、QAS GET 白名单 + 正则(测试/生产共用)、FM 黑名单、审计目录/保留期、`RFC_READ_TABLE` 限额。`prdEnabled:true` 打开**只读生产**(镜像测试机治理:同一 GET 白名单在 `fm-check.js` 强制;写工具保持仅开发/测试,多层锁死)。

`prd-exec-whitelist.json` —— 生产机额外放行的执行类白名单(现值是作者环境的报表族 FM,按需增删,每次调用现读改完即生效)。

## 排障

- **`/mcp` 连不上**:检查 `SAP_MCP_NODE` 路径;手工跑 `Start-SapMcp.ps1` 看报错。
- **`NEED_CREDENTIAL`**:先调 `sap_connect`(每会话每环境一次)。
- **`FM_NOT_ALLOWED_ON_QAS`**:该 FM 不在测试机 GET 白名单;只读。开发机放行任意只读 FM。
- **`FM_NOT_ALLOWED_ON_PRD`**:该 FM 不在测试/生产共用 GET 白名单;只读。

## Status / roadmap

- **Layer 1(MCP + 19 工具)**——完成。读/诊断(13,含 `sap_prog_read` + `sap_variant_read`) + 开发 CRUD(4:建/删/挂TR×2,仅开发机)。
- **Layer 2**——`ZLILY_DIAG_Q3` 查询引擎(无512截断,完整WHERE)双环境部署可用;`ZLILY_DIAG_GEN_EXEC`(变式解码) + `ZLILY_DIAG_SRC_PUT8`(远端 Z/Y 源码修改)双环境部署可用。
- **`sap_variant_read`**——可用(2026-07-31 修复):`buildGenSource` 修了三层根因——IMPORT 对象名是 `%_I`+参数名(SAP 生成的 `<func>=======FT` 测试框架揭示)、tables 行类型是 `DBSTRUCT || TYP`、簇键 `NUMMER` 在 CHAR30 里必须右对齐到**第 29 位**(SAP 第 30 位留空——普通右对齐会差 1 字节)。
- **PRD 只读(2026-07-31)**——启用:`prdEnabled:true` + `fm-check.js` 共用测试机 GET 白名单;写工具(开发 CRUD + `sap_variant_write`)仅开发/测试,多层锁死。

### 已知 SAP 侧远端 ABAP 边界(血泪换来的)

可远端(RFC-enabled):`RPY_FUNCTIONMODULE_INSERT`、`RS_FUNCTION_POOL_INSERT`、`DDIF_FIELDINFO_GET`、`FUNCTION_IMPORT_INTERFACE`、`RPY_FUNCTIONMODULE_READ`、`RFC_READ_TABLE`(存在但被加固 → 没用)。**不可**远端:改源码(`RPY_PROGRAM_UPDATE`)、删(`FUNCTION_DELETE`)、挂 TR(`TR_OBJECT_INSERT`)、建 DDIC(`DDIF_TABL_PUT`——而且无状态 RFC 本就持久不了 DDIC 创建)。⇒ 远端建 ABAP 必须一次写对(无预览、无编辑、无删除);出错污染系统只能靠 GUI(SE37/SE80/SE09)清理。
