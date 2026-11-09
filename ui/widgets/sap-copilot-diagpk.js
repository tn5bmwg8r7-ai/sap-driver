// sap-copilot-diagpk.js — SAP Driver 「体检」页签(v14/v15)——一键只读巡检/报告/Excel(_diagpkXlsxSheets 自 probe 区随属迁入)(2026-10-30 拆分批一,class mixin)。
// 拆分=原地移动零改动:方法体逐字搬运,this 语义不变(SAPC_STORE 经主文件 getter 代理),
// e2e 选择器/data-act 零变化。装配:主文件 import 后把 mixin 方法挂上 SapCopilotWidget.prototype;
// 共享符号经 bindSapShared() 注入(见下方 let 声明)——不 import 主文件防环。

let _toast, _nowStamp, emOf, esc, safeFilename, downloadXlsx, bridge;

// 主文件装配时调一次,把共享符号绑进本模块闭包(app 启动一次;类方法体沿模块作用域取值)。
export function bindSapShared(deps) {
  _toast = deps._toast;
  _nowStamp = deps._nowStamp;
  emOf = deps.emOf;
  esc = deps.esc;
  safeFilename = deps.safeFilename;
  downloadXlsx = deps.downloadXlsx;
  bridge = deps.bridge;
}

export class SapDiagpkMethods {
  // v15 体检 Excel:每节一 SHEET(cols/rows 路由已给好,原样落)
  _diagpkXlsxSheets() {
    const r = this.diagpk.res; if (!r) return [];
    const sheets = [{ name: '概览', rows: [
      { 项目: '系统', 内容: r.system || '' },
      { 项目: '结论 / 时间 / 耗时', 内容: `${r.overallText || r.overall || ''} · ${r.generatedAt || ''} · ${r.durMs}ms` },
      { 项目: '导出时间', 内容: _nowStamp() },
    ] }];
    (r.checks || []).forEach((c, i) => {
      const rows = (c.rows || []).length ? c.rows : [{ 结果: '无异常记录' }];
      sheets.push({ name: c.title || `检查${i + 1}`, rows });
    });
    return sheets;
  }

  // v14 系统体检页签:一键只读巡检(ST22 dump 计数 / SM13 更新失败 / SM12 当前锁 / TBTCO 取消与卡死)
  renderDiagpk() {
    const dp = this.diagpk;
    const sysOpts = ['DVP', 'QAS', 'PRD'].map((s) => `<option value="${s}" ${dp.sys === s ? 'selected' : ''}>${s}${s === 'PRD' ? ' · 只读' : ''}</option>`).join('');
    const badge = { OK: ['✓ 健康', 'var(--sd-success-text)'], WARN: ['⚠ 需关注', 'var(--sd-warning-text)'], CRIT: ['✗ 有问题', 'var(--sd-danger-text)'], NA: ['· 未判定', 'var(--sd-text-faint)'] };
    let bodyHtml = '';
    if (dp.running) bodyHtml = '<div class="sapc-loading"><span class="spin"></span>体检中(ST22/SM13/SM12 锁/TBTCO 只读巡检)…</div>';
    if (dp.res) {
      const r = dp.res;
      const [olb, ocol] = badge[r.overall] || [r.overall, 'inherit'];
      const secs = (r.checks || []).map((c) => {
        const [lb, col] = badge[c.status] || [c.status, 'inherit'];
        const rowsHtml = (c.rows || []).length ? this._dpTable(c.cols, c.rows) : (c.status === 'NA' ? '' : '<span class="sapc-hint">无异常记录 🎉</span>');
        return `<div class="pb-card">
          <div class="pb-title">${esc(c.title)} <span style="color:${col};font-weight:700;">${lb}</span><span class="sub"> · ${esc(c.summary || '')} · ${c.ms}ms</span></div>
          ${rowsHtml}
          ${c.truncated ? '<div class="sapc-hint">…已达查询上限,数据可能不全</div>' : ''}
          ${c.note ? `<div class="sapc-hint" style="margin-top:4px;">${esc(c.note)}</div>` : ''}
        </div>`;
      }).join('');
      bodyHtml = `<div class="pb-card">
        <div class="pb-title">🩺 ${esc(r.system)} 系统体检 <span style="color:${ocol};font-weight:700;">${olb}</span><span class="sub"> · ${esc(r.generatedAt || '')} · ${r.durMs}ms</span>
          <span style="flex:1"></span><button data-act="diagpk-copy" style="font-size:11.5px;padding:2px 10px;">📋 复制报告</button>
          <button data-act="diagpk-html" style="font-size:11.5px;padding:2px 10px;">📄 导出 HTML</button>
          <button data-act="diagpk-xlsx" style="font-size:11.5px;padding:2px 10px;">📊 导出 Excel</button></div>
      </div>${secs}`;
    }
    if (dp.err) bodyHtml += `<div class="pb-err"><span>✗</span><span>${esc(dp.err)}</span></div>`;
    return `<div class="sapc-probe">
      <div class="pb-bar">
        <select data-diagpk-f="sys">${sysOpts}</select>
        <button data-act="diagpk-run" class="primary" style="padding:6px 18px;font-weight:600;" ${dp.running ? 'disabled' : ''}>${dp.running ? '⏳ 体检中…' : '🩺 开始体检'}</button>
        <button data-act="diagpk-refresh" style="padding:6px 12px;" ${dp.running ? 'disabled' : ''} title="跳过 10 分钟缓存,全量实时体检">↻ 强刷</button>
        <span class="sapc-hint">一键只读巡检:ST22 dump 计数 / SM13 更新失败 / SM12 当前锁 / TBTCO 取消与卡死作业;单节读不到只标「未判定」,不炸整份报告。</span>
      </div>
      ${bodyHtml}
    </div>`;
  }

  _dpTable(cols, rows) {
    const th = (cols || []).map((c) => `<th>${esc(c)}</th>`).join('');
    const tr = (rows || []).slice(0, 30).map((r) => `<tr>${cols.map((c) => `<td style="white-space:normal;">${esc(String(r[c] ?? ''))}</td>`).join('')}</tr>`).join('');
    return `<table class="res-tbl"><thead><tr>${th}</tr></thead><tbody>${tr}</tbody></table>${(rows || []).length > 30 ? `<span class="sapc-hint">…共 ${rows.length} 行,仅显示前 30</span>` : ''}`;
  }

  async runDiagpk(force = false) {
    const dp = this.diagpk;
    const sel = this.root.querySelector('[data-diagpk-f="sys"]');
    if (sel) dp.sys = sel.value;
    dp.running = true; dp.res = null; dp.err = null;
    this.render();
    try {
      // force=true 跳过路由侧 10 分钟短缓存(2026-09-21 用户定案:体检加 TTL 缓存+强刷兜底)
      const res = await bridge.run('sap-diagpack', { system: dp.sys, refresh: force === true }, { timeoutMs: 120000 });
      if (res.ok === false) throw new Error(emOf(res));
      dp.res = res;
      _toast(`体检完成:${res.overallText}${res.fromCache ? '(缓存,↻强刷取实时)' : ''}`, res.overall === 'OK' ? 'ok' : 'warn');
    } catch (err) {
      const msg = this._probeErr('体检失败', err);   // 2026-09-21 审查:凭证分流收拢单点(原手抄同款判断)
      dp.err = msg;
    }
    dp.running = false;
    this.render();
  }

  _diagpkReportMd() {
    const r = this.diagpk.res; if (!r) return '';
    const md = [`# 系统体检:${r.system}`, '', `**结论:${r.overallText}** · ${r.generatedAt || ''} · ${r.durMs}ms`, ''];
    (r.checks || []).forEach((c) => {
      md.push(`## ${c.title} — ${c.status}`, '', `${c.summary || ''}`, '');
      if ((c.rows || []).length) {
        md.push(`| ${c.cols.join(' | ')} |`, `|${c.cols.map(() => '---').join('|')}|`);
        c.rows.forEach((row) => md.push(`| ${c.cols.map((k) => String(row[k] ?? '')).join(' | ')} |`));
        md.push('');
      }
      if (c.note) md.push(`> ${c.note}`, '');
    });
    return md.join('\n');
  }

  async _diagpkExport(kind) {
    const r = this.diagpk.res;
    if (!r) { _toast('还没有体检结果', 'err'); return; }
    const label = `系统体检-${r.system}`;
    if (kind === 'xlsx') {
      try { downloadXlsx(`${safeFilename(label)}.xlsx`, this._diagpkXlsxSheets()); _toast(`✓ 已导出 Excel(${1 + (r.checks || []).length} 个 SHEET)`, 'ok'); }
      catch (err) { _toast(`导出 Excel 失败:${err.message || err}`, 'err'); }
      return;
    }
    await this._mdExport(kind, this._diagpkReportMd(), {
      title: 'SAP Driver 系统体检报告',
      subtitle: `${r.system} · ${_nowStamp()}`,
      filename: label,
    });
  }

}
