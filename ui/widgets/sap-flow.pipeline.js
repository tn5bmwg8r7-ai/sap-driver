// sap-flow.pipeline.js — 交付流水线节点/通道注册表(v2 融合版,2026-11-04;真源=设计方案-v2-融合.md §3)。
// 节点与通道都是数据,不是代码——加节点/调顺序/暂停/换大脑只改本文件,
// TAB 渲染/调度/回写全按表自适应,零组件改动。
//
// ── 拓展操作手册 ─────────────────────────────────────────────
// · 加节点:FLOW_NODES 插入对象 + delivery.json stages 加同 id 键(conventions 升版同步)
// · 调顺序:改 seq,其他不动
// · 暂停节点:enabled:false(显示灰「预留」,不算跳过)
// · 节点加通道:channels 数组加通道 id(通道实现在 FLOW_CHANNELS 注册)
// · 禁区:节点 id 一经使用不改名(历史工单 stages 键靠它对齐);已投产工单不回填
//   新节点(stages 缺键=未启用时代的单,渲染「—」不算失败)
// ────────────────────────────────────────────────────────────

// 节点注册表(seq 即交付先后顺序;gate=完成后的人工闸;repeatable=可重复执行)
export const FLOW_NODES = [
  { id: 'intake', seq: 1, name: '接单', icon: '📥', kind: 'manual-or-ai',
    desc: 'BPM 待办捕获(单号/传输号/成果程序名)或纯文字;建工单+requirement 草稿。',
    channels: ['pw-form', 'cc', 'qianwen', 'workbuddy'],
    gate: null },
  { id: 'clarify', seq: 2, name: '澄清', icon: '❓', kind: 'ai-or-hand',
    desc: '歧义清单→答复回收;ambiguity 有 open 项=不得进评审(v3 契约:带着歧义开工是返工主因)。',
    channels: ['cc', 'qianwen', 'workbuddy', 'by-hand'],
    gate: null },
  { id: 'eval', seq: 3, name: '评审', icon: '📋', kind: 'ai-only',
    desc: '现状取证+方案比选+人天风险;每条 REQ 的策略映射(review.strategies);验收要点编号化。',
    channels: ['cc', 'qianwen', 'workbuddy', 'by-hand'],
    gate: 'gate-eval' },
  { id: 'dev', seq: 4, name: '开发', icon: '🛠️', kind: 'ai-or-hand',
    desc: 'ABAP 生成(CC)或 SE80 手写;对象登记 objects[];代码单元标注服务哪条 REQ。',
    channels: ['cc', 'qianwen', 'workbuddy', 'by-hand'],
    gate: 'gate-list' },
  { id: 'check', seq: 5, name: '检查', icon: '🔬', kind: 'ai-repeatable',
    desc: '三道:静态(DevGate/语法/读回,PW 直跑)+语义(REQ×代码覆盖,大脑)+运行(测试道承担);每轮 checks[] 追加,DEF 对象闭环,可重复。',
    channels: ['bridge-direct', 'cc', 'qianwen', 'workbuddy', 'by-hand'],
    gate: null, repeatable: true },
  { id: 'itfdoc', seq: 6, name: '接口文档', icon: '📑', kind: 'auto-or-hand',
    desc: 'FUNC 对象自动生成(bridge 直跑);无接口对象自动 skipped;软闸=定稿。',
    channels: ['bridge-direct', 'cc', 'by-hand'],
    gate: null, softGate: 'S-接口文档定稿',
    autoSkip: (o) => !(o || []).some((x) => x.type === 'FUNC') },
  { id: 'test', seq: 6.5, name: '测试', icon: '🧪', kind: 'auto-or-hand',
    desc: '用例从验收标准生成(一验收≥1正例+1反例);QAS 真跑(bridge 直跑);DEF 修复只重跑受影响用例;闸④。',
    channels: ['bridge-direct', 'cc', 'by-hand'],
    gate: 'gate-test' },
  { id: 'accept', seq: 7, name: '上线验收', icon: '✅', kind: 'manual',
    desc: '预留:业务验收单登记。启用改 enabled:true。',
    channels: ['by-hand'],
    gate: null, enabled: false },
  { id: 'deliver', seq: 8, name: '交付', icon: '🚀', kind: 'auto',
    desc: '覆盖矩阵有空格=只能 blocked 不得 delivered;交付小结+闸⑤;GOAL 记账;待办回写提议。',
    channels: ['bridge-direct', 'cc'],
    gate: 'gate-deliver' },
];

// 人工闸登记(闸挂节点不挂通道——换大脑安全的根;H 硬闸永不预授权,v3 契约)
export const FLOW_GATES = {
  'gate-eval':    { level: 'H', label: '闸① 评估认可', hint: '评估文档过目后认可' },
  'gate-list':    { level: 'H', label: '闸② LIST获批', hint: '对象清单批准后才建' },
  'gate-tr':      { level: 'H', label: '闸③ trkorr现给', hint: 'TR 号现给+E070 验真(dev 节点内)' },
  'gate-test':    { level: 'H', label: '闸④ 测试确认', hint: '测试报告过目;前置=最近一轮检查 pass' },
  'gate-deliver': { level: 'H', label: '闸⑤ 交付确认', hint: '交付小结确认后 delivered' },
};

// 执行通道注册表(大脑是插件;CC 退场=删 'cc' 项+各节点 channels 去引用,其余零改动)
export const FLOW_CHANNELS = {
  'bridge-direct': { label: 'Bridge直跑', icon: '⚙️', kind: 'auto', run: 'bridgeRoute' },
  'cc':        { label: 'Claude Code', icon: '🤝', kind: 'ai', run: 'handoffPhrase',
                 note: 'sap-flow / sap-review / sap-build' },
  'qianwen':   { label: '千问', icon: '🔵', kind: 'ai', run: 'handoffPhrase', note: '预留,通道细节待定' },
  'workbuddy': { label: 'WORKBUDDY', icon: '🔷', kind: 'ai', run: 'handoffPhrase', note: '预留' },
  'pw-form':   { label: 'PW表单', icon: '📝', kind: 'manual', run: 'formDialog' },
  'by-hand':   { label: '我自己干', icon: '✋', kind: 'manual', run: 'registerDialog' },
};

// 阶段取值口径(v3:与 delivery.json stages 键值对齐;+blocked)
export const STAGE_STATES = {
  pending: { dot: '○', label: '未开始' },
  doing:   { dot: '◐', label: '进行中' },
  done:    { dot: '●', label: '完成' },
  skipped: { dot: '◌', label: '跳过' },
  blocked: { dot: '⛔', label: '阻塞' },
};

// 旧工单(v1/v2 时代)stages 只有 eval/dev/itf/test 四键,新节点缺键。
// 时代映射(2026-11-04 实测:"下一步全是接单(null)"根因):缺键节点按相邻已落键推断——
// intake/clarify 缺键但 eval 有值 → 接单/澄清必然已过(评审都做了不可能没接单);
// check 缺键 → 按 schema 判断(v3 单=还没跑;v1/v2 旧单=该时代无此节点,渲染 — 不算 pending);
// itfdoc 缺键 → 旧键名 itf 的值就是它;deliver 缺键 → 由 status 推断(delivered=done 其余=pending)。
export function nodeState(ticket, node) {
  if (node.enabled === false) return 'reserved';
  if (node.autoSkip && node.autoSkip(ticket.objects)) return 'skipped';
  const st = ticket.stages || {};
  const legacy = !('check' in st) && !('intake' in st);   // v1/v2 旧单指纹:新节点键全缺
  const s = st[node.id];
  if (s !== undefined && s !== null) return s;
  // 新键缺 → 按节点类型推断
  if (node.id === 'intake' || node.id === 'clarify') {
    // 评审已动 = 接单/澄清已过;全空 = 整单还没走(真 pending)
    const started = ['eval', 'dev', 'itf', 'test'].some((k) => st[k] && st[k] !== 'pending');
    return started ? 'done' : 'pending';
  }
  if (node.id === 'check') return legacy ? null : 'pending';   // 旧单时代无检查节点 → 「—」
  if (node.id === 'itfdoc') return st.itf !== undefined ? st.itf : 'pending';   // 旧键名 itf 映射
  if (node.id === 'deliver') return ticket.status === 'delivered' ? 'done' : 'pending';
  return 'pending';
}

// 下一步提示:第一个可推进节点(非 done/skipped/reserved/null;blocked/doing/pending 都算"卡在这")
export function nextNode(ticket) {
  const sorted = [...FLOW_NODES].sort((a, b) => a.seq - b.seq);
  for (const n of sorted) {
    const st = nodeState(ticket, n);
    if (st !== 'done' && st !== 'skipped' && st !== 'reserved' && st !== null) return { node: n, state: st };
  }
  return null;
}
