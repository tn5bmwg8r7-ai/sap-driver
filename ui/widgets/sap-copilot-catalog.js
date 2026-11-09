// sap-copilot-catalog.js — SAP Driver 「🗺️ Skill地图」页签(v3 能力地图/v16.1 cc 卡)——
// renderCatalog 卡片渲染/_commandPalette 命令面板定位/_captureArgs 参数回存 + bindCatalog
// 卡片点击直达/⚙run-tool/▶run-cmd/📋copy-result(2026-11-03 拆分批三=收官,class mixin)。
// 拆分=原地移动零改动:方法体逐字搬运,this 语义不变,e2e 选择器/data-act 零变化。
// 装配:主文件 descriptor 级 defineProperty 挂 prototype;共享符号经 bindSapShared() 注入。

let _toast, emOf, esc, escAttr, copyText, bridge, runCommand, CommandRegistry, SAP_CATALOG, SAP_CATEGORIES, todos, FlowStore, loadTicketsFn;

// 主文件装配时调一次,把共享符号绑进本模块闭包(app 启动一次;类方法体沿模块作用域取值)。
export function bindSapShared(deps) {
  _toast = deps._toast;
  emOf = deps.emOf;
  esc = deps.esc;
  escAttr = deps.escAttr;
  copyText = deps.copyText;
  bridge = deps.bridge;
  runCommand = deps.runCommand;
  CommandRegistry = deps.CommandRegistry;
  SAP_CATALOG = deps.SAP_CATALOG;
  SAP_CATEGORIES = deps.SAP_CATEGORIES;
  todos = deps.todos;   // 一站式交付卡待办下拉(2026-11-04 P3):前端 IndexedDB 直读零网络
  FlowStore = deps.FlowStore;           // 2026-11-04 P1:flow 卡直达「🚰 交付」页签
  loadTicketsFn = deps.loadTicketsFn;   // 同上:widget 实例方法由主文件转发
}

export class SapCatalogMethods {
  renderCatalog() {
    const sections = SAP_CATEGORIES.map((cat) => {
      const cards = SAP_CATALOG.filter((c) => c.cat === cat.id);
      if (!cards.length) return '';
      const items = cards.map((c) => {
        const planned = c.type === 'planned';
        const tags = [];
        if (c.type === 'mcp') tags.push('<span class="sapc-tag acc">MCP</span>');
        if (c.type === 'command') tags.push('<span class="sapc-tag acc">快捷指令</span>');
        if (c.type === 'builtin') tags.push('<span class="sapc-tag acc">内置</span>');
        if (c.type === 'cc') tags.push('<span class="sapc-tag acc">Claude Code</span>');
        if (planned) tags.push('<span class="sapc-tag">规划中</span>');
        if (!planned && c.example && typeof c.example === 'object' && !Array.isArray(c.example)) {
          tags.push(`<span class="sapc-tag">${esc(Object.keys(c.example).join(' · '))}</span>`);
        }
        const expanded = this.expandedId === c.id;
        let detail = '';
        if (expanded && c.type === 'mcp') {
          const argsStr = this._argsTexts.get(c.id) || JSON.stringify(c.example || {}, null, 2);
          detail = `<div class="sapc-detail">
            <textarea id="sapc-args-${escAttr(c.id)}" spellcheck="false">${esc(argsStr)}</textarea>
            <div class="actions">
              <button data-act="run-tool" data-card="${escAttr(c.id)}" class="primary" ${this.toolRunning ? 'disabled' : ''}>${this.toolRunning === c.id ? '执行中…' : '▶ 执行'}</button>
              <button data-act="copy-result" data-card="${escAttr(c.id)}" ${this._results.get(c.id) ? '' : 'disabled'}>📋 复制</button>
              <button data-act="res-json" data-card="${escAttr(c.id)}" ${this._results.get(c.id) ? '' : 'disabled'} title="结果原文下载为 JSON 文件">💾 JSON</button>
              <button data-act="res-xlsx" data-card="${escAttr(c.id)}" ${this._results.get(c.id) ? '' : 'disabled'} title="结构化结果导出 Excel(数组一表/其余进概览)">📊 Excel</button>
              <span class="sapc-hint">${esc((this._results.get(c.id) || {}).meta || '')}</span>
            </div>
            ${this._results.get(c.id) ? `<pre>${esc(this._results.get(c.id).text)}</pre>` : ''}
          </div>`;
        } else if (expanded && c.type === 'command') {
          // 2026-09-16:必填参数型指令「运行」=空参必败假按钮,按钮与提示按是否要参数分流
          const rc = CommandRegistry.get(c.id);
          const needsInput = Array.isArray(rc?.paramSchema?.required) && rc.paramSchema.required.length > 0;
          const runLabel = needsInput ? '⚙ 填参数运行' : '▶ 运行';
          const hint = needsInput
            ? '该指令要填参数:点「填参数运行」直达参数表单(等同 Ctrl+K 搜出它);长任务看 JOB 管理。'
            : '无参指令,点「运行」直接执行;长任务看 JOB 管理。';
          detail = `<div class="sapc-detail"><div class="actions">
              <button data-act="run-cmd" data-card="${escAttr(c.id)}" class="primary" ${this.toolRunning ? 'disabled' : ''}>${this.toolRunning === c.id ? '执行中…' : runLabel}</button>
              <button data-act="res-json" data-card="${escAttr(c.id)}" ${this._results.get(c.id) ? '' : 'disabled'} title="结果原文下载为 JSON 文件">💾 JSON</button>
              <button data-act="res-xlsx" data-card="${escAttr(c.id)}" ${this._results.get(c.id) ? '' : 'disabled'} title="结构化结果导出 Excel(数组一表/其余进概览)">📊 Excel</button>
              <span class="sapc-hint">${hint}</span>
            </div>
            ${this._results.get(c.id) ? `<pre>${esc(this._results.get(c.id).text)}</pre>` : ''}</div>`;
        } else if (expanded && c.id === 'sap-flow') {
          // 一站式交付卡(2026-11-04 P3):展开=BPM 待办下拉(前端 IndexedDB 直读零网络)+接单话术。
          // 下拉数据懒加载:首次展开拉一次,之后复用 this._flowTodos;选项=title(截断)+传输号线索。
          const opts = (this._flowTodos || []).map((t, i) => {
            const tr = (t.note || '').match(/传输号:\s*(DVPK|DEVK)\S+/);
            const label = `${t.sourceId} ${(t.title || '').replace(/^\[[^\]]+\]\s*/, '').slice(0, 26)}${tr ? ' | ' + tr[0].replace('传输号:', '').trim() : ''}`;
            return `<option value="${escAttr(t.sourceId)}" data-idx="${i}">${esc(label)}</option>`;
          }).join('');
          detail = `<div class="sapc-detail">
            <div class="sapc-flow-row">
              <select id="sapc-flow-todo" class="sapc-flow-select">
                <option value="">(不选待办,纯文字接单)</option>
                ${opts || '<option value="" disabled>(下拉为空:无未完成 BPM 待办)</option>'}
              </select>
              <button data-act="flow-copy" data-card="${escAttr(c.id)}" class="primary">📋 复制接单话术</button>
            </div>
            <div class="sapc-hint">选中待办 → 话术带单号,CC 里 sap-flow 直接捕获该单(传输号/实施概要/成果程序名);不选 → 纯文字接单。复制后去 Claude Code 粘贴即可。</div>
          </div>`;
        }
        return `<div class="sapc-card ${c.type === 'planned' ? 'planned' : c.type === 'cc' ? 'cc' : ''}" data-card="${escAttr(c.id)}">
          <div class="c-name"><span class="tile">${c.icon || '🔧'}</span>${esc(c.name)}</div>
          <div class="c-desc">${esc(c.desc)}</div>
          <div class="c-tags">${tags.join('')}</div>
          ${detail}
        </div>`;
      }).join('');
      return `<div class="sapc-cat"><div class="cat-title">${cat.icon} ${esc(cat.name)}</div>
        <div class="sapc-cards">${items}</div></div>`;
    }).join('');
    return sections || '<div class="sapc-empty">目录为空</div>';
  }

  // Skill地图「⚙ 填参数运行」跳转用:命令面板挂在 宿主壳 的 shadowRoot 里,
  // widget 挂在其 content 区,getRootNode() 即 shell shadow root(异常宿主返回 null 由调用方回退)。
  // Skill地图「⚙ 填参数运行」跳转用:命令面板挂在 宿主壳 的 shadowRoot 里,
  // widget 挂在其 content 区,getRootNode() 即 shell shadow root(异常宿主返回 null 由调用方回退)。
  _commandPalette() {
    const rn = this.root.getRootNode();
    return rn && typeof rn.querySelector === 'function' ? rn.querySelector('pw-command-palette') : null;
  }


  // bind() 内「🗺️ Skill地图」事件段(2026-11-03 原地抽成 bindCatalog,bind() 改为转发——
  // 原位置逐字未动,只换宿主;主文件 bind() 无条件调 this.bindCatalog(),元素缺席即 no-op)。
  bindCatalog() {
      this.root.querySelectorAll('.sapc-card').forEach((card) => {
        card.addEventListener('click', async (e) => {
          if (e.target.closest('button, textarea, pre, select')) return;   // 2026-11-04 +select:flow 卡下拉点击冒泡到卡级=当场收起重渲染,下拉永远弹不开(实测)
          const id = card.dataset.card;
          const c = SAP_CATALOG.find((x) => x.id === id);
          if (!c) return;
          // 产物中心卡直达「📦 产物」页签(能力串联:目录 → 产物区)
          if (id === 'sap-artifacts') {
            this.tab = 'artifacts';
            if (!this.artifacts && !this.artifactsLoading) this.loadArtifacts(); else this.render();
            return;
          }
          // 交付台账卡直达「📦 产物」页签并切 delivery 根(交付工单产物,sap-ledger 管理)
          if (id === 'sap-delivery') {
            this.tab = 'artifacts';
            this.artifactsKind = 'delivery';
            if (!this.artifacts && !this.artifactsLoading) this.loadArtifacts(); else this.render();
            return;
          }
          // 体检卡直达「🩺 体检」页签(v14),首进自动跑一次
          if (id === 'sap_diag_pack') {
            this.tab = 'diagpk';
            const dp = this.diagpk;
            if (!dp.res && !dp.running) this.runDiagpk(); else this.render();
            return;
          }
          // 负载周报卡直达「📈 负载周报」页签(v16)
          if (id === 'sap_workload') {
            this.tab = 'wk';
            this.render();
            return;
          }
          // 排查卡直达「🔍 排查」页签(v7);程序排查卡直达并切 report 形态(v9)
          if (id === 'sap-probe') {
            this.tab = 'probe';
            this.render();
            return;
          }
          // 灰卡点亮后的直达:v9 程序 / v10 引用 / v11 传输 / v14 五关/内容搜索
          if ({ sap_report_run: 'report', sap_whereused: 'xref', sap_tr_status: 'tr', sap_lint: 'lint', sap_code_search: 'xref', sap_gate: 'gate' }[id]) {
            const wantKind = { sap_report_run: 'report', sap_whereused: 'xref', sap_tr_status: 'tr', sap_lint: 'lint', sap_code_search: 'xref', sap_gate: 'gate' }[id];
            this.tab = 'probe';
            if (this.probe.kind !== wantKind) this._resetProbeKind(wantKind);   // v15:与 kind 切换同一清理链(原 catalog 路径漏清 explain/diag 不停轮询)
            this.render();
            return;
          }
          // 一站式交付卡(2026-11-04 P1 改直达):交付驾驶舱已是 Driver「🚰 交付」页签,
          // 点卡即切页签(待办下拉/检查/续跑全在页签里);不再卡内展开。
          if (id === 'sap-flow') {
            this.tab = 'flow';
            if (!FlowStore.tickets && !FlowStore.loading) loadTicketsFn(this); else this.render();
            return;
          }
          if (false) {   // (2026-11-04 退役:原卡内展开+待办下拉段,功能并入交付页签;保留分支防误删注释)
            this._captureArgs(this.expandedId);
            const willExpand = this.expandedId !== id;
            if (willExpand && !this._flowTodos) {
              try {
                const all = await todos.getAll();
                this._flowTodos = all.filter((t) => t.source === 'bpm' && !t.done && t.sourceId)
                  .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
              } catch { this._flowTodos = []; }   // 读库失败=空下拉,不阻塞展开
            }
            this.expandedId = willExpand ? id : null;
            this.render();
            return;
          }
          // cc 卡(v16.1):已交付但执行通道在 Claude Code(写类不走 Driver);点击复制触发话术
          if (c.type === 'cc') {
            const phrase = c.trigger || c.name;
            const tip = `在 Claude Code 说「${phrase}」`;
            let copied = false;
            try { copied = !!(await copyText(tip)); } catch { copied = false; }
            _toast(copied ? `「${c.name}」在 Claude Code 执行,触发话术已复制:说「${phrase}」` : `「${c.name}」在 Claude Code 执行:说「${phrase}」`, 'ok');
            return;
          }
          if (c.type === 'planned') { _toast(`「${c.name}」规划中:${c.desc}`, 'info'); return; }
          this._captureArgs(this.expandedId);
          this.expandedId = (this.expandedId === id) ? null : id;
          this.render();
        });
      });
      this.root.querySelectorAll('[data-act="run-tool"]').forEach((btn) => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          const id = btn.dataset.card;
          const c = SAP_CATALOG.find((x) => x.id === id);
          let args = {};
          try {
            const raw = this.root.querySelector(`#sapc-args-${CSS.escape(id)}`)?.value || '{}';
            this._argsTexts.set(id, raw);
            args = JSON.parse(raw);
          } catch (err) { _toast(`参数不是合法 JSON:${err.message}`, 'err'); return; }
          this.toolRunning = id;
          this.render();
          try {
            const res = await bridge.run('sap-tool', { tool: id, args }, { timeoutMs: 110000 });
            if (res.ok === false) throw new Error(emOf(res));
            const ms = res.durationMs != null ? `${res.durationMs}ms` : '';
            const fwd = res.facadeHttpMs != null ? ` · 转发${res.facadeHttpMs}ms` : '';
            this._results.set(id, { text: JSON.stringify(res.result ?? res, null, 2), meta: `✓ ${ms}${fwd}` });
            _toast(`✓ ${c.name} 完成 ${ms}`, 'ok');
          } catch (err) {
            this._results.set(id, { text: String(err.message || err), meta: '✗ 失败' });
            _toast(`✗ ${c.name}:${err.message || err}`, 'err');
          }
          this.toolRunning = null;
          this.render();
        });
      });
      this.root.querySelectorAll('[data-act="run-cmd"]').forEach((btn) => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          const id = btn.dataset.card;
          const c = SAP_CATALOG.find((x) => x.id === id);
          const cmd = CommandRegistry.get(id);
          if (!cmd) { _toast('指令未注册(未分发?)', 'err'); return; }
          // 2026-09-16 实爆:必填参数型指令空参硬跑=必败假按钮(接口文档/测试报告点了只报
          // 「请填函数名/密码」)。改跳命令面板直达该指令的参数表单,免手搜;无参指令照旧直跑。
          const needsInput = Array.isArray(cmd.paramSchema?.required) && cmd.paramSchema.required.length > 0;
          if (needsInput) {
            const palette = this._commandPalette();
            if (palette && typeof palette.openFor === 'function') {
              palette.openFor(id);
              _toast(`已打开「${c.name}」参数表单,填完点执行`, 'info');
              return;
            }
            // 找不到面板(宿主异常)→ 回退空参执行:execute 入口校验 fail-fast,零副作用
          }
          this.toolRunning = id;
          this.render();
          try {
            const result = await runCommand(cmd, {});
            this._results.set(id, { text: JSON.stringify(result, null, 2).slice(0, 20000), meta: '✓ 完成' });
            _toast(`✓ ${c.name} 完成(长任务看 JOB 管理)`, 'ok');
          } catch (err) {
            if (err.code === 'CANCELLED') _toast('已取消', 'info');
            else { this._results.set(id, { text: String(err.message || err), meta: '✗ 失败' }); _toast(`✗ ${c.name}:${err.message || err}`, 'err'); }
          }
          this.toolRunning = null;
          this.render();
        });
      });
      this.root.querySelectorAll('[data-act="copy-result"]').forEach((btn) => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          const r = this._results.get(btn.dataset.card);
          if (r) { await copyText(r.text); _toast('已复制', 'ok'); }
        });
      });
      // 一站式交付卡(2026-11-04 P3):复制接单话术。选中待办→带单号(sap-flow 直接捕获该单);
      // 不选→纯接单。话术格式与 sap-flow SKILL.md §指令表对齐。
      this.root.querySelectorAll('[data-act="flow-copy"]').forEach((btn) => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          const sel = this.root.querySelector('#sapc-flow-todo');
          const sourceId = sel ? String(sel.value || '').trim() : '';
          const phrase = sourceId ? `sap-flow 接单:BPM 单 ${sourceId}` : 'sap-flow 接单';
          let copied = false;
          try { copied = !!(await copyText(phrase)); } catch { copied = false; }
          _toast(copied
            ? `话术已复制,去 Claude Code 粘贴:${phrase}`
            : `复制失败,请手动复制:${phrase}`, copied ? 'ok' : 'err');
        });
      });
  }

  _captureArgs(id) {
    if (!id) return;
    const ta = this.root.querySelector(`#sapc-args-${CSS.escape(id)}`);
    if (ta) this._argsTexts.set(id, ta.value);
  }
}
