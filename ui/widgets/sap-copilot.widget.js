import { WidgetRegistry } from '../registry/widget-registry.js';
import { CommandRegistry } from '../registry/command-registry.js';
import { runCommand } from '../shell/command-runner.js';
import { showToast } from '../shell/toast.js';
import { esc, escAttr } from '../shell/html-utils.js';
import { copyRich, copyText, downloadHtml, downloadJson, downloadText, downloadXlsx, safeFilename, todayStamp } from '../shell/export-utils.js';
import { markdownToDocumentHtml } from '../shell/md-document.js';
import { dingtalkFriendly } from '../shell/dingtalk-text.js';
import { renderMarkdown } from '../shell/markdown-renderer.js';
import { bridge } from '../shell/bridge-client.js';
import { todos } from '../dal/repositories/todos.js';
import { SAP_CATEGORIES, SAP_CATALOG } from './sap-copilot.catalog.js';

// 本地 toast 便捷壳:位置参数 → 共享 options 形式。2026-09-15 实爆:widget 内 65 处
// 位置调用直打共享 showToast({msg}),字符串被解构得 msg=undefined → toast 全空白,
// 用户点了操作没有任何可见反馈(「产物打开/定位不灵敏」体感的另一半来源)。
const _toast = (msg, type = 'info') => showToast({ msg: String(msg ?? ''), type });

// 视觉样式外置拆分批一(2026-10-30):STYLES 全量迁 sap-copilot.styles.js,原地搬运零改动。
import { STYLES } from './sap-copilot.styles.js?v=20261104e';   // ?v 破缓存(2026-11-04 Edge 模块缓存实爆)
// 排查/体检/负载周报三页签方法体外置拆分批一(2026-10-30):class mixin 原地搬运,
// 方法挂 SapCopilotWidget.prototype,共享符号经 bindSapShared 注入(见下方装配段)。
import { SapProbeMethods, bindSapShared as bindProbeShared } from './sap-copilot-probe.js';
import { SapDiagpkMethods, bindSapShared as bindDiagpkShared } from './sap-copilot-diagpk.js';
import { SapWkMethods, bindSapShared as bindWkShared } from './sap-copilot-wk.js';
// 拆分批二(2026-11-03):Agent智能体(ask)与 产物+Trace时间线(art)同款 mixin。
import { SapAskMethods, bindSapShared as bindAskShared } from './sap-copilot-ask.js';
import { SapArtMethods, bindSapShared as bindArtShared } from './sap-copilot-art.js';
// 拆分批三(2026-11-03,收官):Skill地图(catalog)同款 mixin。
import { SapCatalogMethods, bindSapShared as bindCatalogShared } from './sap-copilot-catalog.js';
// 🚰 交付驾驶舱页签(2026-11-04 P1,设计方案-v2-融合.md):工单卡/节点条/检查动作。
import { SapFlowMethods, bindFlowShared, FlowStore } from './sap-flow.widget.js?v=20261104e';   // ?v 缓存爆破:Edge 对 module 的启发式缓存攥旧文件,改名 URL 强制拉新(2026-11-04 Console 无[flow]定位)

const PRESETS = [
  { q: '你现在能用哪些工具?各自适合什么场景', sys: 'DVP' },
  { q: '帮我看看 DVP 上 Z_MM_DOC_CREATE 的函数接口和源码,讲下它做什么', sys: 'DVP' },
  { q: 'QAS 的 T001 表里前 10 行有哪些公司代码和名称', sys: 'QAS' },
  { q: 'VBAK 的字段目录和域固定值,挑关键字段讲讲', sys: 'QAS' },
];

// v12 引用影响分析:OTYPE 中文映射 + include→主程序归组(与 sap-xref.ps1 Get-MainName 同规则)。
// OTYPE 未列出的代码原样显示(SAP 内部值,悬停见说明),不瞎编。
const XREF_OTYPE = { TY: '类型', DA: '数据', FU: '函数', ME: '方法', FR: 'FORM', EV: '事件', CL: '类', IN: '接口', TT: '表类型', MS: '消息' };
const XREF_SUBC = { 1: '报表', M: '模块池', F: '函数组', S: '子程序池', I: 'Include', K: '类池', J: '接口池', C: '类' };
const XREF_OTYPE_TIP = 'TY=类型引用(DATA lv TYPE mara-matnr)· DA=数据对象 · FU=函数调用 · ME=方法 · FR=FORM 例程;未列出的为 SAP 内部代码原样显示';
const _xrefOt = (t) => { const k = String(t || '').trim().toUpperCase(); return XREF_OTYPE[k] || (k || '?'); };
function _xrefMainOf(inc) {
  const s = String(inc || '').toUpperCase();
  let m;
  if ((m = s.match(/^L(.+?)(?:UXX|(?:F|O|I|E|U|D|P|S|V|X)\d\d|TOP)$/))) return 'SAPL' + m[1];
  if ((m = s.match(/^(.+?)(?:TOP|(?:F|O|I|E|D|P|S)\d\d)$/))) return m[1];
  if ((m = s.match(/^([A-Z][A-Z0-9_/]*?)=+/))) return m[1];
  return s;
}
const _xrefIsCustom = (main) => /^[ZY]/.test(main) || main.startsWith('/NSP/') || (main.startsWith('SAPL') && /^[ZY]/.test(main.slice(4)));

// 传输形态(v11)状态/类型/结论中文映射——原在 renderProbe 内联两份,收敛到这里供渲染与导出共用。
const TRD_STATUS = { D: '可修改', R: '已释放', O: '释放已启动', L: '导入中?', N: '已导入(升级)' };
const TRD_FUNC = { K: '工作请求', S: '定制请求', W: '未分类', T: '传输' };
const TRD_SEV = {
  missing: ['✗ 未传', 'var(--sd-danger-text)'], diff: ['⚠ 不一致', 'var(--sd-warning-text)'],
  cosmetic: ['≈ 仅注释差异', 'var(--sd-text-faint)'], same: ['✓ 一致', 'var(--sd-success-text)'],
  unverified: ['⟳ 无法比对', 'var(--sd-warning-text)'], unchecked: ['· 未详查', 'var(--sd-text-faint)'],
};
const TRD_SEV_TEXT = { missing: '✗ 未传', diff: '⚠ 不一致', cosmetic: '≈ 仅注释差异', same: '✓ 一致', unverified: '⟳ 无法比对', unchecked: '· 未详查' };

// 导出时间戳(收敛 10 处 toLocaleString 同款)
const _nowStamp = () => new Date().toLocaleString('zh-CN', { hour12: false });

// 模块级会话 store(2026-09-14):切走本 widget 时 shell 会清空 DOM 销毁实例、切回重建
// (与 宿主问答组件 QA_STORE 同款机制)——问答结论/时间线/产物/多轮历史全部
// 放这里,切回来结果还在;执行中的 ask 不中断,完成后数据照常落 store。
// 勾选类偏好(autoDiag/autoExplain)跨刷新记忆:localStorage 读写,按钮动作时落盘。
const SAPC_PREFS_KEY = 'pw:sap-copilot:prefs';
const _sapcPrefs = (() => { try { return JSON.parse(localStorage.getItem(SAPC_PREFS_KEY)) || {}; } catch { return {}; } })();
function p_last_clear(p) {
  p.execRes = null; p.lastErr = null; p.diag = null; p.conv = null;
  p.xrefRes = null; p.searchRes = null; p.trRes = null; p.trListRes = null;
  p.usesRes = null; p.xrefOpen = {}; p.xrefCode = {}; p.xrefFilter = 'all'; p.xrefQ = ''; p.xrefLimit = 30; p.objTrRes = null;
  p.expectRes = null; p.confirmReq = null; p.repStatus = null;
  p.lintRes = null;   // v14 五关Lint结果
  p.lintAiRes = null; p.lintAiBusy = false;   // v16 AI 深审随形态清空
  p.gateRes = null;   // v19 交付门禁结果(五段检查)
  p.contentRes = null;   // v14 内容搜索结果
}
function _saveSapcPrefs(p) {
  try { localStorage.setItem(SAPC_PREFS_KEY, JSON.stringify({ autoDiag: !!p.autoDiag, autoExplain: !!p.autoExplain, probeKind: p.kind || 'fm', probeSys: p.sysByKind || {}, defaultTab: p.defaultTab || '' })); } catch { /* 隐私模式等只读场景静默 */ }
}
// Driver 默认页签(2026-11-04 用户需求:设置-外观可选,默认打开交付页签)。
// 存储=appearance(sapCopilotDefaultTab,设置里下拉改)>localStorage 记忆(切页签自动记)>
// 默认 ask。三层回退,设置里选了就永远以设置为准。
const SAPC_TABS = ['ask', 'flow', 'probe', 'diagpk', 'wk', 'artifacts', 'catalog', 'timeline'];
const SAPC_APPEARANCE_KEY = 'pw:appearance';   // skey('appearance')(appearance.js KEY 同源;此处直字面量避免循环依赖)
function _resolveDefaultTab() {
  try {
    const a = JSON.parse(localStorage.getItem(SAPC_APPEARANCE_KEY) || '{}');
    if (SAPC_TABS.includes(a.sapCopilotDefaultTab)) return a.sapCopilotDefaultTab;
  } catch { /* appearance 解析失败走记忆 */ }
  try {
    const t = JSON.parse(localStorage.getItem(SAPC_PREFS_KEY) || '{}').lastTab;
    if (SAPC_TABS.includes(t)) return t;
  } catch { /* 记忆解析失败走默认 */ }
  return 'ask';
}
// v15.1 各形态默认系统(用户定案 2026-09-16):函数/程序=QAS(接口报文主战场),
// 引用/传输/质量审查=DVP(Z 系对象主场,请求历史最全);体检页签独立默认 PRD(生产健康巡检)。
// 记忆口径:某形态里手动换过系统就按形态记住(prefs.probeSys),没动过=始终默认。
const PROBE_SYS_DEFAULT = { fm: 'QAS', report: 'QAS', xref: 'DVP', tr: 'DVP', lint: 'DVP', gate: 'DVP' };   // v19 交付门禁默认 DVP(交付核验主战场)
const SAPC_STORE = {
  status: null, statusLoading: false,
  connectOpen: false, connecting: null,
  tab: _resolveDefaultTab(),   // 2026-11-04:设置-外观可配 sapCopilotDefaultTab;无配置则记忆上次页签
  diagpk: { sys: 'PRD', running: false, res: null, err: null },   // v14 体检页签状态(v15.1 默认 PRD,用户定案)
  wk: { sys: 'PRD', gran: 'week', mode: 'last', baseSel: 'auto', res: null, running: false, err: null,
        commenting: false, comment: null, commentErr: null, mailing: false },   // v17 周报V2:周/月+任意对比期;AI 解读默认自动生成;✉存草稿不发送
  asking: false, askData: null, openStep: null, askPhase: null, askCallId: null,
  expandedId: null, toolRunning: null,
  timeline: null, timelineLoading: false,
  artifacts: null, artifactsLoading: false, artifactsKind: 'all', artifactsQ: '',
  recent: null,          // Agent Harness主页「今日动态」条(最近 8 条,静默加载)
  rounds: [], roundIdx: -1,   // v6 轮次存档:全部完整结论可回看;roundIdx=当前轮索引(-1=无)
  results: new Map(), argsTexts: new Map(), qText: '', qSys: 'DVP',
  // v7 函数排查(确定性链,零 AI):报文复现 / SE37 变式载入 / 参数集 / 一次执行。
  // form 的值在按钮动作时统一从 DOM 回读(_captureProbeForm,同 _captureArgs 模式)。
  probe: {
    sys: 'QAS', fm: '', variant: '',
    sysByKind: {},   // v15.1 各形态手动选过的系统(按形态记忆;初始按 kind 默认,见 store 初始化后两行)
    kind: ['report', 'xref', 'tr', 'lint', 'gate'].includes(_sapcPrefs.probeKind) ? _sapcPrefs.probeKind : 'fm',   // v9/v10/v19 排查对象:fm / report / xref / tr / lint / gate(v14 白名单化;v19 加交付门禁)
    reportSig: null,    // v9 report 选择屏幕参数清单 [{SELNAME,KIND,SIGN,OPTION,LOW,HIGH}](表单单一真值源)
    xrefSearching: false, xrefRes: null, searchRes: null,   // v10 引用查询结果
    usesRes: null,                             // v12「它用了什么」反查结果
    xrefOpen: {}, xrefCode: {},                // v12 主程序展开态 / include 源码定位缓存
    xrefFilter: 'all', xrefQ: '', xrefLimit: 30,   // v12 筛选(全部/自定义/标准)+ 过滤词 + 显示上限
    trRes: null, trListRes: null,   // v11 传输查询结果
    objTrRes: null,                 // v13 按对象传输溯源结果
    sigLoading: false, sig: null,       // fm_read 接口(生成空表单依据)
    form: { import: {}, tables: {} },   // 当前表单值(import 标量;tables 行数组)
    payloadText: '',                    // 报文 JSON 粘贴框
    sets: null, setsLoading: false, setName: '',
    execLoading: false, execRes: null, execMs: 0, lastErr: null,
    expectKw: '', expectMin: '',   // v12 定点排查期望:关键字(逗号分隔)/最少行数
    expectRes: null,               // v12 期望比对结果 {ok, reasons[]}
    confirmReq: null,              // v12 PRD 逐次确认 {loading}|{riskLevel,risks}|{err}
    repStatus: null,               // v12 RUNNING 接力轮询 {jobname,jobcount,tries}
    conv: null,              // 内外码转换报告(applied/skipped),v8
    autoDiag: _sapcPrefs.autoDiag !== false,   // 报错/空结果自动诊断(默认开,记忆上次选择)
    diag: null, diagCallId: null,   // 诊断状态:{running,text}|{result}|{error}
    autoExplain: _sapcPrefs.autoExplain === true,   // 📐 接口解读(默认关,记忆上次选择)
    explain: null, explainLoading: false,
    lintRes: null,              // v14 五关Lint结果(指纹缓存,route 侧)
    lintAiRes: null, lintAiBusy: false,   // v16 AI 语义深审(不走缓存,每次点击新判断)
    contentRes: null,           // v14 代码内容搜索结果
    gateRes: null,              // v19 交付门禁结果(五段检查;route 侧缓存)
    gateReq: '',                // v19 需求要点 textarea(会话内保持,不落 prefs)
  },
};

// v15.1 形态默认系统:初始 kind 还原后,sys 对齐该形态的默认(或记忆的手选值)
SAPC_STORE.probe.sysByKind = _sapcPrefs.probeSys && typeof _sapcPrefs.probeSys === 'object' ? _sapcPrefs.probeSys : {};
SAPC_STORE.probe.sys = SAPC_STORE.probe.sysByKind[SAPC_STORE.probe.kind] || PROBE_SYS_DEFAULT[SAPC_STORE.probe.kind] || 'QAS';

class SapCopilotWidget {
  constructor(root) {
    this.root = root;
    this._pollTimer = null;   // 实例级:unmount 即清,切回时按 askCallId 重启
  }
  // 实例字段 → 模块级 store 代理(getter/setter,引用处零改动)
  get status() { return SAPC_STORE.status; }                       set status(v) { SAPC_STORE.status = v; }
  get statusLoading() { return SAPC_STORE.statusLoading; }         set statusLoading(v) { SAPC_STORE.statusLoading = v; }
  get connectOpen() { return SAPC_STORE.connectOpen; }             set connectOpen(v) { SAPC_STORE.connectOpen = v; }
  get connecting() { return SAPC_STORE.connecting; }               set connecting(v) { SAPC_STORE.connecting = v; }
  get tab() { return SAPC_STORE.tab; }                             set tab(v) { SAPC_STORE.tab = v; }
  get asking() { return SAPC_STORE.asking; }                       set asking(v) { SAPC_STORE.asking = v; }
  get askData() { return SAPC_STORE.askData; }                     set askData(v) { SAPC_STORE.askData = v; }
  get openStep() { return SAPC_STORE.openStep; }                   set openStep(v) { SAPC_STORE.openStep = v; }
  get askPhase() { return SAPC_STORE.askPhase; }                   set askPhase(v) { SAPC_STORE.askPhase = v; }
  get expandedId() { return SAPC_STORE.expandedId; }               set expandedId(v) { SAPC_STORE.expandedId = v; }
  get toolRunning() { return SAPC_STORE.toolRunning; }             set toolRunning(v) { SAPC_STORE.toolRunning = v; }
  get timeline() { return SAPC_STORE.timeline; }                   set timeline(v) { SAPC_STORE.timeline = v; }
  get timelineLoading() { return SAPC_STORE.timelineLoading; }     set timelineLoading(v) { SAPC_STORE.timelineLoading = v; }
  get artifacts() { return SAPC_STORE.artifacts; }                 set artifacts(v) { SAPC_STORE.artifacts = v; }
  get artifactsLoading() { return SAPC_STORE.artifactsLoading; }   set artifactsLoading(v) { SAPC_STORE.artifactsLoading = v; }
  get artifactsKind() { return SAPC_STORE.artifactsKind; }         set artifactsKind(v) { SAPC_STORE.artifactsKind = v; }
  get artifactsQ() { return SAPC_STORE.artifactsQ; }               set artifactsQ(v) { SAPC_STORE.artifactsQ = v; }
  get recent() { return SAPC_STORE.recent; }                       set recent(v) { SAPC_STORE.recent = v; }
  get rounds() { return SAPC_STORE.rounds; }                       set rounds(v) { SAPC_STORE.rounds = v; }
  get roundIdx() { return SAPC_STORE.roundIdx; }                   set roundIdx(v) { SAPC_STORE.roundIdx = v; }
  get _results() { return SAPC_STORE.results; }
  get _argsTexts() { return SAPC_STORE.argsTexts; }
  get probe() { return SAPC_STORE.probe; }
  get diagpk() { return SAPC_STORE.diagpk; }
  get wk() { return SAPC_STORE.wk; }
  get _qText() { return SAPC_STORE.qText; }                        set _qText(v) { SAPC_STORE.qText = v; }
  get _qSys() { return SAPC_STORE.qSys; }                          set _qSys(v) { SAPC_STORE.qSys = v; }

  async render() {
    const st = this.status;
    // 2026-11-04 凭证合一缺口修复:facade 凭证(本进程,SAP Driver 工具用)与 bridge 文档链槽
    // (喂接口文档/小助理,bridge 重启即清)是两条链。此前 chip 只看 facade cached → bridge
    // 重启后 facade 仍显示「DVP已连」,但接口文档免密链已断,用户对着"已连"被 NEED_PASSWORD
    // 打脸(12:56 实爆)。现在 facade cached 但槽里没有该系统 → 标「已连·链断」,提示重连。
    const bcSet = new Set(((st && st.botDocChain && st.botDocChain.systems) || []).map((x) => x.system));
    const sysChips = ['DVP', 'QAS', 'PRD'].map((s) => {
      const cfg = st && st.systems && st.systems[s];
      const cached = !!(cfg && cfg.cached);
      const chainOk = bcSet.has(s);   // bridge 文档链槽里有该系统格
      const prod = cfg && cfg.role === 'prod';
      const cls = cached ? 'on' : (prod ? 'prod' : '');
      const label = cached ? (chainOk ? '已连' : '已连·链断') : (prod ? '只读' : '未连');
      const tipBase = cfg ? `${cfg.host}:${cfg.client} ${cfg.user || ''}` : s;
      const tip = cached && !chainOk
        ? `${tipBase} ·SAP Driver 工具可用,但接口文档免密链已断(bridge 重启会清)。在下方连接管理对该系统点一次「连接」即可恢复(需重输密码)。`
        : tipBase;
      return `<span class="sapc-chip ${cls}" title="${escAttr(tip)}">
        <span class="sapc-dot"></span>${s} ${label}</span>`;
    }).join('');
    // 小助理文档链 chip(v18.4 凭证合一):随连接管理连接/断开自动同步,按系统分格聚合显示;
    // 未注入=钉钉自动文档必败,点击直达连接管理。无 status 时整个不渲染(首屏加载中)。
    const bc = st && st.botDocChain;
    const bcSys = (bc && bc.systems) || [];
    const bcMin = bcSys.length ? Math.min(...bcSys.map((x) => x.remainingMinutes || 0)) : 0;
    const bcTip = bcSys.length
      ? escAttr('小助理文档链(随连接管理同步):' + bcSys.map((x) => `${x.system}${x.client ? `(client ${x.client})` : ''} 剩${x.remainingMinutes}分`).join('、') + ';bridge 重启即失效')
      : escAttr('小助理文档链未注入:连接管理连一次 DVP/QAS 即自动同步,点此打开连接管理');
    const bcChip = bc ? `<span class="sapc-chip clickable ${bc.ready ? 'on' : ''}" id="sapc-bc-chip" title="${bcTip}">🤖小助理 ${bc.ready ? `已注入 ${bcSys.map((x) => x.system).join('·')}·剩${bcMin}分` : '未注入'}</span>` : '';
    const audit = st && st.audit;
    const auditChip = audit
      ? `<span class="sapc-audit">今日总账 <b>${audit.total}</b> · ✓${audit.ok} ✗${audit.error} ⛔${audit.denied}</span>`
      : '<span class="sapc-audit">今日总账 –</span>';

    const body = this.tab === 'ask' ? this.renderAsk()
      : this.tab === 'probe' ? this.renderProbe()
      : this.tab === 'diagpk' ? this.renderDiagpk()
      : this.tab === 'wk' ? this.renderWk()
      : this.tab === 'artifacts' ? this.renderArtifacts()
      : this.tab === 'flow' ? this.renderFlow()
      : this.tab === 'catalog' ? this.renderCatalog() : this.renderTimeline();

    // 滚动位置保持(2026-09-14 用户反馈:目录页下滑点击卡片后被弹回顶部)。
    // 同页签重渲染→恢复 scrollTop;切页签→归零。
    const prevBody = this.root.querySelector('.sapc-body');
    const prevTab = this._renderedTab;
    const scrollPos = (prevBody && prevTab === this.tab) ? prevBody.scrollTop : 0;

    this.root.innerHTML = `
      <div class="sapc">
        <div class="sapc-status">
          ${sysChips}
          <span class="sapc-sep"></span>
          ${bcChip}
          <span class="sapc-sep"></span>
          ${auditChip}
          <span class="sapc-spacer"></span>
          <button id="sapc-connect-btn">🔑 连接管理</button>
          <button id="sapc-refresh" title="刷新状态" ${this.statusLoading ? 'disabled' : ''}>${this.statusLoading ? '⏳' : '↻'}</button>
        </div>
        <div class="sapc-tabs">
          <button data-tab="ask" class="${this.tab === 'ask' ? 'active' : ''}">🤖 Agent Harness</button>
          <button data-tab="flow" class="${this.tab === 'flow' ? 'active' : ''}">🤖 SAP数字员工</button>
          <button data-tab="probe" class="${this.tab === 'probe' ? 'active' : ''}">🔍 排查</button>
          <button data-tab="diagpk" class="${this.tab === 'diagpk' ? 'active' : ''}">🩺 体检</button>
          <button data-tab="wk" class="${this.tab === 'wk' ? 'active' : ''}">📈 负载周报</button>
          <button data-tab="artifacts" class="${this.tab === 'artifacts' ? 'active' : ''}">📦 产物</button>
          <button data-tab="catalog" class="${this.tab === 'catalog' ? 'active' : ''}">🗺️ Skill地图</button>
          <button data-tab="timeline" class="${this.tab === 'timeline' ? 'active' : ''}">⏱ Trace调用链</button>
        </div>
        ${this.connectOpen ? this.renderConnect() : ''}
        <div class="sapc-body">${body}</div>
      </div>`;
    this.bind();
    this._renderedTab = this.tab;
    if (scrollPos) {
      const nb = this.root.querySelector('.sapc-body');
      if (nb) nb.scrollTop = scrollPos;
    }
  }

  renderConnect() {
    const rows = ['DVP', 'QAS', 'PRD'].map((s) => {
      const cfg = (this.status && this.status.systems && this.status.systems[s]) || {};
      const cached = !!cfg.cached;
      return `<div class="row" data-sys="${s}">
        <span class="sysname">${s}</span>
        <span class="rowstat ${cached ? 'on' : ''}">${cached ? '● 已连' : '○ 未连'}</span>
        <input data-f="user" placeholder="用户" value="${escAttr(cfg.user || '')}" style="width:110px;">
        <input data-f="password" type="password" placeholder="密码(仅内存)" autocomplete="off">
        <input data-f="client" placeholder="client" value="${escAttr(cfg.client || '')}" style="width:62px;">
        <button data-act="connect" class="primary">${this.connecting === s ? '连接中…' : '连接'}</button>
        <button data-act="disconnect" ${(!cached || this.connecting) ? 'disabled' : ''}>断开</button>
      </div>`;
    }).join('');
    // v18.4 凭证合一:小助理文档链不再有独立注入行 —— 上面三行的「连接/断开」就是唯一通道,
    // sap-tool 路由在 facade 连接成功/断开时同写/同清 bridge 内存槽(sap-tool.ps1 双写段)。
    return `<div class="sapc-connect">${rows}
      <div class="sapc-hint">密码只进本机 facade 进程内存(与 Claude Code 的 MCP 同模式),绝不落盘;PRD 全程只读硬闸。</div>
      <div class="sapc-hint">🤖小助理文档链随上面「连接/断开」自动同步:连一次 DVP/QAS,钉钉自动生成接口文档即可用;显式填 client 时文档链按该 client 跑,留空按各系统默认(DVP=900/QAS=800)。</div>
    </div>`;
  }

  // ---- v15 导出共享件:全页签「所有结果都能导出」的公共底座 ----
  // 导出按钮排(三件套或子集;hint 一句话说明 SHEET/报告布局)
  _exportBar(items, hint = '') {
    return `<div style="display:flex;gap:8px;margin:10px 2px;align-items:center;flex-wrap:wrap;">
      ${items.map((a) => `<button data-act="${a.act}" style="font-size:12px;padding:3px 14px;"${a.title ? ` title="${escAttr(a.title)}"` : ''}>${a.label}</button>`).join('')}
      ${hint ? `<span class="sapc-hint">${hint}</span>` : ''}
    </div>`;
  }

  // markdown → 剪贴板富文本(kind='copy')/ HTML 文档下载(kind='html')双栖。
  // 收编 probe/xref/lint/diagpk/answer 五处同构样板(顺带根治 <\\div> 无闭合)。
  async _mdExport(kind, md, { title, subtitle = '', filename = '导出' } = {}) {
    try {
      if (kind === 'copy') {
        let html = '';
        try { html = markdownToDocumentHtml(md, { title }); } catch { /* 兜底纯文本 */ }
        const m = html.match(/<div class="md-body">([\s\S]*)<\/div>\s*<footer/);
        const ok = await copyRich(dingtalkFriendly(md), m ? `<div>${m[1]}</div>` : html);
        _toast(ok ? '✓ 已复制(粘贴自动带排版)' : '复制失败', ok ? 'ok' : 'err');
        return;
      }
      const html = markdownToDocumentHtml(md, { title, subtitle: subtitle || _nowStamp() });
      downloadHtml(`${safeFilename(filename)}.html`, html);
      _toast('✓ 已导出 HTML 文档(下载目录)', 'ok');
    } catch (err) { _toast(`导出失败:${err.message || err}`, 'err'); }
  }

  // 任意结果对象 → sheets(Skill地图单工具等通用导出):对象数组字段一表、其余进概览/输出-其他
  _xlsxFromObj(obj, overview = []) {
    const ov = overview.slice();
    const other = [];
    const sheets = [];
    Object.entries(obj || {}).forEach(([k, v]) => {
      if (Array.isArray(v) && v.length && typeof v[0] === 'object' && v[0] != null && !Array.isArray(v[0])) {
        sheets.push({ name: String(k), rows: v });
      } else if (Array.isArray(v)) {
        other.push({ 参数: k, 值: v.length ? v.map((x) => (x && typeof x === 'object') ? JSON.stringify(x) : String(x ?? '')).join(' | ') : '(0 行)' });
      } else if (v && typeof v === 'object') {
        other.push({ 参数: k, 值: JSON.stringify(v) });
      } else ov.push({ 项目: k, 内容: String(v ?? '') });
    });
    if (other.length) sheets.push({ name: '输出-其他', rows: other });
    return [{ name: '概览', rows: ov.length ? ov : [{ 项目: '-', 内容: '-' }] }, ...sheets];
  }

  bind() {
    this.root.querySelector('#sapc-refresh')?.addEventListener('click', () => this.loadStatus(true));
    this.root.querySelector('#sapc-bc-chip')?.addEventListener('click', () => {
      if (!this.connectOpen) { this.connectOpen = true; this.render(); }
    });
    this.root.querySelector('#sapc-connect-btn')?.addEventListener('click', () => {
      this.connectOpen = !this.connectOpen;
      this.render();
    });
    this.root.querySelectorAll('.sapc-tabs button').forEach((b) => {
      b.addEventListener('click', () => {
        this.tab = b.dataset.tab;
        // 记忆上次页签(2026-11-04:设置-外观 sapCopilotDefaultTab 未配置时下次打开落这里)
        try {
          const prefs = JSON.parse(localStorage.getItem(SAPC_PREFS_KEY) || '{}');
          prefs.lastTab = b.dataset.tab;
          localStorage.setItem(SAPC_PREFS_KEY, JSON.stringify(prefs));
        } catch { /* 只读场景静默 */ }
        // 产物页签首次进入自动扫描一次(之后手动刷新);先 render 展开加载态,
        // 否则 loadArtifacts 首扫不触发渲染,画面停在旧页签最长 20s(09-18 审查 C7)
        if (this.tab === 'artifacts' && !this.artifacts && !this.artifactsLoading) { this.loadArtifacts(); this.render(); return; }
        // 🚰 交付页签首次进入自动扫描工单(之后手动🔄;delivery-status 秒级,不冗防抖)
        if (this.tab === 'flow' && !FlowStore.tickets && !FlowStore.loading) { this.loadTickets(); this.render(); return; }
        this.render();
      });
    });

    // ---- 📦 产物/时间线事件(2026-11-03 拆分批二:chips/搜索/加载/刷新/tl 导出迁 sap-copilot-art.js bindArt)----
    this.bindArt();

    // ---- 🚰 交付驾驶舱事件(2026-11-04 P1:卡片展开/检查/登记/续跑话术,见 sap-flow.widget.js bindFlow)----
    this.bindFlow();

    // ---- 🧪 排查/体检/负载周报三页签事件(2026-10-30 拆分批一:原 258 行绑定原地迁 sap-copilot-probe.js
    //  bindProbe,含 tl/res/art-xlsx 等共用导出件绑定;此处仅转发,tab 激活即可全绑)----
    this.bindProbe();

    // 仅限 facade 三行([data-sys]);小助理槽行(data-slot)走下面的独立通道,互不串
    this.root.querySelectorAll('.sapc-connect .row[data-sys] [data-act]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        if (this.connecting) return;
        const row = btn.closest('.row');
        const system = row.dataset.sys;
        const get = (f) => row.querySelector(`[data-f="${f}"]`)?.value.trim() || '';
        if (btn.dataset.act === 'connect') {
          const password = get('password');
          if (!password) { _toast('请输入密码(仅内存,不落盘)', 'err'); return; }
          const args = { system, user: get('user') || undefined, password };
          const client = get('client');
          if (client) args.client = client;
          this.connecting = system;
          try {
            const res = await bridge.run('sap-tool', { tool: 'sap_connect', args }, { timeoutMs: 60000 });
            if (res.ok === false) throw new Error(emOf(res));
            _toast(`✓ ${system} 已连接(${res.durationMs}ms)`, 'ok');
            row.querySelector('[data-f="password"]').value = '';
          } catch (err) { _toast(`✗ ${system} 连接失败:${err.message || err}`, 'err'); }
          this.connecting = null;
          await this.loadStatus(true);
        } else {
          this.connecting = system;
          try {
            const res = await bridge.run('sap-tool', { tool: 'sap_disconnect', args: { system } }, { timeoutMs: 30000 });
            if (res.ok === false) throw new Error(emOf(res));
            _toast(`✓ ${system} 已断开`, 'ok');
          } catch (err) { _toast(`✗ 断开失败:${err.message || err}`, 'err'); }
          this.connecting = null;
          await this.loadStatus(true);
        }
      });
    });
    // v18.4:小助理文档链无独立注入行 —— 连接/断开按钮本身经 sap-tool 双写/同清槽,无需第二套处理器。

    // ---- 🤖 问 Agent 事件(2026-11-03 拆分批二:原 95 行绑定原地迁 sap-copilot-ask.js bindAsk)----
    this.bindAsk();

    // ---- 🗺️ Skill地图事件(2026-11-03 拆分批三:卡片直达/run-tool/run-cmd/copy-result 迁 sap-copilot-catalog.js bindCatalog)----
    this.bindCatalog();

    // tl-load/open-timeline 已随产物/时间线段并入 bindArt(拆分批二),上方 bindArt() 一次全绑
  }

  async loadStatus(manual = false) {
    this.statusLoading = true;
    if (manual) this.render();
    try {
      this.status = await bridge.run('sap-status', {}, { timeoutMs: 20000 });
    } catch (err) {
      if (manual) _toast(`状态获取失败:${err.message || err}`, 'err');
    }
    this.statusLoading = false;
    this.render();
  }

}

function emOf(res) {
  return (res.error && res.error.message) || res.message || res.code || '未知错误';
}

// ---- 拆分批一装配(2026-10-30):三页签方法体自 mixin 原地搬运,挂上原型即归位 ----
// ★不能用 Object.assign:class 方法是 own 但「不可枚举」,assign 只拷可枚举 → 一个都过不来
// (实爆:页面报 this.bindProbe is not a function)。必须按 descriptor 逐个 defineProperty。
(function mixinInto(target, ...sources) {
  for (const src of sources) {
    for (const name of Object.getOwnPropertyNames(src)) {
      if (name !== 'constructor' && !Object.prototype.hasOwnProperty.call(target, name)) {
        Object.defineProperty(target, name, Object.getOwnPropertyDescriptor(src, name));
      }
    }
  }
})(SapCopilotWidget.prototype, SapProbeMethods.prototype, SapDiagpkMethods.prototype, SapWkMethods.prototype, SapAskMethods.prototype, SapArtMethods.prototype, SapCatalogMethods.prototype, SapFlowMethods.prototype);
bindFlowShared({ _toast, emOf, esc, escAttr, copyText, bridge });
bindProbeShared({
  _toast, _nowStamp, emOf, _xrefOt, _xrefMainOf, _xrefIsCustom, _saveSapcPrefs, p_last_clear,
  PROBE_SYS_DEFAULT, SAPC_STORE, XREF_SUBC, XREF_OTYPE_TIP, TRD_STATUS, TRD_FUNC, TRD_SEV, TRD_SEV_TEXT,
  esc, escAttr, downloadXlsx, bridge, copyText, safeFilename, downloadJson, markdownToDocumentHtml, renderMarkdown, todayStamp,
});
bindDiagpkShared({ _toast, _nowStamp, emOf, esc, safeFilename, downloadXlsx, bridge });
bindWkShared({ _toast, _nowStamp, emOf, esc, safeFilename, downloadXlsx, bridge, markdownToDocumentHtml, renderMarkdown });
bindAskShared({ _toast, _nowStamp, emOf, esc, escAttr, bridge, renderMarkdown, dingtalkFriendly, SAPC_STORE, PRESETS });
bindArtShared({ _toast, esc, escAttr, bridge });
bindCatalogShared({ _toast, emOf, esc, escAttr, copyText, bridge, runCommand, CommandRegistry, SAP_CATALOG, SAP_CATEGORIES, todos, FlowStore, loadTicketsFn: (w) => w.loadTickets() });

WidgetRegistry.register({
  id: 'sap-copilot',
  title: 'SAP Driver',
  icon: '🚗',
  category: 'life',
  feature: 'sap',
  settings: {},
  async mount(host, settings, ctx) {
    const root = document.createElement('div');
    root.style.cssText = 'display:flex;flex-direction:column;height:100%;';
    const styleEl = document.createElement('style');
    styleEl.textContent = STYLES;
    host.appendChild(styleEl);
    host.appendChild(root);
    const w = new SapCopilotWidget(root);
    await w.render();
    w.loadStatus();
    w.loadRecent();   // Agent Harness主页「今日动态」条,静默加载(填下方留白)
    // 执行中切走又切回:数据在模块级 store,恢复进度轮询(ask 本体在旧实例上继续跑)
    if (SAPC_STORE.asking && SAPC_STORE.askCallId) w._startPoll(SAPC_STORE.askCallId);
    // probe 报告 RUNNING 接力同样要恢复(2026-10-14 审查 P1):unmount 清 _probeTimer 断链,
    // 切回不恢复=永卡「执行中 N/24」零计时器,唯一出路重跑=重复提交后台作业(PRD 还要多过一次确认)
    if (SAPC_STORE.probe && SAPC_STORE.probe.execLoading && SAPC_STORE.probe.repStatus) {
      const rs = SAPC_STORE.probe.repStatus;
      w.probePoll(rs.jobname, rs.jobcount, Math.max(0, rs.tries - 1));   // probePoll 内部 tries+1,回退一位保计数连续
    }
    // unmount 全量清定时器(09-18 审查 C7):ask 进度轮询 + 诊断进度轮询 + probe 报告轮询,
    // 漏清=切走后幽灵请求继续打桥(违反「定时器必须 unmount 清理」规范)
    return { unmount() {
      w._stopPoll();
      w._stopDiagPoll();
      if (w._probeTimer) { clearTimeout(w._probeTimer); w._probeTimer = null; }
    } };
  },
});
