// sap-copilot-probe.js — SAP Driver 「排查」页签全家——fm/report/xref/tr/lint/gate 六形态(渲染/动作/报告/Excel/诊断链)(2026-10-30 拆分批一,class mixin)。
// 拆分=原地移动零改动:方法体逐字搬运,this 语义不变(SAPC_STORE 经主文件 getter 代理),
// e2e 选择器/data-act 零变化。装配:主文件 import 后把 mixin 方法挂上 SapCopilotWidget.prototype;
// 共享符号经 bindSapShared() 注入(见下方 let 声明)——不 import 主文件防环。

let _toast, _nowStamp, emOf, _xrefOt, _xrefMainOf, _xrefIsCustom, _saveSapcPrefs, p_last_clear, PROBE_SYS_DEFAULT, SAPC_STORE, XREF_SUBC, XREF_OTYPE_TIP, TRD_STATUS, TRD_FUNC, TRD_SEV, TRD_SEV_TEXT, esc, escAttr, downloadXlsx, bridge, copyText, safeFilename, downloadJson, markdownToDocumentHtml, renderMarkdown, todayStamp;

// 主文件装配时调一次,把共享符号绑进本模块闭包(app 启动一次;类方法体沿模块作用域取值)。
export function bindSapShared(deps) {
  _toast = deps._toast;
  _nowStamp = deps._nowStamp;
  emOf = deps.emOf;
  _xrefOt = deps._xrefOt;
  _xrefMainOf = deps._xrefMainOf;
  _xrefIsCustom = deps._xrefIsCustom;
  _saveSapcPrefs = deps._saveSapcPrefs;
  p_last_clear = deps.p_last_clear;
  PROBE_SYS_DEFAULT = deps.PROBE_SYS_DEFAULT;
  SAPC_STORE = deps.SAPC_STORE;
  XREF_SUBC = deps.XREF_SUBC;
  XREF_OTYPE_TIP = deps.XREF_OTYPE_TIP;
  TRD_STATUS = deps.TRD_STATUS;
  TRD_FUNC = deps.TRD_FUNC;
  TRD_SEV = deps.TRD_SEV;
  TRD_SEV_TEXT = deps.TRD_SEV_TEXT;
  esc = deps.esc;
  escAttr = deps.escAttr;
  downloadXlsx = deps.downloadXlsx;
  bridge = deps.bridge;
  copyText = deps.copyText;
  safeFilename = deps.safeFilename;
  downloadJson = deps.downloadJson;
  markdownToDocumentHtml = deps.markdownToDocumentHtml;
  renderMarkdown = deps.renderMarkdown;
  todayStamp = deps.todayStamp;
}

export class SapProbeMethods {
  // ---- 🧪 函数排查(v7,2026-09-14)----
  // 确定性链零 AI:报文复现 / SE37 变式 / 参数集 / 一次执行(sap-probe 路由编排 facade)。
  // 复用预留(用户定案):将来程序排查 = probe 路由加 SUBMIT 分支 + 本区组件按 kind 复用。
  renderProbe() {
    const p = this.probe;
    const isRep = p.kind === 'report';
    const isXref = p.kind === 'xref';
    const isTr = p.kind === 'tr';
    const isLint = p.kind === 'lint';
    const isGate = p.kind === 'gate';   // v19 交付门禁
    const sysOpts = ['DVP', 'QAS', 'PRD'].map((s) =>
      `<option value="${s}" ${p.sys === s ? 'selected' : ''}>${s}${s === 'PRD' ? ' · 只读' : ''}</option>`).join('');
    const hasForm = isRep ? !!(p.reportSig && p.reportSig.length)
      : (Object.keys(p.form.import || {}).length || Object.keys(p.form.tables || {}).length);

    const kindBtn = (k, label) => {
      const on = (p.kind === k);
      return `<button data-act="probe-kind" data-k="${k}" style="border:none;padding:5px 11px;font-size:12px;cursor:pointer;background:${on ? 'var(--sd-accent-soft)' : 'transparent'};color:${on ? 'var(--sd-accent-active)' : 'var(--sd-text-faint)'};font-weight:${on ? '700' : '400'};">${label}</button>`;
    };
    const bar = `<div class="pb-bar">
      <span style="display:inline-flex;border:1px solid var(--sd-border-strong);border-radius:8px;overflow:hidden;">
        ${kindBtn('fm', '🧪 函数')}${kindBtn('report', '📊 程序')}${kindBtn('xref', '🔗 引用')}${kindBtn('tr', '🚚 传输')}${kindBtn('lint', '📏 质量审查')}${kindBtn('gate', '📤 交付门禁')}
      </span>
      <select data-probe-f="sys">${sysOpts}</select>
      <input data-probe-f="fm" placeholder="${isRep ? '报表程序名,如 ZREP001' : (isXref ? '表/结构/类/函数组,或 表.字段(如 MARA.MATNR)' : (isTr ? '请求号(如 DEVK900001)或用户名(如 XXX.YYY.Z)' : (isLint ? '程序/函数/事务码,如 ZREP003 或 ZREP001' : (isGate ? '程序/函数/事务码/请求号,如 ZREP002 或 DEVK900002' : '接口函数名,如 Z_ORDER_GET_INFO'))))}" style="width:270px;" value="${escAttr(p.fm)}">
      ${isTr ? `<button data-act="probe-objtr" ${p.xrefSearching ? 'disabled' : ''} title="输入事务码/程序/函数组,看它涉及哪些请求+三系统版本是否一致">🎯 按对象分析</button>
      <button data-act="probe-tr-view" ${p.xrefSearching ? 'disabled' : ''}>${p.xrefSearching ? '⏳ 查询中…' : '🔍 查请求详情'}</button>
      <button data-act="probe-tr-list" ${p.xrefSearching ? 'disabled' : ''}>📋 列某用户的请求</button>`
      : isXref ? `<button data-act="probe-xref-used" ${p.xrefSearching ? 'disabled' : ''}>${p.xrefSearching ? '⏳ 查询中…' : '🔎 被谁引用'}</button>
      <button data-act="probe-xref-search" ${p.xrefSearching ? 'disabled' : ''}>📄 搜程序名</button>
      <button data-act="probe-xref-content" ${p.xrefSearching ? 'disabled' : ''} title="关键字搜进源码内容(默认扫 Z*,首建索引较慢,之后按指纹增量秒搜)">${p.xrefSearching ? '⏳ 搜索中…' : '🔍 搜内容'}</button>`
      : isLint ? `<button data-act="probe-lint" ${p.xrefSearching ? 'disabled' : ''}>${p.xrefSearching ? '⏳ 分析中…' : '📏 开始质量审查'}</button>`
      : isGate ? `<button data-act="probe-gate" ${p.xrefSearching ? 'disabled' : ''} title="五段检查:传输包/对象健康/表↔程序兼容/代码质量/需求覆盖(AI,选填)">${p.xrefSearching ? '⏳ 门禁检查中…' : '🚦 跑交付门禁'}</button>`
      : `<button data-act="probe-sig" ${p.sigLoading ? 'disabled' : ''}>${p.sigLoading ? '⏳ 读取中…' : (isRep ? '📖 读选择屏幕' : '📖 读接口')}</button>
      <input data-probe-f="variant" placeholder="${isRep ? '报表变式名' : 'SE37 变式编号(数字)'}" style="width:130px;" value="${escAttr(p.variant)}">
      <button data-act="probe-variant" ${p.sigLoading ? 'disabled' : ''}>📥 载入变式</button>
      ${(isXref || isTr || isLint || isGate) ? '' : `<label style="display:inline-flex;align-items:center;gap:4px;font-size:11.5px;color:var(--sd-text-faint);cursor:pointer;">
        <input type="checkbox" data-probe-f="autodiag" ${p.autoDiag ? 'checked' : ''} style="margin:0;">报错/空结果自动诊断</label>
      <label style="display:inline-flex;align-items:center;gap:4px;font-size:11.5px;color:var(--sd-text-faint);cursor:pointer;" title="勾选后点「读接口/读选择屏幕」时,AI 顺带解读它做什么、取数逻辑">
        <input type="checkbox" data-probe-f="autoexplain" ${p.autoExplain ? 'checked' : ''} style="margin:0;">📐 ${isRep ? '程序解读' : '接口解读'}</label>`}`}
    </div>
    <div class="sapc-hint" style="padding:0 2px;">
      ${isTr
      ? `传输查询(E070/E071 纯只读):填<b>程序/事务码/函数组</b>(如 ZREP001 或 MM03)→ <b>🎯 按对象分析</b> = 传输溯源:这个程序涉及哪些请求(带描述)+ DVP/QAS/PRD 三系统<b>源码内容逐字比对</b>,「未传/不一致」一眼定位,<b>说明列</b>直接写明哪个系统落后、差在哪(悬停日期可看内容指纹);点请求号可下钻完整详情;填请求号 → <b>查请求详情</b>;填用户名 → <b>列某用户的请求</b>。建议 DVP 视角(请求历史最全)。`
      : isXref
      ? `引用影响分析(WBCROSSGT+TRDIRT 纯只读,PRD 可用):填表/结构/类/函数组名 → <b>被谁引用</b> = 按主程序聚合的改动影响清单(自定义程序默认展开,含程序标题;「🔍 看代码」定位引用行,「它用了什么」反查该程序);填「表.字段」查字段级引用(类型引用口径);<b>搜程序名</b> = 名字+中文描述双搜;<b>🔍 搜内容</b> = 关键字搜进源码内容(REPOSRC 指纹增量缓存,程序名默认 Z* 可用 ZFIT* 收窄,首建较慢之后秒搜)。`
      : isLint
      ? `SQL 代码质量审查(按五关准则:零循环内SELECT/命中索引/FAE三要素/交互次数最小化/聚合下推;纯只读,PRD 可用):填<b>程序/函数/事务码</b> → <b>📏 开始质量审查</b> = 拉源码逐条把关,违规带行号+源码片段,SELECT 逐条做索引命中审计(DD03L+DD17S 实查);结果按源码指纹缓存,程序没改秒出。`
      : isGate
      ? `交付门禁(交付顾问测试前的最后一道自动检查;纯只读,建议 DVP):填<b>程序/函数/事务码/请求号</b> → <b>🚦 跑交付门禁</b> = 五段体检:G1 传输包(对象清单/脏树/★LIMU↔R3TR 配对——表只挂子对象没挂主对象行,导入必失败这种坑就是它抓的)/G2 对象健康(激活态/事务码指向/表激活/上传模板在位)/G3 表↔程序兼容(引用表传没传过/字段存在性/表改动晚于程序=有人动过表)/G4 代码质量(五关审查)/G5 需求覆盖(下方粘需求要点,AI 逐条对照源码找功能缺口+逻辑 bug,<b>选填</b>)。FAIL=修完再交,WARN=人工复核,PASS=放行给顾问。`
      : isRep
      ? `程序排查(定点):① 填报表名 → <b>读选择屏幕</b>(自动生成参数表单,P 单值 / S 范围) ② 或填报表变式名 → <b>载入变式</b> ③ 可填「期望关键字 / 最少行数」→ ▶执行 = 后台作业真跑报表取回列表,<b>自动比对期望</b>,未取到自动进诊断。标准报表 + Z/Y 均可跑;执行前自动粗扫源码副作用,<b>PRD 每次执行需人工确认</b>。`
      : `用法三步:① 填函数名 → <b>读接口</b>(读出参数清单,自动生成空表单) ② 有第三方报文就贴到下面「解析填表」 ③ ▶执行 看真实返回。
      变式 = SE37 里保存过的测试入参(按编号,没有可跳过);DVP 跑数据先在连接管理把 client 改 800/900。`}
    </div>`;

    let formCard = '';
    if (isRep && hasForm) {
      // v9 report 表单:单一真值源 p.reportSig,输入框就地写回(_probeBarVals 统一回读)
      const rows = p.reportSig.map((it) => {
        const nm = String(it.SELNAME || '');
        if (it.KIND === 'S') {
          const opt = ['EQ', 'BT', 'NB', 'CP', 'GE', 'LE', 'GT', 'LT'].map((o) =>
            `<option value="${o}" ${it.OPTION === o ? 'selected' : ''}>${o}</option>`).join('');
          return `<div class="imp-row"><span class="k" title="${escAttr(nm)}(范围)">${esc(nm)}</span>
            <select data-rs-sign="${escAttr(nm)}" style="width:56px;"><option value="I" ${it.SIGN !== 'E' ? 'selected' : ''}>I 含</option><option value="E" ${it.SIGN === 'E' ? 'selected' : ''}>E 排</option></select>
            <select data-rs-opt="${escAttr(nm)}" style="width:72px;">${opt}</select>
            <input data-rs-low="${escAttr(nm)}" placeholder="LOW" style="flex:1;" value="${escAttr(String(it.LOW ?? ''))}">
            <input data-rs-high="${escAttr(nm)}" placeholder="HIGH" style="flex:1;" value="${escAttr(String(it.HIGH ?? ''))}">
          </div>`;
        }
        return `<div class="imp-row"><span class="k" title="${escAttr(nm)}(参数)">${esc(nm)}<span style="color:var(--sd-text-faint);">·P</span></span>
          <input data-rp="${escAttr(nm)}" style="flex:1;" value="${escAttr(String(it.LOW ?? ''))}"></div>`;
      }).join('');
      formCard = `<div class="pb-card">
        <div class="pb-title">选择屏幕参数 <span class="sub">${p.reportSig.length} 项 · P=单值参数 · S=范围(默认 I EQ)</span></div>
        ${rows}
      </div>`;
    } else if (hasForm) {
      const impRows = Object.entries(p.form.import).map(([k, v]) => {
        if (v && typeof v === 'object') {
          return `<div class="imp-row"><span class="k" title="${escAttr(k)}(结构)">${esc(k)}</span>
            <textarea class="pb-json" data-imp="${escAttr(k)}" rows="2">${esc(JSON.stringify(v, null, 1))}</textarea></div>`;
        }
        return `<div class="imp-row"><span class="k" title="${escAttr(k)}">${esc(k)}</span>
          <input data-imp="${escAttr(k)}" value="${escAttr(String(v ?? ''))}"></div>`;
      }).join('');
      const tabBlocks = Object.entries(p.form.tables).map(([k, rows]) => {
        const n = Array.isArray(rows) ? rows.length : 0;
        return `<div style="margin:7px 0 2px;">
          <span class="res-sec" style="margin:0 0 3px;">▦ ${esc(k)} <span class="sapc-hint">(${n} 行 · JSON 数组,可编辑)</span></span>
          <textarea class="pb-json" data-tbljson="${escAttr(k)}" rows="${Math.min(8, Math.max(3, n + 1))}">${esc(JSON.stringify(rows || [], null, 1))}</textarea>
        </div>`;
      }).join('');
      formCard = `<div class="pb-card">
        <div class="pb-title">参数表单 <span class="sub">IMPORT ${Object.keys(p.form.import).length} 项 · TABLES ${Object.keys(p.form.tables).length} 张</span></div>
        ${impRows || '<span class="sapc-hint">无 IMPORT 参数</span>'}
        ${tabBlocks || ''}
      </div>`;
    }

    let reqCard = '';
    if (isGate) {
      // v19 需求要点(G5 选填输入):每行一条,空行/# 注释跳过,路由侧再截 30 条
      reqCard = `<div class="pb-card">
        <div class="pb-title">需求要点(选填 · G5 需求覆盖) <span class="sub">每行一条;粘了才跑 AI 对照源码逐条判 PASS/GAP/PARTIAL + 找逻辑 bug;不粘则只跑 G1-G4 确定性四段</span></div>
        <textarea class="pb-json" data-probe-f="gatereq" rows="4" placeholder="例:&#10;表单1 Excel上传:校验物料10位数字/工厂9310/公式组 LS1-LS3&#10;模式3计算:LS1 三分支/LS2 预投×周数/LS3 动态窗口,拼版按 BSTRF 进位&#10;保存:公式组+确认周数落库,日志留痕">${esc(p.gateReq || '')}</textarea>
      </div>`;
    }
    const payloadCard = (isRep || isXref || isTr || isLint || isGate) ? '' : `<div class="pb-card">
      <div class="pb-title">第三方报文复现 <span class="sub">对方系统调这个接口时发的 JSON,贴进来解析填表 → 执行 = 原样重放他的调用</span></div>
      <textarea class="pb-json pb-payload" data-probe-f="payload" placeholder='{"PLANT":"1000","tables":{"IT_ITEMS":[{"POSNR":"000010"}]}} —— 平铺参数、{"import":{},"tables":{}} 结构都认'>${esc(p.payloadText || '')}</textarea>
      <div style="display:flex;gap:8px;margin-top:8px;align-items:center;">
        <button data-act="probe-parse">📋 解析填表</button>
        <input data-probe-f="setname" placeholder="参数集名称(如 报文0728)" style="width:170px;" value="${escAttr(p.setName)}">
        <button data-act="probe-save" ${hasForm ? '' : 'disabled'} title="把当前表单存成这个函数的参数集,以后一键复现">💾 存参数集</button>
      </div>
    </div>`;

    let setsCard = '';
    if (p.sets) {
      const fmNow = p.fm.trim().toUpperCase();
      // 只显示当前函数的参数集(全局混列会误导——2026-09-14 用户实报 SRM测试 混进别的函数)
      const mine = fmNow ? (p.sets || []).filter((s) => String(s.function || '').toUpperCase() === fmNow) : [];
      const rows = mine.map((s) => `<div class="set-row">
        <span class="set-name">${esc(s.name)}</span>
        <span class="set-meta">${esc(s.note || '')} · imp ${s.importKeys.length} / tbl ${s.tableNames.length}${s.savedAt ? ` · ${esc(String(s.savedAt).slice(0, 10))}` : ''}</span>
        <button data-act="probe-loadset" data-set="${escAttr(s.name)}" data-setfm="${escAttr(s.function || '')}">载入</button>
      </div>`).join('');
      setsCard = `<div class="pb-card pb-sets">
        <div class="pb-title">参数集 <span class="sub">${fmNow ? `${esc(fmNow)} 的历史报文 ${mine.length} 个` : (isRep ? '填报表名后只显示该报表的' : '填函数名后只显示该函数的')}${p.setsLoading ? ' · ⏳ 刷新中' : ''}</span>
          <span style="flex:1"></span><button data-act="probe-sets-refresh" style="font-size:11.5px;padding:2px 10px;">↻</button></div>
        ${rows || `<span class="sapc-hint">${fmNow ? (isRep ? '这个报表还没有参数集;跑通一次后点「存参数集」,以后一键复现。' : '这个函数还没有参数集;跑通一次后点「存参数集」,以后一键复现。') : (isRep ? '填上报表名,这里列出它存过的参数集,点「载入」直接填表。' : '填上函数名,这里列出它存过的参数集(历史报文),点「载入」直接填表。')}</span>`}
      </div>`;
    }

    let resultHtml = '';
    if (p.repStatus) {
      // v12 RUNNING 接力:后台作业执行中,5 秒一次轮询(24 次封顶)
      resultHtml = `<div class="sapc-loading"><span class="spin"></span>后台作业 ${esc(p.repStatus.jobname)} 执行中…
        <div class="ph" id="sapc-rep-tries">已轮询 ${p.repStatus.tries}/24 次(每 5 秒;SM37 可看作业详情)</div></div>`;
    } else if (p.confirmReq && p.confirmReq.loading) {
      resultHtml = `<div class="pb-card sapc-diag"><div class="pb-title">🛡 PRD 执行预检中…</div>
        <div class="sapc-loading"><span class="spin"></span>正在粗扫源码副作用(INSERT/UPDATE/DELETE/COMMIT…)…</div></div>`;
    } else if (p.confirmReq && p.confirmReq.err) {
      resultHtml = `<div class="pb-card sapc-diag"><div class="pb-title">🛡 PRD 执行预检失败</div>
        <div class="pb-err"><span>✗</span><span>${esc(p.confirmReq.err)}</span></div>
        <div style="display:flex;gap:8px;margin-top:8px;">
          <button data-act="probe-confirm-go" class="primary">⚠ 跳过预检仍要执行</button>
          <button data-act="probe-confirm-cancel">取消</button>
        </div></div>`;
    } else if (p.confirmReq) {
      // v12 PRD 逐次确认卡(红):风险清单 + 人工放行——红线由用户逐次授权
      const cr = p.confirmReq;
      const lvl = String(cr.riskLevel || 'CLEAN').toUpperCase();
      const lvBadge = lvl === 'HIGH' ? '<span class="diag-badge" style="background:var(--sd-danger-soft);color:var(--sd-danger-text);">高风险(检测到写操作)</span>'
        : lvl === 'MEDIUM' ? '<span class="diag-badge" style="background:var(--sd-warning-soft);color:var(--sd-warning-text);">中风险(MODIFY/BAPI 调用)</span>'
        : '<span class="diag-badge uniq">✓ 纯查询(未检出写操作)</span>';
      const rrows = (cr.risks || []).map((x) => `<tr><td>${esc(String(x.TYPE || ''))}</td><td>${esc(String(x.NUMBER || ''))}</td><td>${esc(String(x.MESSAGE || ''))}</td></tr>`).join('');
      resultHtml = `<div class="pb-card sapc-diag" style="border-left-color:var(--sd-warning);">
        <div class="pb-title">🛡 PRD 执行确认 <span class="sub">${esc(p.fm.trim())}${p.variant ? ` · 变式 ${esc(p.variant)}` : ''} · 源码副作用粗扫</span></div>
        ${lvBadge}
        ${rrows ? `<table class="res-tbl"><thead><tr><th>级别</th><th>行</th><th>命中</th></tr></thead><tbody>${rrows}</tbody></table>`
        : '<div class="sapc-hint" style="margin-top:6px;">未检出写操作关键字。</div>'}
        <div class="sapc-hint" style="margin-top:6px;">PRD 红线:点「确认执行」= 你授权本次运行;操作记入统一总账。高/中风险报表确认后才会真跑。</div>
        <div style="display:flex;gap:8px;margin-top:8px;">
          <button data-act="probe-confirm-go" class="primary">✓ 确认执行</button>
          <button data-act="probe-confirm-cancel">取消</button>
        </div></div>`;
    } else if (p.execLoading) {
      resultHtml = `<div class="sapc-loading"><span class="spin"></span>正在执行 ${esc(p.fm)}(${isRep ? 'RFC 侧 SUBMIT 真跑报表' : 'facade 同源治理,QAS 执行 Z/Y 放行、PRD 仅白名单'})…</div>`;
    } else if (p.lastErr) {
      resultHtml = `<div class="pb-err"><span>✗</span><span>${esc(p.lastErr)}</span></div>`;
    } else if (p.execRes && isRep) {
      // v9 report 结果:概览 KV + 列表文本 pre 等宽呈现(保住对齐)
      const r0 = p.execRes;
      const list = Array.isArray(r0.ET_LIST) ? r0.ET_LIST.map((l) => String((l && l.LINE) ?? '')).join('\n') : '';
      const kv = [['SUBRC', r0.EV_SUBRC], ['耗时', (r0.EV_MS != null && r0.EV_MS !== '') ? `${r0.EV_MS}ms` : ''],
        ['列表行数', r0.EV_LINES], ['消息', r0.EV_MESSAGE]]
        .filter((x) => x[1] !== '' && x[1] != null)
        .map(([k, v]) => `<div class="res-kv"><span class="k">${k}</span><span class="v">${esc(String(v))}</span></div>`).join('');
      const expBadge = !p.expectRes ? '' : (p.expectRes.ok
        ? '<div class="res-kv"><span class="k">期望比对</span><span class="v" style="color:var(--sd-success-text);font-weight:700;">✅ 命中——输出符合期望</span></div>'
        : `<div class="res-kv"><span class="k">期望比对</span><span class="v" style="color:var(--sd-danger-text);font-weight:700;">❌ 未取到:${esc(p.expectRes.reasons.join(';'))}</span></div>`);
      resultHtml = `<div class="pb-card">
        <div class="pb-title">执行结果 <span class="sub">${p.execMs ? `${p.execMs}ms` : ''}</span>
          <span style="flex:1"></span><button data-act="probe-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制 JSON</button></div>
        ${kv}
        ${expBadge}
        ${list ? `<pre style="font-family:Consolas,monospace;font-size:11.5px;line-height:1.45;overflow:auto;background:var(--sd-hover-bg);padding:9px 11px;border-radius:6px;margin:7px 0 0;white-space:pre;">${esc(list)}</pre>`
        : '<span class="sapc-hint">(无列表输出——全屏 ALV GRID 类报表不落列表缓冲,需到 GUI 前台看)</span>'}
      </div>`;
    } else if (p.execRes) {
      const convLine = (p.conv && p.conv.applied && p.conv.applied.length)
        ? `<div class="sapc-hint" style="margin:0 0 7px;">⚙ 已按转换出口转内码 ${p.conv.applied.length} 项:${esc(p.conv.applied.slice(0, 3).map((c) => `${c.path}: ${c.from} → ${c.to}`).join(';'))}${p.conv.applied.length > 3 ? ' …' : ''}</div>`
        : '';
      resultHtml = `<div class="pb-card">
        <div class="pb-title">执行结果 <span class="sub">${p.execMs ? `${p.execMs}ms` : ''}</span>
          <span style="flex:1"></span><button data-act="probe-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制 JSON</button></div>
        ${convLine}
        ${this._probeValHtml(p.execRes)}
      </div>`;
    }
    resultHtml += this._renderDiagCard();
    if (p.execRes != null || p.lastErr) {
      resultHtml += `<div style="display:flex;gap:8px;margin:10px 2px;">
        <button data-act="probe-rep-copy" style="font-size:12px;padding:3px 14px;">📋 复制报告</button>
        <button data-act="probe-rep-html" style="font-size:12px;padding:3px 14px;">📄 导出 HTML</button>
        ${p.execRes != null ? '<button data-act="probe-rep-xlsx" style="font-size:12px;padding:3px 14px;">📊 导出 Excel</button>' : ''}
        <span class="sapc-hint">Excel=多 SHEET(概览/接口解读/输入/每输出一表);HTML 报告含解读与诊断全要素</span>
      </div>`;
    }

    let explainCard = '';
    if (p.explainLoading || p.explain) {
      const exTitle = (p.explain && p.explain.kind === 'report') ? '程序解读' : '接口解读';
      const exBody = (p.explain && p.explain.md)
        ? `${p.explainLoading ? '<div class="sapc-hint" style="margin:0 0 6px;">⏳ 重新解读中,以下为上次结果…</div>' : ''}<div class="md">${renderMarkdown(String(p.explain.md))}</div>`
        : '<div class="sapc-loading"><span class="spin"></span>AI 正在通读签名与源码…</div>';
      explainCard = `<div class="pb-card sapc-diag">
        <div class="pb-title">📐 ${exTitle}${p.explain && !p.explain.hasSource ? '<span class="sub">源码不可得,基于签名推断</span>' : ''}${p.explain && p.explain.model ? `<span class="sub">${esc(p.explain.model)}</span>` : ''}
          <span style="flex:1"></span>${p.explain && !p.explainLoading ? '<button data-act="explain-close" style="font-size:11.5px;padding:2px 10px;">收起</button>' : ''}</div>
        ${exBody}
      </div>`;
    }

    // v10 xref 结果卡:引用表(去重程序数)+ 程序搜索清单;v11 tr 结果卡
    let xrefHtml = '';
    if (isTr) {
      const parts = [];
      if (p.xrefSearching) {
        parts.push('<div class="sapc-loading"><span class="spin"></span>正在查传输目录(E070/E071)…</div>');
      }
      if (p.objTrRes) {
        const r = p.objTrRes;
        const trSt = TRD_STATUS; const sev = TRD_SEV;   // 映射收敛到模块级(渲染/导出共源)
        const nMiss = r.matrix.filter((x) => x.verdict === 'missing').length;
        const nDiff = r.matrix.filter((x) => x.verdict === 'diff').length;
        const nCos = r.matrix.filter((x) => x.verdict === 'cosmetic').length;
        const nUnv = r.matrix.filter((x) => x.verdict === 'unverified').length;
        const fpTip = (c) => !c.hash ? '内容指纹未生成(超出本次详查范围)'
          : `源码指纹(SHA256 前8位) 全文:#${escAttr(String(c.hash).slice(0, 8))} 代码:${c.code ? '#' + escAttr(String(c.code).slice(0, 8)) : '—'}`;
        // v17.1 sysfail(查询失败)显式展示,不与「缺失」混淆;tr=按该系统导入时刻推断的版本来源 TR
        const fpCell = (c) => c.sysfail ? '<span class="sapc-hint" style="color:var(--sd-warning-text);" title="该系统查询失败(未连接或查询出错)——不是「未传输」,补连凭证后重查即可比对">⚠ 查询失败</span>'
          : c.miss ? '<span class="sapc-hint">缺失</span>'
          : `<div style="line-height:1.5;" title="${fpTip(c)}">${c.udat ? `<b>${esc(c.udat.slice(0, 4))}-${esc(c.udat.slice(4, 6))}-${esc(c.udat.slice(6, 8))}</b> <span class="sapc-hint">${esc(c.unam || '')}</span>` : `<span class="sapc-hint">${esc(c.unam || '?')}</span>`}${c.tr ? `<div class="sapc-hint" title="按该系统导入时刻对齐请求日期推断的版本来源,仅供参考(结论以上方哈希比对为准)">TR ${esc(c.tr)}</div>` : ''}</div>`;
        const matRows = r.matrix.slice(0, 120).map((m) => {
          const [lb, col] = sev[m.verdict] || [m.verdict, 'inherit'];
          return `<tr><td class="xref-td-name">${esc(m.obj)}</td><td>${esc(XREF_SUBC[m.subc] || m.subc || '')}</td>
            <td>${fpCell(m.dvp)}</td><td>${fpCell(m.qas)}</td><td>${fpCell(m.prd)}</td>
            <td style="white-space:nowrap;">${m.lastTr ? `<a href="#" data-act="objtr-tr" data-tr="${escAttr(m.lastTr)}" style="color:var(--sd-accent-active);text-decoration:none;">${esc(m.lastTr)}</a>` : '<span class="sapc-hint">-</span>'}</td>
            <td style="color:${col};font-weight:600;white-space:nowrap;">${lb}</td>
            <td style="font-size:11.5px;white-space:normal;">${esc(m.why || '')}</td></tr>`;
        }).join('');
        const reqRows = (r.requests || []).map((q) =>
          `<tr><td class="xref-td-name"><a href="#" data-act="objtr-tr" data-tr="${escAttr(q.trkorr)}" style="color:var(--sd-accent-active);text-decoration:none;">${esc(q.trkorr)}</a></td>
          <td>${esc(q.text || '')}</td><td>${esc(trSt[q.status] || q.status || '')}</td><td>${esc(q.date || '')}</td><td>${esc(q.user || '')}</td><td>${q.n}</td></tr>`).join('');
        const objTypeLabel = ({ TRAN: '事务码', FUNC: '函数模块', FUGR: '函数组', PROG: '程序', TABL: '表', DTEL: '数据元素', DOMA: '域', CLAS: '类' })[r.objType] || r.objType || '';
        const isProgObj = !r.objType || ['PROG', 'TRAN', 'FUNC', 'FUGR'].includes(r.objType);
        parts.push(`<div class="pb-card">
          <div class="pb-title">🎯 「${esc(r.obj)}」传输溯源 <span class="sub">${objTypeLabel ? `识别为 ${esc(objTypeLabel)} · ` : ''}${r.tcode ? `事务码 ${esc(r.tcode)} → ` : ''}${r.func ? `函数 ${esc(r.func)} → ` : ''}程序 ${esc(r.prog)} · ${r.trCount} 个请求(按对象数显示前 ${r.trShown}) · ${r.matrix.length} 个组成对象 · <span style="color:var(--sd-warning-text);">⚠${nDiff} 不一致</span>${nCos ? ` <span style="color:var(--sd-text-faint);">≈${nCos} 仅注释差异</span>` : ''} <span style="color:var(--sd-danger-text);">✗${nMiss} 未传</span>${nUnv ? ` <span style="color:var(--sd-warning-text);">⟳${nUnv} 无法比对</span>` : ''} · ${r.ms}ms</span>
            <span style="flex:1"></span><button data-act="probe-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制 JSON</button></div>
          ${(r.fpErrs && r.fpErrs.length) ? `<div class="sapc-hint" style="color:var(--sd-warning-text);margin:4px 0;">部分系统版本查询异常:${esc(r.fpErrs.join('; '))}(缺凭证时去连接管理补连,补连后点重查——查询失败≠未传输)</div>` : ''}
          <div class="res-sec">版本矩阵 <span class="sapc-hint">结论+说明=三系统源码内容逐字比对(全文+剥离注释双 SHA256,悬停日期看指纹);日期/账号仅供参考(导入会重写时间戳);系统列下 TR=按该系统导入时刻推断的版本来源(结论以哈希比对为准);「≈ 仅注释差异」=代码一致仅注释文本不同;「⟳ 无法比对」=该系统未连接/查询失败(非「未传输」);「未详查」=超出本次详查范围(前 30 个)</span></div>
          ${matRows ? `<table class="res-tbl"><thead><tr><th>对象</th><th>类型</th><th>DVP</th><th>QAS</th><th>PRD</th><th>最新请求</th><th>结论</th><th>说明</th></tr></thead><tbody>${matRows}</tbody></table>
          ${r.matrix.length > 120 ? `<span class="sapc-hint">…共 ${r.matrix.length} 个,仅显示前 120</span>` : ''}` : (isProgObj ? '<span class="sapc-hint">(视角系统查不到该程序——确认名称或环境)</span>' : `<span class="sapc-hint">(识别为${esc(objTypeLabel)}:非程序对象,无源码版本矩阵)</span>`)}
          <div class="res-sec">请求溯源 <span class="sapc-hint">按携带对象数排序;点请求号看完整详情</span></div>
          ${reqRows ? `<table class="res-tbl"><thead><tr><th>请求</th><th>描述</th><th>状态</th><th>日期</th><th>用户</th><th>对象数</th></tr></thead><tbody>${reqRows}</tbody></table>` : '<span class="sapc-hint">(无请求记录——新对象或从未随 TR 传输)</span>'}
          ${r.e71More ? '<div class="sapc-hint" style="margin:4px 0;">请求对象行达 1000 上限,历史可能不全</div>' : ''}
        </div>`);
      }
      // v13.2:详情卡与溯源卡独立渲染——详情卡 unshift 到**最上面**(09-16 用户实爆:此前 push
      //   在溯源卡之后,被高大的版本矩阵顶到折叠线以下,点请求号只见闪一下、以为没反应);
      //   配合 probeTrView 收尾 scrollIntoView。下钻不清溯源卡,详情可收起返回。
      if (p.trRes) {
        const h = p.trRes.head || {};
        const trSt = TRD_STATUS[String(h.TRSTATUS || '')] || h.TRSTATUS;
        const trFn = TRD_FUNC[String(h.TRFUNCTION || '')] || h.TRFUNCTION;
        const kv = [['请求', h.TRKORR], ['类型', trFn], ['状态', `${h.TRSTATUS || ''} ${trSt}`],
          ['所有者', h.AS4USER], ['最后修改', h.AS4DATE ? `${h.AS4DATE.slice(0, 4)}-${h.AS4DATE.slice(4, 6)}-${h.AS4DATE.slice(6, 8)}` : ''],
          ['目标系统', h.TARSYSTEM], ['上级请求', h.STRKORR || '']]
          .filter((x) => x[1] !== '' && x[1] != null)
          .map(([k, v]) => `<div class="res-kv"><span class="k">${k}</span><span class="v">${esc(String(v))}</span></div>`).join('');
        const objCount = p.trRes.objCount || 0;
        parts.unshift(`<div class="pb-card" id="sapc-tr-detail">
          <div class="pb-title">请求 ${esc(p.trRes.trkorr || '')} <span class="sub">${objCount} 个对象${objCount === 0 ? ' · 还没挂对象(SE10 对象清单为空)' : ''}</span>
            <span style="flex:1"></span>${p.objTrRes ? '<button data-act="tr-detail-back" style="font-size:11.5px;padding:2px 10px;">← 返回溯源</button>' : ''}<button data-act="tr-detail-close" style="font-size:11.5px;padding:2px 10px;">✕ 收起</button><button data-act="probe-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制 JSON</button></div>
          ${kv}
          <div class="res-sec">对象清单</div>
          ${objCount ? this._probeValHtml(p.trRes.objects) : '<span class="sapc-hint">(空——对象在子任务或尚未登记)</span>'}
          ${(p.trRes.subtasks && p.trRes.subtasks.length) ? `<div class="res-sec">子任务</div>${this._probeValHtml(p.trRes.subtasks)}` : ''}
        </div>`);
      }
      if (p.trListRes) {
        parts.push(`<div class="pb-card">
          <div class="pb-title">${esc(p.trListRes.user || '')} 的传输请求 <span class="sub">${p.trListRes.count || 0} 条${p.trListRes.moreAvailable ? '+' : ''}(按目录原序,建议看 AS4DATE)</span></div>
          ${(p.trListRes.list && p.trListRes.list.length) ? this._probeValHtml(p.trListRes.list) : '<span class="sapc-hint">该用户在此环境没有请求记录</span>'}
        </div>`);
      }
      if (p.lastErr) parts.push(`<div class="pb-err"><span>✗</span><span>${esc(p.lastErr)}</span></div>`);
      // v15 导出全覆盖:传输形态此前只有「复制JSON」——版本矩阵恰是最该进 Excel 的结果
      if (p.objTrRes || p.trRes || p.trListRes) {
        parts.push(this._exportBar([
          { act: 'tr-rep-copy', label: '📋 复制报告' },
          { act: 'tr-rep-html', label: '📄 导出 HTML' },
          { act: 'tr-rep-xlsx', label: '📊 导出 Excel' },
        ], 'Excel=多 SHEET(概览/版本矩阵/请求溯源/请求对象/请求列表);HTML 报告含矩阵与请求详情全要素'));
      }
      xrefHtml = parts.join('');
    } else if (isXref) {
      const parts = [];
      if (p.xrefSearching) {
        parts.push('<div class="sapc-loading"><span class="spin"></span>正在查引用(WBCROSSGT+TRDIRT)…</div>');
      }
      if (p.xrefRes) parts.push(this._xrefAggHtml(p.xrefRes, 'used'));
      if (p.searchRes) {
        const progs = p.searchRes.progs || [];
        const titles = p.searchRes.titles || {};
        const desc = p.searchRes.descHits || [];
        const rowHtml = progs.slice(0, 100).map((r) => {
          const nm = String(r.PROGNAME || '');
          const tt = String((titles[nm] && titles[nm].text) || '');
          return `<tr><td class="xref-td-name">${esc(nm)}</td><td>${esc(tt)}</td><td>${esc(XREF_SUBC[String(r.SUBC || '').trim()] || String(r.SUBC || ''))}</td><td>${esc(String(r.UNAM || ''))}</td><td>${esc(String(r.UDAT || ''))}</td></tr>`;
        }).join('');
        const descRows = desc.slice(0, 50).map((r) =>
          `<tr><td class="xref-td-name">${esc(String(r.REPID || ''))}</td><td>${esc(String(r.TEXT || ''))}</td></tr>`).join('');
        parts.push(`<div class="pb-card">
          <div class="pb-title">搜「${esc(p.searchRes.kw || '')}」 <span class="sub">名字命中 ${p.searchRes.count || 0}${p.searchRes.moreAvailable ? '+' : ''} · 描述命中 ${p.searchRes.descCount || 0}${p.searchRes.titleMs != null ? ` · 标题增强 ${p.searchRes.titleMs}ms` : ''}</span>
            <span style="flex:1"></span><button data-act="probe-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制 JSON</button></div>
          ${(progs.length || desc.length) ? `
          ${progs.length ? `<div class="res-sec">按名字(${progs.length > 100 ? `前 100 / 共 ${progs.length}` : progs.length})</div>
          <table class="res-tbl"><thead><tr><th>程序</th><th>标题</th><th>类型</th><th>最后改者</th><th>日期</th></tr></thead><tbody>${rowHtml}</tbody></table>` : ''}
          ${desc.length ? `<div class="res-sec">按描述(标题含关键词,支持中文)</div>
          <table class="res-tbl"><thead><tr><th>程序</th><th>标题</th></tr></thead><tbody>${descRows}</tbody></table>` : ''}`
          : '<span class="sapc-hint">名字和描述都没有命中</span>'}
        </div>`);
      }
      if (p.usesRes) {
        const refs = p.usesRes.refs || [];
        const titles = p.usesRes.titles || {};
        const m = new Map();
        refs.forEach((r) => {
          const nm = String(r.NAME || ''); if (!nm) return;
          const e = m.get(nm) || { n: 0, ot: new Set() };
          e.n += 1; if (r.OTYPE) e.ot.add(String(r.OTYPE).toUpperCase()); m.set(nm, e);
        });
        const rowsHtml = [...m.entries()].sort((a, b) => b[1].n - a[1].n).map(([nm, e]) =>
          `<tr><td class="xref-td-name">${esc(nm)}</td><td>${esc([...e.ot].map(_xrefOt).join('/') || '-')}</td><td>${e.n}</td><td>${esc(String((titles[nm] && titles[nm].text) || ''))}</td></tr>`).join('');
        parts.push(`<div class="pb-card">
          <div class="pb-title">「${esc(p.usesRes.include || '')}」(含组内 include)引用了 ${m.size} 个对象 <span class="sub">${refs.length} 处引用行${p.usesRes.moreAvailable ? ' · 已达上限' : ''}</span>
            <span style="flex:1"></span><button data-act="probe-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制 JSON</button></div>
          ${rowsHtml ? `<table class="res-tbl"><thead><tr><th>对象</th><th>种类</th><th>次数</th><th>标题</th></tr></thead><tbody>${rowsHtml}</tbody></table>` : '<span class="sapc-hint">(无引用记录)</span>'}
        </div>`);
      }
      if (p.contentRes) {
        const c = p.contentRes;
        if (c.needNarrow) {
          parts.push(`<div class="pb-card">
            <div class="pb-title">🔍 搜内容「${esc(c.kw)}」<span class="sub">名字匹配 ${c.nameMatch} 个程序,超过单次上限 ${c.cap}</span></div>
            <div class="sapc-hint">${esc(c.hint)}</div>
          </div>`);
        } else {
          const markRe = new RegExp(esc(c.kw).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi');
          const cRows = (c.hits || []).slice(0, 100).map((h) => {
            const marked = esc(h.text || '').replace(markRe, (m) => `<mark style="background:var(--sd-accent-soft);color:var(--sd-accent-active);border-radius:3px;">${m}</mark>`);
            return `<tr><td class="xref-td-name">${esc(h.program)}</td><td style="text-align:right;">${h.line}</td><td style="white-space:normal;font-family:monospace;font-size:11.5px;">${marked}</td></tr>`;
          }).join('');
          parts.push(`<div class="pb-card">
            <div class="pb-title">🔍 搜内容「${esc(c.kw)}」<span class="sub">${esc(c.pattern)} · 命中 ${c.totalHits} 处/显示前 ${Math.min(c.totalHits || 0, 100)} · 扫描 ${c.indexed} 程序(新拉 ${c.pulled}/复用 ${c.reused}${c.readFailedCount ? `/读不到 ${c.readFailedCount}` : ''}) · 索引 ${c.indexMs}ms+搜索 ${c.searchMs}ms</span>
              <span style="flex:1"></span><button data-act="probe-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制 JSON</button></div>
            ${(c.hits || []).length ? `<table class="res-tbl"><thead><tr><th>程序</th><th>行</th><th>内容</th></tr></thead><tbody>${cRows}</tbody></table>${c.totalHits > 100 ? '<div class="sapc-hint">…命中过多,仅显示前 100</div>' : ''}` : '<span class="sapc-hint">没有命中——换个关键字,或扩大/调整程序名范围</span>'}
            ${c.indexPartial ? `<div class="sapc-hint" style="margin-top:4px;">⏳ 已索引 ${c.indexed}/${c.nameMatch} 个程序(单次拉源上限 ${c.pullBudget} 个,防超时);再点「🔍 搜内容」继续增量索引,完成后自动覆盖全量</div>` : ''}
          </div>`);
        }
      }
      if (p.lastErr) parts.push(`<div class="pb-err"><span>✗</span><span>${esc(p.lastErr)}</span></div>`);
      // v12 导出排(用户常用需求:结果可下载)——任一引用/搜索结果存在即显示(v15 补 contentRes)
      if (p.xrefRes || p.usesRes || p.searchRes || p.contentRes) {
        parts.push(`<div style="display:flex;gap:8px;margin:10px 2px;">
          <button data-act="xref-rep-copy" style="font-size:12px;padding:3px 14px;">📋 复制报告</button>
          <button data-act="xref-rep-html" style="font-size:12px;padding:3px 14px;">📄 导出 HTML</button>
          <button data-act="xref-rep-xlsx" style="font-size:12px;padding:3px 14px;">📊 导出 Excel</button>
          <span class="sapc-hint">Excel=多 SHEET(概览/程序清单/include 明细/引用行/代码定位);HTML 报告含已查看的代码定位证据</span>
        </div>`);
      }
      xrefHtml = parts.join('');
    } else if (isLint) {
      xrefHtml = this._lintHtml();
    } else if (isGate) {
      xrefHtml = this._gateHtml();
    }

    return `<div class="sapc-probe">
      ${bar}
      ${(!isXref && !isTr && !isLint && !isGate) && !hasForm && !p.execRes ? `<div class="sapc-hint" style="padding:0 2px;">填函数名 → 读接口自动生成表单;或直接贴报文解析填表 → 执行看真实返回。确定性链无 AI,追问走「问 Agent」。</div>` : ''}
      ${explainCard}
      ${(isXref || isTr || isLint || isGate) ? xrefHtml : formCard}
      ${reqCard}
      ${payloadCard}
      ${setsCard}
      ${(isXref || isTr || isLint || isGate) ? '' : `<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;">
        <button data-act="probe-exec" class="primary" style="padding:7px 26px;font-size:13.5px;font-weight:600;" ${p.execLoading ? 'disabled' : ''}>${p.execLoading ? '⏳ 执行中…' : '▶ 执行'}</button>
        ${isRep ? `<input data-probe-f="expectkw" placeholder="期望关键字(逗号分隔,可空)" style="width:220px;" value="${escAttr(p.expectKw || '')}" title="定点排查:执行后自动比对列表输出是否包含这些关键字">
        <input data-probe-f="expectmin" placeholder="最少行数" style="width:86px;" value="${escAttr(p.expectMin || '')}" title="定点排查:期望列表至少多少行,不达即判「未取到」">` : ''}
        <span class="sapc-hint">${isRep ? '执行 = 后台作业真跑报表取回列表,自动比对期望;未取到自动进诊断。' : '直接点执行也行:会自动读接口出表单。结果 = 接口真实返回(表格/KV 原样呈现)。'}</span>
      </div>`}
      ${(isXref || isTr || isLint || isGate) ? '' : resultHtml}
    </div>`;
  }

  // 执行结果通用结构化渲染:数组→表格,对象→KV,标量→KV(不塞 AI,原样呈现)
  _probeValHtml(v, depth = 0) {
    if (v == null) return '<span class="sapc-hint">(空)</span>';
    if (Array.isArray(v)) {
      if (!v.length) return '<span class="sapc-hint">(0 行)</span>';
      const cols = [...new Set(v.slice(0, 50).flatMap((r) => (r && typeof r === 'object') ? Object.keys(r) : ['VALUE']))];
      const rows = v.slice(0, 200).map((r) => `<tr>${cols.map((c) =>
        `<td>${esc(r && typeof r === 'object' ? String(r[c] ?? '') : String(r))}</td>`).join('')}</tr>`).join('');
      return `<table class="res-tbl"><thead><tr>${cols.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead><tbody>${rows}</tbody></table>
        ${v.length > 200 ? `<span class="sapc-hint">…共 ${v.length} 行,仅显示前 200</span>` : ''}`;
    }
    if (typeof v === 'object') {
      return Object.entries(v).map(([k, val]) => {
        if (val && typeof val === 'object') {
          return `<div class="res-sec">${esc(k)}</div>${this._probeValHtml(val, depth + 1)}`;
        }
        return `<div class="res-kv"><span class="k" title="${escAttr(k)}">${esc(k)}</span><span class="v">${esc(String(val))}</span></div>`;
      }).join('');
    }
    return `<div class="res-kv"><span class="v">${esc(String(v))}</span></div>`;
  }

  // DOM 表单 → store(import inputs / tables JSON textareas)。tables JSON 非法时 false。
  _captureProbeForm() {
    const p = this.probe;
    this.root.querySelectorAll('[data-imp]').forEach((el) => {
      p.form.import[el.dataset.imp] = el.value;
    });
    for (const el of this.root.querySelectorAll('[data-tbljson]')) {
      try {
        const rows = JSON.parse(el.value || '[]');
        if (!Array.isArray(rows)) throw new Error('不是 JSON 数组');
        p.form.tables[el.dataset.tbljson] = rows;
      } catch (err) {
        _toast(`表 ${el.dataset.tbljson} 的 JSON 非法:${err.message}`, 'err');
        return false;
      }
    }
    return true;
  }

  // 参数对象归一化(变式/报文共用)。三种形态全吃:
  //   ① {"import":{...},"tables":{...}}   结构化报文 → 原样取
  //   ② {"PLANT":"1000","tables":{...}}   平铺+tables 混合(真实第三方报文常见)→
  //      顶层标量/结构→import,tables 键并入 tables,import 键并入 import
  //   ③ {"MATERIAL":"100000","IT_TAB":[…]} 纯平铺 → 数组值→tables,其余→import
  _normalizeProbeParams(obj) {
    const out = { import: {}, tables: {} };
    if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return out;
    if (obj.import && typeof obj.import === 'object' && !Array.isArray(obj.import)) {
      out.import = obj.import;
      if (obj.tables && typeof obj.tables === 'object') out.tables = obj.tables;
      return out;
    }
    for (const [k, v] of Object.entries(obj)) {
      if (k === 'import' && v && typeof v === 'object') { Object.assign(out.import, v); continue; }
      if (k === 'tables' && v && typeof v === 'object') { Object.assign(out.tables, v); continue; }
      if (Array.isArray(v)) out.tables[k] = v;
      else out.import[k] = v;
    }
    return out;
  }

  // v10 引用查询:对象(表/结构/类/函数组)被哪些程序引用;「表.字段」→ 字段级类型引用
  async probeXrefUsed() {
    const p = this.probe;
    this._probeBarVals();
    const raw = p.fm.trim().toUpperCase();
    if (!raw) { _toast('填对象名,如 MARA 或 MARA.MATNR', 'err'); return; }
    let name = raw, field = '';
    if (raw.includes('.')) { const i = raw.indexOf('.'); name = raw.slice(0, i); field = raw.slice(i + 1); }
    p.xrefSearching = true; p.xrefRes = null; p.lastErr = null;
    p.usesRes = null; p.xrefOpen = {}; p.xrefCode = {}; p.xrefFilter = 'all'; p.xrefQ = ''; p.xrefLimit = 30; p.objTrRes = null;   // 新查询=新树
    this.render();
    try {
      const res = await bridge.run('sap-xref', { action: 'whereused', system: p.sys, name, field }, { timeoutMs: 30000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.xrefRes = res;
    } catch (err) { p.lastErr = this._probeErr('查引用失败', err); }
    p.xrefSearching = false;
    this.render();
  }

  // v10 程序名搜索:REPOSRC PROGNAME LIKE
  async probeXrefSearch() {
    const p = this.probe;
    this._probeBarVals();
    const kw = p.fm.trim().toUpperCase();
    if (!kw) { _toast('填关键字,如 ZMM 或 PRODORD', 'err'); return; }
    p.xrefSearching = true; p.searchRes = null; p.lastErr = null;
    this.render();
    try {
      const res = await bridge.run('sap-xref', { action: 'search', system: p.sys, kw }, { timeoutMs: 30000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.searchRes = res;
    } catch (err) { p.lastErr = this._probeErr('搜程序失败', err); }
    p.xrefSearching = false;
    this.render();
  }

  // v12「它用了什么」:反查某主程序(含组内 include)引用了哪些对象(sap-xref uses)
  async probeXrefUses(main) {
    const p = this.probe;
    if (!main) return;
    p.xrefSearching = true; p.usesRes = null; p.lastErr = null;
    this.render();
    try {
      const res = await bridge.run('sap-xref', { action: 'uses', system: p.sys, include: main }, { timeoutMs: 30000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.usesRes = res;
    } catch (err) { p.lastErr = this._probeErr('反查失败', err); }
    p.xrefSearching = false;
    this.render();
  }

  // v12 看代码:拉 include 源码定位引用行(路由 code action),结果缓存 p.xrefCode[include]
  async probeXrefCode(inc, ot) {
    const p = this.probe;
    const cur = p.xrefCode[inc];
    if (cur && cur.loading) return;
    if (cur && !cur.loading) { delete p.xrefCode[inc]; this.render(); return; }   // 再点=收起
    const src = p.xrefRes || {};
    p.xrefCode[inc] = { loading: true };
    this.render();
    try {
      const res = await bridge.run('sap-xref', { action: 'code', system: p.sys, include: inc, name: src.name || '', field: src.field || '', otype: ot || '' }, { timeoutMs: 90000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.xrefCode[inc] = res;
    } catch (err) { p.xrefCode[inc] = { err: String((err && err.message) || err) }; }
    this.render();
  }

  // v12 引用结果导出三件套(用户常用需求:结果可下载)——复制报告/HTML/Excel 共源
  _probeXrefReportMd() {
    const p = this.probe;
    const stamp = _nowStamp();
    const L = [];
    L.push(`# SAP Driver · 引用查询报告`);
    L.push(`- 环境:${p.sys} · 导出时间:${stamp}`);
    if (p.xrefRes) {
      const r = p.xrefRes;
      const titles = r.titles || {};
      const { arr, indirect } = this._xrefAggData(r.refs || []);
      const nCus = arr.filter((g) => g.custom).length;
      L.push(``);
      L.push(`## 「${r.name || ''}${r.field ? '.' + r.field : ''}」影响分析`);
      L.push(`- 引用 ${r.count} 处 · ${arr.length} 个程序 · 自定义 ${nCus} / 标准 ${arr.length - nCus} · ${indirect ? `含 ${indirect} 处间接` : '全部直接引用'}${r.titlesCount != null ? ` · 标题命中 ${r.titlesCount}` : ''}`);
      if (r.customCount) L.push(`- 自定义引用 ${r.customCount} 行全量(专项补全)${r.moreAvailable ? ';标准部分截断至上限' : ''}`);
      L.push(``);
      L.push(`### 程序影响清单(自定义优先,前 100)`);
      L.push(`| 程序 | 标题 | 类别 | 引用处 | 种类 |`);
      L.push(`| --- | --- | --- | --- | --- |`);
      arr.slice(0, 100).forEach((g) => {
        L.push(`| ${g.main} | ${(titles[g.main] && titles[g.main].text) || ''} | ${g.custom ? '自定义' : '标准'} | ${g.count} | ${[...g.ots].map(_xrefOt).join('/') || '-'} |`);
      });
      L.push(``);
      L.push(`### include 明细(前 150)`);
      L.push(`| 主程序 | include | 引用处 |`);
      L.push(`| --- | --- | --- |`);
      let n = 0;
      for (const g of arr) {
        for (const [inc, c] of g.incs) {
          if (n++ >= 150) break;
          L.push(`| ${g.main} | ${inc} | ${c} |`);
        }
        if (n >= 150) break;
      }
      const codes = Object.entries(p.xrefCode || {}).filter(([, v]) => v && v.hitCount != null);
      if (codes.length) {
        L.push(``);
        L.push(`### 代码定位(已查看 ${codes.length} 个 include)`);
        for (const [inc, cd] of codes) {
          L.push(``);
          L.push(`**${inc}** — 「${cd.word || ''}」命中 ${cd.hitCount} 处 / 共 ${cd.scanned || 0} 行`);
          (cd.segments || []).slice(0, 12).forEach((s) => {
            L.push(``);
            L.push('```');
            (s.rows || []).forEach((row) => L.push(`${String(row.no).padStart(4, ' ')} | ${row.text}`));
            L.push('```');
          });
        }
      }
    }
    if (p.usesRes) {
      const r = p.usesRes;
      const titles = r.titles || {};
      const m = new Map();
      (r.refs || []).forEach((x) => {
        const nm = String(x.NAME || ''); if (!nm) return;
        const e = m.get(nm) || { n: 0, ot: new Set() };
        e.n += 1; if (x.OTYPE) e.ot.add(String(x.OTYPE).toUpperCase()); m.set(nm, e);
      });
      L.push(``);
      L.push(`## 「${r.include || ''}」引用对象清单(含组内 include)`);
      L.push(`- 共 ${m.size} 个对象 · ${r.count} 处引用行`);
      L.push(``);
      L.push(`| 对象 | 种类 | 次数 | 标题 |`);
      L.push(`| --- | --- | --- | --- |`);
      [...m.entries()].sort((a, b) => b[1].n - a[1].n).slice(0, 200).forEach(([nm, e]) => {
        L.push(`| ${nm} | ${[...e.ot].map(_xrefOt).join('/') || '-'} | ${e.n} | ${(titles[nm] && titles[nm].text) || ''} |`);
      });
    }
    if (p.searchRes) {
      const r = p.searchRes;
      const titles = r.titles || {};
      L.push(``);
      L.push(`## 程序搜索「${r.kw || ''}」`);
      L.push(``);
      L.push(`### 按名字(${r.count || 0})`);
      if ((r.progs || []).length) {
        L.push(`| 程序 | 标题 | 类型 | 最后改者 | 日期 |`);
        L.push(`| --- | --- | --- | --- | --- |`);
        r.progs.slice(0, 100).forEach((x) => {
          const nm = String(x.PROGNAME || '');
          L.push(`| ${nm} | ${(titles[nm] && titles[nm].text) || ''} | ${XREF_SUBC[String(x.SUBC || '').trim()] || x.SUBC || ''} | ${x.UNAM || ''} | ${x.UDAT || ''} |`);
        });
      } else L.push(`(无命中)`);
      if ((r.descHits || []).length) {
        L.push(``);
        L.push(`### 按描述(${r.descCount || 0})`);
        L.push(`| 程序 | 标题 |`);
        L.push(`| --- | --- |`);
        r.descHits.slice(0, 80).forEach((x) => L.push(`| ${x.REPID || x.NAME || ''} | ${x.TEXT || ''} |`));
      }
    }
    if (p.contentRes) {
      const c = p.contentRes;
      L.push(``);
      L.push(`## 🔍 内容搜索「${c.kw || ''}」`);
      if (c.needNarrow) {
        L.push(`- 名字匹配 ${c.nameMatch} 个程序,超过单次上限 ${c.cap}——${c.hint || '请收窄程序名范围'}`);
      } else {
        L.push(`- 模式 \`${c.pattern || ''}\` · 命中 ${c.totalHits} 处 · 扫描 ${c.indexed} 程序(新拉 ${c.pulled}/复用 ${c.reused}${c.readFailedCount ? `/读不到 ${c.readFailedCount}` : ''}) · 索引 ${c.indexMs}ms + 搜索 ${c.searchMs}ms`);
        if ((c.hits || []).length) {
          L.push(``);
          L.push(`| 程序 | 行 | 内容 |`);
          L.push(`| --- | --- | --- |`);
          c.hits.slice(0, 300).forEach((h) => L.push(`| ${h.program} | ${h.line} | ${String(h.text || '').replace(/\|/g, '\\|').replace(/`/g, "'")} |`));
          if (c.hits.length > 300) L.push(`(共 ${c.hits.length} 行,表内截前 300,全量见 Excel)`);
        } else L.push(`- 没有命中——换个关键字,或扩大/调整程序名范围`);
      }
    }
    return L.join('\n');
  }

  _xrefXlsxSheets() {
    const p = this.probe;
    const stamp = _nowStamp();
    const sheets = [];
    if (p.xrefRes) {
      const r = p.xrefRes;
      const titles = r.titles || {};
      const { arr, indirect } = this._xrefAggData(r.refs || []);
      const nCus = arr.filter((g) => g.custom).length;
      sheets.push({ name: '概览', rows: [
        { 项目: '对象', 内容: `${r.name || ''}${r.field ? '.' + r.field : ''}` },
        { 项目: '环境 / 导出时间', 内容: `${p.sys} · ${stamp}` },
        { 项目: '引用', 内容: `${r.count} 处(返回 ${(r.refs || []).length} 行)` },
        { 项目: '程序', 内容: `${arr.length} 个 · 自定义 ${nCus} / 标准 ${arr.length - nCus}` },
        { 项目: '引用性质', 内容: indirect ? `含 ${indirect} 处间接` : '全部直接引用' },
        { 项目: '自定义补全', 内容: r.customCount ? `${r.customCount} 行全量` : '-' },
      ] });
      sheets.push({ name: '程序影响清单', rows: arr.slice(0, 1000).map((g) => ({
        程序: g.main, 标题: (titles[g.main] && titles[g.main].text) || '', 类别: g.custom ? '自定义' : '标准',
        引用处: g.count, 种类: [...g.ots].map(_xrefOt).join('/'),
      })) });
      const incRows = [];
      arr.forEach((g) => { for (const [inc, c] of g.incs) incRows.push({ 主程序: g.main, include: inc, 标题: (titles[inc] && titles[inc].text) || '', 引用处: c }); });
      sheets.push({ name: 'include明细', rows: incRows });
      sheets.push({ name: '引用行', rows: (r.refs || []).map((x) => ({
        种类: _xrefOt(x.OTYPE), 对象: x.NAME, 引用方: x.INCLUDE, 主程序: _xrefMainOf(x.INCLUDE),
        直接: String(x.DIRECT || '').trim() === 'X' ? '是' : '间接',
      })) });
      const codeRows = [];
      Object.entries(p.xrefCode || {}).forEach(([inc, cd]) => {
        if (!cd || cd.hitCount == null) return;
        (cd.segments || []).forEach((s) => (s.rows || []).forEach((row) => codeRows.push({
          include: inc, 行号: row.no, 命中: (s.hits || []).includes(row.no) ? '是' : '', 内容: row.text,
        })));
      });
      if (codeRows.length) sheets.push({ name: '代码定位', rows: codeRows });
    } else if (p.usesRes) {
      const r = p.usesRes;
      const titles = r.titles || {};
      const m = new Map();
      (r.refs || []).forEach((x) => {
        const nm = String(x.NAME || ''); if (!nm) return;
        const e = m.get(nm) || { n: 0, ot: new Set() };
        e.n += 1; if (x.OTYPE) e.ot.add(String(x.OTYPE).toUpperCase()); m.set(nm, e);
      });
      sheets.push({ name: '概览', rows: [
        { 项目: '程序(含组内 include)', 内容: r.include || '' },
        { 项目: '环境 / 导出时间', 内容: `${p.sys} · ${stamp}` },
        { 项目: '引用对象', 内容: `${m.size} 个 · ${r.count} 处引用行` },
      ] });
      sheets.push({ name: '引用对象', rows: [...m.entries()].sort((a, b) => b[1].n - a[1].n).map(([nm, e]) => ({
        对象: nm, 种类: [...e.ot].map(_xrefOt).join('/'), 次数: e.n, 标题: (titles[nm] && titles[nm].text) || '',
      })) });
    } else if (p.searchRes) {
      const r = p.searchRes;
      const titles = r.titles || {};
      sheets.push({ name: '概览', rows: [
        { 项目: '关键词', 内容: r.kw || '' },
        { 项目: '环境 / 导出时间', 内容: `${p.sys} · ${stamp}` },
        { 项目: '命中', 内容: `名字 ${r.count || 0} · 描述 ${r.descCount || 0}` },
      ] });
      sheets.push({ name: '按名字', rows: (r.progs || []).map((x) => ({
        程序: x.PROGNAME, 标题: (titles[String(x.PROGNAME || '')] && titles[String(x.PROGNAME || '')].text) || '',
        类型: XREF_SUBC[String(x.SUBC || '').trim()] || x.SUBC || '', 最后改者: x.UNAM, 日期: x.UDAT,
      })) });
      if ((r.descHits || []).length) sheets.push({ name: '按描述', rows: r.descHits.map((x) => ({ 程序: x.REPID || x.NAME || '', 标题: x.TEXT || '' })) });
    }
    // v15 内容搜索结果接入导出(可与其余引用结果并存,故独立 if 不走互斥链)
    if (p.contentRes) {
      const c = p.contentRes;
      const ov = [{ 项目: '关键词', 内容: c.kw || '' }];
      if (c.needNarrow) {
        ov.push({ 项目: '结果', 内容: `名字匹配 ${c.nameMatch} 个程序,超过单次上限 ${c.cap}——${c.hint || '请收窄'}` });
      } else {
        ov.push({ 项目: '模式 / 命中', 内容: `${c.pattern || ''} · ${c.totalHits} 处` });
        ov.push({ 项目: '扫描 / 耗时', 内容: `${c.indexed} 程序(新拉 ${c.pulled}/复用 ${c.reused}) · 索引 ${c.indexMs}ms + 搜索 ${c.searchMs}ms` });
        ov.push({ 项目: '环境 / 导出时间', 内容: `${p.sys} · ${_nowStamp()}` });
        sheets.push({ name: '搜内容命中行', rows: (c.hits || []).map((h) => ({ 程序: h.program, 行: h.line, 内容: h.text || '' })) });
      }
      if (sheets.length && sheets[0].name === '概览') sheets.push({ name: '搜内容概览', rows: ov });
      else sheets.unshift({ name: '概览', rows: ov });
    }
    return sheets;
  }

  async probeXrefExport(kind) {
    const p = this.probe;
    try {
      const label = (p.xrefRes && `影响分析-${p.xrefRes.name || ''}${p.xrefRes.field ? '.' + p.xrefRes.field : ''}`)
        || (p.usesRes && `引用对象-${p.usesRes.include || ''}`) || (p.searchRes && `程序搜索-${p.searchRes.kw || ''}`)
        || (p.contentRes && `内容搜索-${p.contentRes.kw || ''}`) || '引用查询';
      if (kind === 'copy' || kind === 'html') {
        await this._mdExport(kind, this._probeXrefReportMd(), {
          title: 'SAP Driver 引用查询报告',
          subtitle: `${p.sys} · ${_nowStamp()}`,
          filename: label,
        });
        return;
      }
      const sheets = this._xrefXlsxSheets();
      if (!sheets.length) { _toast('没有可导出的结果', 'info'); return; }
      downloadXlsx(`${safeFilename(label)}.xlsx`, sheets);
      _toast(`✓ 已导出 Excel(${sheets.length} 个 SHEET)`, 'ok');
    } catch (err) { _toast(`导出失败:${err.message || err}`, 'err'); }
  }


  // v15 传输溯源报告:按对象分析(版本矩阵/请求溯源)> 请求详情 > 用户请求列表,有啥导啥
  _trReportMd() {
    const p = this.probe;
    const L = ['# SAP Driver 传输溯源报告'];
    L.push(`- 环境:${p.sys} · 导出时间:${_nowStamp()}`);
    const r = p.objTrRes;
    if (r) {
      const cnt = (v) => (r.matrix || []).filter((x) => x.verdict === v).length;
      L.push('');
      L.push(`## 🎯 「${r.obj || ''}」按对象分析`);
      L.push(`- ${r.tcode ? `事务码 ${r.tcode} → ` : ''}${r.func ? `函数 ${r.func} → ` : ''}程序 ${r.prog || '?'} · ${r.trCount} 个请求(显示前 ${r.trShown}) · ${(r.matrix || []).length} 个组成对象 · ⚠${cnt('diff')} 不一致${cnt('cosmetic') ? ` ≈${cnt('cosmetic')} 仅注释差异` : ''} · ✗${cnt('missing')} 未传 · ${r.ms}ms`);
      if ((r.fpErrs || []).length) L.push(`- 部分系统版本查询异常:${r.fpErrs.join('; ')}`);
      L.push('');
      L.push('### 版本矩阵(三系统源码内容逐字比对:全文+剥离注释双 SHA256;日期仅供参考,导入会重写;系统列 TR=按导入时刻推断)');
      L.push('| 对象 | 类型 | DVP | QAS | PRD | QAS TR | PRD TR | 最新请求 | 结论 | 说明 |');
      L.push('| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |');
      const fp = (c) => !c ? '?' : c.sysfail ? '⚠查询失败' : c.miss ? '缺失' : (c.udat ? `${c.udat.slice(0, 4)}-${c.udat.slice(4, 6)}-${c.udat.slice(6, 8)} ${c.unam || ''}` : (c.unam || '?'));
      (r.matrix || []).slice(0, 500).forEach((m) => {
        L.push(`| ${m.obj} | ${XREF_SUBC[m.subc] || m.subc || ''} | ${fp(m.dvp)} | ${fp(m.qas)} | ${fp(m.prd)} | ${(m.qas && m.qas.tr) || '-'} | ${(m.prd && m.prd.tr) || '-'} | ${m.lastTr || '-'} | ${TRD_SEV_TEXT[m.verdict] || m.verdict} | ${m.why || ''} |`);
      });
      if ((r.matrix || []).length > 500) L.push(`(共 ${r.matrix.length} 行,表内截前 500,全量见 Excel)`);
      if (r.e71More) L.push('(请求对象行达 1000 上限,历史可能不全)');
      if ((r.requests || []).length) {
        L.push('');
        L.push('### 请求溯源');
        L.push('| 请求 | 描述 | 状态 | 日期 | 用户 | 对象数 |');
        L.push('| --- | --- | --- | --- | --- | --- |');
        r.requests.forEach((q) => L.push(`| ${q.trkorr} | ${q.text || ''} | ${TRD_STATUS[q.status] || q.status || ''} | ${q.date || ''} | ${q.user || ''} | ${q.n} |`));
      }
    }
    const t = p.trRes;
    if (t) {
      const h = t.head || {};
      const objs = t.objects || [];
      L.push('');
      L.push(`## 请求 ${t.trkorr || ''} 详情`);
      L.push(`- 类型 ${TRD_FUNC[h.TRFUNCTION] || h.TRFUNCTION || ''} · 状态 ${h.TRSTATUS || ''}${TRD_STATUS[h.TRSTATUS] ? `(${TRD_STATUS[h.TRSTATUS]})` : ''} · 所有者 ${h.AS4USER || ''} · 日期 ${h.AS4DATE || ''} · 目标 ${h.TARSYSTEM || ''}${h.STRKORR ? ` · 上级 ${h.STRKORR}` : ''} · ${t.objCount ?? objs.length} 个对象`);
      if (objs.length) {
        L.push('');
        L.push('| 程序ID | 对象 | 对象名 |');
        L.push('| --- | --- | --- |');
        objs.slice(0, 500).forEach((o) => L.push(`| ${o.PGMID || ''} | ${o.OBJECT || ''} | ${o.OBJ_NAME || ''} |`));
      } else L.push('(对象清单为空——对象在子任务或尚未登记)');
      if ((t.subtasks || []).length) {
        L.push('');
        L.push(`### 子任务(${t.subtasks.length})`);
        L.push('| 请求 | 状态 | 用户 | 日期 |');
        L.push('| --- | --- | --- | --- |');
        t.subtasks.forEach((s) => L.push(`| ${s.TRKORR || ''} | ${TRD_STATUS[s.TRSTATUS] || s.TRSTATUS || ''} | ${s.AS4USER || ''} | ${s.AS4DATE || ''} |`));
      }
    }
    const tl = p.trListRes;
    if (tl) {
      L.push('');
      L.push(`## ${tl.user || ''} 的传输请求(${tl.count || 0} 条${tl.moreAvailable ? '+' : ''},按目录原序)`);
      L.push('| 请求 | 类型 | 状态 | 日期 | 用户 | 描述 |');
      L.push('| --- | --- | --- | --- | --- | --- |');
      (tl.list || []).forEach((q) => L.push(`| ${q.TRKORR || ''} | ${TRD_FUNC[q.TRFUNCTION] || q.TRFUNCTION || ''} | ${TRD_STATUS[q.TRSTATUS] || q.TRSTATUS || ''} | ${q.AS4DATE || ''} | ${q.AS4USER || ''} | ${q.AS4TEXT || ''} |`));
    }
    if (!r && !t && !tl) L.push('', '(无传输结果)');
    return L.join('\n');
  }

  _trXlsxSheets() {
    const p = this.probe;
    const r = p.objTrRes; const t = p.trRes; const tl = p.trListRes;
    if (!r && !t && !tl) return [];
    const ov = [{ 项目: '环境 / 导出时间', 内容: `${p.sys} · ${_nowStamp()}` }];
    if (r) ov.push({ 项目: '按对象分析', 内容: `${r.obj || ''} → 程序 ${r.prog || '?'} · ${r.trCount} 请求 · ${(r.matrix || []).length} 对象 · ⚠${(r.matrix || []).filter((x) => x.verdict === 'diff').length} 不一致 · ✗${(r.matrix || []).filter((x) => x.verdict === 'missing').length} 未传` });
    if (t) ov.push({ 项目: '请求详情', 内容: `${t.trkorr || ''} · ${t.objCount ?? 0} 对象` });
    if (tl) ov.push({ 项目: '用户请求列表', 内容: `${tl.user || ''} · ${tl.count || 0} 条` });
    const sheets = [{ name: '概览', rows: ov }];
    if (r) {
      const fp = (c) => !c ? '?' : c.sysfail ? '⚠查询失败' : c.miss ? '缺失' : (c.udat ? `${c.udat} ${c.unam || ''}` : (c.unam || '?'));
      sheets.push({ name: '版本矩阵', rows: (r.matrix || []).map((m) => ({
        对象: m.obj, 类型: XREF_SUBC[m.subc] || m.subc || '',
        DVP: fp(m.dvp), QAS: fp(m.qas), PRD: fp(m.prd),
        QAS_TR: (m.qas && m.qas.tr) || '', PRD_TR: (m.prd && m.prd.tr) || '',
        最新请求: m.lastTr || '', 结论: TRD_SEV_TEXT[m.verdict] || m.verdict, 说明: m.why || '',
      })) });
      sheets.push({ name: '请求溯源', rows: (r.requests || []).map((q) => ({
        请求: q.trkorr, 描述: q.text || '', 状态: TRD_STATUS[q.status] || q.status || '',
        日期: q.date || '', 用户: q.user || '', 对象数: q.n,
      })) });
    }
    if (t) {
      sheets.push({ name: '请求对象', rows: (t.objects || []) });
      if ((t.subtasks || []).length) sheets.push({ name: '子任务', rows: t.subtasks });
    }
    if (tl) sheets.push({ name: '用户请求列表', rows: (tl.list || []) });
    return sheets;
  }

  async _trExport(kind) {
    const p = this.probe;
    const label = (p.objTrRes && `传输溯源-${p.objTrRes.obj || ''}`) || (p.trRes && `请求详情-${p.trRes.trkorr || ''}`) || (p.trListRes && `请求列表-${p.trListRes.user || ''}`) || '传输查询';
    if (kind === 'xlsx') {
      const sheets = this._trXlsxSheets();
      if (!sheets.length) { _toast('没有可导出的结果', 'info'); return; }
      try { downloadXlsx(`${safeFilename(label)}.xlsx`, sheets); _toast(`✓ 已导出 Excel(${sheets.length} 个 SHEET)`, 'ok'); }
      catch (err) { _toast(`导出 Excel 失败:${err.message || err}`, 'err'); }
      return;
    }
    await this._mdExport(kind, this._trReportMd(), {
      title: 'SAP Driver 传输溯源报告',
      subtitle: `${p.sys} · ${_nowStamp()}`,
      filename: `${label} 传输溯源报告`,
    });
  }

  // v15 lint Excel:五关卡/违规清单/SELECT 索引审计三张天然表 + 概览
  _lintXlsxSheets() {
    const r = this.probe.lintRes; if (!r) return [];
    // 2026-10-14 审查 P1:原 return [...] 后跟 AI 深审 push(永不可达)→ Excel 永缺
    // 「AI语义深审」SHEET(_lintReportMd 有,两口径不一致);改先装 sheets 再收 AI,尾补 return
    const sheets = [
      { name: '概览', rows: [
        { 项目: '对象', 内容: `${r.program}(${r.system || ''})` },
        { 项目: '结论 / 耗时', 内容: `${r.verdictText} · ${r.summary || ''} · ${r.durMs}ms${r.cacheHit ? '(缓存)' : ''}` },
        { 项目: '导出时间', 内容: _nowStamp() },
        { 项目: '分析范围', 内容: (r.includes || []).map((x) => `${x.name}(${x.lines}行)`).join(' + ') || '-' },
      ] },
      { name: '五关卡', rows: (r.passes || []).map((ps) => ({ 关卡: `${ps.id} ${ps.title}`, 结论: ps.status, 高危: ps.high, 中等: ps.med, 建议: ps.low, 注: ps.note || '' })) },
      { name: '违规清单', rows: (r.findings || []).map((f) => ({ 级别: f.Severity, 关卡: `${f.Rule} ${f.Subtype || ''}`, 位置: `${f.Include || ''}:${f.Line}`, 说明: f.Message || '', 建议: f.Suggestion || '' })) },
      { name: 'SELECT索引审计', rows: (r.selectAudit || []).map((a) => ({
        行: `${a.Include && (r.includes || []).length > 1 ? a.Include + ':' : ''}${a.Line}`, 类型: a.Kind || '',
        表: (a.Tables || []).join('+') || (a.TableStatus === 'unknown' ? '(动态)' : '-'),
        条件字段: (a.WhereFields || []).join(','), 命中: (a.G2 && a.G2.Status) || '-', 说明: (a.G2 && (a.G2.Note || a.G2.MatchedIndex)) || '',
      })) },
    ];
    const ai = this.probe.lintAiRes;   // v16 AI 深审单列一 SHEET(如有)
    if (ai) {
      sheets.push({ name: 'AI语义深审', rows: (ai.findings || []).length ? ai.findings.map((f) => ({
        级别: f.severity || '-', '行/类型': `${f.line || '?'} ${f.type || ''}`, 说明: f.message || '', 建议: f.suggestion || '',
        引用: f.evidence || '', 校准注: f.note || '',
      })) : [{ 说明: '未发现明显逻辑盲区(模型判断,需人工确认)' }] });
    }
    return sheets;
  }

  // (_diagpkXlsxSheets 不在本模块:属「🩺 体检」页签,在 sap-copilot-diagpk.js——
  //  2026-10-30 拆分按页签归属切,原文件里它物理上夹在 lint 区与 xref 区之间,拆分时归位。)

  // v12 引用聚合(渲染与导出共源):refs → 主程序组数组 + 间接计数
  _xrefAggData(refs) {
    const groups = new Map();
    let indirect = 0;
    (refs || []).forEach((r) => {
      const inc = String(r.INCLUDE || '') || '(未知位置)';
      const main = _xrefMainOf(inc);
      let g = groups.get(main);
      if (!g) { g = { main, custom: _xrefIsCustom(main), count: 0, ots: new Set(), incs: new Map() }; groups.set(main, g); }
      g.count += 1;
      const ot = String(r.OTYPE || '').toUpperCase();
      if (ot) g.ots.add(ot);
      if (String(r.DIRECT || '').trim() !== 'X') indirect += 1;
      g.incs.set(inc, (g.incs.get(inc) || 0) + 1);
    });
    const arr = [...groups.values()].sort((a, b) => ((b.custom ? 1 : 0) - (a.custom ? 1 : 0)) || (b.count - a.count) || a.main.localeCompare(b.main));
    return { arr, indirect };
  }

  // v12 影响分析卡:refs(WBCROSSGT 原始行)→ include 归组主程序聚合树。
  // 自定义默认展开到 include 层、标准折叠(用户定案);看代码按需拉源码并缓存。
  _xrefAggHtml(res) {
    const p = this.probe;
    const refs = res.refs || [];
    const titles = res.titles || {};
    const { arr, indirect } = this._xrefAggData(refs);
    const nCus = arr.filter((g) => g.custom).length;
    const fq = p.xrefQ.trim().toUpperCase();
    const chips = [['all', `全部 ${arr.length}`], ['custom', `自定义 ${nCus}`], ['std', `标准 ${arr.length - nCus}`]].map(([k, lb]) =>
      `<button data-act="xref-chip" data-f="${k}" style="border:1px solid ${p.xrefFilter === k ? 'var(--sd-accent-border)' : 'var(--sd-border)'};background:${p.xrefFilter === k ? 'var(--sd-accent-soft)' : 'transparent'};color:${p.xrefFilter === k ? 'var(--sd-accent-active)' : 'var(--sd-text-faint)'};font-size:11px;padding:2px 10px;border-radius:999px;cursor:pointer;">${lb}</button>`).join('');
    const shown = arr
      .filter((g) => p.xrefFilter === 'all' || (p.xrefFilter === 'custom') === g.custom)
      .filter((g) => !fq || g.main.includes(fq)
        || String((titles[g.main] && titles[g.main].text) || '').toUpperCase().includes(fq)
        || [...g.incs.keys()].some((i) => i.includes(fq)));
    const lim = p.xrefLimit;
    const rows = shown.slice(0, lim).map((g) => {
      const defOpen = g.custom;                      // 自定义默认展开,标准折叠(用户定案)
      const open = p.xrefOpen[g.main] !== undefined ? p.xrefOpen[g.main] : defOpen;
      const otArr = [...g.ots];
      const otHtml = otArr.map((o) => `<span title="${escAttr(o)}: ${escAttr(_xrefOt(o))}">${esc(_xrefOt(o))}</span>`).join('/');
      const priOt = ['FU', 'ME', 'FR', 'TY', 'DA'].find((o) => otArr.includes(o)) || otArr[0] || '';
      const incRows = [...g.incs.entries()].map(([inc, n]) => {
        const cd = p.xrefCode[inc];
        let codeHtml = '';
        if (cd && cd.loading) codeHtml = '<div class="xref-codebox"><span class="sapc-hint">⏳ 正在拉取源码并定位…</span></div>';
        else if (cd && cd.err) codeHtml = `<div class="xref-codebox"><span class="sapc-hint">读取失败:${esc(cd.err)}</span></div>`;
        else if (cd) codeHtml = this._xrefCodeHtml(cd, inc);
        return `<div class="xref-inc">
          <span class="xref-in" title="${escAttr(String((titles[inc] && titles[inc].text) || ''))}">${esc(inc)}</span>
          <span class="xref-it">${esc(String((titles[inc] && titles[inc].text) || ''))}</span>
          <span class="xref-meta">${n} 处</span>
          <button data-act="xref-code" data-inc="${escAttr(inc)}" data-ot="${escAttr(priOt)}">${cd && !cd.loading ? '收起 ▴' : '🔍 看代码'}</button>
          ${codeHtml}
        </div>`;
      }).join('');
      const usesBtn = `<button data-act="xref-uses" data-main="${escAttr(g.main)}" title="反查这个程序(含组内 include)引用了哪些对象" style="font-size:10.5px;padding:1px 8px;">它用了什么</button>`;
      return `<div class="xref-prog" data-xp="${escAttr(g.main)}">
        <div class="xref-prog-hd" data-act="xref-sec" data-main="${escAttr(g.main)}" title="点击展开/收起该程序的引用明细">
          <span class="xref-tw">${open ? '▾' : '▸'}</span>
          <span class="xref-pn">${esc(g.main)}</span>
          <span class="xref-pt">${esc(String((titles[g.main] && titles[g.main].text) || ''))}</span>
          <span class="xref-badge${g.custom ? '' : ' std'}" title="${g.custom ? 'Z/Y 自定义程序,改动前重点评估' : 'SAP 标准程序,一般不改动'}">${g.custom ? 'Z' : '标准'}</span>
          <span class="xref-meta">${g.count} 处 · ${otHtml || '-'}</span>
          ${usesBtn}
        </div>
        ${open ? `<div class="xref-incs">${incRows || '<div class="xref-inc"><span class="sapc-hint">(无 include 明细)</span></div>'}</div>` : ''}
      </div>`;
    }).join('');
    return `<div class="pb-card">
      <div class="pb-title">「${esc(res.name || '')}${res.field ? `.${esc(res.field)}` : ''}」影响分析 <span class="sub">${refs.length} 处引用 · ${arr.length} 个程序${res.customCount ? ` · 自定义引用 ${res.customCount} 行全量` : ''}${res.moreAvailable ? ' · 标准部分截断至上限' : ''} · ${indirect ? `含 ${indirect} 处间接` : '全部直接引用'}${res.titlesCount != null ? ` · 标题命中 ${res.titlesCount}` : ''}${res.titleMs != null ? ` · ${res.titleMs}ms` : ''}</span>
        <span style="flex:1"></span><button data-act="probe-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制 JSON</button></div>
      <div class="xref-sum">
        ${chips}
        <input data-xref-q placeholder="过滤:程序名/标题/include" value="${escAttr(p.xrefQ)}">
        <span class="sapc-hint" title="${escAttr(XREF_OTYPE_TIP)}">种类含义悬停可看;Z=自定义程序优先展开</span>
      </div>
      ${rows || '<span class="sapc-hint">无引用记录(可能是终端对象,或交叉索引未建——SE84 环境分析可比对)</span>'}
      ${shown.length > lim ? `<div style="margin-top:8px;"><button data-act="xref-more" style="font-size:11.5px;padding:2px 12px;">显示更多(还有 ${shown.length - lim} 个程序)</button></div>` : ''}
    </div>`;
  }

  // v12 代码定位结果渲染:命中段(行号+关键词高亮);零命中→如实提示+head300 全文兜底(用户定案)
  _xrefCodeHtml(cd, inc) {
    if (!cd.hitCount) {
      const head = (cd.head300 || []).map((l, i) => `${String(i + 1).padStart(4, '0')} | ${l}`).join('\n');
      return `<div class="xref-codebox">
        <div class="sapc-hint" style="margin:4px 0;">索引与当前代码不同步:「${esc(cd.word || '')}」在 ${esc(inc)}(${cd.scanned || 0} 行)未定位到引用——WBCROSSGT 是激活索引,可能是旧引用或该处已被重构。可展开前 300 行人工确认:</div>
        <details><summary style="cursor:pointer;font-size:11.5px;color:var(--sd-accent-active);">查看全文前 300 行</summary><pre>${esc(head)}</pre></details>
      </div>`;
    }
    const rxWord = new RegExp(`(${String(cd.word || '').replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'ig');
    const segs = (cd.segments || []).map((s) => {
      const rows = s.rows.map((r) =>
        `<span class="xref-ln">${String(r.no).padStart(4, '0')}</span> ${esc(r.text).replace(rxWord, '<mark>$1</mark>')}`).join('\n');
      const hot = s.hits && s.hits.length ? ` <span class="sapc-hint">(L${s.hits.join(', L')})</span>` : '';
      return `<div class="xref-seg"><div class="xref-seg-h">行 ${s.from}–${s.to}${hot}</div><pre>${rows}</pre></div>`;
    }).join('');
    return `<div class="xref-codebox">
      ${cd.fellBack ? '<div class="sapc-hint" style="margin:3px 0;">按引用词全文搜索命中(精确模式未命中)</div>' : ''}
      ${segs}${cd.truncated ? '<div class="sapc-hint">…命中过多,仅显示前 40 处</div>' : ''}
    </div>`;
  }

  // v13 按对象传输溯源:事务码/程序/函数组 → 涉及请求(带描述)+ 三系统版本指纹比对
  async probeObjTr() {
    const p = this.probe;
    this._probeBarVals();
    const obj = p.fm.trim().toUpperCase();
    if (!obj) { _toast('填程序/事务码/函数组,如 ZREP001 或 MM03', 'err'); return; }
    p.xrefSearching = true; p.objTrRes = null; p.lastErr = null;
    p.trRes = null; p.trListRes = null;   // 反向互斥:新溯源分析收起旧详情/列表
    this.render();
    try {
      const res = await bridge.run('sap-xref', { action: 'objtr', system: p.sys, obj }, { timeoutMs: 120000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.objTrRes = res;
    } catch (err) { p.lastErr = this._probeErr('按对象分析失败', err); }
    p.xrefSearching = false;
    this.render();
  }

  // v11 传输查询:请求详情(E070 头+E071 对象+子任务)/ 列某用户的请求
  async probeTrView() {
    const p = this.probe;
    this._probeBarVals();
    const t = p.fm.trim().toUpperCase();
    if (!t) { _toast('填请求号,如 DEVK900001', 'err'); return; }
    p.xrefSearching = true; p.trRes = null; p.trListRes = null; p.lastErr = null;
    // v13.1:不再清 objTrRes——溯源卡保留在下方,详情卡可收起返回(用户反馈:进去没地方返回)
    this.render();
    try {
      const res = await bridge.run('sap-xref', { action: 'tr', system: p.sys, trkorr: t }, { timeoutMs: 30000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.trRes = res;
    } catch (err) { p.lastErr = this._probeErr('查请求失败', err); }
    p.xrefSearching = false;
    this.render();
    // v13.2 下钻场景(溯源卡在下方时)把详情卡滚进视口,点请求号必有可见反馈
    if (p.objTrRes) this.root.querySelector('#sapc-tr-detail')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  async probeTrList() {
    const p = this.probe;
    this._probeBarVals();
    const u = p.fm.trim().toUpperCase();
    if (!u) { _toast('填用户名,如 XXX.YYY.Z', 'err'); return; }
    p.xrefSearching = true; p.trRes = null; p.trListRes = null; p.lastErr = null;
    this.render();
    try {
      const res = await bridge.run('sap-xref', { action: 'trlist', system: p.sys, user: u }, { timeoutMs: 30000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.trListRes = res;
    } catch (err) { p.lastErr = this._probeErr('列请求失败', err); }
    p.xrefSearching = false;
    this.render();
  }

  // v14 SQL 五关检查:程序/函数/事务码 → sap-lint 路由(拉源码+本地引擎+DDIC 索引终判)
  async probeLint() {
    const p = this.probe;
    this._probeBarVals();
    const obj = p.fm.trim().toUpperCase();
    if (!obj) { _toast('填程序/函数/事务码,如 ZREP003 或 ZREP001', 'err'); return; }
    p.xrefSearching = true; p.lintRes = null; p.lintAiRes = null; p.lastErr = null;   // v16:源码可能已变,AI 旧结论一并清
    this.render();
    try {
      const res = await bridge.run('sap-lint', { system: p.sys, object: obj }, { timeoutMs: 150000 });
      if (res.ok === false) throw new Error(emOf(res));
      // 后端结果缓存经 PS hashtable 往返,1 元素数组可能降级成标量(09-17 实爆:Tables:"X" → .join 崩 → 渲染中断 → 加载态永转);
      // 已知数组字段统一归一,渲染层无需各自设防
      const arr = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
      res.findings = arr(res.findings); res.passes = arr(res.passes); res.selectAudit = arr(res.selectAudit);
      res.includes = arr(res.includes); res.includesUnreadable = arr(res.includesUnreadable); res.limitations = arr(res.limitations);
      res.selectAudit = res.selectAudit.map((a) => { a.Tables = arr(a.Tables); a.WhereFields = arr(a.WhereFields); return a; });
      res.findings = res.findings.map((f) => { f.Tags = arr(f.Tags); return f; });
      p.lintRes = res;
      _toast(`质量审查完成:${res.verdictText}`, res.verdict === 'PASS' ? 'ok' : 'warn');
    } catch (err) { p.lastErr = this._probeErr('质量审查失败', err); }
    p.xrefSearching = false;
    try { this.render(); } catch (err) { _toast(`质量审查结果渲染失败:${err.message}`, 'err'); }
  }

  // v16 AI 语义深审:拉全源码喂公司内网 DeepSeek 通读,找静态规则抓不到的业务逻辑盲区(不走缓存)
  async probeLintAi() {
    const p = this.probe;
    this._probeBarVals();
    const obj = p.fm.trim().toUpperCase();
    if (!obj) { _toast('先填程序/函数,再点 AI 深审', 'err'); return; }
    p.lintAiBusy = true; p.lintAiRes = null; p.lastErr = null;
    this.render();
    try {
      const res = await bridge.run('sap-lint', { system: p.sys, object: obj, action: 'ai' }, { timeoutMs: 240000 });
      if (res.ok === false) throw new Error(emOf(res));
      const r = res.result || res;
      r.findings = (r.findings == null) ? [] : (Array.isArray(r.findings) ? r.findings : [r.findings]);
      p.lintAiRes = r;
      const n = (r.findings || []).length;
      _toast(`AI 深审完成:${n ? `${n} 处疑似盲区` : '未发现明显盲区'}`, n ? 'warn' : 'ok');
    } catch (err) { p.lastErr = this._probeErr('AI 深审失败', err); }
    p.lintAiBusy = false;
    try { this.render(); } catch (err) { _toast(`AI 深审结果渲染失败:${err.message}`, 'err'); }
  }

  // v16 AI 深审结果卡(与静态规则并列展示;模型判断,需人工确认)
  _lintAiHtml() {
    const p = this.probe;
    const parts = [];
    if (p.lintAiBusy) parts.push('<div class="sapc-loading"><span class="spin"></span>🤖 AI 通读源码审查中…(公司内网 DeepSeek,大对象约 1-3 分钟)</div>');
    if (p.lintAiRes) {
      const r = p.lintAiRes;
      const sevCol = { HIGH: 'var(--sd-danger-text)', MED: 'var(--sd-warning-text)', LOW: 'var(--sd-accent-active)' };
      const rows = (r.findings || []).map((f) => `<tr>
        <td style="white-space:nowrap;color:${sevCol[f.severity] || 'inherit'};font-weight:600;">${esc(f.severity || '-')}</td>
        <td style="white-space:nowrap;"><b>${esc(f.line || '?')}</b><span class="sapc-hint"> ${esc(f.type || '')}</span></td>
        <td style="white-space:normal;">${esc(f.message || '')}${f.suggestion ? `<div class="sapc-hint">→ ${esc(f.suggestion)}</div>` : ''}${f.note ? `<div class="sapc-hint" style="color:var(--sd-warning-text);">⚖ ${esc(f.note)}</div>` : ''}${f.evidence ? `<div class="sapc-hint">📎 ${esc(f.evidence)}</div>` : ''}</td></tr>`).join('');
      parts.push(`<div class="pb-card">
        <div class="pb-title">🤖 AI 语义深审「${esc(r.program)}」<span class="sub">${esc(r.system || '')} · ${esc(r.model || '')} · ${(r.findings || []).length} 条 · ${r.durMs}ms · 通读 ${r.sourceLines} 行/${r.sourceCount} include${r.truncated ? '(已截断)' : ''}${r.calibrated ? ' · ⚖' + esc(r.calibrated) : ''}${r.scopeNote ? ' · 📍' + esc(r.scopeNote) : ''}</span></div>
        <div class="sapc-hint" style="margin:2px 0 6px;">模型判断,可能误报,采纳前务必人工核对行号与代码;AI 不可达时明确报错,不降级外网</div>
        ${r.parseError ? `<div class="pb-err"><span>✗</span><span>AI 输出解析失败,原文如下(仍可人工阅读)</span></div><pre class="lint-snip" style="white-space:pre-wrap;font-size:11px;">${esc(r.raw || '')}</pre>` : ''}
        ${rows ? `<table class="res-tbl"><thead><tr><th>级别</th><th>行/类型</th><th>说明</th></tr></thead><tbody>${rows}</tbody></table>`
          : (!r.parseError ? '<span class="sapc-hint">未发现明显逻辑盲区(不等于没有,静态规则与人工复核仍是底线)</span>' : '')}
      </div>`);
    }
    return parts.join('');
  }

  // v14 五关结果卡:verdict 徽章 + 五关卡 + 违规清单(点行号展开源码片段) + SELECT 索引审计 + 能力边界
  _lintHtml() {
    const p = this.probe;
    const parts = [];
    if (p.xrefSearching) parts.push('<div class="sapc-loading"><span class="spin"></span>拉取源码+代码质量分析中…(首次拉 include 族较慢,结果按源码指纹缓存)</div>');
    if (p.lintRes) {
      const r = p.lintRes;
      const stBadge = { FAIL: ['✗ 不通过', 'var(--sd-danger-text)'], WARN: ['⚠ 有条件通过', 'var(--sd-warning-text)'], PASS: ['✓ 通过', 'var(--sd-success-text)'], ADVISE: ['💡 建议', 'var(--sd-accent-active)'], NA: ['· 未判定', 'var(--sd-text-faint)'] };
      const passChips = (r.passes || []).map((ps) => {
        const [lb, col] = stBadge[ps.status] || [ps.status, 'inherit'];
        const cnt = [ps.high ? `✗${ps.high}` : '', ps.med ? `⚠${ps.med}` : '', ps.low ? `💡${ps.low}` : ''].filter(Boolean).join(' ');
        return `<span style="display:inline-flex;align-items:center;gap:5px;border:1px solid var(--sd-border);border-radius:8px;padding:3px 10px;font-size:12px;">
          <b style="color:${col};">${lb}</b><span>${esc(ps.title)}</span>${cnt ? `<span class="sapc-hint">${cnt}</span>` : ''}</span>`;
      }).join('');
      const sevCol = { HIGH: 'var(--sd-danger-text)', MED: 'var(--sd-warning-text)', LOW: 'var(--sd-accent-active)' };
      const fRows = (r.findings || []).map((f) => {
        const loc = `${esc(f.Include || '')}:${f.Line}`;
        return `<tr><td style="white-space:nowrap;color:${sevCol[f.Severity] || 'inherit'};font-weight:600;">${esc(f.Severity)}</td>
          <td style="white-space:nowrap;"><b>${esc(f.Rule)}</b><span class="sapc-hint"> ${esc(f.Subtype || '')}</span></td>
          <td style="white-space:nowrap;">${f.Snippet ? `<details><summary style="cursor:pointer;color:var(--sd-accent-active);">${loc}</summary><pre class="lint-snip" style="max-width:420px;white-space:pre-wrap;font-size:11px;margin:4px 0;">${esc(f.Snippet)}</pre></details>` : esc(loc)}</td>
          <td style="white-space:normal;">${esc(f.Message || '')}${f.Suggestion ? `<div class="sapc-hint">→ ${esc(f.Suggestion)}</div>` : ''}</td></tr>`;
      }).join('');
      const g2Col = { PK: 'var(--sd-success-text)', INDEX: 'var(--sd-success-text)', MISS: 'var(--sd-warning-text)', FULL_SCAN: 'var(--sd-danger-text)', UNKNOWN: 'inherit', SELTAB: 'inherit', REVIEW: 'inherit', NA: 'var(--sd-text-faint)' };
      const aRows = (r.selectAudit || []).slice(0, 50).map((a) => {
        const g2 = a.G2 || {};
        return `<tr><td>${a.Include && r.includes && r.includes.length > 1 ? esc(a.Include) + ':' : ''}${a.Line}</td>
          <td>${esc(a.Kind || '')}</td><td>${esc((a.Tables || []).join('+') || (a.TableStatus === 'unknown' ? '(动态)' : '-'))}</td>
          <td>${esc((a.WhereFields || []).slice(0, 6).join(',') || '-')}</td>
          <td style="color:${g2Col[g2.Status] || 'inherit'};font-weight:600;">${esc(g2.Status || '-')}</td>
          <td style="font-size:11.5px;white-space:normal;">${esc(g2.Note || g2.MatchedIndex || '')}</td></tr>`;
      }).join('');
      const incInfo = (r.includes || []).map((x) => `${esc(x.name)}(${x.lines}行)`).join(' + ');
      const unrd = (r.includesUnreadable || []).map((x) => esc(x.name)).join(', ');
      parts.push(`<div class="pb-card">
        <div class="pb-title">📏 代码质量审查「${esc(r.program)}」<span class="sub">${esc(r.system)} · ${esc(r.verdictText)} · ${esc(r.summary || '')} · ${r.durMs}ms${r.cacheHit ? ' · 缓存' : ''}</span>
          <span style="flex:1"></span><button data-act="lint-ai" style="font-size:11.5px;padding:2px 10px;">${p.lintAiBusy ? '⏳ 审查中…' : '🤖 AI 深审'}</button>
          <button data-act="lint-rep-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制报告</button>
          <button data-act="lint-rep-html" style="font-size:11.5px;padding:2px 10px;">📄 导出 HTML</button>
          <button data-act="lint-rep-xlsx" style="font-size:11.5px;padding:2px 10px;">📊 导出 Excel</button></div>
        <div style="display:flex;flex-wrap:wrap;gap:6px;margin:6px 0;">${passChips}</div>
        <div class="sapc-hint" style="margin:2px 0 6px;">分析范围:${incInfo || '-'}${unrd ? `;读不到:${unrd}` : ''}${r.resolvedVia && r.resolvedVia !== 'program' ? `;输入「${esc(r.requested || '')}」按${r.resolvedVia === 'tcode' ? '事务码' : '函数'}解析` : ''}${r.scopeNote ? `;📍${esc(r.scopeNote)}` : ''}${r.capHit ? ';⚠达 include 上限(30 文件),结果可能不全' : ''}${r.tableCapHit ? ';⚠涉及表超 15 张,超出部分未判索引' : ''}</div>
        ${fRows ? `<div class="res-sec">违规清单(${r.findings.length} 条,点行号看源码片段)</div>
        <table class="res-tbl"><thead><tr><th>级别</th><th>关卡</th><th>位置</th><th>说明</th></tr></thead><tbody>${fRows}</tbody></table>` : '<div class="res-sec">违规清单</div><span class="sapc-hint">无违规 🎉</span>'}
        ${(r.selectAudit || []).length ? `<div class="res-sec">SELECT 索引命中审计(${r.selectAudit.length} 条${r.selectAudit.length > 50 ? ',显示前 50' : ''})</div>
        <table class="res-tbl"><thead><tr><th>行</th><th>类型</th><th>表</th><th>条件字段</th><th>命中</th><th>说明</th></tr></thead><tbody>${aRows}</tbody></table>` : ''}
        <div class="res-sec">能力边界(如实声明)</div>
        <div class="sapc-hint" style="line-height:1.7;">${(r.limitations || []).map((l) => esc(l)).join(';')}</div>
      </div>`);
    }
    parts.push(this._lintAiHtml());
    if (p.lastErr) parts.push(`<div class="pb-err"><span>✗</span><span>${esc(p.lastErr)}</span></div>`);
    return parts.join('');
  }

  _lintReportMd() {
    const r = this.probe.lintRes; if (!r) return '';
    const md = [];
    md.push(`# 代码质量审查:${r.program}(${r.system || ''})`, '');
    md.push(`**结论:${r.verdictText}** · ${r.summary || ''} · ${r.durMs}ms${r.cacheHit ? '(缓存)' : ''}`, '');
    md.push('| 关卡 | 结论 | 高危 | 中等 | 建议 |', '|---|---|---|---|---|');
    (r.passes || []).forEach((ps) => md.push(`| ${ps.id} ${ps.title} | ${ps.status} | ${ps.high} | ${ps.med} | ${ps.low} |`));
    if ((r.findings || []).length) {
      md.push('', '## 违规清单', '', '| 级别 | 关卡 | 位置 | 说明 | 建议 |', '|---|---|---|---|---|');
      r.findings.forEach((f) => md.push(`| ${f.Severity} | ${f.Rule} ${f.Subtype || ''} | ${f.Include || ''}:${f.Line} | ${f.Message || ''} | ${f.Suggestion || ''} |`));
    }
    if ((r.selectAudit || []).length) {
      md.push('', '## SELECT 索引命中审计', '', '| 行 | 类型 | 表 | 条件字段 | 命中 | 说明 |', '|---|---|---|---|---|---|');
      r.selectAudit.forEach((a) => md.push(`| ${a.Line} | ${a.Kind || ''} | ${(a.Tables || []).join('+')} | ${(a.WhereFields || []).join(',')} | ${(a.G2 && a.G2.Status) || '-'} | ${(a.G2 && (a.G2.Note || a.G2.MatchedIndex)) || ''} |`));
    }
    const ai = this.probe.lintAiRes;   // v16 AI 深审结论一并入报告(如有)
    if (ai) {
      md.push('', `## 🤖 AI 语义深审(${ai.model || ''},模型判断需人工确认)`, '');
      if (ai.truncated) md.push('> ⚠ 源码超预算已截断,结论仅覆盖可见部分', '');
      if ((ai.findings || []).length) {
        md.push('| 级别 | 行/类型 | 说明 | 建议 |', '|---|---|---|---|');
        ai.findings.forEach((f) => md.push(`| ${f.severity || '-'} | ${f.line || '?'} ${f.type || ''} | ${f.message || ''}${f.evidence ? `(📎${f.evidence})` : ''} | ${f.suggestion || ''}${f.note ? `(⚖${f.note})` : ''} |`));
      } else { md.push('未发现明显逻辑盲区'); }
    }
    md.push('', '## 能力边界', '');
    (r.limitations || []).forEach((l) => md.push(`- ${l}`));
    return md.join('\n');
  }

  async _lintExport(kind) {
    const p = this.probe;
    if (!p.lintRes) { _toast('还没有检查结果', 'err'); return; }
    const label = `代码质量审查-${p.lintRes.program}`;
    if (kind === 'xlsx') {
      try { const sheets = this._lintXlsxSheets(); downloadXlsx(`${safeFilename(label)}.xlsx`, sheets); _toast(`✓ 已导出 Excel(${sheets.length} 个 SHEET)`, 'ok'); }
      catch (err) { _toast(`导出 Excel 失败:${err.message || err}`, 'err'); }
      return;
    }
    await this._mdExport(kind, this._lintReportMd(), {
      title: 'SAP Driver SQL 代码质量审查报告',
      subtitle: `${p.sys} · ${_nowStamp()}`,
      filename: label,
    });
  }

  // v19 交付门禁:五段检查(G1 传输包/G2 对象健康/G3 表↔程序兼容/G4 lint 复用/G5 AI 需求覆盖)
  // 路由 sap-gate;G5 吃 textarea 需求要点,300s 闸(AI 慢路径)
  async probeGate(refresh = false) {
    const p = this.probe;
    this._probeBarVals();
    const obj = p.fm.trim().toUpperCase();
    if (!obj) { _toast('填程序/函数/事务码/请求号,如 ZREP002 或 DEVK900002', 'err'); return; }
    const reqs = (p.gateReq || '').split('\n').map((s) => s.trim()).filter((s) => s && !s.startsWith('#')).slice(0, 30);
    p.xrefSearching = true; p.gateRes = null; p.lastErr = null;
    this.render();
    try {
      const res = await bridge.run('sap-gate', { system: p.sys, object: obj, requirements: reqs, refresh: !!refresh }, { timeoutMs: 300000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.gateRes = res.result || res;
      _toast(`交付门禁:${p.gateRes.verdictText || p.gateRes.verdict}`, p.gateRes.verdict === 'PASS' ? 'ok' : 'warn');
    } catch (err) { p.lastErr = this._probeErr('交付门禁失败', err); }
    p.xrefSearching = false;
    try { this.render(); } catch (err) { _toast(`门禁结果渲染失败:${err.message}`, 'err'); }
  }

  // v19 门禁结果卡:总 verdict 横幅+五段状态条+逐段检查项+G5 明细+对象清单(折叠)+导出
  _gateHtml() {
    const p = this.probe;
    const parts = [];
    if (p.xrefSearching) parts.push(`<div class="sapc-loading"><span class="spin"></span>交付门禁检查中(E070/E071/TADIR/DDIC/源码/五关${(p.gateReq || '').trim() ? '/AI 需求对照' : ''})…${(p.gateReq || '').trim() ? '(含 AI 段,约 1-3 分钟)' : '(五关按源码指纹缓存,程序没改秒回) '}</div>`);
    if (p.gateRes) {
      const r = p.gateRes;
      const arr = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
      r.checks = arr(r.checks); r.objects = arr(r.objects); r.limitations = arr(r.limitations);
      if (r.g5) { r.g5.reqs = arr(r.g5.reqs); r.g5.findings = arr(r.g5.findings); }
      if (r.g4) { r.g4.findings = arr(r.g4.findings); r.g4.passes = arr(r.g4.passes); r.g4.selectAudit = arr(r.g4.selectAudit); }
      const vb = { PASS: ['✓ 可交付', 'var(--sd-success-text)'], WARN: ['⚠ 有疑点', 'var(--sd-warning-text)'], FAIL: ['✗ 不可交付', 'var(--sd-danger-text)'] };
      const [vlb, vcol] = vb[r.verdict] || [r.verdict, 'inherit'];
      const stBadge = { PASS: ['✓', 'var(--sd-success-text)'], WARN: ['⚠', 'var(--sd-warning-text)'], FAIL: ['✗', 'var(--sd-danger-text)'], NA: ['·', 'var(--sd-text-faint)'] };
      const lvlCol = { FAIL: 'var(--sd-danger-text)', WARN: 'var(--sd-warning-text)', OK: 'var(--sd-success-text)', INFO: 'var(--sd-text-faint)' };
      const segChips = r.checks.map((c) => {
        const [lb, col] = stBadge[c.status] || [c.status, 'inherit'];
        return `<span style="display:inline-flex;align-items:center;gap:5px;border:1px solid var(--sd-border);border-radius:8px;padding:3px 10px;font-size:12px;"><b style="color:${col};">${lb} ${esc(c.id)}</b><span>${esc(c.title)}</span></span>`;
      }).join('');
      const secHtml = r.checks.map((c) => {
        const [lb, col] = stBadge[c.status] || [c.status, 'inherit'];
        const rows = arr(c.items).map((it) => `<tr><td style="white-space:nowrap;color:${lvlCol[it.level] || 'inherit'};font-weight:600;">${esc(it.level)}</td><td style="white-space:normal;">${esc(it.msg || '')}${it.detail ? `<div class="sapc-hint">${esc(it.detail)}</div>` : ''}</td></tr>`).join('');
        // v19.1 G4 附违规明细(路由 g4.findings 已返回全量,此前只在导出报告里有——用户 FAIL 却看不到条目)
        let g4Detail = '';
        if (c.id === 'G4' && r.g4 && arr(r.g4.findings).length) {
          const sevCol4 = { HIGH: 'var(--sd-danger-text)', MED: 'var(--sd-warning-text)', LOW: 'var(--sd-accent-active)' };
          const fRows4 = arr(r.g4.findings).map((f) => {
            const loc = `${esc(f.Include || '')}:${f.Line}`;
            return `<tr><td style="white-space:nowrap;color:${sevCol4[f.Severity] || 'inherit'};font-weight:600;">${esc(f.Severity)}</td>
              <td style="white-space:nowrap;"><b>${esc(f.Rule)}</b><span class="sapc-hint"> ${esc(f.Subtype || '')}</span></td>
              <td style="white-space:nowrap;">${f.Snippet ? `<details><summary style="cursor:pointer;color:var(--sd-accent-active);">${loc}</summary><pre class="lint-snip" style="max-width:420px;white-space:pre-wrap;font-size:11px;margin:4px 0;">${esc(f.Snippet)}</pre></details>` : esc(loc)}</td>
              <td style="white-space:normal;">${esc(f.Message || '')}${f.Suggestion ? `<div class="sapc-hint">→ ${esc(f.Suggestion)}</div>` : ''}</td></tr>`;
          }).join('');
          const passChips4 = arr(r.g4.passes).map((ps) => {
            const st4 = { PASS: ['✓', 'var(--sd-success-text)'], FAIL: ['✗', 'var(--sd-danger-text)'], WARN: ['⚠', 'var(--sd-warning-text)'], ADVISE: ['💡', 'var(--sd-accent-active)'], NA: ['·', 'var(--sd-text-faint)'] };
            const [l4, c4] = st4[ps.status] || [ps.status, 'inherit'];
            const cnt = [ps.high ? `✗${ps.high}` : '', ps.med ? `⚠${ps.med}` : '', ps.low ? `💡${ps.low}` : ''].filter(Boolean).join(' ');
            return `<span style="display:inline-flex;align-items:center;gap:4px;border:1px solid var(--sd-border);border-radius:8px;padding:2px 9px;font-size:11.5px;"><b style="color:${c4};">${l4}</b><span>${esc(ps.title)}</span>${cnt ? `<span class="sapc-hint">${cnt}</span>` : ''}</span>`;
          }).join('');
          g4Detail = `<div style="display:flex;flex-wrap:wrap;gap:6px;margin:7px 0 2px;">${passChips4}</div>
            <div class="res-sec">违规清单(${arr(r.g4.findings).length} 条,点行号看源码片段)</div>
            <table class="res-tbl"><thead><tr><th>级别</th><th>关卡</th><th>位置</th><th>说明</th></tr></thead><tbody>${fRows4}</tbody></table>
            <div class="sapc-hint" style="margin-top:4px;">⚠ 五关按军规从严判定:FAE 语义自动去重(SORT/去重属建议性)、守卫可经外层 IF 传递保证、MAX(主键前缀) 无 WHERE 常为取最新版本设计意图——逐条看片段判读,确属安全的可放行。缓存说明:结果按「程序|修改人|修改时间」指纹缓存,程序没改复用上次完整检查,程序一改自动全量重跑。</div>`;
        }
        return `<div class="pb-card"><div class="pb-title">${esc(c.id)} ${esc(c.title)} <b style="color:${col};">${lb} ${esc(c.status)}</b></div>${rows || '<span class="sapc-hint">(无检查项)</span>'}${g4Detail}</div>`;
      }).join('');
      let g5Html = '';
      if (r.g5 && r.g5.reqCount > 0) {
        const stMap = { PASS: ['✓ PASS', 'var(--sd-success-text)'], GAP: ['✗ GAP', 'var(--sd-danger-text)'], PARTIAL: ['⚠ PARTIAL', 'var(--sd-warning-text)'] };
        const reqRows = r.g5.reqs.map((q) => {
          const [lb, col] = stMap[q.status] || [q.status, 'inherit'];
          return `<tr><td style="white-space:nowrap;">R${esc(String(q.no))}</td><td style="white-space:normal;">${esc(q.req || '')}</td><td style="color:${col};font-weight:600;white-space:nowrap;">${lb}</td><td style="white-space:normal;font-size:11.5px;">${esc(q.note || '')}${q.evidence ? `<div class="sapc-hint">📎 ${esc(q.evidence)}</div>` : ''}</td></tr>`;
        }).join('');
        const sevCol = { HIGH: 'var(--sd-danger-text)', MED: 'var(--sd-warning-text)', LOW: 'var(--sd-accent-active)' };
        const fRows = r.g5.findings.map((f) => `<tr><td style="color:${sevCol[f.severity] || 'inherit'};font-weight:600;white-space:nowrap;">${esc(f.severity || '-')}</td><td style="white-space:nowrap;"><b>${esc(String(f.line || '?'))}</b></td><td style="white-space:normal;">${esc(f.message || '')}${f.suggestion ? `<div class="sapc-hint">→ ${esc(f.suggestion)}</div>` : ''}${f.note ? `<div class="sapc-hint" style="color:var(--sd-warning-text);">⚖ ${esc(f.note)}</div>` : ''}${f.evidence ? `<div class="sapc-hint">📎 ${esc(f.evidence)}</div>` : ''}</td></tr>`).join('');
        g5Html = `<div class="pb-card">
          <div class="pb-title">🤖 需求覆盖明细 <span class="sub">${esc(r.g5.model || '')} · ${r.g5.reqCount} 条需求${r.g5.truncated ? ' · ⚠源码截断' : ''}${r.g5.calibrated ? ` · ⚖校准 ${r.g5.calibrated}` : ''}</span></div>
          ${r.g5.summary ? `<div class="sapc-hint" style="margin:2px 0 6px;">总评:${esc(r.g5.summary)}</div>` : ''}
          ${reqRows ? `<table class="res-tbl"><thead><tr><th>#</th><th>需求</th><th>判定</th><th>说明</th></tr></thead><tbody>${reqRows}</tbody></table>` : ''}
          ${fRows ? `<div class="res-sec">逻辑疑点(${r.g5.findings.length} 条,模型判断需人工确认)</div><table class="res-tbl"><thead><tr><th>级别</th><th>行</th><th>说明</th></tr></thead><tbody>${fRows}</tbody></table>` : ''}
        </div>`;
      }
      const objRows = r.objects.map((o) => `<tr><td>${esc(o.pgmid)}</td><td>${esc(o.type)}</td><td class="xref-td-name">${esc(o.name)}</td><td><a href="#" data-act="objtr-tr" data-tr="${escAttr(o.trkorr)}" style="color:var(--sd-accent-active);text-decoration:none;">${esc(o.trkorr)}</a></td></tr>`).join('');
      parts.push(`<div class="pb-card" style="border-left:3px solid ${vcol};">
        <div class="pb-title">🚦 交付门禁「${esc(r.mainProg || r.object)}」<b style="color:${vcol};font-size:14px;">${vlb}</b><span class="sub">${esc(r.system)} · ${esc(r.targetTr || '')} · ${r.durMs}ms${r.cacheHit ? ' · 缓存命中(程序未改,复用上次完整检查;程序一改自动全量重跑)' : ''}</span>
          <span style="flex:1"></span>
          <button data-act="gate-refresh" style="font-size:11.5px;padding:2px 10px;" title="跳缓存重查(对象/TR 有变动后用)">↻ 重查</button>
          <button data-act="gate-rep-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制报告</button>
          <button data-act="gate-rep-html" style="font-size:11.5px;padding:2px 10px;">📄 导出 HTML</button>
          <button data-act="gate-rep-xlsx" style="font-size:11.5px;padding:2px 10px;">📊 导出 Excel</button></div>
        <div class="sapc-hint" style="margin:2px 0 6px;">${esc(r.summary || '')}</div>
        <div style="display:flex;flex-wrap:wrap;gap:6px;margin:6px 0;">${segChips}</div>
        ${objRows ? `<details style="margin:4px 0;"><summary class="sapc-hint" style="cursor:pointer;">请求对象清单(${r.objects.length} 个,点请求号下钻详情)</summary><table class="res-tbl"><thead><tr><th>PGMID</th><th>类型</th><th>对象</th><th>所在请求</th></tr></thead><tbody>${objRows}</tbody></table></details>` : ''}
      </div>
      ${secHtml}
      ${g5Html}
      <div class="res-sec">能力边界(如实声明)</div>
      <div class="sapc-hint" style="line-height:1.7;">${r.limitations.map((l) => esc(l)).join(';')}</div>`);
    }
    if (p.lastErr) parts.push(`<div class="pb-err"><span>✗</span><span>${esc(p.lastErr)}</span></div>`);
    return parts.join('');
  }

  _gateReportMd() {
    const r = this.probe.gateRes; if (!r) return '';
    const md = [];
    const vb = { PASS: '✓ 可交付', WARN: '⚠ 有疑点', FAIL: '✗ 不可交付' };
    md.push(`# 交付门禁:${r.mainProg || r.object}(${r.system || ''})`, '');
    md.push(`**结论:${vb[r.verdict] || r.verdict}** · ${r.summary || ''} · 目标请求 ${r.targetTr || '-'} · ${r.durMs}ms${r.cacheHit ? '(缓存)' : ''}`, '');
    (r.checks || []).forEach((c) => {
      md.push(`## ${c.id} ${c.title} — ${c.status}`, '', '| 级别 | 说明 |', '|---|---|');
      (c.items || []).forEach((it) => md.push(`| ${it.level} | ${it.msg || ''}${it.detail ? `(detail:${it.detail})` : ''} |`));
      md.push('');
    });
    if (r.g5 && r.g5.reqCount > 0) {
      md.push(`## G5 需求覆盖明细(${r.g5.model || ''})`, '');
      if (r.g5.summary) md.push(`总评:${r.g5.summary}`, '');
      md.push('| # | 需求 | 判定 | 说明 |', '|---|---|---|---|');
      (r.g5.reqs || []).forEach((q) => md.push(`| R${q.no} | ${q.req || ''} | ${q.status} | ${q.note || ''}${q.evidence ? ` 📎${q.evidence}` : ''} |`));
      if ((r.g5.findings || []).length) {
        md.push('', '### 逻辑疑点', '', '| 级别 | 行 | 说明 | 建议 |', '|---|---|---|---|');
        r.g5.findings.forEach((f) => md.push(`| ${f.severity || '-'} | ${f.line || '?'} | ${f.message || ''}${f.evidence ? `(📎${f.evidence})` : ''}${f.note ? `(⚖${f.note})` : ''} | ${f.suggestion || ''} |`));
      }
      md.push('');
    }
    if (r.g4 && (r.g4.findings || []).length) {
      md.push('## G4 质量违规明细', '', '| 级别 | 关卡 | 位置 | 说明 |', '|---|---|---|---|');
      r.g4.findings.forEach((f) => md.push(`| ${f.Severity} | ${f.Rule} ${f.Subtype || ''} | ${f.Include || ''}:${f.Line} | ${f.Message || ''} |`));
      md.push('');
    }
    md.push('## 能力边界', '');
    (r.limitations || []).forEach((l) => md.push(`- ${l}`));
    return md.join('\n');
  }

  _gateXlsxSheets() {
    const r = this.probe.gateRes; if (!r) return [];
    const sheets = [];
    const ov = [{ 项目: '对象', 值: r.mainProg || r.object }, { 项目: '系统', 值: r.system }, { 项目: '目标请求', 值: r.targetTr || '' },
      { 项目: '总verdict', 值: r.verdictText }, { 项目: '摘要', 值: r.summary || '' }, { 项目: '耗时ms', 值: r.durMs }];
    (r.checks || []).forEach((c) => ov.push({ 项目: `${c.id} ${c.title}`, 值: c.status }));
    sheets.push({ name: '概览', rows: ov });
    const items = [];
    (r.checks || []).forEach((c) => (c.items || []).forEach((it) => items.push({ 段: c.id, 段名: c.title, 级别: it.level, 说明: it.msg || '', 详情: it.detail || '' })));
    if (items.length) sheets.push({ name: '检查项', rows: items });
    if ((r.objects || []).length) sheets.push({ name: '请求对象', rows: r.objects.map((o) => ({ PGMID: o.pgmid, 类型: o.type, 对象: o.name, 请求: o.trkorr })) });
    if (r.g5 && (r.g5.reqs || []).length) sheets.push({ name: '需求覆盖', rows: r.g5.reqs.map((q) => ({ 编号: `R${q.no}`, 需求: q.req || '', 判定: q.status, 说明: q.note || '', 证据: q.evidence || '' })) });
    if (r.g4 && (r.g4.findings || []).length) sheets.push({ name: '质量违规', rows: r.g4.findings.map((f) => ({ 级别: f.Severity, 关卡: `${f.Rule} ${f.Subtype || ''}`, 位置: `${f.Include || ''}:${f.Line}`, 说明: f.Message || '', 建议: f.Suggestion || '' })) });
    return sheets;
  }

  async _gateExport(kind) {
    const p = this.probe;
    if (!p.gateRes) { _toast('还没有门禁结果', 'err'); return; }
    const label = `交付门禁-${p.gateRes.mainProg || p.gateRes.object}`;
    if (kind === 'xlsx') {
      try { const sheets = this._gateXlsxSheets(); downloadXlsx(`${safeFilename(label)}.xlsx`, sheets); _toast(`✓ 已导出 Excel(${sheets.length} 个 SHEET)`, 'ok'); }
      catch (err) { _toast(`导出 Excel 失败:${err.message || err}`, 'err'); }
      return;
    }
    await this._mdExport(kind, this._gateReportMd(), {
      title: 'SAP Driver 交付门禁报告',
      subtitle: `${p.sys} · ${_nowStamp()}`,
      filename: label,
    });
  }

  // v14 代码内容搜索:关键字搜进源码(REPOSRC 指纹增量缓存,route 侧)
  async probeXrefContent() {
    const p = this.probe;
    this._probeBarVals();
    const kw = p.fm.trim();
    if (!kw) { _toast('填关键字,如 BAPI_ACC_DOCUMENT 或 CALL TRANSACTION', 'err'); return; }
    p.xrefSearching = true; p.contentRes = null; p.lastErr = null;
    this.render();
    try {
      const res = await bridge.run('sap-codesearch', { system: p.sys, kw }, { timeoutMs: 300000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.contentRes = res;
    } catch (err) { p.lastErr = this._probeErr('内容搜索失败', err); }
    p.xrefSearching = false;
    this.render();
  }

  // probe 系动作统一错误分流:NEED_CREDENTIAL(或中文原文)→ 自动弹连接面板;
  // 其余如实 toast。bridge-client throw 只带 message,code 丢了,双判据兜底。
  _probeErr(where, err) {
    const msg = String((err && err.message) || err);
    if (msg.includes('NEED_CREDENTIAL') || msg.includes('未注入凭证')) {
      this.connectOpen = true;
      _toast('需要先连接 SAP:请在上方连接管理里输入密码', 'info');
    } else _toast(`${where}:${msg}`, 'err');
    return msg;
  }

  // v15 排查形态清理链统一(kind 切换与 catalog 直达共用——原两套并存,catalog 路径漏清
  // explain/diag、不停诊断轮询,潜伏串台 bug)。v15.1 系统跟形态走(记忆过=记忆,没动过=默认)。
  _resetProbeKind(k) {
    const p = this.probe;
    p.kind = k;
    p.sys = p.sysByKind[k] || PROBE_SYS_DEFAULT[k] || p.sys;
    p.reportSig = null; p.sig = null; p.variant = '';
    p.execLoading = false; p.sigLoading = false; p.xrefSearching = false;
    p_last_clear(p);   // 结果类状态(exec/diag/conv/xref/tr/objtr/lint/content/expect/confirm)
    this._stopDiagPoll();
    p.explain = null; p.explainLoading = false;   // 解读随形态清空,不串台(2026-09-15 用户反馈)
    _saveSapcPrefs(p);   // 排查对象偏好(含 v15.1 sysByKind)落盘,刷新后保持
  }

  _probeBarVals() {
    const p = this.probe;
    const sys = this.root.querySelector('[data-probe-f="sys"]');
    const fm = this.root.querySelector('[data-probe-f="fm"]');
    const vari = this.root.querySelector('[data-probe-f="variant"]');
    const pl = this.root.querySelector('[data-probe-f="payload"]');
    const sn = this.root.querySelector('[data-probe-f="setname"]');
    const gq = this.root.querySelector('[data-probe-f="gatereq"]');   // v19 需求要点随动作回读,防 render 丢输入
    if (sys) {
      p.sys = sys.value;
      if (p.sysByKind[p.kind] !== sys.value) { p.sysByKind[p.kind] = sys.value; _saveSapcPrefs(p); }   // v15.1 手选系统按形态记忆落盘
    }
    if (fm) p.fm = fm.value;
    if (vari) p.variant = vari.value;
    if (pl) p.payloadText = pl.value;
    if (sn) p.setName = sn.value;
    if (gq) p.gateReq = gq.value;
    const ad = this.root.querySelector('[data-probe-f="autodiag"]');
    if (ad) p.autoDiag = ad.checked;
    const ae = this.root.querySelector('[data-probe-f="autoexplain"]');
    if (ae) p.autoExplain = ae.checked;
    if (ad || ae) _saveSapcPrefs(p);   // 勾选偏好落盘,刷新后保持
    const ekw = this.root.querySelector('[data-probe-f="expectkw"]');
    if (ekw) p.expectKw = ekw.value;
    const emn = this.root.querySelector('[data-probe-f="expectmin"]');
    if (emn) p.expectMin = emn.value;
    // v9 report 表单回读:输入框值就地写回 reportSig(单一真值源,exec 直接组装 seltab)
    if (p.kind === 'report' && Array.isArray(p.reportSig)) {
      for (const el of this.root.querySelectorAll('[data-rp]')) {
        const it = p.reportSig.find((x) => x.SELNAME === el.dataset.rp);
        if (it) it.LOW = el.value;
      }
      for (const el of this.root.querySelectorAll('[data-rs-low]')) {
        const it = p.reportSig.find((x) => x.SELNAME === el.dataset.rsLow);
        if (it) it.LOW = el.value;
      }
      for (const el of this.root.querySelectorAll('[data-rs-high]')) {
        const it = p.reportSig.find((x) => x.SELNAME === el.dataset.rsHigh);
        if (it) it.HIGH = el.value;
      }
      for (const el of this.root.querySelectorAll('[data-rs-sign]')) {
        const it = p.reportSig.find((x) => x.SELNAME === el.dataset.rsSign);
        if (it) it.SIGN = el.value;
      }
      for (const el of this.root.querySelectorAll('[data-rs-opt]')) {
        const it = p.reportSig.find((x) => x.SELNAME === el.dataset.rsOpt);
        if (it) it.OPTION = el.value;
      }
    }
  }

  async probeLoadSig() {
    const p = this.probe;
    this._probeBarVals();
    const fm = p.fm.trim();
    if (!fm) { _toast('先填函数名', 'err'); return; }
    p.sigLoading = true; this.render();
    // v9 report 分支:ZLILY_REPORT_META ACTION=P → 选择屏幕参数 → reportSig
    if (p.kind === 'report') {
      try {
        const res = await bridge.run('sap-probe', { kind: 'report', action: 'signature', system: p.sys, fm }, { timeoutMs: 60000 });
        if (res.ok === false) throw new Error(emOf(res));
        const dv = (x) => { const s = String(x ?? '').trim(); return /^[0\s]+$/.test(s) ? '' : s; };
        p.reportSig = (res.params || []).map((it) => ({
          SELNAME: String(it.SELNAME || ''), KIND: String(it.KIND || 'P') === 'S' ? 'S' : 'P',
          SIGN: 'I', OPTION: 'EQ', LOW: dv(it.LOW), HIGH: '',
        }));
        p.sig = null;
        _toast(`✓ 选择屏幕已读:${p.reportSig.length} 个参数`, 'ok');
      } catch (err) { this._probeErr('读选择屏幕失败', err); }
      p.sigLoading = false;
      this.render();
      this.probeLoadSets();
      if (p.autoExplain && p.reportSig) this.probeExplain();   // 📐 勾选了程序解读:顺带 AI 概览
      return;
    }
    try {
      const res = await bridge.run('sap-probe', { kind: 'fm', action: 'signature', system: p.sys, fm }, { timeoutMs: 60000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.sig = res.signature;
      // facade 返回归一化形状 {importing:[{name,type,…}],tables:[…]};兼容旧 raw 形状
      const imp = {};
      for (const it of ((res.signature && (res.signature.importing || res.signature.IMPORT_PARAMETER)) || [])) {
        const nm = it && (it.name || it.PARAMETER);
        if (nm) imp[nm] = '';
      }
      const tabs = {};
      for (const it of ((res.signature && (res.signature.tables || res.signature.TABLES_PARAMETER)) || [])) {
        const nm = it && (it.name || it.PARAMETER);
        if (nm) tabs[nm] = [];
      }
      // 已填的值保留(重读接口不冲掉手工输入),只补缺失的键
      p.form.import = { ...imp, ...p.form.import };
      p.form.tables = { ...tabs, ...p.form.tables };
      _toast(`✓ 接口已读:IMPORT ${Object.keys(imp).length} / TABLES ${Object.keys(tabs).length}`, 'ok');
    } catch (err) { this._probeErr('读接口失败', err); }
    p.sigLoading = false;
    this.render();
    this.probeLoadSets();   // 顺带刷新参数集清单(静默)
    if (p.autoExplain && p.sig) this.probeExplain();   // 📐 勾选了接口解读:顺带 AI 概览
  }

  // 📐 接口解读:一次 AI 调用(签名+源码 → 做什么/输入输出/取数逻辑/注意)
  async probeExplain() {
    const p = this.probe;
    const fm = p.fm.trim();
    if (!fm) return;
    const isRep = p.kind === 'report';
    // 旧解读保留(v11 用户定案:不默认清空)——loading 期间卡片继续显示旧内容,新的到了再替换
    p.explainLoading = true;
    this.render();
    try {
      const res = await bridge.run('sap-probe', { kind: isRep ? 'report' : 'fm', action: 'explain', system: p.sys, fm }, { timeoutMs: 60000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.explain = { md: res.explain, hasSource: res.hasSource, model: res.model, kind: isRep ? 'report' : 'fm' };
    } catch (err) {
      _toast(`${isRep ? '程序解读' : '接口解读'}失败:${err.message || err}`, 'err');   // 保留旧解读不置空
    }
    p.explainLoading = false;
    this.render();
  }

  async probeLoadVariant() {
    const p = this.probe;
    this._probeBarVals();
    const fm = p.fm.trim(), vari = p.variant.trim();
    if (!fm || !vari) { _toast(p.kind === 'report' ? '报表名和变式名都要填' : '函数名和变式号都要填', 'err'); return; }
    p.sigLoading = true; this.render();
    // v9 report 分支:ZLILY_REPORT_META ACTION=C → 变式内容(RSPARAMS 带 SIGN/OPTION)
    if (p.kind === 'report') {
      try {
        const res = await bridge.run('sap-probe', { kind: 'report', action: 'variant', system: p.sys, function: fm, variant: vari }, { timeoutMs: 60000 });
        if (res.ok === false) throw new Error(emOf(res));
        p.reportSig = (res.params || []).map((it) => ({
          SELNAME: String(it.SELNAME || ''), KIND: String(it.KIND || 'P') === 'S' ? 'S' : 'P',
          SIGN: String(it.SIGN || 'I'), OPTION: String(it.OPTION || 'EQ'),
          LOW: String(it.LOW ?? ''), HIGH: String(it.HIGH ?? ''),
        }));
        _toast(`✓ 变式 ${vari} 已载入:${p.reportSig.length} 个参数`, 'ok');
      } catch (err) { this._probeErr('载入变式失败', err); }
      p.sigLoading = false;
      this.render();
      return;
    }
    try {
      const res = await bridge.run('sap-probe', { kind: 'fm', action: 'variant', system: p.sys, function: fm, variant: vari }, { timeoutMs: 60000 });
      if (res.ok === false) throw new Error(emOf(res));
      const norm = this._normalizeProbeParams(res.params);
      p.form = norm;
      _toast(`✓ 变式 ${vari} 已载入:IMPORT ${Object.keys(norm.import).length} / TABLES ${Object.keys(norm.tables).length}`, 'ok');
    } catch (err) { this._probeErr('载入变式失败', err); }
    p.sigLoading = false;
    this.render();
  }

  probeParsePayload() {
    const p = this.probe;
    this._probeBarVals();
    let j;
    try { j = JSON.parse(p.payloadText || ''); } catch (err) { _toast(`报文不是合法 JSON:${err.message}`, 'err'); return; }
    const norm = this._normalizeProbeParams(j);   // 结构化/平铺/混合三种形态统一归一
    p.form = norm;
    _toast(`✓ 已填表:IMPORT ${Object.keys(norm.import).length} / TABLES ${Object.keys(norm.tables).length}`, 'ok');
    this.render();
  }

  async probeLoadSets(silent = true) {
    const p = this.probe;
    p.setsLoading = true;
    if (p.sets) this.render();
    try {
      const fm = p.fm.trim();
      // 按函数过滤(路由侧筛),避免别的函数的参数集混进来误导
      const res = await bridge.run('sap-probe', {
        kind: 'fm', action: 'list', system: p.sys, ...(fm ? { function: fm } : {}),
      }, { timeoutMs: 15000 });
      if (res.ok === false) throw new Error(emOf(res));
      // 参数集同样经 PS 结果缓存往返:1 元素数组降级标量会让 render 的 .filter 抛错
      // (09-17 MutHashTable 同型,09-18 审查 C7)——与 loadLint 的 arr() 同口径归一
      const arr = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
      p.sets = arr(res.sets).map((s) => { if (s && typeof s === 'object') { s.importKeys = arr(s.importKeys); s.tableNames = arr(s.tableNames); } return s; });
    } catch (err) { if (!silent) _toast(`参数集清单失败:${err.message || err}`, 'err'); }
    p.setsLoading = false;
    this.render();
  }

  async probeLoadSet(name, fm) {
    const p = this.probe;
    this._probeBarVals();
    const target = fm || p.fm.trim();
    if (!target) { _toast('参数集缺函数名,请在函数名框填上再载入', 'err'); return; }
    try {
      const res = await bridge.run('sap-probe', { kind: 'fm', action: 'load', system: p.sys, function: target, name }, { timeoutMs: 15000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.form = { import: (res.set && res.set.import) || {}, tables: (res.set && res.set.tables) || {} };
      p.fm = target;
      _toast(`✓ 参数集 ${name} 已载入`, 'ok');
    } catch (err) { this._probeErr('载入参数集失败', err); }
    this.render();
  }

  async probeSaveSet() {
    const p = this.probe;
    this._probeBarVals();
    if (!this._captureProbeForm()) return;
    const fm = p.fm.trim(), name = p.setName.trim();
    if (!fm || !name) { _toast('函数名和参数集名称都要填', 'err'); return; }
    try {
      const res = await bridge.run('sap-probe', {
        kind: 'fm', action: 'save', system: p.sys, function: fm, name,
        note: `Driver存 ${_nowStamp()}`,
        payload: { import: p.form.import, tables: p.form.tables },
      }, { timeoutMs: 15000 });
      if (res.ok === false) throw new Error(emOf(res));
      _toast(`✓ 参数集 ${name} 已存(一键复现)`, 'ok');
    } catch (err) { _toast(`存参数集失败:${err.message || err}`, 'err'); }
    this.probeLoadSets();
  }

  // v12 期望比对(定点排查):关键字全命中 + 行数达标 → {ok:true};填了才比对(null=没填)
  _expectCheck(res) {
    const p = this.probe;
    const kws = String(p.expectKw || '').split(/[,，、;]+/).map((s) => s.trim()).filter(Boolean);
    const minRaw = String(p.expectMin ?? '').trim();
    const min = /^\d+$/.test(minRaw) ? parseInt(minRaw, 10) : 0;
    if (!kws.length && !min) return null;
    const list = (res && Array.isArray(res.ET_LIST)) ? res.ET_LIST.map((l) => String((l && l.LINE) ?? '')).join('\n') : '';
    const lines = Number((res && res.EV_LINES) ?? 0) || (list ? list.split('\n').length : 0);
    const reasons = [];
    if (min && lines < min) reasons.push(`列表仅 ${lines} 行 < 期望 ${min} 行`);
    for (const k of kws) {
      if (!list.includes(k)) reasons.push(`输出中未找到「${k}」`);
    }
    return reasons.length ? { ok: false, reasons } : { ok: true, reasons: [] };
  }

  async probeExec(force = false) {
    const p = this.probe;
    this._probeBarVals();
    const fm = p.fm.trim();
    if (!fm) { _toast(p.kind === 'report' ? '先填报表名' : '先填函数名', 'err'); return; }
    // v12 report 分支:ZLILY_REPORT_RUN2(标准+Z/Y 报表均可,后台作业真跑+列表取回)。
    // PRD 治理:每次执行先预检副作用,人工点「确认执行」才带 force 重发——逐次确认,绝无自动放行。
    if (p.kind === 'report') {
      if (p.sys === 'PRD' && !force) {
        p.confirmReq = { loading: true };
        this.render();
        try {
          const pc = await bridge.run('sap-probe', { kind: 'report', action: 'precheck', system: p.sys, report: fm }, { timeoutMs: 60000 });
          p.confirmReq = pc.ok === false
            ? { err: emOf(pc) }
            : { riskLevel: pc.riskLevel, risks: pc.risks || [], message: pc.message || '' };
        } catch (err) { p.confirmReq = { err: String((err && err.message) || err) }; }
        this.render();
        return;
      }
      p.confirmReq = null;
      if (!p.reportSig) { await this.probeLoadSig(); if (!p.reportSig) return; }
      // 只提交有值的行:P 非空即提交;S LOW/HIGH 任一非空提交(SIGN 默认 I,OPTION 默认 EQ)
      const seltab = (p.reportSig || [])
        .filter((it) => (it.KIND === 'S' ? (String(it.LOW ?? '').length + String(it.HIGH ?? '').length) : String(it.LOW ?? '').length) > 0)
        .map((it) => (it.KIND === 'S'
          ? { SELNAME: it.SELNAME, KIND: 'S', SIGN: it.SIGN || 'I', OPTION: it.OPTION || 'EQ', LOW: String(it.LOW ?? ''), HIGH: String(it.HIGH ?? '') }
          : { SELNAME: it.SELNAME, KIND: 'P', SIGN: 'I', OPTION: 'EQ', LOW: String(it.LOW ?? ''), HIGH: '' }));
      p.execLoading = true; p.lastErr = null; p.execRes = null; p.expectRes = null; p.repStatus = null;
      this.render();
      try {
        const res = await bridge.run('sap-probe', {
          kind: 'report', action: 'exec', system: p.sys, report: fm,
          ...(p.variant.trim() ? { variant: p.variant.trim() } : {}),
          ...(p.sys === 'PRD' ? { force: true } : {}),
          seltab,
        }, { timeoutMs: 115000 });
        if (res.ok === false) throw new Error(emOf(res));
        if (res.status === 'RUNNING' && res.jobname) {
          // RFC 等待预算内没跑完:作业在后台继续,轮询接力取结果
          p.execLoading = false;
          _toast(`⏳ 后台作业 ${res.jobname} 已提交,轮询取结果中…`, 'info');
          this.render();
          this.probePoll(res.jobname, res.jobcount, 0);
          return;
        }
        p.execRes = res.exec;
        p.execMs = res.durationMs != null ? res.durationMs : (res.facadeHttpMs || 0);
        p.expectRes = this._expectCheck(p.execRes);
        _toast(`✓ ${fm} 执行完成 ${p.execMs}ms${p.expectRes && !p.expectRes.ok ? '(未取到期望结果)' : ''}`, 'ok');
      } catch (err) {
        p.lastErr = this._probeErr('执行失败', err);
      }
      p.execLoading = false;
      this.render();
      // v12:report 自动诊断——「报错 / 空 / 期望未命中」都触发;诊断对象=报表程序本身
      const r0 = p.execRes || {};
      const emptyRep = !p.lastErr && Number(r0.EV_LINES || 0) === 0;
      const missExp = !p.lastErr && p.expectRes && !p.expectRes.ok;
      const credErr2 = p.lastErr && (p.lastErr.includes('NEED_CREDENTIAL') || p.lastErr.includes('未注入凭证'));
      if (p.autoDiag && (p.lastErr || emptyRep || missExp) && !credErr2) this.probeDiagnose(emptyRep || missExp);
      return;
    }
    // 没读过接口且表单还是空的 → 自动读一次接口生成表单(少点一步;失败时里面已提示)
    const hasFormNow = Object.keys(p.form.import || {}).length || Object.keys(p.form.tables || {}).length;
    if (!p.sig && !hasFormNow) {
      await this.probeLoadSig();
      if (!p.sig) return;
    }
    if (!this._captureProbeForm()) return;
    p.execLoading = true; p.lastErr = null; p.execRes = null; p.conv = null; p.diag = null;
    this.render();
    try {
      const res = await bridge.run('sap-probe', {
        kind: 'fm', action: 'exec', system: p.sys, function: fm,
        import: p.form.import, tables: p.form.tables,
      }, { timeoutMs: 115000 });
      if (res.ok === false) throw new Error(emOf(res));
      p.execRes = res.exec;
      p.conv = res.conv || null;
      p.execMs = res.durationMs != null ? res.durationMs : (res.facadeHttpMs || 0);
      const nConv = p.conv && p.conv.applied ? p.conv.applied.length : 0;
      _toast(`✓ ${fm} 执行完成 ${p.execMs}ms${nConv ? `(已转内码 ${nConv} 项)` : ''}`, 'ok');
    } catch (err) {
      p.lastErr = this._probeErr('执行失败', err);   // NEED_CREDENTIAL → 自动弹连接面板
    }
    p.execLoading = false;
    this.render();
    // 报错/空结果 → 自动诊断「为什么」(可关)。凭证类错误不诊断,原因自明。
    const empty = this._probeLooksEmpty(p.execRes);
    const credErr = p.lastErr && (p.lastErr.includes('NEED_CREDENTIAL') || p.lastErr.includes('未注入凭证'));
    if (p.autoDiag && (p.lastErr || empty) && !credErr) this.probeDiagnose(empty);
  }

  // v12 RUNNING 接力:5 秒一次 poll,24 次封顶(2 分钟);完成后与同步路径同一出口。
  // 作业本身在后台不受断连影响——超封顶只是不追了,如实告知去 SM37 看。
  async probePoll(jobname, jobcount, tries = 0) {
    const p = this.probe;
    if (tries >= 24) {
      p.repStatus = null;
      p.lastErr = `后台作业 ${jobname} 超过 2 分钟仍未完成——作业还在跑,可稍后重跑同参数取回,或 SM37 看作业 ${jobname}`;
      this.render();
      return;
    }
    p.repStatus = { jobname, jobcount, tries: tries + 1 };
    try {
      const res = await bridge.run('sap-probe', { kind: 'report', action: 'poll', system: p.sys, jobname, jobcount }, { timeoutMs: 30000 });
      if (res.ok === false) throw new Error(emOf(res));
      if (res.status === 'RUNNING') {
        // 就地更新轮询计数(2026-09-21 审查 P2):原每 5s 全量 render 整页重建 24 次,
        // 等待期间在报文框/参数表单打字会被打断焦点;对齐 ask/diag 轮询的就地刷新模式
        const triesEl = this.root.querySelector('#sapc-rep-tries');
        if (triesEl) triesEl.textContent = `已轮询 ${tries + 1}/24 次(每 5 秒;SM37 可看作业详情)`;
        else this.render();
        // timer 存引用(09-18 审查 C7):unmount 时可清,切走后不再打桥
        this._probeTimer = setTimeout(() => this.probePoll(jobname, jobcount, tries + 1), 5000);
        return;
      }
      p.repStatus = null;
      if (res.status === 'CANCELLED') {
        p.lastErr = `后台作业 ${jobname} 被取消(状态 A)——明细见 SM37`;
      } else {
        p.execRes = res.exec;
        p.execMs = res.durationMs != null ? res.durationMs : (res.facadeHttpMs || 0);
        p.expectRes = this._expectCheck(p.execRes);
        _toast(`✓ ${p.fm.trim()} 后台执行完成 ${p.execMs}ms${p.expectRes && !p.expectRes.ok ? '(未取到期望结果)' : ''}`, 'ok');
      }
    } catch (err) {
      p.repStatus = null;
      p.lastErr = this._probeErr('轮询作业结果失败', err);
      this.render();
      return;
    }
    this.render();
    const r0 = p.execRes || {};
    const emptyRep = !p.lastErr && p.execRes != null && Number(r0.EV_LINES || 0) === 0;
    const missExp = !p.lastErr && p.expectRes && !p.expectRes.ok;
    if (p.autoDiag && !p.lastErr && (emptyRep || missExp)) this.probeDiagnose(emptyRep || missExp);
  }

  // 结果值 → markdown:数组→表格(截 100 行),对象→KV,标量原样。全量走 CSV 导出
  _valToMd(v) {
    if (v == null) return '(空)';
    if (Array.isArray(v)) {
      if (!v.length) return '(0 行)';
      if (typeof v[0] === 'object' && v[0] != null && !Array.isArray(v[0])) {
        const cols = [...new Set(v.slice(0, 20).flatMap((r) => Object.keys(r)))];
        const cell = (x) => String(x ?? '').replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
        const MAX = 5000;
        const body = v.slice(0, MAX).map((r) => `| ${cols.map((c) => (r && typeof r === 'object' ? cell(r[c]) : cell(r))).join(' | ')} |`).join('\n');
        const head = `| ${cols.join(' | ')} |\n| ${cols.map(() => '---').join(' | ')} |`;
        return `${head}\n${body}${v.length > MAX ? `\n\n(共 ${v.length} 行,仅渲染前 ${MAX} 行;全量请 📊 导出 Excel)` : ''}`;
      }
      return v.map((x) => `- ${String(x)}`).join('\n');
    }
    if (typeof v === 'object') {
      const kv = Object.entries(v).map(([k2, v2]) => `- **${k2}**: ${typeof v2 === 'object' ? JSON.stringify(v2) : String(v2 ?? '')}`);
      return kv.length ? kv.join('\n') : '(空对象)';
    }
    return String(v);
  }

  _execResToMd(res) {
    return Object.entries(res || {}).map(([k, v]) => {
      const tag = Array.isArray(v) ? `▦ ${k}(${v.length} 行)` : k;
      return `**${tag}**\n\n${this._valToMd(v)}`;
    }).join('\n\n');
  }

  // v15 时间线导出行(与表格渲染同口径;复制/Excel 共源)
  _timelineRows() {
    return ((this.timeline && this.timeline.entries) || []).map((e) => {
      const t = new Date(Number(e.ts));
      const hh = `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}:${String(t.getSeconds()).padStart(2, '0')}`;
      return { 时间: hh, 通道: e.channel === 'pw' ? 'Driver' : 'CC', 工具: e.tool, 系统: e.system,
        结果: e.result === 'ok' ? '✓ ok' : (e.result === 'error' ? `✗ ${e.code || 'error'}` : `⛔ ${e.code || 'denied'}`),
        耗时ms: e.durationMs ?? '', 行数: e.rows ?? '', 错误: e.error || '' };
    });
  }

  // 排查报告 markdown:环境-函数/输入参数/内外码转换/报错/执行结果/诊断分析全要素
  _probeReportMd() {
    const p = this.probe;
    const L = ['# SAP Driver 排查报告'];
    L.push(`- 环境/程序:**${p.sys} · ${p.fm.trim() || '(未填)'}**${p.variant ? `(变式 ${p.variant})` : ''}`);
    L.push(`- 导出时间:${_nowStamp()}`);
    if (p.kind === 'report' && (p.expectKw || p.expectMin)) {
      const exp = [p.expectKw ? `关键字「${p.expectKw}」` : '', p.expectMin ? `≥${p.expectMin} 行` : ''].filter(Boolean).join(' + ');
      L.push(`- 期望结果:${exp} → ${p.expectRes ? (p.expectRes.ok ? '**✅ 命中**' : `**❌ 未取到**(${p.expectRes.reasons.join(';')})`) : '(未比对)'}`);
    }
    const ex = p.explain;
    if (ex && ex.md) L.push('\n## 接口解读\n\n' + ex.md);
    L.push('\n## 输入参数');
    L.push('```json\n' + JSON.stringify({ import: p.form.import, tables: p.form.tables }, null, 1) + '\n```');
    if (p.conv && p.conv.applied && p.conv.applied.length) {
      L.push('\n内外码转换:' + p.conv.applied.map((c) => `${c.path} \`${c.from}\`→\`${c.to}\``).join(';'));
    }
    if (p.lastErr) L.push('\n## 执行报错\n\n```\n' + p.lastErr + '\n```');
    if (p.execRes != null) L.push('\n## 执行结果\n\n' + this._execResToMd(p.execRes));
    const d = p.diag;
    if (d && d.result && d.result.answer) {
      L.push('\n## 诊断分析\n\n' + d.result.answer);
      const v = d.result.verify || [];
      if (v.length) L.push('\n反证验证:' + v.map((s) => `${s.tool}(${s.why || ''})→${s.ok ? '✓' : '✗ ' + (s.error || '')}`).join(';'));
    }
    return L.join('\n');
  }

  // 执行返回是否「空」:所有导出参数/表都无内容 → 该问「为什么没数据」了
  _probeLooksEmpty(res) {
    if (res == null) return false;
    if (typeof res !== 'object') return false;
    const vals = Object.values(res);
    if (!vals.length) return true;
    const has = (v) => {
      if (v == null) return false;
      if (typeof v === 'string') return v.trim().length > 0;
      if (Array.isArray(v)) return v.length > 0;
      if (typeof v === 'object') return Object.values(v).some(has);
      return true;
    };
    return !vals.some(has);
  }

  // ---- 🔍 排查诊断(v8):exec 报错/空结果 → 采信号 → AI 定位 → 自动反证 → 唯一根因 ----
  async probeDiagnose(emptyHint = false) {
    const p = this.probe;
    const callId = (crypto.randomUUID ? crypto.randomUUID() : (Date.now().toString(16) + Math.floor(Math.random() * 1e8).toString(16)));
    p.diag = { running: true, text: '采集信号(源码/消息解码/参数体检)…', empty: !!emptyHint };
    p.diagCallId = callId;
    this.render();
    this._startDiagPoll(callId);
    try {
      const isRepDiag = p.kind === 'report';
      const selForm = (p.reportSig || []).filter((it) => (it.KIND === 'S'
        ? (String(it.LOW ?? '').length + String(it.HIGH ?? '').length) : String(it.LOW ?? '').length) > 0)
        .map((it) => ({ SELNAME: it.SELNAME, KIND: it.KIND, SIGN: it.SIGN, OPTION: it.OPTION, LOW: String(it.LOW ?? ''), HIGH: String(it.HIGH ?? '') }));
      const res = await bridge.run('sap-diagnose', {
        system: p.sys, function: p.fm.trim(),
        ...(isRepDiag ? { kind: 'report', form: { seltab: selForm } } : { form: { import: p.form.import, tables: p.form.tables } }),
        execError: p.lastErr || '', execRes: p.execRes || null,
        emptyHint: !!emptyHint, callId,
      }, { timeoutMs: 180000 });
      if (res.ok === false) throw new Error(emOf(res));
      const wasDiscarded = !!(p.diag && p.diag.discarded);
      p.diag = { running: false, result: res };
      this._stopDiagPoll();
      if (wasDiscarded) return;   // 用户已收起:结果照存进 store,不再打扰界面
    } catch (err) {
      const wasDiscarded = !!(p.diag && p.diag.discarded);
      p.diag = { running: false, error: String((err && err.message) || err) };
      this._stopDiagPoll();
      if (wasDiscarded) return;
    }
    this.render();
  }

  _startDiagPoll(callId) {
    SAPC_STORE.probe.diagCallId = callId;
    this._stopDiagPoll();
    this._diagTimer = setInterval(async () => {
      try {
        const res = await bridge.run('sap-ask-progress', { callId, kind: 'diag' }, { timeoutMs: 8000 });
        if (res && res.found) {
          if (this.probe.diag && this.probe.diag.running) {
            this.probe.diag.text = this._diagPhaseText(res);
            const node = this.root.querySelector('#sapc-diag-phase');
            if (node) node.textContent = this.probe.diag.text;
          }
        }
      } catch { /* 静默,下一拍 */ }
    }, 850);
  }
  _stopDiagPoll() {
    if (this._diagTimer) { clearInterval(this._diagTimer); this._diagTimer = null; }
  }
  _diagPhaseText(p) {
    if (p.phase === 'collect') return '采集信号(源码/消息解码/参数体检)…';
    if (p.phase === 'locate') return 'AI 定位候选根因…';
    if (p.phase === 'verify') return `自动反证验证 ${p.step}/${p.total} ${p.tool ? `(${p.tool})` : ''}`;
    if (p.phase === 'verdict') return 'AI 终裁,出唯一结论…';
    return '处理中…';
  }

  _renderDiagCard() {
    const d = this.probe.diag;
    if (!d || d.discarded) return '';
    if (d.running) {
      return `<div class="pb-card sapc-diag">
        <div class="pb-title">🔍 诊断中<span class="sub">为什么报错 / 为什么没数据</span>
          <span style="flex:1"></span><button data-act="diag-close" style="font-size:11.5px;padding:2px 10px;">收起</button></div>
        <div class="sapc-loading"><span class="spin"></span><span id="sapc-diag-phase">${esc(d.text)}</span></div>
      </div>`;
    }
    if (d.error) {
      return `<div class="pb-card sapc-diag">
        <div class="pb-title">🔍 诊断失败</div>
        <div class="pb-err"><span>✗</span><span>${esc(d.error)}</span></div>
        <div style="margin-top:8px;"><button data-act="diag-retry" style="font-size:12px;padding:3px 14px;">重试诊断</button></div>
      </div>`;
    }
    const r = d.result || {};
    const v = String(r.verdict || '');
    const badge = v === 'unique' ? '<span class="diag-badge uniq">🎯 唯一根因</span>'
      : v === 'ambiguous' ? '<span class="diag-badge amb">⚖️ 候选根因(差一个数据裁决)</span>'
      : '<span class="diag-badge amb">需要更多信号</span>';
    const verify = r.verify || [];
    const vRows = verify.length ? `<table class="res-tbl"><thead><tr><th>反证验证</th><th>目的</th><th>结果</th></tr></thead><tbody>${
      verify.map((s) => `<tr><td>${esc(s.tool)}</td><td>${esc(s.why || '')}</td>
        <td>${s.ok ? `✓ ${s.ms || 0}ms` : `✗ ${esc(String(s.error || '').slice(0, 60))}`}</td></tr>`).join('')
    }</tbody></table>` : '';
    const t = r.timings || {};
    return `<div class="pb-card sapc-diag">
      <div class="pb-title">${badge} 诊断报告 <span class="sub">${t.totalMs ? `${t.totalMs}ms` : ''}${r.model ? ` · ${esc(r.model)}` : ''}</span>
        <span style="flex:1"></span><button data-act="diag-close" style="font-size:11.5px;padding:2px 10px;">收起</button></div>
      <div class="md">${renderMarkdown(String(r.answer || ''))}</div>
      ${vRows}
      ${r.nextHint ? `<div style="margin-top:8px;"><button data-act="diag-next" style="font-size:12px;padding:3px 14px;">⚡ 让「问 Agent」接着查</button></div>` : ''}
    </div>`;
  }


  // bind() 内「🧪 函数排查事件」段(2026-10-30 原地抽成 bindProbe,bind() 改为转发——
  // 原位置逐字未动,只换宿主;主文件 bind() 在 probe 页签激活时调 this.bindProbe())。
  bindProbe() {
    // ---- 🧪 函数排查事件(输入框只存 store 不 render,防丢焦点;按钮动作时回读)----
    this.root.querySelectorAll('[data-probe-f]').forEach((el) => {
      el.addEventListener('input', () => this._probeBarVals());
    });
    this.root.querySelectorAll('[data-act="probe-kind"]').forEach((b) => {
      b.addEventListener('click', () => {
        const p = this.probe;
        this._probeBarVals();   // 当前表单先回读 store,切回来还在
        if (b.dataset.k && b.dataset.k !== p.kind) {
          this._resetProbeKind(b.dataset.k);   // v15:清理链收敛(与 catalog 直达共用)
          this.render();
        }
      });
    });
    this.root.querySelector('[data-act="probe-sig"]')?.addEventListener('click', () => this.probeLoadSig());
    this.root.querySelector('[data-act="probe-lint"]')?.addEventListener('click', () => this.probeLint());   // v14
    this.root.querySelector('[data-act="lint-ai"]')?.addEventListener('click', () => this.probeLintAi());   // v16 AI 深审
    this.root.querySelector('[data-act="probe-gate"]')?.addEventListener('click', () => this.probeGate());   // v19 交付门禁
    this.root.querySelector('[data-act="gate-refresh"]')?.addEventListener('click', () => this.probeGate(true));
    this.root.querySelector('[data-act="gate-rep-copy"]')?.addEventListener('click', () => this._gateExport('copy'));
    this.root.querySelector('[data-act="gate-rep-html"]')?.addEventListener('click', () => this._gateExport('html'));
    this.root.querySelector('[data-act="gate-rep-xlsx"]')?.addEventListener('click', () => this._gateExport('xlsx'));
    this.root.querySelector('[data-act="lint-rep-copy"]')?.addEventListener('click', () => this._lintExport('copy'));
    this.root.querySelector('[data-act="lint-rep-html"]')?.addEventListener('click', () => this._lintExport('html'));
    this.root.querySelector('[data-act="lint-rep-xlsx"]')?.addEventListener('click', () => this._lintExport('xlsx'));   // v15
    this.root.querySelector('[data-act="diagpk-run"]')?.addEventListener('click', () => this.runDiagpk());   // v14 体检
    this.root.querySelector('[data-act="diagpk-refresh"]')?.addEventListener('click', () => this.runDiagpk(true));   // 2026-09-21 强刷(跳 TTL 缓存)
    this.root.querySelector('[data-act="diagpk-copy"]')?.addEventListener('click', () => this._diagpkExport('copy'));
    this.root.querySelector('[data-act="diagpk-html"]')?.addEventListener('click', () => this._diagpkExport('html'));
    this.root.querySelector('[data-act="diagpk-xlsx"]')?.addEventListener('click', () => this._diagpkExport('xlsx'));   // v15
    this.root.querySelector('[data-act="wk-run"]')?.addEventListener('click', () => this.runWk());   // v16 负载周报
    this.root.querySelector('[data-act="wk-ai"]')?.addEventListener('click', () => this.runWkComment());
    this.root.querySelector('[data-act="wk-mail"]')?.addEventListener('click', () => this.wkMail());   // v17 V2 存草稿
    this.root.querySelector('[data-wk-f="gran"]')?.addEventListener('change', () => {   // 周↔月切换:对比期选项随粒度重建,自选值作废回 auto
      const g = this.root.querySelector('[data-wk-f="gran"]');
      if (g) this.wk.gran = g.value;
      if (this.wk.baseSel !== 'auto') this.wk.baseSel = 'auto';
      this.render();
    });
    this.root.querySelector('[data-act="wk-copy"]')?.addEventListener('click', () => this._wkExport('copy'));
    this.root.querySelector('[data-act="wk-html"]')?.addEventListener('click', () => this._wkExport('html'));
    this.root.querySelector('[data-act="wk-xlsx"]')?.addEventListener('click', () => this._wkExport('xlsx'));
    this.root.querySelector('[data-act="probe-xref-content"]')?.addEventListener('click', () => this.probeXrefContent());   // v14 内容搜索
    this.root.querySelector('[data-act="probe-variant"]')?.addEventListener('click', () => this.probeLoadVariant());
    this.root.querySelector('[data-act="probe-parse"]')?.addEventListener('click', () => this.probeParsePayload());
    this.root.querySelector('[data-act="probe-save"]')?.addEventListener('click', () => this.probeSaveSet());
    this.root.querySelector('[data-act="probe-exec"]')?.addEventListener('click', () => this.probeExec());
    // v12 PRD 逐次确认卡按钮:确认=带 force 真发;取消=清确认态
    this.root.querySelector('[data-act="probe-confirm-go"]')?.addEventListener('click', () => this.probeExec(true));
    this.root.querySelector('[data-act="probe-confirm-cancel"]')?.addEventListener('click', () => {
      this.probe.confirmReq = null;
      this.render();
    });
    this.root.querySelector('[data-act="probe-sets-refresh"]')?.addEventListener('click', () => this.probeLoadSets(false));
    this.root.querySelectorAll('[data-act="probe-loadset"]').forEach((b) => {
      b.addEventListener('click', () => this.probeLoadSet(b.dataset.set, b.dataset.setfm));
    });
    this.root.querySelector('[data-act="probe-copy"]')?.addEventListener('click', async () => {
      const p = this.probe;
      // v10:xref 场景复制引用/搜索结果,函数与程序场景复制 execRes
      const data = p.execRes != null ? p.execRes
        : (p.xrefRes ? { name: p.xrefRes.name, field: p.xrefRes.field, refs: p.xrefRes.refs } : null)
        || (p.searchRes ? { kw: p.searchRes.kw, progs: p.searchRes.progs, descHits: p.searchRes.descHits } : null)
        || (p.usesRes ? { include: p.usesRes.include, refs: p.usesRes.refs } : null)
        || (p.trRes ? { trkorr: p.trRes.trkorr, head: p.trRes.head, objects: p.trRes.objects, subtasks: p.trRes.subtasks } : null)
        || (p.trListRes ? { user: p.trListRes.user, list: p.trListRes.list } : null);
      if (data == null) return;
      const ok = await copyText(JSON.stringify(data, null, 2));
      _toast(ok ? '已复制结果 JSON' : '复制失败(剪贴板被拒)', ok ? 'ok' : 'err');
    });
    this.root.querySelector('[data-act="probe-xref-used"]')?.addEventListener('click', () => this.probeXrefUsed());
    this.root.querySelector('[data-act="probe-xref-search"]')?.addEventListener('click', () => this.probeXrefSearch());
    // v12 引用影响分析树:展开/收起、看代码、筛选、反查、显示更多、过滤框(就地过滤保焦点)
    this.root.querySelectorAll('[data-act="xref-sec"]').forEach((b) => {
      b.addEventListener('click', () => {
        const p = this.probe; const m = b.dataset.main;
        const cur = p.xrefOpen[m] !== undefined ? p.xrefOpen[m] : _xrefIsCustom(m);
        p.xrefOpen[m] = !cur;
        this.render();
      });
    });
    this.root.querySelectorAll('[data-act="xref-code"]').forEach((b) => {
      b.addEventListener('click', () => this.probeXrefCode(b.dataset.inc, b.dataset.ot));
    });
    this.root.querySelectorAll('[data-act="xref-chip"]').forEach((b) => {
      b.addEventListener('click', () => { this.probe.xrefFilter = b.dataset.f || 'all'; this.render(); });
    });
    this.root.querySelectorAll('[data-act="xref-uses"]').forEach((b) => {
      b.addEventListener('click', () => this.probeXrefUses(b.dataset.main));
    });
    this.root.querySelector('[data-act="xref-more"]')?.addEventListener('click', () => { this.probe.xrefLimit += 40; this.render(); });
    // v12 引用结果导出三件套
    this.root.querySelector('[data-act="xref-rep-copy"]')?.addEventListener('click', () => this.probeXrefExport('copy'));
    this.root.querySelector('[data-act="xref-rep-html"]')?.addEventListener('click', () => this.probeXrefExport('html'));
    this.root.querySelector('[data-act="xref-rep-xlsx"]')?.addEventListener('click', () => this.probeXrefExport('xlsx'));
    // v15 传输溯源导出三件套
    this.root.querySelector('[data-act="tr-rep-copy"]')?.addEventListener('click', () => this._trExport('copy'));
    this.root.querySelector('[data-act="tr-rep-html"]')?.addEventListener('click', () => this._trExport('html'));
    this.root.querySelector('[data-act="tr-rep-xlsx"]')?.addEventListener('click', () => this._trExport('xlsx'));
    // v15 Trace调用链导出
    this.root.querySelector('[data-act="tl-copy"]')?.addEventListener('click', async () => {
      const rows = this._timelineRows();
      if (!rows.length) return;
      const ok = await copyText(JSON.stringify(rows, null, 2));
      _toast(ok ? `已复制 ${rows.length} 条` : '复制失败(剪贴板被拒)', ok ? 'ok' : 'err');
    });
    this.root.querySelector('[data-act="tl-xlsx"]')?.addEventListener('click', () => {
      try {
        const rows = this._timelineRows();
        if (!rows.length) { _toast('没有可导出的调用记录', 'info'); return; }
        downloadXlsx(`SAP调用总账-${this.timeline.date || todayStamp()}.xlsx`, [{ name: '调用总账', rows }]);
        _toast(`✓ 已导出 Excel(${rows.length} 条)`, 'ok');
      } catch (err) { _toast(`导出失败:${err.message || err}`, 'err'); }
    });
    // v15 Skill地图(单工具)结果下载(JSON 原文 / Excel 结构化)
    this.root.querySelectorAll('[data-act="res-json"]').forEach((b) => {
      b.addEventListener('click', (e) => {
        e.stopPropagation();
        const r = this._results.get(b.dataset.card);
        if (!r) return;
        downloadJson(`${safeFilename(b.dataset.card)}-结果.json`, r.text);
        _toast('✓ 已下载 JSON(下载目录)', 'ok');
      });
    });
    this.root.querySelectorAll('[data-act="res-xlsx"]').forEach((b) => {
      b.addEventListener('click', (e) => {
        e.stopPropagation();
        const r = this._results.get(b.dataset.card);
        if (!r) return;
        let data;
        try { data = JSON.parse(r.text); } catch { _toast('结果不是结构化 JSON,请用 💾 JSON 下载', 'err'); return; }
        try {
          const sheets = (Array.isArray(data) && data.length && typeof data[0] === 'object' && data[0] != null && !Array.isArray(data[0]))
            ? [{ name: '结果', rows: data }]
            : (Array.isArray(data) ? [{ name: '结果', rows: data.map((x) => ({ 值: String(x ?? '') })) }] : this._xlsxFromObj(data));
          downloadXlsx(`${safeFilename(b.dataset.card)}-结果.xlsx`, sheets);
          _toast(`✓ 已导出 Excel(${sheets.length} 个 SHEET)`, 'ok');
        } catch (err) { _toast(`导出 Excel 失败:${err.message || err}`, 'err'); }
      });
    });
    // v15 产物清单导出(按当前筛选)
    this.root.querySelector('#sapc-art-xlsx')?.addEventListener('click', () => {
      try {
        const items = this._artFiltered();
        if (!items.length) { _toast('没有匹配的产物', 'info'); return; }
        downloadXlsx('本地产物清单.xlsx', [{ name: '产物清单', rows: items.map((f) => ({
          文件名: f.name, 类型: f.label, 大小KB: f.sizeKB, 修改时间: f.mtime, 路径: f.path,
        })) }]);
        _toast(`✓ 已导出 Excel(${items.length} 条)`, 'ok');
      } catch (err) { _toast(`导出失败:${err.message || err}`, 'err'); }
    });
    this.root.querySelectorAll('[data-xref-q]').forEach((el) => {
      el.addEventListener('input', () => {
        this.probe.xrefQ = el.value;   // 存 store;过滤就地做,不重绘(保焦点)
        const q = el.value.trim().toUpperCase();
        this.root.querySelectorAll('.xref-prog').forEach((n) => {
          n.style.display = (!q || String(n.textContent || '').toUpperCase().includes(q)) ? '' : 'none';
        });
      });
    });
    this.root.querySelector('[data-act="probe-tr-view"]')?.addEventListener('click', () => this.probeTrView());
    this.root.querySelector('[data-act="probe-tr-list"]')?.addEventListener('click', () => this.probeTrList());
    this.root.querySelector('[data-act="probe-objtr"]')?.addEventListener('click', () => this.probeObjTr());
    // v13.1 请求详情卡收起/返回溯源(点击请求号下钻后能回得来)
    this.root.querySelector('[data-act="tr-detail-close"]')?.addEventListener('click', () => {
      const p = this.probe; p.trRes = null; p.trListRes = null; this.render();
    });
    this.root.querySelector('[data-act="tr-detail-back"]')?.addEventListener('click', () => {
      const p = this.probe; p.trRes = null; p.trListRes = null; this.render();
    });
    // v13 溯源下钻:点请求号 → 填输入框 + 触发「查请求详情」(复用现有 tr 详情卡)
    // ★必须走 DOM→input 事件链:直接设 store 会被 probeTrView 开头的 _probeBarVals() 回读 DOM 覆盖
    this.root.querySelectorAll('[data-act="objtr-tr"]').forEach((b) => {
      b.addEventListener('click', (e) => {
        e.preventDefault();
        const inp = this.root.querySelector(".sapc-probe input[data-probe-f='fm']");
        if (inp) { inp.value = b.dataset.tr || ''; inp.dispatchEvent(new Event('input', { bubbles: true })); }
        this.probeTrView();
      });
    });
    // 📊 导出 Excel:一个工作簿多 SHEET——概览 / 接口解读 / 输入参数 / 每个输出表各一 SHEET
    this.root.querySelector('[data-act="probe-rep-xlsx"]')?.addEventListener('click', () => {
      try {
        const p = this.probe;
        if (p.execRes == null) return;
        const sheets = [];
        const ov = [
          { 项目: '环境 / 函数', 内容: `${p.sys} · ${p.fm.trim()}${p.variant ? `(变式 ${p.variant})` : ''}` },
          { 项目: '导出时间', 内容: _nowStamp() },
          { 项目: '执行耗时', 内容: p.execMs ? `${p.execMs}ms` : '' },
        ];
        if (p.lastErr) ov.push({ 项目: '执行报错', 内容: p.lastErr });
        if (p.conv && p.conv.applied && p.conv.applied.length) ov.push({ 项目: '内外码转换', 内容: p.conv.applied.map((c) => `${c.path}: ${c.from}→${c.to}`).join('; ') });
        sheets.push({ name: '概览', rows: ov });
        if (p.explain && p.explain.md) {
          const lines = String(p.explain.md).split(/\r?\n/).map((l) => ({ 内容: l.replace(/^#{1,6}\s*/, '').replace(/\*\*/g, '').replace(/`/g, '') }));
          sheets.push({ name: '接口解读', rows: lines });
        }
        const inRows = [];
        Object.entries(p.form.import || {}).forEach(([k, v]) => inRows.push({ 类别: 'IMPORT', 参数: k, 值: typeof v === 'object' ? JSON.stringify(v) : String(v ?? '') }));
        Object.entries(p.form.tables || {}).forEach(([k, v]) => {
          inRows.push({ 类别: 'TABLES', 参数: `${k}(${Array.isArray(v) ? v.length : 0} 行)`, 值: '' });
          (Array.isArray(v) ? v : []).forEach((r, ri) => inRows.push({ 类别: '', 参数: `行${ri + 1}`, 值: JSON.stringify(r) }));
        });
        sheets.push({ name: '输入参数', rows: inRows.length ? inRows : [{ 类别: '-', 参数: '(无)', 值: '' }] });
        const used = new Set();
        const otherRows = [];
        Object.entries(p.execRes).forEach(([k, v]) => {
          if (Array.isArray(v) && v.length && typeof v[0] === 'object' && v[0] != null && !Array.isArray(v[0])) {
            let n = String(k).replace(/[\\/*?:[\]]/g, '_').slice(0, 31) || 'Sheet';
            let i = 2; const base = n; while (used.has(n)) { n = `${base}_${i++}`; }
            used.add(n);
            sheets.push({ name: n, rows: v });
          } else {
            otherRows.push({ 参数: k, 值: typeof v === 'object' ? JSON.stringify(v) : String(v ?? '') });
          }
        });
        if (otherRows.length) sheets.push({ name: '输出-其他', rows: otherRows });
        downloadXlsx(`${safeFilename(p.fm.trim() || 'SAP Driver')}-结果.xlsx`, sheets);
        _toast(`✓ 已导出 Excel(${sheets.length} 个 SHEET)`, 'ok');
      } catch (err) { _toast(`导出 Excel 失败:${err.message || err}`, 'err'); }
    });
    // 🔍 诊断卡动作(收起 = 哨兵挂起,结果回来也不打扰;重试/转问Agent)
    this.root.querySelectorAll('[data-act="diag-close"]').forEach((b) => {
      b.addEventListener('click', () => {
        this._stopDiagPoll();
        const d = this.probe.diag;
        this.probe.diag = d && d.running ? { running: true, discarded: true, text: '', empty: d.empty } : null;
        this.render();
      });
    });
    this.root.querySelector('[data-act="diag-retry"]')?.addEventListener('click', () => {
      const e = this.probe.diag && this.probe.diag.empty;
      this.probe.diag = null;
      this.probeDiagnose(e);
    });
    this.root.querySelector('[data-act="explain-close"]')?.addEventListener('click', () => {
      this.probe.explain = null;
      this.render();
    });
    this.root.querySelector('[data-act="diag-next"]')?.addEventListener('click', () => {
      const nh = this.probe.diag && this.probe.diag.result && this.probe.diag.result.nextHint;
      if (!nh) return;
      this.tab = 'ask';
      this._qText = nh;
      this.render();
    });
    // 📋📄 排查报告导出(v15 收敛到 _mdExport 共享件)
    this.root.querySelector('[data-act="probe-rep-copy"]')?.addEventListener('click', () => {
      this._mdExport('copy', this._probeReportMd(), { title: 'SAP Driver 排查报告' });
    });
    this.root.querySelector('[data-act="probe-rep-html"]')?.addEventListener('click', () => {
      const p = this.probe;
      this._mdExport('html', this._probeReportMd(), {
        title: 'SAP Driver 排查报告',
        subtitle: `${p.sys} · ${p.fm.trim()} · ${_nowStamp()}`,
        filename: `${p.fm.trim() || 'SAP Driver'} 排查报告`,
      });
    });
  }
}
