// PW 工作台资产服务端镜像推送(2026-09-03)。
//
// 背景:待办/项目生命周期主数据在前端 IndexedDB,bridge(服务端)拿不到。智能问答
// 新增「PW资产」检索源(apps\bridge\routes\_pwasset-helpers.ps1)读服务端镜像文件,
// 本模块负责把裁剪快照推过去:数据变更后 touchAssetMirror(kind)(防抖合并连发),
// 应用启动时 seedAssetMirrors() 保底推一次,镜像永不为空。
//
// 设计红线:镜像只是问答检索的冗余副本,IndexedDB 原数据不动;fire-and-forget,
// bridge 未起/超限/任何失败一律静默——绝不影响业务链路。
import { bridge } from '../shell/bridge-client.js';

const DEBOUNCE_MS = 3000;   // 四路 sync bulkPut 会连发多次,合并成一次推送
const _timers = {};          // kind -> timer

// 待办裁剪:问答检索只需要进度事实(标题/备注/完成态/截止/来源),不搬业务私有字段
function _trimTodo(t) {
  return {
    id: t.id,
    title: t.title || '',
    note: t.note || '',
    category: t.category || 'work',
    done: !!t.done,
    due: t.due || null,
    completedAt: t.completedAt || null,
    source: t.source || null,
    sourceId: t.sourceId || null,
    updatedAt: t.updatedAt || null
  };
}

// 快照裁剪:取每项目最新 3 条(进度问答只关心近期),不搬 raw 大字段
function _trimSnapshot(s) {
  return {
    capturedAt: s.capturedAt || null,
    progress: s.progress || '',
    issues: s.issues || '',
    plan: s.plan || '',
    status: s.status || '',
    overallPlan: s.overallPlan || '',
    source: s.source || ''
  };
}

// 动态 import 收集(避免与 repositories 的静态循环依赖:repo → 本模块单向)
async function _collect(kind) {
  if (kind === 'todos') {
    const { todos } = await import('./repositories/todos.js');
    const all = await todos.getAll();
    return { syncedAt: new Date().toISOString(), items: all.map(_trimTodo) };
  }
  if (kind === 'lifecycle') {
    const { intlProjects } = await import('./repositories/intl-projects.js');
    const { intlSnapshots } = await import('./repositories/intl-snapshots.js');
    const projects = await intlProjects.all();
    // 2026-09-11 审计 #10:原逐项目 byProject 索引查询(N+1,防抖后一拍 N 个事务)→
    // 单次全量拉取按 projectId 分组;组内按 capturedAt 降序与 byProject 同序,输出一致
    const allSnaps = await intlSnapshots.getAll();
    const byPid = new Map();
    for (const s of allSnaps) {
      const k = s && s.projectId;
      if (!k) continue;
      if (!byPid.has(k)) byPid.set(k, []);
      byPid.get(k).push(s);
    }
    const out = [];
    for (const p of projects) {
      const snaps = (byPid.get(p.id) || []).sort((a, b) => (b.capturedAt || 0) - (a.capturedAt || 0));
      out.push({
        id: p.id,
        name: p.name || '',
        description: p.description || '',
        owner: p.owner || '',
        departments: p.departments || '',
        currentStatus: p.currentStatus || '',
        lastSnapshotAt: p.lastSnapshotAt || null,
        snapshots: snaps.slice(0, 3).map(_trimSnapshot)
      });
    }
    return { syncedAt: new Date().toISOString(), projects: out };
  }
  if (kind === 'recaps') {
    return _collectRecaps();
  }
  throw new Error('unknown asset kind: ' + kind);
}

// 历史日报全量收集(IndexedDB interactions,counterparty='(全天汇总)',一天一条)。
// 口径与 today-todos._collectRecapDays 完全一致:按 timestamp 落桶业务日、同日多条取最新;
// 日期即桶键 yyyy-MM-dd。这是「历史数据回灌」的数据源——服务端归档(9:10 worker)只从
// 部署日起积累,今天以前的天只存在浏览器里。
async function _collectRecaps() {
  const { interactions } = await import('./repositories/interactions.js');
  const recs = await interactions.queryByIndex('by_counterparty', '(全天汇总)');
  const pad2 = v => String(v).padStart(2, '0');
  const byDate = new Map();
  for (const r of (recs || [])) {
    if (!r || !r.timestamp) continue;
    const d = new Date(r.timestamp);
    const key = `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
    const cur = byDate.get(key);
    if (!cur || r.timestamp > cur.timestamp) byDate.set(key, r);
  }
  const days = [...byDate.entries()]
    .sort((a, b) => (a[0] < b[0] ? -1 : 1))
    .map(([date, r]) => ({
      date,
      generatedAt: r.timestamp || null,
      item: {
        topic: r.topic || '',
        notes: r.notes || '',
        byPerson: (r.byPerson || []).map(p => ({ name: p.name, type: p.type, convs: p.convs, timeSpan: p.timeSpan, atMe: p.atMe, mine: p.mine })),
        myTodos: (r.myTodos || []).map(t => ({ title: t.title || '', detail: t.detail || '', sourceConvs: t.sourceConvs || [], quote: t.quote || '' })).filter(t => t.title)
      }
    }));
  return { syncedAt: new Date().toISOString(), days };
}

const RECAP_SIG_KEY = 'pw:asset-recap-sig';
const RECAP_CHUNK = 20;   // 每块天数:单块远小于镜像路由 2MB 上限;历史几十~几百天也只几块

// 历史日报回灌(初始化,只在有「新历史天」时推):启动种子调一次。
// 签名 = 天数+最新日期,localStorage 记忆,与上次相同就跳过——日常启动零成本,
// 只有导入新历史/换浏览器等场景才真正推送。分块 fire-and-forget,失败静默。
function pushRecapMirrorOnce() {
  _collectRecaps().then(payload => {
    const days = payload.days || [];
    if (!days.length) return;
    const sig = days.length + ':' + days[days.length - 1].date;
    let last = null;
    try { last = localStorage.getItem(RECAP_SIG_KEY); } catch (e) { /* 只读场景忽略 */ }
    if (last === sig) return;
    let chain = Promise.resolve();
    for (let i = 0; i < days.length; i += RECAP_CHUNK) {
      const part = days.slice(i, i + RECAP_CHUNK);
      chain = chain.then(() => bridge.run('pw-asset-mirror', { action: 'push-recaps', payload: { syncedAt: payload.syncedAt, days: part } })).catch(() => {});
    }
    chain.then(() => { try { localStorage.setItem(RECAP_SIG_KEY, sig); } catch (e) {} }).catch(() => {});
  }).catch(() => { /* IndexedDB 不可用/bridge 未起:静默 */ });
}

// 数据变更后调用(kind: 'todos' | 'lifecycle')。在 repo 层 put/delete/patch 后挂一行即可。
export function touchAssetMirror(kind) {
  if (_timers[kind]) clearTimeout(_timers[kind]);
  _timers[kind] = setTimeout(() => {
    _timers[kind] = null;
    _collect(kind)
      .then(payload => bridge.run('pw-asset-mirror', { action: 'push', kind, payload }))
      .catch(() => { /* bridge 未起/IndexedDB 空/超限:静默,镜像缺失只影响问答检索 */ });
  }, DEBOUNCE_MS);
}

// 应用启动种子推送(main.js 调一次):用户还没改过数据镜像里也有底,问答探针可用;
// 同时做历史日报回灌初始化(签名去重,只在有新历史天时真正推)
export function seedAssetMirrors() {
  touchAssetMirror('todos');
  touchAssetMirror('lifecycle');
  pushRecapMirrorOnce();
}
