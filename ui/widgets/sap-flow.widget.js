// sap-flow.widget.js — SAP Driver「🚰 交付」页签(2026-11-04 P1,设计方案-v2-融合.md §6)。
// 工单驾驶舱:流程图例条 + 工单卡列表(节点条/blocked/下一步)+ 检查节点动作。
// 状态真源=delivery.json(schema v3);只读走 delivery-status 路由,写走 delivery-update 窄写路由
// (status/objects 归 sap-ledger,本 TAB 禁触)。大脑通道(CC/千问/WORKBUDDY)以话术按钮接入,
// 通道注册表见 sap-flow.pipeline.js——大脑退场=删注册项,本组件零改动。

import { FLOW_NODES, FLOW_GATES, FLOW_CHANNELS, STAGE_STATES, nodeState, nextNode } from './sap-flow.pipeline.js';
import { todos } from '../dal/repositories/todos.js';

let _toast, emOf, esc, escAttr, copyText, bridge;

// 主文件装配时调一次(P1 接入 sap-copilot widget 页签树;共享符号注入同既有 mixin 惯例)
export function bindFlowShared(deps) {
  _toast = deps._toast;
  emOf = deps.emOf;
  esc = deps.esc;
  escAttr = deps.escAttr;
  copyText = deps.copyText;
  bridge = deps.bridge;
}

// ── 工单↔BPM 待办对名(2026-11-04 用户需求:卡标题显示 单号/提单人,日期退居次要)──
// 匹配链(命中即用):①工单 mossTodo.sourceId → ②工单 ticket/source 里的 SYST 号 →
// ③工单 TR 号(objects/trkorr/tr 块)反查待办 note 传输号。数据源=前端 todos 直读零网络。
// 结果缓存 FlowStore.bpmMap(dir→{sourceId,applyer}) + unlinkedTodos(未建工单的待办清单,
// 用户实锤:想找某同事的单子找不到——它还没建工单,TAB 只显示工单=断层;补「未接单待办」区)。
async function _buildMossMap(ticketList) {
  const map = {};
  let pool = [];
  try {
    const all = await todos.getAll();
    pool = all.filter((t) => t.source === 'bpm' && t.sourceId);
  } catch { /* 读库失败=匹配链退化,照旧渲染 */ }
  const trIndex = new Map();   // TR 号 → 待办
  for (const t of pool) {
    const m = (t.note || '').match(/\b(?:DVPK|DEVK)\w+/);
    if (m) trIndex.set(m[0], t);
  }
  const linked = new Set();   // 已有工单的待办 sourceId(反推"未建工单"清单)
  // ④ 成果名索引(用户实锤场景:工单↔待办 TR 换过号匹配不上,
  // 但待办手注「成果:Z程序名」= 工单 objects 的同名程序——程序名是铁证,全库验证零假匹配)
  const chengIndex = new Map();   // 大写程序名 → 待办
  for (const t of pool) {
    for (const line of ((t.note || '').match(/成果[:：]\s*(.+)/g) || [])) {
      for (const tok of line.split(/[\s,，;；]+/)) {
        const name = tok.trim().toUpperCase().split('--')[0].trim();
        if (/^Z[A-Z0-9_/]{4,}$/.test(name)) {
          if (!chengIndex.has(name)) chengIndex.set(name, t);   // 先到先得(同名归最早待办)
        }
      }
    }
  }
  for (const t of ticketList) {
    // ① 显式登记
    if (t.mossTodo && t.mossTodo.sourceId) {
      map[t.dir] = { sourceId: t.mossTodo.sourceId, applyer: _applyerOf(pool, t.mossTodo.sourceId), due: _dueOf(pool, t.mossTodo.sourceId) };
      linked.add(t.mossTodo.sourceId);
      continue;
    }
    // ② 工单名/来源里带 SYST 号
    const hay = `${t.ticket || ''} ${t.source || ''}`;
    const m2 = hay.match(/SYST\d{10,}/);
    if (m2) {
      map[t.dir] = { sourceId: m2[0], applyer: _applyerOf(pool, m2[0]), due: _dueOf(pool, m2[0]) };
      linked.add(m2[0]);
      continue;
    }
    // ③ TR 反查(新旧单没有显式登记的兜底)
    let trHit = null;
    for (const o of (t.objects || [])) {
      const m3 = String(o.trkorr || '').match(/(?:DVPK|DEVK)\w+/g);
      if (m3) { for (const tr of m3) { if (trIndex.has(tr)) { trHit = trIndex.get(tr); break; } } }
      if (trHit) break;
    }
    if (!trHit) {
      const trBlob = JSON.stringify([t.tr || {}, (t.objects || []).map((o) => o.trkorr)]);
      for (const m4 of trBlob.match(/(?:DVPK|DEVK)\w+/g) || []) {
        if (trIndex.has(m4)) { trHit = trIndex.get(m4); break; }
      }
    }
    if (trHit) {
      map[t.dir] = { sourceId: trHit.sourceId, applyer: _applyerOf(pool, trHit.sourceId), due: _dueOf(pool, trHit.sourceId) };
      linked.add(trHit.sourceId);
      continue;
    }
    // ④ 成果程序名匹配(工单 objects 名 vs 待办手注 成果-)
    let objHit = null;
    for (const o of (t.objects || [])) {
      const name = String(o.name || '').toUpperCase();
      if (name && chengIndex.has(name)) { objHit = chengIndex.get(name); break; }
    }
    if (objHit) {
      map[t.dir] = { sourceId: objHit.sourceId, applyer: _applyerOf(pool, objHit.sourceId), due: _dueOf(pool, objHit.sourceId), via: '成果名' };
      linked.add(objHit.sourceId);
    }
  }
  // 2026-11-04 用户实锤(重复显示):①已完成待办不滤会冒充"未接单";
  // ②工单卡名换没换与未接单区显示必须同生同灭——bpmMap 构建失败时返回 unlinked:[]
  // (数据不完整宁可不出,不能"上面有下面没换名"两边对不上)
  const unlinked = pool.filter((t) => !t.done && !linked.has(t.sourceId))
    .sort((a, b) => {   // 2026-11-04 用户需求:按交付日期(期望完成)升序=先做在前,和 TODO 对应
      const da = a.due ? new Date(a.due).getTime() : Infinity;
      const db = b.due ? new Date(b.due).getTime() : Infinity;
      return da - db;
    })
    .map((t) => ({
      sourceId: t.sourceId,
      applyer: _applyerOf(pool, t.sourceId),
      due: t.due || null,
      // 流程类型(标题「[单号] 类型 - 提单人」中段;2026-11-04 用户定案:未建工单区只显示
      // 信息系统功能变更——审计整改/非IT固定资产等其他流程不进交付流水线)
      procType: _procTypeOf(t),
      url: (t.note || '').match(/办理[:：]\s*(\S+)/)?.[1] || '',
      brief: (t.note || '').match(/实施概要[:：]\s*([\s\S]*?)(?:\n|$)/)?.[1]?.slice(0, 90) || '',
      node: (t.note || '').match(/当前节点[:：]\s*([^\n(]+)/)?.[1]?.trim() || '',
      // 手注进度标记(成果行 --xxx):--自测文档=测试已完成;--未完=开发中;未知标记原样给
      chengguo: (t.note || '').match(/成果[:：]\s*(.+)/)?.[1]?.trim() || '',
    }));
  // 工单的 done 标志(BPM 待办已办结 → 工单卡收进「已完成」折叠区;2026-11-04)
  for (const [dir, info] of Object.entries(map)) {
    const t = pool.find((x) => x.sourceId === info.sourceId);
    if (t && t.done) info.done = true;
  }
  return { map, unlinked };
}
function _procTypeOf(t) {
  // 标题「[SYSTxxx] 流程类型 - 提单人」→ 取中段"流程类型"
  const m = (t.title || '').match(/^\[[^\]]+\]\s*(.+?)\s*-\s*[^-]+$/);
  return m ? m[1].trim() : '';
}
function _applyerOf(pool, sourceId) {
  const t = pool.find((x) => x.sourceId === sourceId);
  // 标题形如「[SYSTxxx] 流程类型 - 提单人」→ 取提单人
  const m = t && (t.title || '').match(/-\s*([^-]+)$/);
  return m ? m[1].trim() : '';
}
function _dueOf(pool, sourceId) {
  const t = pool.find((x) => x.sourceId === sourceId);
  return t && t.due ? t.due : null;   // 期望完成日期(todos.due;排序与卡片徽标共用)
}

export const FlowStore = {
  tickets: null, loading: false, err: null,
  bpmMap: {},             // 工单 dir → {sourceId, applyer}(BPM 对名,2026-11-04)
  unlinkedTodos: [],       // 未建工单的 BPM 待办(「未接单」区;2026-11-04 用户实锤补)
  expanded: null,          // 展开的工单 dir
  checkBusy: null,         // 正在跑检查的工单 dir
  itfBusy: null,           // 接口文档直跑中(同步 300s)
  testBusy: null,          // 测试作业轮询中
  testPoll: null,          // 轮询 timer(P2;unmount 清理)
  checkCh: 'cc',           // 语义道大脑(默认 CC;下拉可切)
  briefCh: 'cc',           // 续跑 brief 目标大脑(P3;下拉可切)
  helpOpen: false,         // 使用说明折叠态(2026-11-04 用户需求:默认折叠可展开)
  doneOpen: false,         // 已完成折叠区(2026-11-04:交付/办结的单不占主列表)
};

export class SapFlowMethods {
  async loadTickets(manual = false) {
    if (FlowStore.loading) return;
    FlowStore.loading = true;
    if (manual) this.render();
    try {
      const r = await bridge.run('delivery-status', {}, { timeoutMs: 20000 });
      if (r.ok === false) throw new Error(emOf(r));
      // bridge.run 已剥一层 result(bridge-client:184 return data.result)——直接 r.tickets,
      // 再 .result 是双层解包 BUG(2026-11-04 实测:页面恒显「工单库为空」的根因)
      FlowStore.tickets = Array.isArray(r.tickets) ? r.tickets : [];
      FlowStore.err = null;
      // 工单↔BPM 待办对名(标题显示 单号+提单人;失败不阻塞列表)。
      // 失败时 unlinked 也清零:两个视图同源,bpmMap 挂了未接单区必须一起隐(否则
      // "工单卡没换名+未接单区还显示"= 同一单上下两行重复,用户实锤)
      try {
        const { map, unlinked } = await _buildMossMap(FlowStore.tickets);
        FlowStore.bpmMap = map;
        FlowStore.unlinkedTodos = unlinked;
        console.info('[flow] bpmMap ready:', Object.keys(map).length, '条;unlinked:', unlinked.length,
          '| 工单卡对应:', Object.entries(map).map(([dir, v]) => `${dir.slice(-14)}→${v.sourceId}`).join(' '));
      } catch (e) {
        FlowStore.bpmMap = {}; FlowStore.unlinkedTodos = [];
        console.warn('[flow] bpmMap 构建失败(卡显示原名):', e);
      }
    } catch (e) {
      FlowStore.err = String(e.message || e);
    }
    FlowStore.loading = false;
    this.render();
  }

  renderFlow() {
    const s = FlowStore;
    // 默认页签=flow 时(2026-11-04 用户实爆:刷新后「工单库为空」)mount 直渲染,
    // 没人点页签按钮→bind 里那条触发链不跑。这里兜底:首渲染数据未拉就自动触发,
    // 先画加载态,数据回来 loadTickets 尾部 render() 自会替换。
    if (!s.tickets && !s.loading && !s.err) {
      // 不手动设 loading:loadTickets 开头有 loading 守卫,先设 true 会把自己挡在门外
      // (2026-11-04 实爆「恒扫描中」的根因)。直接调它,首帧先返回提示,数据回来尾部 render()。
      this.loadTickets();
      return '<div class="flow-empty">扫描工单中…</div>';
    }
    // 使用说明(2026-11-04 用户需求:默认折叠,点开看懂每个按钮/下拉干什么)
    const helpOpen = !!s.helpOpen;
    const help = `<div class="flow-help">
      <button data-act="flow-help-toggle" class="flow-btn-sm" title="展开/收起使用说明">${helpOpen ? '▾' : '▸'} 怎么用这个页签</button>
      ${helpOpen ? `<div class="flow-help-body">
        <p><b>这是什么</b>:SAP 交付流水线的驾驶舱。一张工单从接单到交付的全部进度、产物、下一步,都在这里看和推进。</p>
        <p><b>卡片顺序</b>=交付日期(⏰期望完成)升序,和 TODO 待办的先后对应;过期红、一周内橙。上方「未建工单的待办」区=还没接单的 BPM 单,按提单人找,同样按日期排。</p>
        <p><b>点卡片</b>展开详情:对象清单、REQ 基线、检查轮次、<b>交付物(可点开:接口文档/测试报告/检查报告)</b>。</p>
        <p><b>各按钮干什么</b>:</p>
        <ul>
          <li><b>🔬 检查</b>:双道体检。<b>静态道</b>永远 PW 自己跑(五关门禁/语法,机器判不打扰你);<b>语义道</b>=「需求符合度」部分,由旁边的「<b>🧠 检查语义道用谁</b>」下拉决定交给哪个 AI(CC=Claude Code、千问、WORKBUDDY,选哪个就生成哪个的话术,粘到对应工具里跑)。检查可重复:改完代码再点一轮,历史轮次都留档。</li>
          <li><b>🧪 直跑测试</b>:PW 直接在 QAS 真跑场景出报告,不需要任何 AI;前置=最近一轮检查 pass(闸④)。</li>
          <li><b>📑 直跑接口文档</b>:FUNC 对象自动生成接口文档,免密(用 Driver 连接管理的凭证),产物路径自动登记进卡片「交付物」。</li>
          <li><b>📋 续跑 brief</b>:点它生成一页"任务书"(下一步做什么/输入文件/上轮失败证据),复制后粘到「<b>🧠 续跑交给谁</b>」下拉选的那个 AI 里——AI 读了就知道从哪接着干。两个下拉是<b>两个独立用途</b>:一个管检查交给谁,一个管续跑交给谁,可以不同。</li>
          <li><b>✋ 登记检查</b>:你自己人工检查完,把结论登记进轮次(我自己干通道)。</li>
        </ul>
        <p><b>⚠ 硬闸纪律</b>:评估认可/LIST获批/trkorr/测试确认/交付确认五个闸永远要你点头,任何自动化不会替你过。</p>
      </div>` : ''}
    </div>`;
    const head = `${help}<div class="flow-legend">
      ${[...FLOW_NODES].sort((a, b) => a.seq - b.seq).map((n) => {
        const dim = n.enabled === false;
        return `<span class="flow-lg ${dim ? 'dim' : ''}" title="${escAttr(n.desc)}">${n.icon}${esc(n.name)}</span>`;
      }).join('<span class="flow-arrow">→</span>')}
      <button data-act="flow-reload" class="flow-btn-sm" title="重新扫描工单">🔄</button>
    </div>`;

    let body = '';
    if (s.loading && !s.tickets) body = '<div class="flow-empty">扫描工单中…</div>';
    else if (s.err) body = `<div class="flow-empty">⚠ ${esc(s.err)}<br><button data-act="flow-reload" class="flow-btn-sm">重试</button></div>`;
    else if (!s.tickets || !s.tickets.length) body = '<div class="flow-empty">工单库为空(data/delivery,可用 SAP_DELIVERY_ROOT 改向)</div>';
    else {
      // 排序=交付日期(期望完成)升序(2026-11-04 用户需求:与 TODO 对应,先做在前);
      // 无日期(线下单/旧单没对上待办)排最后按 updatedAt 倒序。日期徽标随卡显示,排序依据可见。
      const dueOf = (t) => {
        const info = (s.bpmMap || {})[t.dir] || (t.mossTodo && t.mossTodo.sourceId ? { due: null } : null);
        return info && info.due ? new Date(info.due).getTime() : Infinity;
      };
      // 完工分流(2026-11-04 用户需求:已完成的不再占主列表):状态机 delivered、
      // 手动标记 doneFlag、或 BPM 待办已办结 → 收进底部「已完成」折叠区。
      const isDone = (t) => t.status === 'delivered' || t.doneFlag === true
        || (() => { const m = (s.bpmMap || {})[t.dir]; return m && m.done === true; })();
      const active = [...s.tickets].filter((t) => !isDone(t));
      const finished = [...s.tickets].filter((t) => isDone(t));
      const cards = active.sort((a, b) => {
        const da = dueOf(a), db = dueOf(b);
        if (da !== db) return da - db;   // 有日期的互比升序;无日期=Infinity 天然垫底
        return String(b.updatedAt || '').localeCompare(String(a.updatedAt || ''));   // 同组内 updatedAt 倒序
      }).map((t) => this._flowCard(t)).join('');
      // 未建工单的 BPM 待办(用户实锤:想找某同事的单子找不到——还没接单建工单,
      // TAB 只显示工单=索引断层)。单列一区:按提单人找;有成果手注(--自测文档/--未完)的单子
      // 显示进度徽标+「中途接入」话术(带成果程序名,flow 建单时按实际进度预置阶段)。
      // 2026-11-04 收窄:只要「信息系统功能变更」单(用户定案:审计整改/非IT固定资产等其他
      // 流程类型目前不进交付流水线——张娟娟/宋云那些)。
      const un = (Array.isArray(s.unlinkedTodos) ? s.unlinkedTodos : []).filter((u) => u.procType === '信息系统功能变更');
      const unBlock = un.length ? `<div class="flow-unlinked">
        <div class="fu-title">📮 未建工单的功能变更待办(${un.length})——按提单人找;手注过进度的可直接「中途接入」:</div>
        ${un.map((u) => {
          const cg = u.chengguo || '';
          const marks = cg.match(/--\S+/g) || [];
          const progTag = marks.includes('--自测文档') ? '<span class="fc-badge ok">测试已做</span>'
            : marks.includes('--未完') ? '<span class="fc-badge warn">开发中</span>' : '';
          const midBtn = cg
            ? `<button data-act="flow-cc-midintake" data-sid="${escAttr(u.sourceId)}" data-cg="${escAttr(cg)}" title="已有成果在做的:话术带成果程序名,CC 建单按实际进度预置阶段,从断点续">🚀 中途接入</button>`
            : '';
          return `<div class="fu-row" data-un="${escAttr(u.sourceId)}">
          <b>${esc(u.sourceId)}</b><span class="fu-applyer">${esc(u.applyer || '?')}</span>${progTag}
          <span class="fu-brief" title="${escAttr(u.brief)}">${esc(cg || u.brief || '(无概要)')}</span>
          <span class="fu-node">${esc(u.node)}</span>
          ${midBtn}<button data-act="flow-cc-intake" data-sid="${escAttr(u.sourceId)}" title="从头接单:复制话术去 CC 粘贴建工单">🤝 接单</button>
        </div>`;
        }).join('')}
      </div>` : '';
      // 已完成折叠区(2026-11-04):交付了的/流程办结的;收起只留一行计数,点开看卡。
      const finBlock = finished.length ? `<div class="flow-done-box">
        <button data-act="flow-done-toggle" class="flow-btn-sm">${s.doneOpen ? '▾' : '▸'} ✅ 已完成(${finished.length})</button>
        ${s.doneOpen ? `<div class="flow-cards">${finished.map((t) => this._flowCard(t)).join('')}</div>` : ''}
      </div>` : '';
      body = unBlock + `<div class="flow-cards">${cards}</div>` + finBlock;
    }
    return head + body;
  }

  _flowCard(t) {
    if (t.parseError) {
      return `<div class="flow-card bad"><div class="fc-head"><b>${esc(t.dir)}</b><span class="fc-badge err">档损待修</span></div>
        <div class="fc-note">delivery.json 解析失败,先修档再走流水线。</div></div>`;
    }
    const open = FlowStore.expanded === t.dir;
    const nn = nextNode(t);
    const nextTxt = nn
      ? `${nn.node.icon} ${esc(nn.node.name)}(${STAGE_STATES[nn.state]?.label || nn.state})`
      : '✅ 全节点完成';
    // BPM 对名(2026-11-04 用户需求):主标题=单号+提单人,工单原名降为副行——
    // 用户对不上"2026-1103-xxx"是哪个单谁提的,对得上的是待办里的 SYST 号。
    const bpmInfo = (FlowStore.bpmMap || {})[t.dir] || (t.mossTodo && t.mossTodo.sourceId ? { sourceId: t.mossTodo.sourceId, applyer: '' } : null);
    // 交付日期徽标(2026-11-04 排序配套:卡序=期望完成升序,日期上卡排序依据可见;
    // 过期红/一周内橙/其余常规)。无日期单排底部不显示徽标。
    const dueTxt = bpmInfo && bpmInfo.due ? String(bpmInfo.due).slice(0, 10) : '';
    const dueCls = dueTxt ? (new Date(dueTxt) < new Date() ? 'fc-badge err' : (new Date(dueTxt) - new Date() < 7 * 86400000 ? 'fc-badge warn' : 'fc-badge')) : '';
    const dueBadge = dueTxt ? `<span class="${dueCls}" title="期望完成(交付日期;列表按此升序)">⏰ ${esc(dueTxt)}</span>` : '';
    const moss = bpmInfo ? `<span class="fc-badge bpm" title="BPM 来源单${bpmInfo.via ? '(经' + bpmInfo.via + '匹配)' : ''}">${esc(bpmInfo.sourceId)}${bpmInfo.applyer ? ' · ' + esc(bpmInfo.applyer) : ''}</span>` : '';
    const lastCheck = Array.isArray(t.checks) && t.checks.length
      ? [...t.checks].sort((a, b) => (b.round || 0) - (a.round || 0))[0] : null;

    // 节点条:点亮态按 nodeState 归一化(执行通道无关——谁干的无所谓,进度只看 delivery.json)
    // P3:done 节点带通道徽标(stageRuns[节点id] 最后一条的 channel;无记录=历史手工/旧单)
    const runs = t.stageRuns || {};
    const dots = [...FLOW_NODES].sort((a, b) => a.seq - b.seq).map((n) => {
      const st = nodeState(t, n);
      const meta = STAGE_STATES[st];
      if (st === 'reserved' || st === null) return `<span class="fd na" title="${escAttr(n.name)}(未启用/旧单)">–</span>`;
      const run = Array.isArray(runs[n.id]) && runs[n.id].length ? runs[n.id][runs[n.id].length - 1] : null;
      const ch = run && FLOW_CHANNELS[run.channel] ? FLOW_CHANNELS[run.channel].icon : '';
      return `<span class="fd st-${st}" title="${escAttr(n.name)}:${meta?.label || st}${run ? ' · ' + escAttr(ch.label || run.channel) + (run.at ? ' ' + escAttr(run.at) : '') : ''}">${meta?.dot || '○'}${ch}</span>`;
    }).join('');
    const doneChs = [...new Set((Array.isArray(t.objects) ? [] : []).concat(
      Object.values(runs).flat().map((r) => r.channel).filter(Boolean)))];
    const channelBadges = doneChs.map((c) => FLOW_CHANNELS[c] ? `<span class="fc-ch" title="有节点由 ${FLOW_CHANNELS[c].label} 完成">${FLOW_CHANNELS[c].icon}</span>` : '').join('');

    let detail = '';
    if (open) {
      const checks = Array.isArray(t.checks) ? t.checks : [];
      const defOpen = (Array.isArray(t.defects) ? t.defects : []).filter((d) => d.status !== 'verified' && d.status !== 'closed');
      detail = `<div class="fc-detail">
        <div class="fc-line"><span class="k">摘要</span>${esc(t.summary || '(无)')}</div>
        <div class="fc-line"><span class="k">状态机</span>${esc(t.status)} · schema ${t.schema ?? '1'}</div>
        <div class="fc-line"><span class="k">对象</span>${(t.objects || []).map((o) => `${esc(o.type)} ${esc(o.name)}`).join(' · ') || '(无)'}</div>
        ${t.requirement && t.requirement.reqs && t.requirement.reqs.length
          ? `<div class="fc-line"><span class="k">基线</span>v${esc(t.requirement.baseline)} · REQ×${t.requirement.reqs.length}
             ${Array.isArray(t.requirement.reqs) && t.requirement.reqs.some((r) => (r.ambiguity || []).some((a) => a.status === 'open')) ? '<span class="fc-badge warn">有未清歧义</span>' : ''}</div>` : ''}
        <div class="fc-line"><span class="k">检查</span>${checks.length
          ? checks.map((c) => `第${c.round}轮 ${esc(c.verdict || '?')}(${esc(c.channel || '?')}${c.defects && c.defects.length ? ',DEF×' + c.defects.length : ''})`).join(' · ')
          : '未跑'}</div>
        ${(t.artifacts && (t.artifacts.itf || []).length) || (t.handoff && t.handoff.test && t.handoff.test.reportPath) || (lastCheck && lastCheck.report) ? `
        <div class="fc-arts">
          <div class="fc-line"><span class="k">交付物</span></div>
          ${(t.artifacts && t.artifacts.itf || []).map((a, i) => {
            // 条目可能是带括号备注的字符串(如"03接口文档/xxx.docx(工单内留档,45394 字节)")
            // 或 {path} 对象;清洗:剥尾部括号备注再取路径,显示名取 basename。
            const raw = typeof a === 'string' ? a : (a && a.path) || '';
            const path = String(raw).replace(/\([^)]*\)\s*$/, '').trim();
            const disp = String(path).split(/[\\/]/).pop();
            return `<div class="fc-art-row"><span class="t">📑 接口文档</span>
              <button data-act="flow-open-art" data-p="${escAttr(path)}" data-dir="${escAttr(t.dir)}" title="${escAttr(path)}">📄 ${esc(disp || path)}</button></div>`;
          }).join('')}
          ${(t.handoff && t.handoff.test && t.handoff.test.reportPath) ? `<div class="fc-art-row"><span class="t">🧪 测试</span>
            <button data-act="flow-open-art" data-p="${escAttr(t.handoff.test.reportPath)}" data-dir="${escAttr(t.dir)}" data-rel="abs" title="${escAttr(t.handoff.test.reportPath)}">📄 ${esc(String(t.handoff.test.reportPath).split(/[\\/]/).pop())}</button>
            ${t.handoff.test.gatePending ? '<span class="fc-badge warn">闸④待确认</span>' : ''}</div>` : ''}
          ${(lastCheck && lastCheck.report) ? `<div class="fc-art-row"><span class="t">🔬 检查</span>
            <button data-act="flow-open-art" data-p="${escAttr(lastCheck.report)}" data-dir="${escAttr(t.dir)}" data-rel="rel" title="${escAttr(lastCheck.report)}">📄 ${esc(String(lastCheck.report).split(/[\\/]/).pop())}</button></div>` : ''}
        </div>` : ''}
        ${defOpen.length ? `<div class="fc-line"><span class="k">未闭环DEF</span><span class="fc-badge err">${defOpen.map((d) => esc(d.id)).join(' / ')}</span></div>` : ''}
        <div class="fc-actions">
          <button data-act="flow-check" data-dir="${escAttr(t.dir)}" class="primary" ${FlowStore.checkBusy === t.dir ? 'disabled' : ''}>
            ${FlowStore.checkBusy === t.dir ? '检查中…' : `🔬 检查(静态道直跑+语义道:${FLOW_CHANNELS[FlowStore.checkCh]?.label || FlowStore.checkCh})`}</button>
          <select data-act="flow-check-ch" title="语义道大脑:检查的"需求符合度"部分由哪个 AI 做(静态道总是 PW 直跑,与此无关)">
            <option value="" disabled selected hidden>🧠 检查语义道用谁</option>
            ${Object.entries(FLOW_CHANNELS).filter(([id, c]) => c.kind === 'ai').map(([id, c]) =>
              `<option value="${id}" ${FlowStore.checkCh === id ? 'selected' : ''}>${c.icon} 检查·${esc(c.label)}</option>`).join('')}
          </select>
          <button data-act="flow-reg-check" data-dir="${escAttr(t.dir)}" title="我自己干:手工登记一轮检查结果(落 checks[],窄写)">✋ 登记检查</button>
          ${lastCheck && lastCheck.report ? `<button data-act="flow-open-report" data-p="${escAttr(lastCheck.report)}" data-dir="${escAttr(t.dir)}">📄 最近轮报告</button>` : ''}
          <select data-act="flow-brief-ch" title="续跑话术发给谁:点「续跑 brief」生成的结构化任务书复制后,粘到哪个 AI 里去接着干">
            <option value="" disabled selected hidden>🧠 续跑交给谁</option>
            ${Object.entries(FLOW_CHANNELS).filter(([id, c]) => c.kind === 'ai').map(([id, c]) =>
              `<option value="${id}" ${FlowStore.briefCh === id ? 'selected' : ''}>${c.icon} 续跑·${esc(c.label)}</option>`).join('')}
          </select>
          <button data-act="flow-brief" data-dir="${escAttr(t.dir)}" title="生成续跑 brief(下一步节点做什么/输入哪些文件/上轮失败证据),复制后粘到所选大脑">📋 续跑 brief</button>
          <button data-act="flow-mark-done" data-dir="${escAttr(t.dir)}" title="${t.doneFlag === true ? '已完成区翻回进行中' : '标记为已完成:收进底部折叠区,不占主列表(不改变状态机,可翻回)'}">${t.doneFlag === true ? '↩ 翻回进行中' : '✔ 标记完工'}</button>
        </div>
        ${(t.objects || []).some((o) => o.type === 'FUNC') ? `<div class="fc-actions">
          <button data-act="flow-itfdoc" data-dir="${escAttr(t.dir)}" ${FlowStore.itfBusy === t.dir ? 'disabled' : ''}>
            ${FlowStore.itfBusy === t.dir ? '接口文档生成中…(最长 5 分钟)' : '📑 直跑接口文档'}</button>
          <span class="fc-hint2">FUNC×${(t.objects || []).filter((o) => o.type === 'FUNC').length} · 走 Driver 连接槽免密,产物落 产物目录 + 拷回工单 03</span>
        </div>` : ''}
        <div class="fc-actions">
          <button data-act="flow-test" data-dir="${escAttr(t.dir)}" ${FlowStore.testBusy === t.dir ? 'disabled' : ''}>
            ${FlowStore.testBusy === t.dir ? '测试作业已提交,轮询中…' : '🧪 直跑测试(QAS 全自动)'}</button>
          <select data-act="flow-test-obj" title="测试对象(FM=函数/PROG=程序)">
            ${(t.objects || []).filter((o) => o.name).map((o) =>
              `<option value="${escAttr(o.type + ':' + o.name)}">${o.type === 'FUNC' ? 'FM' : o.type} ${esc(o.name)}</option>`).join('')}
          </select>
          <span class="fc-hint2">闸④前置:最近一轮检查 pass。PRD 拒;QAS 真跑。</span>
        </div>
        ${defOpen.length ? `<div class="fc-defs">
          <div class="fc-line"><span class="k">DEF 闭环</span>${defOpen.map((d) =>
            `<span class="def-chip" title="${escAttr(d.symptom || '')}">${esc(d.id)}·${esc(d.status)} <button data-act="flow-def-fix" data-dir="${escAttr(t.dir)}" data-def="${escAttr(d.id)}" title="修复后标记 fixed(窄写 defects)">→fixed</button> <button data-act="flow-def-verify" data-dir="${escAttr(t.dir)}" data-def="${escAttr(d.id)}" title="复验通过(窄写 defects+只重跑受影响用例的提示)">→verified</button></span>`).join(' ')}</div>
          <div class="fc-hint">修复后「→fixed」;复验「→verified」(触发提示:只重跑受影响用例,不做全量回归)。</div>
        </div>` : ''}
        <div class="fc-hint">直跑=静态道机器判(lint/语法/读回);语义道走所选大脑(带行号证据写 coverage);「CC续跑话术」复制后去 Claude Code 粘贴,大脑读 handoff 从断点推进。</div>
      </div>`;
    }

    // 主标题=BPM 单号+提单人(有匹配时);工单原名(日期-slug)降为副行小字——对单靠 SYST 号
    const headTitle = bpmInfo
      ? `<b>${esc(bpmInfo.sourceId)}${bpmInfo.applyer ? ' · ' + esc(bpmInfo.applyer) : ''}</b>
         <span class="fc-sub">${esc(t.ticket || t.dir)}</span>`
      : `<b>${esc(t.ticket || t.dir)}</b>`;
    return `<div class="flow-card ${nn ? '' : 'done'}" data-flow-card="${escAttr(t.dir)}">
      <div class="fc-head">
        ${headTitle}
        <span class="fc-status">${esc(t.status || '?')}</span>
        ${dueBadge}${channelBadges}
      </div>
      <div class="fc-dots">${dots}</div>
      <div class="fc-next">下一步:<b>${nextTxt}</b><span class="fc-upd">${esc(t.updatedAt || '')}</span></div>
      ${detail}
    </div>`;
  }

  // ── 动作(事件绑定;卡片点击展开/收起,按钮各自 data-act)──
  bindFlow() {
    this.root.querySelectorAll('[data-flow-card]').forEach((card) => {
      card.addEventListener('click', async (e) => {
        if (e.target.closest('button, select, input')) return;
        const dir = card.dataset.flowCard;
        FlowStore.expanded = FlowStore.expanded === dir ? null : dir;
        this.render();
      });
    });
    const reload = this.root.querySelector('[data-act="flow-reload"]');
    if (reload) reload.addEventListener('click', (e) => { e.stopPropagation(); this.loadTickets(true); });

    // 使用说明折叠切换(2026-11-04)
    const helpBtn = this.root.querySelector('[data-act="flow-help-toggle"]');
    if (helpBtn) helpBtn.addEventListener('click', (e) => { e.stopPropagation(); FlowStore.helpOpen = !FlowStore.helpOpen; this.render(); });

    // 已完成折叠区切换(2026-11-04)
    const doneBtn = this.root.querySelector('[data-act="flow-done-toggle"]');
    if (doneBtn) doneBtn.addEventListener('click', (e) => { e.stopPropagation(); FlowStore.doneOpen = !FlowStore.doneOpen; this.render(); });

    // 手动标记完工(用户需求:某单实际已完成但状态机没走到 delivered 时手工收口)。
    // 写 delivery.json 顶层 doneFlag(窄字段;与 status 分离——不篡改状态机,仅列表分流用),
    // 经 delivery-update 走白名单。取消=同字段翻回。
    this.root.querySelectorAll('[data-act="flow-mark-done"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const dir = btn.dataset.dir;
        const t = (FlowStore.tickets || []).find((x) => x.dir === dir);
        if (!t) return;
        const toDone = !(t.doneFlag === true);
        if (toDone && !window.confirm(`把「${t.ticket || dir}」标记为已完成?卡片会移入底部「已完成」区(可随时翻回)。`)) return;
        try {
          const r = await bridge.run('delivery-update', { ticket: dir, patch: { doneFlag: toDone } }, { timeoutMs: 15000 });
          if (r.ok === false) throw new Error(emOf(r));
          _toast(toDone ? '已移入「已完成」区' : '已翻回进行中', 'ok');
          await this.loadTickets();
        } catch (err) { _toast(`回写失败:${err.message || err}`, 'err'); }
      });
    });

    // 未接单待办的「🤝 接单」话术(2026-11-04):复制后去 CC 粘贴,sap-flow 按 BPM 单号捕获建工单
    this.root.querySelectorAll('[data-act="flow-cc-intake"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const sid = btn.dataset.sid;
        const phrase = `sap-flow 接单:BPM 单 ${sid}`;
        let copied = false;
        try { copied = !!(await copyText(phrase)); } catch { copied = false; }
        _toast(copied ? `接单话术已复制,去 CC 粘贴:${phrase}` : `复制失败,手动:${phrase}`, copied ? 'ok' : 'err');
      });
    });

    // 「🚀 中途接入」话术(2026-11-04 用户实锤:单子做了一半没建工单——5019 三个程序连
    // 自测文档都做完了)。话术带成果程序名+进度标记,CC 里 flow 建单按实际进度预置阶段
    // (--自测文档→stages.test=done),直接从断点(如接口文档/交付)续跑。
    this.root.querySelectorAll('[data-act="flow-cc-midintake"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const sid = btn.dataset.sid, cg = btn.dataset.cg || '';
        const phrase = `sap-flow 接单:BPM 单 ${sid},已有成果在做的,中途接入 —— 成果:${cg}`;
        let copied = false;
        try { copied = !!(await copyText(phrase)); } catch { copied = false; }
        _toast(copied ? `中途接入话术已复制(${cg.slice(0, 40)}),去 CC 粘贴` : `复制失败,手动复制`, copied ? 'ok' : 'err');
      });
    });

    // 检查:静态道 PW 直跑(逐对象打 sap-gate 五段门禁,内嵌 lint 五关=G4;DVP 默认);
    // 语义道=所选大脑话术复制(REQ 逐条对照→coverage.semantic+checks 轮次)
    this.root.querySelectorAll('[data-act="flow-check"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const dir = btn.dataset.dir;
        const t = (FlowStore.tickets || []).find((x) => x.dir === dir);
        if (!t) return;
        const objs = (t.objects || []).filter((o) => o.name).map((o) => o.name);
        if (!objs.length) { _toast('工单无对象登记,静态道无从跑;先登记 objects 或走大脑语义道', 'err'); return; }
        FlowStore.checkBusy = dir;
        this.render();
        const results = [];
        try {
          for (const obj of objs) {
            try {
              // bridge.run 已剥一层 result → 直接 r.verdict/r.gates(双层解包 BUG 同上)
              const r = await bridge.run('sap-gate', { system: 'DVP', object: obj }, { timeoutMs: 300000 });
              results.push({ object: obj, verdict: r.verdict || 'OK', gates: r.gates || null });
            } catch (err) {
              results.push({ object: obj, verdict: 'ERR', err: String(err.message || err) });
            }
          }
          const failN = results.filter((x) => x.verdict === 'FAIL').length;
          const errN = results.filter((x) => x.verdict === 'ERR').length;
          const summary = results.map((x) => `${x.object}=${x.verdict}`).join(' ');
          _toast(`静态道 ${objs.length} 对象:FAIL×${failN} ERR×${errN} | ${summary.slice(0, 80)}`, failN || errN ? 'err' : 'ok');
          // 语义道话术(通道无关:CC 粘贴即跑;千问/WORKBUDDY 接入后同文本)
          const ch = FLOW_CHANNELS[FlowStore.checkCh] || {};
          const reqLine = t.requirement?.reqs?.length
            ? `REQ 清单:${t.requirement.reqs.map((r) => r.id).join(',')}`
            : '(无 REQ 基线:先补 requirement)';
          const phrase = `sap-flow 检查:${dir} —— 静态道 PW 已跑完(${summary});请做语义道:${reqLine},逐条对照代码写 coverage.semantic + checks 第${(Array.isArray(t.checks) ? t.checks.length : 0) + 1}轮。`;
          let copied = false;
          try { copied = !!(await copyText(phrase)); } catch { copied = false; }
          _toast(`${ch.label || '大脑'}语义道话术${copied ? '已复制,去粘贴' : '生成失败,手动复制'}`, copied ? 'info' : 'err');
          await this.loadTickets();
        } catch (err) {
          _toast(`检查失败:${err.message || err}`, 'err');
        }
        FlowStore.checkBusy = null;
        this.render();
      });
    });
    const chSel = this.root.querySelectorAll('[data-act="flow-check-ch"]');
    chSel.forEach((sel) => sel.addEventListener('change', (e) => { e.stopPropagation(); FlowStore.checkCh = sel.value; }));

    // 手工登记检查(我自己干通道):轮次+结论→窄写 checks[](delivery-update 校验器守门)。
    // v2(2026-11-04 用户需求:不要手动输入):点「✋ 登记检查」弹行内选择条——
    // ✅通过/❌有问题/取消 三个按键选,不再 prompt 打字;备注改为可选快捷标签(按键多选)。
    this.root.querySelectorAll('[data-act="flow-reg-check"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const dir = btn.dataset.dir;
        const t = (FlowStore.tickets || []).find((x) => x.dir === dir);
        if (!t) return;
        // 已弹一条就不重复弹(防连点)
        if (this.root.querySelector('.reg-check-bar')) return;
        const round = (Array.isArray(t.checks) ? t.checks.length : 0) + 1;
        const QUICK = ['代码走查', 'SE30 性能', '手工测试', '需求方确认', '上轮DEF复验'];
        const bar = document.createElement('div');
        bar.className = 'reg-check-bar';
        bar.innerHTML = `
          <span class="rcb-title">第 ${round} 轮检查(✋我自己干):</span>
          <span class="rcb-tags">${QUICK.map((q) => `<button type="button" data-quick="${escAttr(q)}" title="点选备注标签(可多选)">${esc(q)}</button>`).join('')}</span>
          <span class="rcb-btns">
            <button type="button" class="rcb-pass" data-verdict="pass">✅ 通过</button>
            <button type="button" class="rcb-fail" data-verdict="fail">❌ 有问题</button>
            <button type="button" class="rcb-cancel" data-verdict="">✕ 取消</button>
          </span>`;
        btn.closest('.fc-actions').after(bar);
        const picked = new Set();
        bar.querySelectorAll('[data-quick]').forEach((qb) => qb.addEventListener('click', (ev) => {
          ev.stopPropagation();
          const q = qb.dataset.quick;
          if (picked.has(q)) { picked.delete(q); qb.classList.remove('on'); }
          else { picked.add(q); qb.classList.add('on'); }
        }));
        bar.querySelectorAll('[data-verdict]').forEach((vb) => vb.addEventListener('click', async (ev) => {
          ev.stopPropagation();
          const v = vb.dataset.verdict;
          bar.remove();
          if (!v) return;   // 取消
          const note = [...picked].join(',') || '';
          try {
            const runs = t.stageRuns || {};
            const r = await bridge.run('delivery-update', { ticket: dir, patch: {
              checks: [
                ...(Array.isArray(t.checks) ? t.checks : []),
                { round, at: new Date().toISOString().slice(0, 16).replace('T', ' '), channel: 'by-hand',
                  static: 'pass', semantic: v, report: '', defects: [], verdict: v, note }
              ],
              stageRuns: { ...runs, check: [...(runs.check || []), { channel: 'by-hand', at: new Date().toISOString().slice(0, 10), verdict: v }] }
            } }, { timeoutMs: 20000 });
            if (r.ok === false) throw new Error(emOf(r));
            _toast(`第${round}轮已登记(${v}${note ? ' · ' + note : ''})`, 'ok');
            await this.loadTickets();
          } catch (err) { _toast(`登记失败:${err.message || err}`, 'err'); }
        }));
      });
    });

    // brief 目标大脑下拉(P3)
    this.root.querySelectorAll('[data-act="flow-brief-ch"]').forEach((sel) =>
      sel.addEventListener('change', (e) => { e.stopPropagation(); FlowStore.briefCh = sel.value; }));

    // 结构化续跑 brief(P3,通道无关):下一步节点做什么/输入文件/上轮失败证据/闸提示。
    // 任何大脑(CC/千问/WORKBUDDY)拿到同一段 brief,读 handoff 即断点续跑——大脑退场零影响。
    this.root.querySelectorAll('[data-act="flow-brief"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const dir = btn.dataset.dir;
        const t = (FlowStore.tickets || []).find((x) => x.dir === dir);
        if (!t) return;
        const nn = nextNode(t);
        const ch = FLOW_CHANNELS[FlowStore.briefCh] || FLOW_CHANNELS.cc;
        const reqIds = (t.requirement?.reqs || []).map((r) => r.id);
        const checks = Array.isArray(t.checks) ? t.checks : [];
        const lastFail = checks.filter((c) => c.verdict === 'fail').slice(-1)[0];
        const lines = [
          `【交付流水线续跑 brief】`,
          `工单:${t.ticket || dir}(状态 ${t.status || '?'})`,
          `进度:${[...FLOW_NODES].sort((a, b) => a.seq - b.seq)
            .map((n) => `${n.name}=${nodeState(t, n) || '—'}`).join(' · ')}`,
          `下一步:${nn ? `${nn.node.icon} ${nn.node.name} —— ${nn.node.desc}` : '全部节点完成,走交付小结'}`,
          nn && nn.node.gate ? `⚠ 该节点有硬闸:${FLOW_GATES[nn.node.gate]?.label || nn.node.gate}(到闸停下等用户批准)` : '',
          `输入文件:工单目录 ${dir}/ 下的 delivery.json(handoff 块=上阶段交接)${t.requirement?.reqs?.length ? ` + 01需求评审\\requirement.json(REQ 基线${reqIds.join(',')})` : ''}`,
          lastFail ? `上轮检查失败(第${lastFail.round}轮,${lastFail.channel}):未闭环 DEF ${(lastFail.defects || []).join(',') || '(见 defects 块)'}——优先复验` : '',
          `规则:读 handoff 备料,缺什么才问什么;状态推进只能经桥路由 delivery-update(白名单窄写);红线五闸逐次批准。`,
        ].filter(Boolean);
        const phrase = lines.join('\n');
        let copied = false;
        try { copied = !!(await copyText(phrase)); } catch { copied = false; }
        _toast(copied
          ? `${ch.label} 续跑 brief 已复制(${phrase.length} 字),去 ${ch.label} 粘贴`
          : `复制失败,请手动复制`, copied ? 'ok' : 'err');
      });
    });

    // ── P2:直跑接口文档(sap-interface-doc 同步 300s;凭证走 Driver 连接槽免密)──
    this.root.querySelectorAll('[data-act="flow-itfdoc"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const dir = btn.dataset.dir;
        const t = (FlowStore.tickets || []).find((x) => x.dir === dir);
        if (!t) return;
        const funcs = (t.objects || []).filter((o) => o.type === 'FUNC' && o.name).map((o) => o.name);
        if (!funcs.length) { _toast('无 FUNC 对象', 'err'); return; }
        FlowStore.itfBusy = dir;
        this.render();
        try {
          const res = await bridge.run('sap-interface-doc', { functions: funcs, system: 'DVP', language: 'ZH' }, { timeoutMs: 300000 });
          // 已剥一层:res.docxPath/res.basename 直接用(r.result||r 双层解包是 BUG,r.ok===false 不可能出现——
          // bridge.run 在 ok:false 时直接 throw)
          // 窄写登记(docxPath 桥端已落 产物目录):artifacts.itf + handoff.itf + stages.itf=done。
          // artifacts/handoff 顶层键整体替换=覆盖既有条目的风险,先带旧值再合并(P1 惯例:前端持旧态)
          const oldArt = t.artifacts || { itf: [], test: [], copies: [] };
          const oldHand = t.handoff || { itf: {}, test: {} };
          const runs = t.stageRuns || {};
          try {
            const c = await bridge.run('delivery-update', { ticket: dir, patch: {
              artifacts: { ...oldArt, itf: [...(oldArt.itf || []), { path: res.docxPath || '', basename: res.basename || funcs.join('-'), at: new Date().toISOString().slice(0, 10), source: 'bridge-direct' }] },
              handoff: { ...oldHand, itf: { functions: funcs, docPath: res.docxPath || '', doneAt: new Date().toISOString().slice(0, 16).replace('T', ' ') } },
              stages: { itf: 'done' },
              stageRuns: { ...runs, itfdoc: [...(runs.itfdoc || []), { channel: 'bridge-direct', at: new Date().toISOString().slice(0, 10), ok: true }] }
            } }, { timeoutMs: 15000 });
            if (c.ok === false) throw new Error(emOf(c));
          } catch (e2) { _toast(`登记回写失败(文档已生成):${e2.message || e2}`, 'err'); }
          _toast(`接口文档完成:${res.basename || funcs.join(',')}${res.docxPath ? ' · ' + res.docxPath : ''}`, 'ok');
          await this.loadTickets();
        } catch (err) {
          _toast(`接口文档失败:${err.message || err}`, 'err');
        }
        FlowStore.itfBusy = null;
        this.render();
      });
    });

    // ── P2:直跑测试(sap-test-report start-analyze→job 轮询;系统 QAS;PRD 拒=闸纪律)──
    this.root.querySelectorAll('[data-act="flow-test"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const dir = btn.dataset.dir;
        const t = (FlowStore.tickets || []).find((x) => x.dir === dir);
        if (!t) return;
        // 闸④前置:最近一轮检查 pass(机器判,delivery-update 同款守门在写侧;读侧再拦一次)
        const checks = Array.isArray(t.checks) ? t.checks : [];
        const last = checks.length ? [...checks].sort((a, b) => (b.round || 0) - (a.round || 0))[0] : null;
        if (!last || last.verdict !== 'pass') {
          _toast('闸④未开:最近一轮检查非 pass。先跑检查(或 ✋登记)再直跑测试;确要带病推进请走 CC 续跑话术并明示豁免', 'err');
          return;
        }
        const sel = this.root.querySelector(`[data-flow-card="${CSS.escape(dir)}"] [data-act="flow-test-obj"]`);
        const val = sel ? String(sel.value || '') : '';
        const [ot, on] = val.split(':');
        if (!on) { _toast('请选测试对象', 'err'); return; }
        FlowStore.testBusy = dir;
        this.render();
        try {
          const sub = await bridge.run('sap-test-report', {
            op: 'start-analyze', objectType: ot === 'FUNC' ? 'FM' : 'PROG', objectName: on, system: 'QAS', extraHint: ''
          }, { timeoutMs: 30000 });
          const jobId = sub.jobId;   // bridge.run 已剥一层;sub.result 双层解包是 BUG
          if (!jobId) throw new Error('未返回 jobId');
          _toast(`测试作业 ${jobId} 已提交(QAS),轮询中…`, 'info');
          // 轮询(done/error 读后即删;上限 30 分钟,间隔 4s——驾驶舱节奏,比命令面板宽松)
          await this._pollTestJob(dir, jobId, 0, `${ot === 'FUNC' ? 'FM' : ot} ${on}`);
        } catch (err) {
          _toast(`测试直跑失败:${err.message || err}`, 'err');
          FlowStore.testBusy = null;
          this.render();
        }
      });
    });
    this.root.querySelectorAll('[data-act="flow-test-obj"]').forEach((sel) =>
      sel.addEventListener('click', (e) => e.stopPropagation()));

    // ── P2:DEF 状态流转(窄写 defects;verified 附带影响面重测提示)──
    this.root.querySelectorAll('[data-act="flow-def-fix"], [data-act="flow-def-verify"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const dir = btn.dataset.dir, defId = btn.dataset.def;
        const toStatus = btn.dataset.act === 'flow-def-fix' ? 'fixed' : 'verified';
        const t = (FlowStore.tickets || []).find((x) => x.dir === dir);
        const defs = Array.isArray(t?.defects) ? t.defects.map((d) =>
          d.id === defId ? { ...d, status: toStatus } : d) : [];
        try {
          const r = await bridge.run('delivery-update', { ticket: dir, patch: { defects: defs } }, { timeoutMs: 15000 });
          if (r.ok === false) throw new Error(emOf(r));
          if (toStatus === 'verified') {
            // 影响面重测提示(定向,不盲目全量):该 DEF 关联 REQ 的用例
            const d = (t.defects || []).find((x) => x.id === defId);
            const reqs = (d && d.req) || [];
            _toast(`${defId} verified。定向重测提示:只重跑 REQ ${reqs.join(',') || '(未关联)'} 的用例`, 'ok', 6000);
          } else {
            _toast(`${defId} → fixed`, 'ok');
          }
          await this.loadTickets();
        } catch (err) { _toast(`DEF 回写失败:${err.message || err}`, 'err'); }
      });
    });

    // 最近轮报告打开(工单内相对路径→绝对)
    this.root.querySelectorAll('[data-act="flow-open-report"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const dir = btn.dataset.dir, p = btn.dataset.p;
        const abs = p.startsWith('0') ? `${dir}\\${p}` : p;
        try { await bridge.run('file-open', { path: abs }, { timeoutMs: 10000 }); _toast('已打开', 'ok'); }
        catch (err) { _toast(`打开失败:${err.message || err}`, 'err'); }
      });
    });
    // 交付物打开(2026-11-04 用户需求:接口文档/测试/检查产物路径可见可点,方便核查对应)。
    // 路径两种:工单内相对(0[1-4]xxx 开头)→拼工单根;绝对路径直开。
    this.root.querySelectorAll('[data-act="flow-open-art"]').forEach((btn) => {
      btn.addEventListener('click', async (e) => {
        e.stopPropagation();
        const dir = btn.dataset.dir, p = btn.dataset.p;
        if (!p) { _toast('该产物只登记了文字说明,没有可打开的路径', 'err'); return; }
        const abs = p.startsWith('0') ? `${dir}\\${p}` : p;
        try { await bridge.run('file-open', { path: abs }, { timeoutMs: 10000 }); _toast('已打开', 'ok'); }
        catch (err) { _toast(`打开失败:${err.message || err}`, 'err'); }
      });
    });
  }

  // 测试作业轮询(P2):done/error 读后即删(_job-poll 协议);stages.test 写回窄写路由。
  async _pollTestJob(dir, jobId, tries, testObj) {
    const MAX_TRIES = 450;   // 4s×450≈30 分钟
    try {
      const st = await bridge.run('sap-test-report-job', { jobId }, { timeoutMs: 15000 });
      const status = st.status;   // 已剥一层:st.result 双层解包是 BUG(同 loadTickets)
      if (status === 'done') {
        // done 载荷字段直接在 st 上(reportId/conclusion/result)
        const reportId = st.reportId || (st.result && st.result.reportId) || '';
        const conc = st.conclusion || (st.result && st.result.conclusion) || '';
        // 窄写:stages.test=done(handoff.test 登记+stageRuns 徽标)+ test 闸④待用户确认(闸本身不自动过)
        const tk = (FlowStore.tickets || []).find((x) => x.dir === dir);
        const runs = (tk && tk.stageRuns) || {};
        await bridge.run('delivery-update', { ticket: dir, patch: {
          stages: { test: 'done' },
          handoff: { test: { target: reportId || testObj || '', mode: '新建测试全自动', reportPath: reportId ? `${reportId}.json` : '', doneAt: new Date().toISOString().slice(0, 16).replace('T', ' '), gatePending: 'gate-test' } },
          stageRuns: { ...runs, test: [...(runs.test || []), { channel: 'bridge-direct', at: new Date().toISOString().slice(0, 10), obj: testObj || '', conclusion: conc || '' }] }
        } }, { timeoutMs: 15000 });
        _toast(`测试完成(${conc || '见报告'})。闸④:报告待你过目确认`, 'ok', 8000);
        FlowStore.testBusy = null;
        await this.loadTickets();
        this.render();
        return;
      }
      if (status === 'error') {
        throw new Error(st.message || st.result?.message || '作业失败');
      }
      if (tries >= MAX_TRIES) { throw new Error('轮询超 30 分钟,放弃(作业可能仍在跑,报告 ID 稍后手动查)'); }
      FlowStore.testPoll = setTimeout(() => this._pollTestJob(dir, jobId, tries + 1), 4000);
    } catch (err) {
      _toast(`测试轮询终止:${err.message || err}`, 'err');
      FlowStore.testBusy = null;
      this.render();
    }
  }
}
