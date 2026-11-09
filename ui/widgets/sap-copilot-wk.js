// sap-copilot-wk.js — SAP Driver 「负载周报」页签(v16/v17)——renderWk/runWk/AI解读/存草稿/报告/Excel(2026-10-30 拆分批一,class mixin)。
// 拆分=原地移动零改动:方法体逐字搬运,this 语义不变(SAPC_STORE 经主文件 getter 代理),
// e2e 选择器/data-act 零变化。装配:主文件 import 后把 mixin 方法挂上 SapCopilotWidget.prototype;
// 共享符号经 bindSapShared() 注入(见下方 let 声明)——不 import 主文件防环。

let _toast, _nowStamp, emOf, esc, safeFilename, downloadXlsx, bridge, markdownToDocumentHtml, renderMarkdown;

// 主文件装配时调一次,把共享符号绑进本模块闭包(app 启动一次;类方法体沿模块作用域取值)。
export function bindSapShared(deps) {
  _toast = deps._toast;
  _nowStamp = deps._nowStamp;
  emOf = deps.emOf;
  esc = deps.esc;
  safeFilename = deps.safeFilename;
  downloadXlsx = deps.downloadXlsx;
  bridge = deps.bridge;
  markdownToDocumentHtml = deps.markdownToDocumentHtml;
  renderMarkdown = deps.renderMarkdown;
}

export class SapWkMethods {
  // v16 工作负载周报:SWNC/SAPWL 负载聚合(每日趋势/任务类型/TOP 榜),独立页签。
  renderWk() {
    const w = this.wk;
    const sysOpts = ['DVP', 'QAS', 'PRD'].map((s) => `<option value="${s}" ${w.sys === s ? 'selected' : ''}>${s}${s === 'PRD' ? ' · 只读' : ''}</option>`).join('');
    const granOpts = [['week', '周报'], ['month', '月报']].map(([v, t]) => `<option value="${v}" ${w.gran === v ? 'selected' : ''}>${t}</option>`).join('');
    const modeOpts = [['last', '上一完整周期'], ['this', '本期至今']].map(([v, t]) => `<option value="${v}" ${w.mode === v ? 'selected' : ''}>${t}</option>`).join('');
    // 对比期选项:近 12 个周期(周=周一;月=月初);auto=默认自动环比(上一完整周期的上一期)
    const baseOpts = ['<option value="auto">对比:自动(上一期)</option>'];
    try {
      const today = new Date();
      const items = [];
      if (w.gran === 'month') {
        for (let i = 1; i <= 12; i++) {
          const d = new Date(today.getFullYear(), today.getMonth() - i, 1);
          items.push({ v: `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}01`, t: `${d.getFullYear()} 年 ${d.getMonth() + 1} 月` });
        }
      } else {
        const monday = new Date(today);
        monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7));
        for (let i = 1; i <= 12; i++) {
          const d = new Date(monday); d.setDate(monday.getDate() - 7 * i);
          const e = new Date(d); e.setDate(d.getDate() + 6);
          const f = (x) => `${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
          const v = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
          items.push({ v, t: `${f(d)} ~ ${f(e)}` });
        }
      }
      for (const it of items) baseOpts.push(`<option value="${it.v}" ${w.baseSel === it.v ? 'selected' : ''}>对比:${it.t}</option>`);
    } catch { /* 选项构建失败退化为 auto 一项 */ }
    const badge = { OK: ['✓ 良好', 'var(--sd-success-text)'], WARN: ['⚠ 偏慢', 'var(--sd-warning-text)'], CRIT: ['✗ 过慢', 'var(--sd-danger-text)'], NA: ['· 无数据', 'var(--sd-text-faint)'] };
    const n = (x) => (x == null ? '-' : Number(x).toLocaleString('en-US'));
    const avgMsTxt = (x) => (x == null ? '-' : (x < 1 ? '<1' : n(x)));
    let bodyHtml = '';
    if (w.running) bodyHtml = '<div class="sapc-loading"><span class="spin"></span>负载报告生成中(拉取 SAP 负载聚合+环比;首次跑某周期需 1~3 分钟,之后走缓存秒级)…</div>';
    if (w.res) {
      const r = w.res;
      const h = r.health || {};
      const [hb, hc] = badge[h.status] || [h.status, 'inherit'];
      const cd = r.cur || {}; const bd = r.base || {};
      const period = `${cd.label || ''}${cd.isPartial ? '(未完)' : ''}`;
      const plainBits = [];
      const p = r.plain || {};
      if (p.busy) plainBits.push(['🕰 系统忙不忙', p.busy]);
      if (p.fast) plainBits.push(['🚀 反应快不快', p.fast]);
      if (p.where) plainBits.push(['🏋️ 资源大头在哪', p.where]);
      if (p.changes) plainBits.push(['📊 和上期比', p.changes]);
      const noteBits = [];
      const cdData = r.curData || {};
      if (cdData.periodMissing) noteBits.push(`该系统无本${w.gran === 'month' ? '月' : '周'}聚合记录(聚合采集未运行)` + (cdData.dirLatest ? `,统计目录最新记录 ${cdData.dirLatest}` : ''));
      if ((cdData.trendMissing || []).length) noteBits.push(`缺数据日期:${cdData.trendMissing.join(', ')}(当日无聚合记录/停机)`);
      if (cd.isPartial) noteBits.push('未完周期:榜单与均值含未结束的今天,收盘数据会继续变化');
      if (r.topCached) noteBits.push('汇总为 30 分钟内缓存(今天数据会继续变化)');
      const trendRows = (cdData.trend || []).map((d) => ({
        '时段': (d.label || d.date) + (d.crossMonth ? '(含邻月)' : ''), '总步数': n(d.totalSteps), '对话步数': n(d.dialogSteps),
        '对话均响 ms': n(d.dialogAvgMs), '后台': n(d.batchSteps), 'RFC': n(d.rfcSteps),
        '更新': n(d.updateSteps),
      }));
      const ttRows = (cdData.tasktypes || []).map((t) => ({
        '任务类型': `${t.name || t.type}`, '步数': n(t.steps), '平均响应 ms': n(t.avgMs), 'CPU 合计 s': n(t.cpuTotalMs == null ? null : Math.round(t.cpuTotalMs / 1000)),
      }));
      const etypeZh = { tcode: '事务码', report: '标准报表', zprog: '自定义报表', rfc: 'RFC 调用', sys: '系统活动', other: '' };
      const entryRows = (cdData.topEntry || []).map((t) => ({
        '名称': t.entry, '说明': t.desc || '', '类别': etypeZh[t.etype] || '', '步数': n(t.steps), '平均响应 ms': avgMsTxt(t.avgMs), '用户数': t.users,
      }));
      const userRows = (cdData.topUser || []).map((t) => ({
        '用户': t.user, '姓名': t.fullName || '', '步数': n(t.steps), '平均响应 ms': avgMsTxt(t.avgMs), 'CPU s': t.cpuS,
      }));
      const cmpRows = ((r.compare && r.compare.rows) || []).map((c) => ({
        '指标': c.metric, '本期': n(c.a), '对比期': c.b == null ? '-' : n(c.b),
        '变化': c.deltaPct == null ? '—' : `${c.deltaPct > 0 ? '+' : ''}${c.deltaPct}%`, '判定': c.verdict || '—',
      }));
      const dg = r.digest || null;
      const dgBits = [];
      if (dg) {
        if (dg.st22Dumps != null) dgBits.push(`近 7 天程序崩溃 ${dg.st22Dumps} 次${(dg.st22TopUsers || []).length ? '(集中:' + dg.st22TopUsers.join('、') + ')' : ''}`);
        if (dg.sm13Failed != null) dgBits.push(`更新失败积压 ${dg.sm13Failed} 项${(dg.sm13TopFuncs || []).length ? '(模块:' + dg.sm13TopFuncs.join('、') + ')' : ''}`);
        if (dg.jobsCanceled != null) dgBits.push(`近 7 天取消作业 ${dg.jobsCanceled} 个${(dg.jobsTopNames || []).length ? '(' + dg.jobsTopNames.join('、') + ')' : ''}`);
      }
      const card = (title, inner) => `<div class="pb-card"><div class="pb-title">${title}</div>${inner}</div>`;
      const tbl = (cols, rows) => this._dpTable(cols, rows);
      bodyHtml = `<div class="pb-card">
        <div class="pb-title">📈 ${esc(r.system)} 负载${w.gran === 'month' ? '月' : '周'}报 <span style="color:${hc};font-weight:700;">${hb}</span><span class="sub"> · ${esc(period)} · 对话均响 ${n(h.dialogAvgMs)}ms · ${esc(r.generatedAt || '')}</span>
          <span style="flex:1"></span><button data-act="wk-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制报告</button>
          <button data-act="wk-html" style="font-size:11.5px;padding:2px 10px;">📄 导出 HTML</button>
          <button data-act="wk-xlsx" style="font-size:11.5px;padding:2px 10px;">📊 导出 Excel</button>
          <button data-act="wk-mail" style="font-size:11.5px;padding:2px 10px;" ${w.mailing ? 'disabled' : ''}>${w.mailing ? '⏳ 存草稿中…' : '✉ 存邮件草稿'}</button></div>
      </div>
      ${plainBits.length ? card('💡 一页话结论', plainBits.map(([t, x]) => `<div style="margin:4px 0;"><b>${t}</b>:${esc(x)}</div>`).join('')) : ''}
      ${card(w.gran === 'month' ? '📅 月内各周趋势' : '📅 每日趋势', trendRows.length ? tbl(['时段', '总步数', '对话步数', '对话均响 ms', '后台', 'RFC', '更新'], trendRows) : '<span class="sapc-hint">无趋势数据</span>')}
      ${card('🧮 任务类型汇总', ttRows.length ? tbl(['任务类型', '步数', '平均响应 ms', 'CPU 合计 s'], ttRows) : '<span class="sapc-hint">无数据</span>')}
      ${card('🏆 TOP 事务码 / 报表(按步数,含批量/接口类)', entryRows.length ? tbl(['名称', '说明', '类别', '步数', '平均响应 ms', '用户数'], entryRows) : '<span class="sapc-hint">无数据</span>')}
      ${card('👤 TOP 用户(按步数)', userRows.length ? tbl(['用户', '姓名', '步数', '平均响应 ms', 'CPU s'], userRows) + ((cdData.topUser || []).some((t) => !t.fullName) ? '<div class="sapc-hint" style="margin:4px 2px;">部分账号无中文名;若账号列显示乱码样串,为 PRD 系统侧「统计用户假名化」配置所致(SAP 隐私特性,聚合里存的就是假名,ST03N 画面同样如此)——需 BASIS 关闭假名化后新数据才显示真实账号。</div>' : '') : '<span class="sapc-hint">无数据</span>')}
      ${cmpRows.length ? card(`🔄 环比对比(本期 ${esc(cd.label || '')} vs ${esc(bd.label || '对比期')})`, tbl(['指标', '本期', '对比期', '变化', '判定'], cmpRows) + (((r.compare && r.compare.notes) || []).length ? `<div class="sapc-hint" style="margin:6px 2px;">${esc((r.compare.notes || []).join(';'))}</div>` : '')) : ''}
      ${dgBits.length ? card('🩺 体检摘要(与 🩺体检页签同口径)', `<div style="margin:4px 0;">${esc(dgBits.join(';'))}。</div>`) : ''}
      ${w.commentErr ? `<div class="pb-err"><span>✗</span><span>${esc(w.commentErr)}</span></div>` : ''}
      ${w.comment || w.commenting ? `<div class="pb-card"><div class="pb-title">✨ AI 解读(面向顾问的大白话版) <span class="sub"> · ${esc((w.commentMeta && w.commentMeta.model) || '')}</span>
          <span style="flex:1"></span><button data-act="wk-ai" style="font-size:11.5px;padding:2px 10px;" ${w.commenting ? 'disabled' : ''}>${w.commenting ? '⏳ 解读生成中…' : '↻ 重新解读'}</button></div>
          ${w.commenting ? '<div class="sapc-hint">生成中…</div>' : `<div class="md">${renderMarkdown(String(w.comment || ''))}</div>`}</div>`
        : `<div style="margin:8px 2px;"><button data-act="wk-ai" style="font-size:12px;padding:4px 14px;" ${w.commenting ? 'disabled' : ''}>${w.commenting ? '⏳ 解读生成中…' : '✨ AI 解读'}</button><span class="sapc-hint" style="margin-left:8px;">基于负载+环比+体检生成大白话分析与建议</span></div>`}
      ${noteBits.length ? `<div class="sapc-hint" style="margin:6px 2px;">${esc(noteBits.join(';'))}</div>` : ''}`;
    }
    if (w.err) bodyHtml += `<div class="pb-err"><span>✗</span><span>${esc(w.err)}</span></div>`;
    return `<div class="sapc-probe">
      <div class="pb-bar">
        <select data-wk-f="sys">${sysOpts}</select>
        <select data-wk-f="gran">${granOpts}</select>
        <select data-wk-f="mode">${modeOpts}</select>
        <select data-wk-f="base">${baseOpts.join('')}</select>
        <button data-act="wk-run" class="primary" style="padding:6px 18px;font-weight:600;" ${w.running ? 'disabled' : ''}>${w.running ? '⏳ 生成中…' : '📈 生成报告'}</button>
        <input data-wk-f="to" placeholder="邮件收件人(✉ 用,可空)" style="width:200px;">
        <span class="sapc-hint">忙不忙/快不快/大头在哪/和上期比 · AI 大白话解读 · 🩺体检摘要 · ✉ 存 Outlook 草稿(不自动发送);历史周期缓存,首次跑某周期 1~3 分钟,之后秒级。</span>
      </div>
      ${bodyHtml}
    </div>`;
  }

  async runWk() {
    const w = this.wk;
    const q = (f) => this.root.querySelector(`[data-wk-f="${f}"]`);
    const sel = q('sys'); if (sel) w.sys = sel.value;
    const selG = q('gran'); if (selG) w.gran = selG.value;
    const selM = q('mode'); if (selM) w.mode = selM.value;
    const selB = q('base'); if (selB) w.baseSel = selB.value;
    w.running = true; w.res = null; w.err = null; w.comment = null; w.commentErr = null;
    this.render();
    try {
      const args = { system: w.sys, granularity: w.gran, mode: w.mode };
      if (w.baseSel && w.baseSel !== 'auto') args.baselineStart = w.baseSel;
      const res = await bridge.run('sap-workload', args, { timeoutMs: 300000 });   // 冷首跑双周期 SWNC+逐日真查可到 ~2-3 分钟(bridge 护栏 600s 内;数据落缓存后秒级)
      if (res.ok === false) throw new Error(emOf(res));
      // ★bridge(PS 5.1)序列化下,缓存读回的空数组跨 runspace 会漂移成 {}——非空数组不受影响,
      //   统一归一化置 [](空态),防 render 侧 .map 炸;后端 route 出口已重建实例,这是第二道闸。
      const fixArrs = (d, keys) => { if (d && typeof d === 'object') for (const k of keys) if (d[k] != null && !Array.isArray(d[k])) d[k] = []; };
      fixArrs(res.curData, ['tasktypes', 'topEntry', 'topUser', 'trend', 'trendMissing']);
      fixArrs(res.baseData, ['tasktypes', 'topEntry', 'topUser', 'trend', 'trendMissing']);
      fixArrs(res.compare, ['rows', 'notes']);
      fixArrs(res.digest, ['sm13TopFuncs', 'st22TopUsers', 'jobsTopNames']);
      // ENTRY_ID/名称类字段是 SAP 定长字符,历史缓存里 padding 已入库——显示层统一压缩空白
      const squeeze = (s) => String(s == null ? '' : s).replace(/\s+/g, ' ').trim();
      for (const d of [res.curData, res.baseData]) {
        if (!d) continue;
        for (const t of d.topEntry || []) t.entry = squeeze(t.entry);
        for (const t of d.topUser || []) t.user = squeeze(t.user);
      }
      if (res.compare) for (let i = 0; i < (res.compare.notes || []).length; i++) res.compare.notes[i] = squeeze(res.compare.notes[i]);
      w.res = res;
      _toast(`报告完成:${(res.health && res.health.text) || ''}(对话均响 ${res.health && res.health.dialogAvgMs}ms)`, res.health && res.health.status === 'OK' ? 'ok' : 'warn');
    } catch (err) {
      const msg = this._probeErr('报告生成失败', err);   // 2026-09-21 审查:凭证分流收拢单点
      w.err = msg;
    }
    w.running = false;
    this.render();
    if (w.res) this.runWkComment();   // AI 解读默认自动生成(失败不阻塞,可手动重跑)
  }

  async runWkComment() {
    const w = this.wk;
    if (!w.res) { _toast('先生成报告', 'err'); return; }
    w.commenting = true; w.commentErr = null;
    this.render();
    try {
      const res = await bridge.run('sap-workload', { action: 'comment', system: w.sys, res: w.res }, { timeoutMs: 140000 });
      if (res.ok === false) throw new Error(emOf(res));
      w.comment = res.comment;
      w.commentMeta = { model: res.model };
    } catch (err) {
      const msg = String((err && err.message) || err);
      _toast(`AI 解读失败:${msg}`, 'err');
      w.commentErr = msg;
    }
    w.commenting = false;
    this.render();
  }

  async wkMail() {
    const w = this.wk;
    if (!w.res) { _toast('先生成报告', 'err'); return; }
    const toEl = this.root.querySelector('[data-wk-f="to"]');
    const to = (toEl && toEl.value || '').trim();
    w.mailing = true;
    this.render();
    try {
      // 正文=分析(四问+体检摘要+AI 解读);附件=完整明细报告 HTML(用户定案:附件放 HTML 不要 Excel)
      const md = this._wkReportMd(false);
      const html = markdownToDocumentHtml(md, { title: `SAP 负载${w.gran === 'month' ? '月' : '周'}报:${w.res.system}`, subtitle: _nowStamp() });
      const label = `负载${w.gran === 'month' ? '月报' : '周报'}-${w.res.system}-${(w.res.cur && w.res.cur.start) || ''}`;
      const subject = `SAP 负载${w.gran === 'month' ? '月' : '周'}报 ${w.res.system} ${(w.res.cur && w.res.cur.label) || ''}`;
      let attachB64 = '';
      try {
        const mdFull = this._wkReportMd(true);
        const htmlFull = markdownToDocumentHtml(mdFull, { title: `SAP 负载${w.gran === 'month' ? '月' : '周'}报明细:${w.res.system}`, subtitle: _nowStamp() });
        const bytes = new TextEncoder().encode(htmlFull);
        let s = ''; const CH = 0x8000;
        for (let i = 0; i < bytes.length; i += CH) s += String.fromCharCode.apply(null, bytes.subarray(i, i + CH));
        attachB64 = btoa(s);
      } catch (e) { /* 附件生成失败不阻塞正文草稿 */ }
      const res = await bridge.run('sap-workload', { action: 'mail', to, subject, html, attachBase64: attachB64, attachName: `${label}.html` }, { timeoutMs: 90000 });
      if (res.ok === false) throw new Error(emOf(res));
      _toast(`✓ 已存 Outlook 草稿(未发送)${attachB64 ? '+明细附件' : ''}:${res.result && res.result.to || to || '收件人待填'}`, 'ok');
    } catch (err) {
      _toast(`存草稿失败:${String((err && err.message) || err)}`, 'err');
    }
    w.mailing = false;
    this.render();
  }

  _wkReportMd(full = true) {
    const r = this.wk.res; if (!r) return '';
    const n = (x) => (x == null ? '-' : Number(x).toLocaleString('en-US'));
    const cd = r.cur || {}; const cdData = r.curData || {}; const bd = r.base || {};
    const granZh = r.granularity === 'month' ? '月' : '周';
    const L = [`# SAP 负载${granZh}报:${r.system}`, '',
      `**周期:${cd.label || ''}${cd.isPartial ? '(未完)' : ''}** · 对话均响 ${n(r.health && r.health.dialogAvgMs)}ms · ${r.health && r.health.text} · ${r.generatedAt || ''}`, ''];
    const p = r.plain || {};
    if (p.busy || p.fast || p.where || p.changes) {
      L.push('## 一页话结论', '');
      if (p.busy) L.push(`- **系统忙不忙**:${p.busy}`);
      if (p.fast) L.push(`- **反应快不快**:${p.fast}`);
      if (p.where) L.push(`- **资源大头在哪**:${p.where}`);
      if (p.changes) L.push(`- **和上期比**:${p.changes}`);
      L.push('');
    }
    if (!full) {
      // 邮件正文精简版:头+四问+体检摘要+AI 解读(明细在 Excel 附件)
      const dg0 = r.digest;
      if (dg0) {
        const bits = [];
        if (dg0.st22Dumps != null) bits.push(`近 7 天程序崩溃 ${dg0.st22Dumps} 次`);
        if (dg0.sm13Failed != null) bits.push(`更新失败积压 ${dg0.sm13Failed} 项${dg0.sm13Truncated ? '(100+ 截断)' : ''}`);
        if (dg0.jobsCanceled != null) bits.push(`近 7 天取消作业 ${dg0.jobsCanceled} 个`);
        if (bits.length) L.push('## 体检摘要', '', bits.join(';') + '。');
      }
      if (this.wk.comment) L.push('', '## AI 解读', '', this.wk.comment);
      L.push('', `> 详细数据(趋势/任务类型/TOP 榜/环比对比)见附件 Excel;由个人工作台 SAP Driver 生成。`);
      return L.join('\n');
    }
    L.push(`## ${r.granularity === 'month' ? '月内各周趋势' : '每日趋势'}`, '', '| 时段 | 总步数 | 对话步数 | 对话均响 ms | 后台 | RFC | 更新 |', '|---|---|---|---|---|---|---|');
    (cdData.trend || []).forEach((d) => L.push(`| ${(d.label || d.date) + (d.crossMonth ? '(含邻月)' : '')} | ${n(d.totalSteps)} | ${n(d.dialogSteps)} | ${n(d.dialogAvgMs)} | ${n(d.batchSteps)} | ${n(d.rfcSteps)} | ${n(d.updateSteps)} |`));
    L.push('', '## 任务类型', '', '| 类型 | 步数 | 平均响应 ms | CPU 合计 s |', '|---|---|---|---|');
    (cdData.tasktypes || []).forEach((t) => L.push(`| ${t.name || t.type} | ${n(t.steps)} | ${n(t.avgMs)} | ${t.cpuTotalMs == null ? '-' : Math.round(t.cpuTotalMs / 1000)} |`));
    L.push('## TOP 事务码 / 报表', '', '| 名称 | 说明 | 类别 | 步数 | 平均响应 ms | 用户数 |', '|---|---|---|---|---|---|');
    const etypeZh = { tcode: '事务码', report: '标准报表', zprog: '自定义报表', rfc: 'RFC 调用', sys: '系统活动', other: '' };
    (cdData.topEntry || []).forEach((t) => L.push(`| ${t.entry} | ${t.desc || ''} | ${etypeZh[t.etype] || ''} | ${n(t.steps)} | ${n(t.avgMs)} | ${t.users} |`));
    L.push('', '## TOP 用户', '', '| 用户 | 姓名 | 步数 | 平均响应 ms | CPU s |', '|---|---|---|---|---|');
    (cdData.topUser || []).forEach((t) => L.push(`| ${t.user} | ${t.fullName || ''} | ${n(t.steps)} | ${n(t.avgMs)} | ${t.cpuS} |`));
    if (r.compare && (r.compare.rows || []).length) {
      L.push('', `## 环比对比(本期 vs ${bd.label || '对比期'})`, '', '| 指标 | 本期 | 对比期 | 变化 | 判定 |', '|---|---|---|---|---|');
      (r.compare.rows || []).forEach((c) => L.push(`| ${c.metric} | ${n(c.a)} | ${c.b == null ? '-' : n(c.b)} | ${c.deltaPct == null ? '—' : (c.deltaPct > 0 ? '+' : '') + c.deltaPct + '%'} | ${c.verdict || '—'} |`));
      if ((r.compare.notes || []).length) L.push('', (r.compare.notes || []).map((x) => `> ${x}`).join('\n'));
    }
    const dg = r.digest;
    if (dg) {
      const bits = [];
      if (dg.st22Dumps != null) bits.push(`近 7 天程序崩溃 ${dg.st22Dumps} 次${(dg.st22TopUsers || []).length ? '(集中:' + dg.st22TopUsers.join('、') + ')' : ''}`);
      if (dg.sm13Failed != null) bits.push(`更新失败积压 ${dg.sm13Failed} 项${(dg.sm13TopFuncs || []).length ? '(模块:' + dg.sm13TopFuncs.join('、') + ')' : ''}`);
      if (dg.jobsCanceled != null) bits.push(`近 7 天取消作业 ${dg.jobsCanceled} 个${(dg.jobsTopNames || []).length ? '(' + dg.jobsTopNames.join('、') + ')' : ''}`);
      if (bits.length) L.push('', '## 体检摘要', '', bits.join(';') + '。');
    }
    if (cdData.periodMissing) L.push('', `> 该系统无本期聚合记录${cdData.dirLatest ? `,统计目录最新记录 ${cdData.dirLatest}(近期聚合采集未运行)` : ''}`);
    if ((cdData.trendMissing || []).length) L.push('', `> 缺数据日期:${cdData.trendMissing.join(', ')}(当日无聚合记录/停机)`);
    if (this.wk.comment) L.push('', '## AI 解读', '', this.wk.comment);
    return L.join('\n');
  }

  _wkXlsxSheets() {
    const r = this.wk.res; if (!r) return [];
    const n = (x) => (x == null ? null : Number(x));
    const cd = r.cur || {}; const cdData = r.curData || {}; const bd = r.base || {};
    const granZh = r.granularity === 'month' ? '月' : '周';
    const ov = [
      { 项目: '系统 / 周期', 内容: `${r.system} · ${cd.label || ''}${cd.isPartial ? '(未完)' : ''}` },
      { 项目: '对话均响', 内容: `${n(r.health && r.health.dialogAvgMs)}ms(${r.health && r.health.text})` },
    ];
    const p = r.plain || {};
    if (p.busy) ov.push({ 项目: '忙不忙', 内容: p.busy });
    if (p.fast) ov.push({ 项目: '快不快', 内容: p.fast });
    if (p.where) ov.push({ 项目: '大头在哪', 内容: p.where });
    if (p.changes) ov.push({ 项目: '和上期比', 内容: p.changes });
    const dg = r.digest;
    if (dg) {
      if (dg.st22Dumps != null) ov.push({ 项目: '近7天程序崩溃', 内容: dg.st22Dumps });
      if (dg.sm13Failed != null) ov.push({ 项目: '更新失败积压', 内容: dg.sm13Failed });
      if (dg.jobsCanceled != null) ov.push({ 项目: '近7天取消作业', 内容: dg.jobsCanceled });
    }
    ov.push({ 项目: '生成时间', 内容: r.generatedAt || '' });
    if (this.wk.comment) ov.push({ 项目: 'AI 解读', 内容: this.wk.comment });
    const sheet = (name, rows) => ({ name, rows });
    const sheets = [{ name: '概览', rows: ov },
      sheet('趋势', (cdData.trend || []).map((d) => ({ '时段': (d.label || d.date) + (d.crossMonth ? '(含邻月)' : ''), '总步数': n(d.totalSteps), '对话步数': n(d.dialogSteps), '对话均响ms': n(d.dialogAvgMs), '后台': n(d.batchSteps), 'RFC': n(d.rfcSteps), '更新': n(d.updateSteps) }))),
      sheet('任务类型', (cdData.tasktypes || []).map((t) => ({ '类型': t.name || t.type, '步数': n(t.steps), '平均响应ms': n(t.avgMs), 'CPU合计s': t.cpuTotalMs == null ? null : Math.round(t.cpuTotalMs / 1000) }))),
      sheet('TOP事务码报表', (cdData.topEntry || []).map((t) => ({ '名称': t.entry, '说明': t.desc || '', '类别': t.etype || '', '步数': n(t.steps), '平均响应ms': n(t.avgMs), '用户数': t.users }))),
      sheet('TOP用户', (cdData.topUser || []).map((t) => ({ '用户': t.user, '姓名': t.fullName || '', '步数': n(t.steps), '平均响应ms': n(t.avgMs), 'CPU s': t.cpuS })))];
    if (r.compare && (r.compare.rows || []).length) {
      sheets.push(sheet('环比对比', (r.compare.rows || []).map((c) => ({ '指标': c.metric, '本期': n(c.a), '对比期': c.b == null ? null : n(c.b), '变化%': c.deltaPct, '判定': c.verdict || '—', '对比期区间': bd.label || '' }))));
    }
    return sheets;
  }

  async _wkExport(kind) {
    const r = this.wk.res;
    if (!r) { _toast('还没有报告结果', 'err'); return; }
    const granZh = r.granularity === 'month' ? '月报' : '周报';
    const label = `负载${granZh}-${r.system}-${(r.cur && r.cur.start) || _nowStamp()}`;
    if (kind === 'xlsx') {
      try { downloadXlsx(`${safeFilename(label)}.xlsx`, this._wkXlsxSheets()); _toast(`✓ 已导出 Excel(${this._wkXlsxSheets().length} 个 SHEET)`, 'ok'); }
      catch (err) { _toast(`导出 Excel 失败:${err.message || err}`, 'err'); }
      return;
    }
    await this._mdExport(kind, this._wkReportMd(), {
      title: `SAP Driver 负载${granZh}`,
      subtitle: `${r.system} · ${(r.cur && r.cur.label) || ''} · ${_nowStamp()}`,
      filename: label,
    });
  }

}
