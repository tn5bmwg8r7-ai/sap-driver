// sap-copilot-art.js — SAP Driver 「📦 产物」+「⏱ Trace调用链」页签(v5 产物中心/v3 时间线)——
// 产物扫描/打开定位/清单 Excel + 统一总账表格/复制/Excel(2026-11-03 拆分批二,class mixin)。
// 拆分=原地移动零改动:方法体逐字搬运,this 语义不变,e2e 选择器/data-act 零变化。
// 装配:主文件 descriptor 级 defineProperty 挂 prototype;共享符号经 bindSapShared() 注入。

let _toast, esc, escAttr, bridge;

// 主文件装配时调一次,把共享符号绑进本模块闭包(app 启动一次;类方法体沿模块作用域取值)。
export function bindSapShared(deps) {
  _toast = deps._toast;
  esc = deps.esc;
  escAttr = deps.escAttr;
  bridge = deps.bridge;
}

export class SapArtMethods {
  renderTimeline() {
    if (!this.timeline) {
      return `<div style="padding:16px 2px;">
        <button id="sapc-tl-load" class="primary" ${this.timelineLoading ? 'disabled' : ''}>${this.timelineLoading ? '⏳ 加载中…' : '加载今日总账(最近 50 条)'}</button>
        <div class="sapc-hint" style="margin-top:9px;">统一总账 = Claude Code(MCP)与 SAP Driver(facade)两条通道的全部 SAP 操作,参数已脱敏。</div>
      </div>`;
    }
    const rows = (this.timeline.entries || []).map((e) => {
      const t = new Date(Number(e.ts));
      const hh = `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}:${String(t.getSeconds()).padStart(2, '0')}`;
      const rcls = e.result === 'ok' ? 'res-ok' : (e.result === 'error' ? 'res-error' : 'res-denied');
      const rtxt = e.result === 'ok' ? '✓ ok' : (e.result === 'error' ? `✗ ${esc(e.code || 'error')}` : `⛔ ${esc(e.code || 'denied')}`);
      return `<tr>
        <td>${hh}</td>
        <td><span class="${e.channel === 'pw' ? 'ch-pw' : 'ch-mcp'}">${e.channel === 'pw' ? 'Driver' : 'CC'}</span></td>
        <td>${esc(e.tool)}</td>
        <td>${esc(e.system)}</td>
        <td class="${rcls}">${rtxt}</td>
        <td class="num">${e.durationMs != null ? `${e.durationMs}ms` : ''}</td>
        <td class="num">${e.rows != null ? e.rows : ''}</td>
        <td style="max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="${escAttr(e.error || '')}">${esc(e.error || '')}</td>
      </tr>`;
    }).join('');
    return `<div class="sapc-tl" style="padding:4px 2px;">
      <div style="display:flex;gap:9px;margin-bottom:9px;align-items:center;">
        <button id="sapc-tl-load" ${this.timelineLoading ? 'disabled' : ''}>${this.timelineLoading ? '⏳ …' : '↻ 刷新'}</button>
        <button data-act="tl-copy" ${this.timeline.entries.length ? '' : 'disabled'}>📋 复制</button>
        <button data-act="tl-xlsx" ${this.timeline.entries.length ? '' : 'disabled'}>📊 导出 Excel</button>
        <span class="sapc-hint">${this.timeline.date} · ${this.timeline.entries.length} 条${this.timeline.moreOlder ? '(更早的未显示)' : ''}</span>
      </div>
      <table><thead><tr><th>时间</th><th>通道</th><th>工具</th><th>系统</th><th>结果</th>
        <th class="num">耗时</th><th class="num">行数</th><th>错误摘要</th></tr></thead>
      <tbody>${rows || '<tr><td colspan="8" class="sapc-empty">今日暂无调用</td></tr>'}</tbody></table>
    </div>`;
  }

// ---- 📦 产物区(v5,2026-09-14)----
// 列表 = sap-artifacts 路由(顶层非递归扫两个落点);打开/定位复用 file-open 路由
// (两个落点都在其白名单根 产物目录(桥路由 sap-artifacts 配置的落点) 之下)。kind 筛选与文件名搜索全在前端过滤(≤500
// 条内存过滤零成本),不二次打桥;搜索框输入走就地刷新 tbody,不全量 render(保焦点)。
  // ---- 📦 产物区(v5,2026-09-14)----
  // 列表 = sap-artifacts 路由(顶层非递归扫两个落点);打开/定位复用 file-open 路由
  // (两个落点都在其白名单根 产物目录(桥路由 sap-artifacts 配置的落点) 之下)。kind 筛选与文件名搜索全在前端过滤(≤500
  // 条内存过滤零成本),不二次打桥;搜索框输入走就地刷新 tbody,不全量 render(保焦点)。
  // ---- 📦 产物区(v5,2026-09-14)----
  // 列表 = sap-artifacts 路由(顶层非递归扫两个落点);打开/定位复用 file-open 路由
  // (两个落点都在其白名单根 产物目录(桥路由 sap-artifacts 配置的落点) 之下)。kind 筛选与文件名搜索全在前端过滤(≤500
  // 条内存过滤零成本),不二次打桥;搜索框输入走就地刷新 tbody,不全量 render(保焦点)。
  renderArtifacts() {
    if (!this.artifacts) {
      return `<div class="sapc-art" style="padding:16px 2px;">
        <button id="sapc-art-load" class="primary" ${this.artifactsLoading ? 'disabled' : ''}>${this.artifactsLoading ? '⏳ 扫描中…' : '扫描本地产物'}</button>
        <div class="sapc-hint" style="margin-top:9px;">接口文档与测试报告生成后的落盘产物一览,一键打开 / 定位文件。</div>
      </div>`;
    }
    const d = this.artifacts;
    const chips = [{ k: 'all', t: `全部 ${d.total}` }, { k: 'interface-doc', t: '接口文档' }, { k: 'test-report', t: '测试报告' }, { k: 'req-digest', t: '需求解读' }, { k: 'delivery', t: '交付台账' }]
      .map((c) => `<button class="art-chip ${this.artifactsKind === c.k ? 'active' : ''}" data-artk="${c.k}">${c.t}</button>`).join('');
    const stats = (d.roots || []).map((r) => `${r.label} ${r.exists ? r.count : '目录不存在'}`).join(' · ');
    return `<div class="sapc-art">
      <div class="art-bar">
        ${chips}
        <input class="art-q" id="sapc-art-q" placeholder="搜文件名…" value="${escAttr(this.artifactsQ)}">
        <button id="sapc-art-refresh" ${this.artifactsLoading ? 'disabled' : ''}>${this.artifactsLoading ? '⏳ …' : '↻ 刷新'}</button>
        <button id="sapc-art-xlsx" title="按当前筛选导出清单(名称/类型/大小/时间/路径)">📊 清单 Excel</button>
        <span class="sapc-hint">${esc(stats)} · 扫描 ${d.elapsedMs}ms${d.truncated ? ` · 仅显示最新 ${d.items.length} 条` : ''}</span>
      </div>
      <div class="sapc-tl"><table><thead><tr><th>文件名</th><th>类型</th><th class="num">大小</th><th>修改时间</th><th>操作</th></tr></thead>
      <tbody id="sapc-art-rows">${this._artRowsHtml()}</tbody></table></div>
    </div>`;
  }

  // 产物过滤(kind chips + 文件名搜索)——表格渲染与 Excel 导出共用同一份结果
  _artFiltered() {
    const q = this.artifactsQ.trim().toLowerCase();
    let items = (this.artifacts && this.artifacts.items) || [];
    if (this.artifactsKind !== 'all') items = items.filter((x) => x.kind === this.artifactsKind);
    if (q) items = items.filter((x) => String(x.name || '').toLowerCase().includes(q));
    return items;
  }

  _artRowsHtml() {
    const items = this._artFiltered();
    if (!items.length) return '<tr><td colspan="5" class="sapc-empty">没有匹配的产物</td></tr>';
    return items.map((f) => `<tr>
      <td class="art-name" title="${escAttr(f.path)}">${esc(f.name)}</td>
      <td><span class="sapc-tag ${f.kind === 'interface-doc' ? 'acc' : ''}">${esc(f.label)}</span></td>
      <td class="num">${f.sizeKB} KB</td>
      <td>${esc(f.mtime)}</td>
      <td class="op">
        <button data-act="art-open" data-path="${escAttr(f.path)}">打开</button>
        <button data-act="art-reveal" data-path="${escAttr(f.path)}">定位</button>
      </td>
    </tr>`).join('');
  }

  async loadArtifacts(manual = false) {
    this.artifactsLoading = true;
    if (this.artifacts || manual) this.render();
    try {
      this.artifacts = await bridge.run('sap-artifacts', { kind: 'all', limit: 500 }, { timeoutMs: 20000 });
    } catch (err) { _toast(`产物扫描失败:${err.message || err}`, 'err'); }
    this.artifactsLoading = false;
    this.render();
  }

  async artOpen(path, action) {
    try {
      await bridge.run('file-open', { path, action }, { timeoutMs: 15000 });
      _toast(action === 'reveal' ? '✓ 已在资源管理器定位' : '✓ 已打开', 'ok');
    } catch (err) { _toast(`打开失败:${err.message || err}`, 'err'); }
  }


  // bind() 内「📦 产物区事件」段(2026-11-03 原地抽成 bindArt,bind() 改为转发——
  // 原位置逐字未动,只换宿主;主文件 bind() 无条件调 this.bindArt(),元素缺席即 no-op)。
  bindArt() {
      // ---- 📦 产物区事件(kind chips / 搜索框 = 就地刷新 tbody,不全量 render 保焦点)----
      this.root.querySelectorAll('[data-artk]').forEach((b) => {
        b.addEventListener('click', () => {
          this.artifactsKind = b.dataset.artk;
          this.root.querySelectorAll('[data-artk]').forEach((x) => x.classList.toggle('active', x === b));
          const rows = this.root.querySelector('#sapc-art-rows');
          if (rows) { rows.innerHTML = this._artRowsHtml(); this._bindArtRows(); }   // 重刷后必须重绑,否则按钮是死的(09-15 实爆)
        });
      });
      const artQ = this.root.querySelector('#sapc-art-q');
      if (artQ) {
        artQ.addEventListener('input', () => {
          this.artifactsQ = artQ.value;
          const rows = this.root.querySelector('#sapc-art-rows');
          if (rows) { rows.innerHTML = this._artRowsHtml(); this._bindArtRows(); }
        });
      }
      this.root.querySelector('#sapc-art-load')?.addEventListener('click', () => this.loadArtifacts());
      this.root.querySelector('#sapc-art-refresh')?.addEventListener('click', () => this.loadArtifacts(true));
      this._bindArtRows();
      this.root.querySelectorAll('#sapc-tl-load').forEach((b) => {
        b.addEventListener('click', () => this.loadTimeline());
      });
      // 今日动态 → 全部时间线
      this.root.querySelectorAll('[data-act="open-timeline"]').forEach((b) => {
        b.addEventListener('click', () => {
          this.tab = 'timeline';
          if (!this.timeline) this.loadTimeline(); else this.render();
        });
      });
  }

  // 产物行按钮绑定(打开/定位):bind() 与每次 tbody 就地重刷后都要跑——
  // 2026-09-15 用户实爆「打开/定位不灵敏或用不了」:搜索框/切类目重刷 tbody 后
  // 新按钮无 listener,点击零反应(连报错 toast 都没有)。
  _bindArtRows() {
    this.root.querySelectorAll('[data-act="art-open"]').forEach((b) => {
      b.addEventListener('click', () => this.artOpen(b.dataset.path, 'open'));
    });
    this.root.querySelectorAll('[data-act="art-reveal"]').forEach((b) => {
      b.addEventListener('click', () => this.artOpen(b.dataset.path, 'reveal'));
    });
  }

  async loadTimeline() {
    this.timelineLoading = true;
    if (this.timeline) this.render();
    try {
      this.timeline = await bridge.run('sap-audit', { lines: 50 }, { timeoutMs: 20000 });
      this.recent = this.timeline;   // 主页动态条与时间线共用数据
    } catch (err) { _toast(`总账加载失败:${err.message || err}`, 'err'); }
    this.timelineLoading = false;
    this.render();
  }

  async loadRecent() {
    if (this.timeline) { this.recent = this.timeline; return; }
    try {
      this.recent = await bridge.run('sap-audit', { lines: 8 }, { timeoutMs: 20000 });
      if (this.tab === 'ask' && !this.asking) this.render();
    } catch { /* 静默:动态条加载失败不打扰 */ }
  }
}
