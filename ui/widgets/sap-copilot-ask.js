// sap-copilot-ask.js — SAP Driver 「🤖 Agent智能体」页签(v2~v6 编排引擎)——renderAsk/多轮存档/
// 进度轮询/⚡下一步/🧩合成/📨转问答 + 主页「今日动态」条(2026-11-03 拆分批二,class mixin)。
// 拆分=原地移动零改动:方法体逐字搬运,this 语义不变(SAPC_STORE 经主文件 getter 代理),
// e2e 选择器/data-act 零变化。装配:主文件 descriptor 级 defineProperty 挂 prototype(★class 方法
// own 但不可枚举,Object.assign 拷不动);共享符号经 bindSapShared() 注入——不 import 主文件防环。

let _toast, _nowStamp, emOf, esc, escAttr, bridge, renderMarkdown, dingtalkFriendly, SAPC_STORE, PRESETS;

// 主文件装配时调一次,把共享符号绑进本模块闭包(app 启动一次;类方法体沿模块作用域取值)。
export function bindSapShared(deps) {
  _toast = deps._toast;
  _nowStamp = deps._nowStamp;
  emOf = deps.emOf;
  esc = deps.esc;
  escAttr = deps.escAttr;
  bridge = deps.bridge;
  renderMarkdown = deps.renderMarkdown;
  dingtalkFriendly = deps.dingtalkFriendly;
  SAPC_STORE = deps.SAPC_STORE;
  PRESETS = deps.PRESETS;
}

export class SapAskMethods {
  renderRecent() {
    if (!this.recent || !this.recent.entries || !this.recent.entries.length) return '';
    const rows = this.recent.entries.slice(0, 8).map((e) => {
      const t = new Date(Number(e.ts));
      const hh = `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}:${String(t.getSeconds()).padStart(2, '0')}`;
      const icon = e.result === 'ok' ? '✓' : (e.result === 'error' ? '✗' : '⛔');
      const cls = e.result === 'ok' ? 'res-ok' : (e.result === 'error' ? 'res-error' : 'res-denied');
      return `<div class="rc-row">
        <span class="rc-t">${hh}</span>
        <span class="${e.channel === 'pw' ? 'ch-pw' : 'ch-mcp'}">${e.channel === 'pw' ? 'Driver' : 'CC'}</span>
        <span class="rc-tool">${esc(e.tool)}</span>
        <span class="rc-sys">${esc(e.system)}</span>
        <span class="${cls}">${icon}</span>
        <span class="rc-ms">${e.durationMs != null ? `${e.durationMs}ms` : ''}</span>
      </div>`;
    }).join('');
    return `<div class="sapc-recent">
      <div class="rc-head"><span>今日动态</span>
        <button data-act="open-timeline">全部 →</button></div>
      ${rows}
    </div>`;
  }

  renderAsk() {
    const presets = PRESETS.map((p, i) => `<button data-preset="${i}">${esc(p.q)}</button>`).join('');
    let result = '';
    if (this.asking) {
      const rb = this.rounds.length > 1 ? `<div class="sapc-rounds" style="margin-top:12px;">
        ${this.rounds.map((r, i) => `<button class="rt ${i === this.roundIdx ? 'active' : ''}" data-round="${i}"
          title="${escAttr(r.question || '')}">${r.synthesized ? '🧩' : i + 1}</button>`).join('')}
        <span class="sapc-hint">执行中,可点序号回看上一轮</span>
      </div>` : '';
      result = `<div class="sapc-loading"><span class="spin"></span>AI 正在编排:规划 → 串行调工具 → 汇总结论
        <div class="ph" id="sapc-phase">${esc(this._phaseText())}</div>
        <div class="ph">每一步都会自动记入统一总账,可在「Trace调用链」回看</div>${rb}</div>`;
    } else if (this.askData) {
      const d = this.askData;
      const t = d.timings || {};
      // 轮次条(v6):多轮完整存档,点 chip 回看任意轮;🧩=合成轮
      const roundsBar = this.rounds.length > 1 ? `<div class="sapc-rounds">
        ${this.rounds.map((r, i) => `<button class="rt ${i === this.roundIdx ? 'active' : ''}" data-round="${i}"
          title="${escAttr(r.question || '')}">${r.synthesized ? '🧩' : i + 1}</button>`).join('')}
        <span class="sapc-hint">共 ${this.rounds.length} 轮 · 点序号回看</span>
      </div>` : '';
      const realRounds = this.rounds.filter((r) => !r.synthesized).length;
      const meta = `<div class="a-meta">
        <span>⏱ 总 <b>${((t.totalMs || 0) / 1000).toFixed(1)}s</b></span>
        <span>规划 ${t.planMs || 0}ms</span><span>执行 ${t.execMs || 0}ms</span><span>汇总 ${t.synthMs || 0}ms</span>
        ${d.model ? `<span>${esc(d.model)}</span>` : ''}
        <span class="sapc-spacer"></span>
        ${this.rounds.length ? '<button data-act="new-topic">🆕 新话题</button>' : ''}
        ${d.nextHint ? `<button data-act="ask-next" class="primary" title="${escAttr(d.nextHint)}">⚡ 执行下一步</button>` : ''}
        ${realRounds >= 2 && !d.synthesized ? '<button data-act="ask-merge" title="把各轮结论整合成一份最终交付物">🧩 合成结论</button>' : ''}
        <button data-act="copy-answer" title="富文本:粘到钉钉/Word 保留排版">📋 复制</button>
        <button data-act="export-answer" title="导出为排版好的 HTML 文档">📄 导出 HTML</button>
        <button data-act="handoff-qa" title="转到智能问答,用现成的「发送到会话」发出去">📨 转智能问答</button>
      </div>`;
      const steps = (d.steps || []).map((s, i) => {
        const cls = s.ok ? 'ok' : 'fail';
        const badge = s.ok ? '✓' : '✗';
        return `<span class="sapc-step ${cls}" data-step="${i}">
          <span class="no">${i + 1}</span>${badge} ${esc(s.tool)}${s.ms ? ` · ${s.ms}ms` : ''}</span>`;
      }).join('');
      const open = (this.openStep != null && d.steps && d.steps[this.openStep])
        ? (() => {
            const s = d.steps[this.openStep];
            let txt = `why: ${s.why || ''}\n\nargs:\n${JSON.stringify(s.args ?? {}, null, 2)}`;
            if (s.error) txt += `\n\nerror:\n${s.error}`;
            if (s.result) txt += `\n\nresult:\n${JSON.stringify(s.result, null, 2)}`;
            if (txt.length > 20000) txt = txt.slice(0, 20000) + '\n…(截断)';
            return `<div class="sapc-stepdetail"><pre>${esc(txt)}</pre></div>`;
          })()
        : '';
      result = `<div class="sapc-answer">${meta}
        ${roundsBar}
        <div class="md">${renderMarkdown(String(d.answer || ''))}</div>
        ${steps ? `<div class="sapc-steps"><span class="s-label">执行轨迹</span>${steps}</div>` : ''}${open}
      </div>`;
    }
    return `<div class="sapc-hero">
      <div class="h-title">一句话,让 Agent 替你跑一遍 SAP</div>
      <div class="h-sub">Agent 自动编排工具链:规划要用哪些工具 → 串起来执行 → 给你带证据的结论 —— 查表 / 读源码 / 复现报文 / 跨表分析都可以</div>
      <textarea id="sapc-q" placeholder="例如:DVP 上 Z_MM_DOC_CREATE 是干嘛的?接口给我,再看看有没有存过测试参数…">${esc(this._qText || '')}</textarea>
      <div class="h-actions">
        <select id="sapc-sys">${['DVP', 'QAS', 'PRD'].map((s) =>
          `<option value="${s}" ${this._qSys === s ? 'selected' : ''}>${s}${s === 'PRD' ? ' · 只读' : ''}</option>`).join('')}</select>
        <button id="sapc-ask-btn" class="primary h-ask" ${this.asking ? 'disabled' : ''}>${this.asking ? '编排执行中…' : '⚡ 问 Agent'}</button>
        <span class="h-enter">回车发送 · Shift+回车换行</span>
      </div>
      <div class="sapc-presets"><span class="p-label">试试:</span>${presets}</div>
    </div>
    ${result}
    ${this.asking ? '' : this.renderRecent()}`;
  }

  _phaseText() {
    const p = this.askPhase;
    if (!p) return '正在唤醒 SAP 编排器…';
    if (p.phase === 'plan') return '🧠 AI 规划中:决定要用哪些工具…';
    if (p.phase === 'replan') return '🔁 上一步失败,AI 正在调整计划…';
    if (p.phase === 'synth') return '✍️ 工具跑完,AI 正在汇总结论…';
    if (p.phase === 'exec') {
      const t = p.tool ? `(${p.tool})` : '';
      return `⚙️ 执行工具 第 ${p.step}/${p.total} 步 ${t}`;
    }
    return '处理中…';
  }

  _startPoll(callId) {
    SAPC_STORE.askCallId = callId;   // 存 store:切走再切回时按它恢复进度轮询
    this._stopPoll();
    this._pollTimer = setInterval(async () => {
      try {
        const res = await bridge.run('sap-ask-progress', { callId }, { timeoutMs: 8000 });
        if (res && res.found) {
          this.askPhase = res;
          const node = this.root.querySelector('#sapc-phase');
          if (node) node.textContent = this._phaseText();   // 就地刷新,不全量 render
        }
      } catch { /* 轮询失败静默,下一拍再来 */ }
    }, 850);
  }

  _stopPoll() {
    if (this._pollTimer) { clearInterval(this._pollTimer); this._pollTimer = null; }
  }

  // 结果落地为新一轮(v6):完整存档 answer/steps/nextHint,askData 指向当前轮。
  // 上限 5 轮(丢最旧),追问 history 由 _historyFor 从存档派生。
  _adoptResult(res, question) {
    this.askData = res;
    this.rounds.push({
      question,
      answer: String(res.answer || ''),
      steps: res.steps || [],
      timings: res.timings || {},
      model: res.model || '',
      nextHint: res.nextHint || '',
      synthesized: !!res.synthesized,
    });
    if (this.rounds.length > 5) this.rounds.splice(0, this.rounds.length - 5);
    this.roundIdx = this.rounds.length - 1;
  }


  // bind() 内「问 Agent」事件段(2026-11-03 原地抽成 bindAsk,bind() 改为转发——
  // 原位置逐字未动,只换宿主;主文件 bind() 无条件调 this.bindAsk(),元素缺席即 no-op)。
  bindAsk() {
      const q = this.root.querySelector('#sapc-q');
      const askBtn = this.root.querySelector('#sapc-ask-btn');
      this.root.querySelectorAll('.sapc-presets button').forEach((b) => {
        b.addEventListener('click', () => {
          const p = PRESETS[Number(b.dataset.preset)];
          if (!q) return;
          q.value = p.q;
          this._qText = p.q;
          const sel = this.root.querySelector('#sapc-sys');
          if (sel) sel.value = p.sys;
          this._qSys = p.sys;
          q.focus();
        });
      });
      if (q) {
        q.addEventListener('input', () => { this._qText = q.value; });
        q.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); askBtn?.click(); }
        });
      }
      askBtn?.addEventListener('click', () => this.ask());

      this.root.querySelectorAll('.sapc-step').forEach((el) => {
        el.addEventListener('click', () => {
          this.openStep = (this.openStep === Number(el.dataset.step)) ? null : Number(el.dataset.step);
          this.render();
        });
      });
      this.root.querySelectorAll('[data-act="copy-answer"]').forEach((b) => {
        b.addEventListener('click', () => {
          if (!this.askData) return;
          // 富文本复制(_mdExport 共享件):text/html=渲染后排版,text/plain 兜底=钉钉友好
          this._mdExport('copy', String(this.askData.answer || ''), { title: 'SAP Driver 结论' });
        });
      });
      this.root.querySelectorAll('[data-act="export-answer"]').forEach((b) => {
        b.addEventListener('click', () => {
          if (!this.askData) return;
          const q = (this._qText || '').trim().slice(0, 40);
          this._mdExport('html', String(this.askData.answer || ''), {
            title: 'SAP Driver 结论',
            subtitle: q ? `问题:${q} · ${_nowStamp()}` : _nowStamp(),
            filename: q || 'SAP Driver结论',
          });
        });
      });
      this.root.querySelectorAll('[data-act="handoff-qa"]').forEach((b) => {
        b.addEventListener('click', () => {
          if (!this.askData) return;
          // 交接给智能问答:文本走 sessionStorage(切视图销毁重建实例也能送达),
          // kb 视图 connectedCallback 消费后自动弹「发送到会话」弹窗(自由会话模式)
          const md = String(this.askData.answer || '');
          if (!md.trim()) { _toast('结论为空,无可发送内容', 'info'); return; }
          try {
            sessionStorage.setItem('pw-qa-handoff', JSON.stringify({ text: dingtalkFriendly(md), ts: Date.now() }));
          } catch (err) { _toast(`交接失败:${err.message || err}`, 'err'); return; }
          window.dispatchEvent(new CustomEvent('pw:navigate-view', { detail: { view: 'knowledge-base', section: 'work' } }));
          _toast('已转到智能问答:选好会话后确认发送', 'ok');
        });
      });
      this.root.querySelectorAll('[data-act="new-topic"]').forEach((b) => {
        b.addEventListener('click', () => {
          this.rounds = [];
          this.roundIdx = -1;
          this.askData = null;
          this.openStep = null;
          _toast('已开新话题(历史上下文已清)', 'ok');
          this.render();
        });
      });
      // v6:轮次回看(只切 askData 指向,不重新执行)
      this.root.querySelectorAll('[data-round]').forEach((b) => {
        b.addEventListener('click', () => {
          const i = Number(b.dataset.round);
          if (!this.rounds[i]) return;
          this.roundIdx = i;
          this.askData = this.rounds[i];
          this.openStep = null;
          this.render();
        });
      });
      // v6:⚡ 执行下一步——AI 给的可执行下一步直接作为新一轮跑,免手工打字
      this.root.querySelectorAll('[data-act="ask-next"]').forEach((b) => {
        b.addEventListener('click', () => {
          const d = this.askData;
          if (!d || !d.nextHint || this.asking) return;
          const q = this.root.querySelector('#sapc-q');
          if (q) q.value = d.nextHint;
          this._qText = d.nextHint;
          this.ask();
        });
      });
      // v6:🧩 合成最终结论
      this.root.querySelectorAll('[data-act="ask-merge"]').forEach((b) => {
        b.addEventListener('click', () => this.askMerge());
      });
  }

  async ask() {
    if (this.asking) return;
    const qEl = this.root.querySelector('#sapc-q');
    const sEl = this.root.querySelector('#sapc-sys');
    const question = (qEl?.value || '').trim();
    if (!question) { _toast('先输入你的问题', 'err'); return; }
    const system = sEl?.value || 'DVP';
    this._qText = question; this._qSys = system;
    this.asking = true;
    this.askData = null;
    this.openStep = null;
    this.askPhase = null;
    this.render();
    const callId = (crypto.randomUUID ? crypto.randomUUID() : `u${Date.now()}${Math.floor(Math.random() * 1e6)}`);
    this._startPoll(callId);
    try {
      const res = await bridge.run('sap-ask', {
        question, system, callId,
        // 多轮追问:最近 ≤3 轮的摘要给规划器衔接代词(完整结论在轮次存档里)
        history: this.rounds.slice(-3).map((r) => ({
          question: r.question,
          answer: String(r.answer || '').slice(0, 300),
          tools: (r.steps || []).map((s) => s.tool).filter(Boolean),
        })),
      }, { timeoutMs: 180000 });
      if (res.ok === false) throw new Error(emOf(res));
      this._adoptResult(res, question);
      const needCred = (res.steps || []).some((s) => (s.error || '').includes('NEED_CREDENTIAL'));
      if (needCred) {
        this.connectOpen = true;
        _toast('需要先连接 SAP:请在上方连接管理里输入密码', 'info');
      }
    } catch (err) {
      _toast(`问 Agent 失败:${err.message || err}`, 'err');
      this.askData = { answer: `执行失败:${err.message || err}`, steps: [], timings: {} };
    }
    this._stopPoll();
    this.askPhase = null;
    this.asking = false;
    this.render();
  }

  // ⚡ 合成最终结论(v6):各轮(非合成)全文送 sap-ask 合成模式,产出整合交付物,存为新轮
  async askMerge() {
    if (this.asking) return;
    const rs = this.rounds.filter((r) => !r.synthesized && String(r.answer || '').trim());
    if (rs.length < 2) { _toast('至少要有 2 轮结论才能合成', 'info'); return; }
    this.asking = true;
    this.openStep = null;
    this.askPhase = null;
    this.render();
    const callId = (crypto.randomUUID ? crypto.randomUUID() : `u${Date.now()}${Math.floor(Math.random() * 1e6)}`);
    this._startPoll(callId);
    try {
      const res = await bridge.run('sap-ask', {
        question: '把各轮结果合成最终交付结论',
        system: this._qSys,
        callId,
        synthesizeFrom: rs.map((r) => ({ question: r.question, answer: r.answer })),
      }, { timeoutMs: 180000 });
      if (res.ok === false) throw new Error(emOf(res));
      this._adoptResult(res, '🧩 合成最终结论');
      _toast('✓ 已合成最终结论(轮次条点 🧩 回看)', 'ok');
    } catch (err) {
      _toast(`合成失败:${err.message || err}`, 'err');
    }
    this._stopPoll();
    this.askPhase = null;
    this.asking = false;
    this.render();
  }
}
