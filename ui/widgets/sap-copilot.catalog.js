// sap-copilot.catalog.js — SAPDriver 能力地图(P1,2026-09-14)。
//
// 这是整个Driver的稳定契约:九大分类从第一天定死,后期加能力 = 在对应分类里加一张卡
// (active 亮卡 / planned 灰卡),目录结构与 UI 骨架永不重排——"慢慢填充丰满"只动这份
// 数据,不动代码。对应关系:
//   type:'mcp'      → bridge.run('sap-tool', {tool:id, args}) → facade TOOLS 注册表(治理同源)
//   type:'command'  → runCommand(CommandRegistry.get(ref), {}) → 既有快捷指令,零改动复用
//   type:'builtin'  → 状态条内置交互(连接管理)
//   type:'cc'       → 已交付但执行通道在 Claude Code(写类不走 Driver):带 trigger 触发话术,
//                     点击复制「在 Claude Code 说『…』」;与 planned 灰卡区分,不是规划中
//   type:'planned'  → 蓝图灰卡:点卡片提示规划中,实现后把 type 改成 mcp/command 即点亮
//
// 红线映射:PRD 只读硬闸在 facade/env-policy 同源生效;写类工具(dev_create/dev_delete/
// dev_tr/variant_write)不在 facade 白名单,故意不建亮卡——地图上它们用 cc 卡标「Claude Code」,
// 执行走 sap-build/sap-review/sap-ledger 技能的完整流程(质量闸+LIST 获批)。
export const SAP_CATEGORIES = [
  { id: 'conn', name: '连接状态', icon: '🔌' },
  { id: 'data', name: '数据查询', icon: '🗄️' },
  { id: 'code', name: '代码对象', icon: '📜' },
  { id: 'test', name: '执行测试', icon: '🧪' },
  { id: 'auth', name: '权限治理', icon: '🔐' },
  { id: 'diag', name: '诊断运维', icon: '🚨' },
  { id: 'itf',  name: '接口集成', icon: '🔗' },
  { id: 'doc',  name: '文档产物', icon: '📄' },
  { id: 'ai',   name: 'AI 助手', icon: '🤖' },
];

export const SAP_CATALOG = [
  // ============ 连接状态 ============
  { id: 'sap_connect', cat: 'conn', type: 'builtin', name: '凭证连接管理', icon: '🔑',
    desc: '注入并验证 SAP 凭证(密码仅内存,绝不落盘;断开/桥重启即失效)。入口 = 顶部状态条「🔑 连接管理」。' },
  { id: 'sap_env_status', cat: 'conn', type: 'mcp', name: '系统环境状态', icon: '📡',
    desc: '查看 DVP/QAS/PRD 可达性、凭证缓存、24h 审计调用计数。',
    example: { system: 'DVP' } },
  { id: 'sap_help', cat: 'conn', type: 'mcp', name: 'MCP 工具总览', icon: '🧭',
    desc: '列出全部 SAP MCP 工具、治理规则与选择启发式。不确定用哪个工具时先看它。',
    example: {} },

  // ============ 数据查询 ============
  { id: 'sap_query', cat: 'data', type: 'mcp', name: '读业务表', icon: '🔎',
    desc: '读表数据。WHERE 简单等值/LIKE(拒括号/OR);maxRows 上限 1000。PRD 只读放行。',
    example: { system: 'QAS', table: 'T001', fields: ['BUKRS', 'BUTXT'], maxRows: 10 } },
  { id: 'sap_object_meta', cat: 'data', type: 'mcp', name: 'DDIC 元信息', icon: '📐',
    desc: '表/结构/数据元素:字段目录 + ZZ 域固定值 + 检查表。开发前调研首选。',
    example: { system: 'QAS', object: 'VBAK' } },
  { id: 'sap_column_profile', cat: 'data', type: 'planned', name: '列画像/分布统计', icon: '📊',
    desc: '按列非空率/去重数/GROUP BY 分布,聚合下推到数据库。规划中(P3 蓝图)。' },
  { id: 'sap_ddic_search', cat: 'data', type: 'planned', name: '按描述搜字典', icon: '🔤',
    desc: '"库存批次表" → MCHA 这类模糊检索(DD02T/DD03T 文本搜索)。规划中。' },
  { id: 'sap_export_csv', cat: 'data', type: 'planned', name: '大表本机导出', icon: '📤',
    desc: 'NCo 流式拉取 + keyset 分页,本机落 CSV(不碰服务器)。规划中。' },

  // ============ 代码对象 ============
  { id: 'sap_fm_read', cat: 'code', type: 'mcp', name: '读函数接口+源码', icon: '📖',
    desc: '函数模块签名(importing/exporting/tables)+ ABAP 源码。改前先读。',
    example: { system: 'DVP', function: 'Z_MM_DOC_CREATE' } },
  { id: 'sap_prog_read', cat: 'code', type: 'mcp', name: '读程序/Include 源码', icon: '📄',
    desc: '任意程序/函数 include 源码(REPOSRC 直解,补 fm_read 读不了的)。',
    example: { system: 'DVP', program: 'ZREPORT' } },
  { id: 'sap_variant_read', cat: 'code', type: 'mcp', name: '读 SE37 测试变式', icon: '🎛️',
    desc: '读测试变式入参值(只读)。',
    example: { system: 'DVP', function: 'ZXXX', variant: '999' } },
  { id: 'sap_whereused', cat: 'code', type: 'builtin', name: '影响分析/Where-Used', icon: '🕸️',
    desc: '改字段/改逻辑前先看影响面:被哪些程序引用(WBCROSSGT)按主程序聚合,自定义程序默认展开带中文标题;「看代码」定位引用行(±2 行高亮),「它用了什么」反查程序;支持字段级「表.字段」。入口 = 「🔍 排查」页签「🔗 引用」形态,点这里直达。' },
  { id: 'sap_code_search', cat: 'code', type: 'builtin', name: '代码内容搜索', icon: '🧲',
    desc: '关键字搜进 Z/Y 程序源码内容(如搜 BAPI 名/CALL TRANSACTION/关键字段):程序名模式收窄范围(默认 Z*,可用 ZFIT*),REPOSRC 指纹增量拉源+本地缓存,首建较慢之后秒搜;超 300 程序劝收窄不硬扛。入口 = 「🔍 排查」→「🔗 引用」→「🔍 搜内容」,点这里直达。' },
  { id: 'sap_lint', cat: 'code', type: 'builtin', name: 'SQL 代码质量审查', icon: '📏',
    desc: '填程序/函数/事务码,按五关准则静态把关:零循环内 SELECT / WHERE 命中主键·二级索引(DD03L+DD17S 实查)/ FOR ALL ENTRIES 三要素 / 同表多次取数 / 聚合下推;违规带行号+源码片段,SELECT 逐条审计,能力边界如实声明;结果按源码指纹缓存。入口 = 「🔍 排查」页签「📏 质量审查」形态,点这里直达。' },
  { id: 'sap-build', cat: 'code', type: 'cc', trigger: '开发实施', name: '开发实施', icon: '🛠️',
    desc: '生成 ABAP → 质量闸(ECC7.02 禁用词+SQL 五关,FAIL 一票否决)→ DVP 建 Z/Y 对象+挂 TR(函数/函数组/表全自动,程序半自动)→ 交付自证必附实测数字。写类工具不走 Driver,执行在 Claude Code:说「开发实施/建函数/建表/挂TR」触发(sap-build)。' },

  // ============ 执行测试 ============
  { id: 'sap_fm_exec', cat: 'test', type: 'mcp', name: '执行只读 FM/BAPI', icon: '▶️',
    desc: '看实际返回,复现第三方报文。QAS 放行 Z/Y 自定义函数;PRD 仅 GET 白名单+查询类显式白名单(prd-exec-whitelist.json 热生效);COMMIT/ROLLBACK/TR_ 全局拒。',
    example: { system: 'QAS', function: 'BAPI_MATERIAL_GET_DETAIL', import: { MATERIAL: '100000', PLANT: '1000' } } },
  { id: 'sap_testdata_save', cat: 'test', type: 'mcp', name: '存参数集', icon: '💾',
    desc: '第三方报文/测试参数存为本地参数集,之后 sap_fm_exec 配 paramSet 一键复现。',
    example: { system: 'QAS', function: 'ZXXX', name: 'case48', import: {}, note: '问题现象备注' } },
  { id: 'sap_testdata_load', cat: 'test', type: 'mcp', name: '读参数集', icon: '📂',
    desc: '读取已存参数集完整内容(import/tables/备注)。',
    example: { system: 'QAS', function: 'ZXXX', name: 'case48' } },
  { id: 'sap_testdata_list', cat: 'test', type: 'mcp', name: '列参数集', icon: '🗂️',
    desc: '列出某系统/某函数下已存的全部参数集。',
    example: { system: 'QAS' } },
  { id: 'sap_report_run', cat: 'test', type: 'builtin', name: '程序排查(SUBMIT)', icon: '🧾',
    desc: '报表选择屏幕参数/变式 → RFC 侧 SUBMIT 真跑 → 取回列表定位。仅 Z/Y 自定义报表;PRD 治理层拒。入口 = 「🔍 排查」页签「📊 程序」形态,点这里直达。' },
  { id: 'sap_dev_create', cat: 'test', type: 'cc', trigger: '开发实施', name: '建 Z/Y 对象(写)', icon: '🏗️',
    desc: '新建结构/函数/函数组/源码写入(FUNC/FUNCGROUP 出生即挂 TR)。写类工具不走 Driver;已纳入 Claude Code「🛠️ 开发实施」流程(质量闸把关:列 LIST 获批 → 生成 → 闸 → 建对象 → 自证),说「开发实施/建函数/建表」触发(sap-build)。' },
  { id: 'sap_dev_tr', cat: 'test', type: 'cc', trigger: '开发实施', name: '挂传输请求(写)', icon: '🚚',
    desc: 'Z/Y 对象挂 TR。TR_OBJECT_INSERT 非 RFC 物理必败;自动挂走 Claude Code「🛠️ 开发实施」的 sap_dev_tr_put(TRINT 包装器,支持范围见其类型矩阵),其余 SE10 手工+工单登记。' },

  // ============ 权限治理 ============
  { id: 'auth-ledger-query', cat: 'auth', type: 'command', name: '权限台账查询', icon: '🔍',
    desc: '快捷指令:四模块权限台账查询(本地库,免连 SAP)。' },
  { id: 'auth-ledger-sync', cat: 'auth', type: 'command', name: '权限台账同步', icon: '🔄',
    desc: '快捷指令:从 SAP 同步权限台账(增量+删除哨兵)。' },
  { id: 'sap-auth-request-flow', cat: 'auth', type: 'planned', name: '权限申请单流程', icon: '📝',
    desc: '申请表单 → 台账评估 → BC004 场景匹配 → 授权 → 台账回写 → 通知。规划中(P2,待定纸面流程)。' },
  { id: 'sap-fi-auth-wrapper', cat: 'auth', type: 'planned', name: 'FI 六事务码权限封装', icon: '🏦',
    desc: 'Z_BUKRSL + SUBMIT 方案落地。规划中。' },

  // ============ 诊断运维 ============
  { id: 'sap_diag_pack', cat: 'diag', type: 'builtin', name: '系统体检', icon: '🩺',
    desc: '选系统一键只读巡检:ST22 短 dump 计数(SNAP 近 7 天)/ SM13 更新失败(VBMOD+VBHDR)/ SM12 当前锁与跨天残留(ENQUEUE_READ 内存读)/ 后台作业取消与卡死(TBTCO);单节读不到只标「未判定」不炸报告;📋复制/📄HTML/📊Excel 报告。PRD 可用。入口 = 「🩺 体检」页签,点这里直达。(原「🚑事故应急包」卡 09-16 并入本卡,SM21 系统日志定案放弃。)' },
  { id: 'sap_env_diff', cat: 'diag', type: 'planned', name: '环境对拍', icon: '⚖️',
    desc: '点查已上线 = 「TR 链路跟踪」(传输形态·按对象分析,三系统内容级比对);本卡剩余面查场景 = 全量 Z 系漂移巡检(无锚批量初筛→可疑清单下钻),挂起待场景(月结前/大传输窗口后),暂不规划。' },
  { id: 'sap_tr_status', cat: 'diag', type: 'builtin', name: 'TR 链路跟踪', icon: '🛤️',
    desc: '传输溯源:填**程序/事务码/函数** → 涉及哪些请求(带描述)+ DVP/QAS/PRD 三系统**源码内容级比对**(SHA256,时间戳会被导入重写不可信)是否一致;矩阵带各系统最新请求号;点请求号下钻详情;也支持按请求号/用户查。入口 = 「🔍 排查」页签「🚚 传输」形态,点这里直达。' },
  { id: 'sap_gate', cat: 'diag', type: 'builtin', name: '交付门禁', icon: '🚦',
    desc: '交付顾问测试前的最后一道自动检查(2026-10-14 ZREP002 实战清单固化):G1 传输包(对象清单/脏树/★LIMU↔R3TR 配对——表只挂子对象没挂主对象行=导入必失败)/G2 对象健康(激活态/事务码指向/表激活/上传模板在位)/G3 表↔程序兼容(引用表传没传/字段存在性/表改动晚于程序)/G4 代码质量(五关)/G5 需求覆盖(AI 逐条对照源码找功能缺口+逻辑 bug,选填)。FAIL=修完再交,WARN=人工复核,PASS=放行。入口 = 「🔍 排查」页签「📤 交付门禁」形态,点这里直达。' },
  { id: 'sap_workload', cat: 'diag', type: 'builtin', name: '工作负载周报', icon: '📈',
    desc: '选系统+周期一键生成:每日趋势(步数/对话均响/后台/RFC/更新)/ 任务类型汇总 / TOP 事务码·报表 / TOP 用户 / 对话响应分布;可选 AI 管理视角点评;📋复制/📄HTML/📊Excel 三件套。数据源 = SWNC/SAPWL 只读聚合(历史日缓存,零 SAP 部署);PRD 可用。入口 = 「📈 负载周报」页签,点这里直达。' },

  // ============ 接口集成 ============
  { id: 'sap-probe', cat: 'itf', type: 'builtin', name: 'SAP 排查', icon: '🔍',
    desc: '六形态:🧪函数(报文复现/SE37 变式/参数集)+ 📊程序(SUBMIT 真跑)+ 🔗引用(影响分析:聚合+标题+看代码+内容搜索)+ 🚚传输(TR 状态与对象清单)+ 📏质量审查(SQL 五关把关)+ 📤交付门禁(交付前五段体检)。报错/空结果自动诊断,AI 解读。QAS800 主战场。入口 = 「🔍 排查」页签,点这里直达。' },
  { id: 'sap-interface-doc', cat: 'itf', type: 'command', name: 'SAP 接口文档生成器', icon: '📑',
    desc: '快捷指令:读函数接口自动生成接口文档。' },
  { id: 'sap-interface-diag', cat: 'itf', type: 'command', name: 'SAP 接口定位排查', icon: '🔌',
    desc: '快捷指令:对方贴了接口报错+报文?填函数名+粘贴报文,自动读接口结构、解析报文,(确认后)落 SE37 变式并回读验证,出排查报告。默认预览不写数据;问答里说「接口报错/复现报文」也会推荐此动作。' },
  // sap-read 卡已删(2026-09-18 退役整合 D1):一句话只读能力=本页顶部提问框(sap-ask),不再双入口双治理

  // ============ 文档产物 ============
  { id: 'sap-flow', cat: 'doc', type: 'cc', trigger: '接单', name: '一站式交付', icon: '🚰',
    desc: '交付流水线总调度(sap-flow):接单(可从 BPM 待办捕获单号/传输号/成果程序名)→ 需求评审 → 开发+符合性对照 → 接口文档 → 测试报告,五个人工闸到闸即停。执行在 Claude Code:展开选 BPM 待办(可不选)后点「📋 复制接单话术」,去 CC 粘贴。' },
  { id: 'sap-review', cat: 'doc', type: 'cc', trigger: '需求评审', name: '需求评审', icon: '📋',
    desc: '文字/Word/多文件需求 → 现状只读核实(带证据) → 方案比选+人天+风险 → 评估文档供线下沟通;模板带系统维度,可辐射 MES/SRM/BPM。执行在 Claude Code:说「需求评审/评估一下」触发(sap-review)。' },
  { id: 'sap-req-digest', cat: 'doc', type: 'command', name: '需求文档解读', icon: '🖼️',
    desc: '快捷指令:填 docx/图片文件夹路径,后台逐图视觉识别(glm-5.3-flash)转文字,生成纯文本 requirement-brief.md 落 产物目录。带图大文档不再塞会话防超长;新会话读简报即可继续。产物见「📦 产物」页签「需求解读」类目。' },
  { id: 'sap-delivery', cat: 'doc', type: 'cc', trigger: '新建工单', name: '交付台账', icon: '🗂️',
    desc: '需求全生命周期工单库(需求评审→开发实施→接口文档→测试文档),每单一目录+delivery.json 状态机。库在 data/delivery(可用 SAP_DELIVERY_ROOT 改向);Claude Code 说「新建工单/交付台账」管理(sap-ledger);产物终稿见「📦 产物中心」。' },
  { id: 'sap-test-report', cat: 'doc', type: 'command', name: 'SAP 测试报告生成器', icon: '🧾',
    desc: '快捷指令:FM 全链路真跑测试并出报告(GUI 通道/文件场景支持)。产物落本地。' },
  { id: 'sap-artifacts', cat: 'doc', type: 'builtin', name: '产物中心', icon: '📦',
    desc: '接口文档/测试报告等本地产物一览,一键打开/定位。入口 = 「📦 产物」页签,点这里直达。' },
  { id: 'sap-user-manual', cat: 'doc', type: 'planned', name: '用户手册同步生成', icon: '📚',
    desc: '程序 → 操作手册(Word 同步)。规划中。' },

  // ============ AI 助手 ============
  { id: 'sap_deepseek', cat: 'ai', type: 'mcp', name: '敏感数据内网分析', icon: '🛡️',
    desc: '薪酬/绩效等敏感数据走公司内网 DeepSeek,真值不进 AI 上下文,只回脱敏结论。',
    example: { system: 'PRD', table: 'PA0008', intent: '分析薪酬分布找异常' } },
  { id: 'sap-copilot-chat', cat: 'ai', type: 'builtin', name: '综合问答(Agent 编排)', icon: '💭',
    desc: '一句话 → Agent 规划 → 自动编排工具串行执行 → 带证据结论。入口 = 「Agent Harness」主页。' },
];
