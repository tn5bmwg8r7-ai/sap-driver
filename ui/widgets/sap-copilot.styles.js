// sap-copilot.styles.js — SAP Driver 视觉样式单点(2026-10-30 外置;2026-11-04 v2 UI 重做)。
// 设计令牌对齐 theme/tokens.css:indigo 主调/slate 中性/绿-琥珀-红语义三色;暗色自动适配。
// v2 升级(2026-11-04 用户需求"页面太规矩,弄好看点"):渐变 hero/玻璃拟态状态条/
// 胶囊页签带品牌渐变高亮/卡片 hover 浮起/交付区专属视觉语言。
export const STYLES = `
  /* 底层亚麻色(2026-11-04 用户需求:浅灰/亚麻底)。亮=亚麻暖白,暗=暖黑;
     硬编码色对(非令牌)是因为 PW 全局令牌无暖灰档,且只影响本 widget 不外溢 */
  .sapc { display:flex; flex-direction:column; height:100%; gap:12px; color:var(--sd-text);
    background:#f6f5f1; border-radius:var(--sd-radius-lg); }
  .sapc * { box-sizing:border-box; }
  @media (prefers-color-scheme: dark) {
    .sapc { background:#15181e; }
  }
  .sapc button { cursor:pointer; border:1px solid var(--sd-border); border-radius:var(--sd-radius-md);
    padding:5px 13px; font-size:12.5px; background:var(--sd-button-bg); color:var(--sd-text);
    transition:all var(--sd-dur) var(--sd-ease); }
  .sapc button:hover { border-color:var(--sd-accent); color:var(--sd-accent); background:var(--sd-accent-softer);
    transform:translateY(-1px); }
  .sapc button:disabled { opacity:.5; cursor:wait; transform:none; }
  .sapc button.primary { background:linear-gradient(135deg, var(--sd-accent), var(--sd-accent-hover));
    border:none; color:#fff; font-weight:600; box-shadow:0 2px 8px rgba(99,102,241,.35); }
  .sapc button.primary:hover { background:linear-gradient(135deg, var(--sd-accent-hover), var(--sd-accent-active));
    color:#fff; box-shadow:0 4px 14px rgba(99,102,241,.45); transform:translateY(-1px); }

  /* ---- 状态条(玻璃质感) ---- */
  .sapc-status { display:flex; align-items:center; gap:10px; flex-wrap:wrap; padding:9px 16px;
    border:1px solid var(--sd-accent-border); border-radius:var(--sd-radius-lg);
    background:linear-gradient(180deg, var(--sd-accent-softer), var(--sd-panel-bg));
    box-shadow:var(--sd-shadow-xs); }
  .sapc-chip { display:inline-flex; align-items:center; gap:6px; padding:3px 12px; border-radius:var(--sd-radius-full);
    font-size:12px; border:1px solid var(--sd-border); color:var(--sd-text-muted); background:var(--sd-panel-bg); }
  .sapc-chip.on { background:var(--sd-success-soft); border-color:transparent; color:var(--sd-success-text); }
  .sapc-chip.prod { background:var(--sd-warning-soft); border-color:transparent; color:var(--sd-warning-text); }
  .sapc-chip.clickable { cursor:pointer; transition:border-color var(--sd-dur) var(--sd-ease); }
  .sapc-chip.clickable:hover { border-color:var(--sd-accent); color:var(--sd-accent); }
  .sapc-chip.clickable:not(.on):hover { background:var(--sd-danger-soft); color:var(--sd-danger-text); border-color:transparent; }
  .sapc-dot { width:8px; height:8px; border-radius:50%; background:var(--sd-text-faint); }
  .sapc-chip.on .sapc-dot { background:var(--sd-success); box-shadow:0 0 0 3px var(--sd-success-soft); }
  .sapc-chip.prod .sapc-dot { background:var(--sd-warning); box-shadow:0 0 0 3px var(--sd-warning-soft); }
  .sapc-audit { font-size:12px; color:var(--sd-text-muted); }
  .sapc-audit b { color:var(--sd-text); }
  .sapc-sep { width:1px; height:16px; background:var(--sd-border); }
  .sapc-spacer { flex:1; }

  /* ---- 页签(胶囊 + 渐变激活;v2.1 活泼版:每个页签一个主题色) ---- */
  .sapc-tabs { display:flex; gap:4px; background:var(--sd-tag-bg); padding:3px; border-radius:var(--sd-radius-full); width:max-content; }
  .sapc-tabs button { border:none; background:transparent; border-radius:var(--sd-radius-full);
    padding:4px 16px; font-size:12.5px; color:var(--sd-text-muted); transition:all var(--sd-dur) var(--sd-ease); }
  .sapc-tabs button:hover { color:var(--sd-text); background:var(--sd-panel-bg); transform:translateY(-1px); }
  .sapc-tabs button.active { color:#fff; font-weight:600; box-shadow:0 2px 6px rgba(15,23,42,.18); }
  .sapc-tabs button[data-tab="ask"].active { background:linear-gradient(135deg, #6366f1, #8b5cf6); }
  .sapc-tabs button[data-tab="flow"].active { background:linear-gradient(135deg, #0ea5e9, #06b6d4); box-shadow:0 2px 8px rgba(14,165,233,.4); }
  .sapc-tabs button[data-tab="probe"].active { background:linear-gradient(135deg, #f59e0b, #f97316); box-shadow:0 2px 8px rgba(245,158,11,.4); }
  .sapc-tabs button[data-tab="diagpk"].active { background:linear-gradient(135deg, #10b981, #14b8a6); box-shadow:0 2px 8px rgba(16,185,129,.4); }
  .sapc-tabs button[data-tab="wk"].active { background:linear-gradient(135deg, #ec4899, #f43f5e); box-shadow:0 2px 8px rgba(236,72,153,.4); }
  .sapc-tabs button[data-tab="artifacts"].active { background:linear-gradient(135deg, #8b5cf6, #a855f7); box-shadow:0 2px 8px rgba(139,92,246,.4); }
  .sapc-tabs button[data-tab="catalog"].active { background:linear-gradient(135deg, #6366f1, #0ea5e9); box-shadow:0 2px 8px rgba(99,102,241,.4); }
  .sapc-tabs button[data-tab="timeline"].active { background:linear-gradient(135deg, #64748b, #475569); }

  .sapc-body { flex:1; overflow:auto; min-height:0; padding:2px; }

  /* ---- Agent Harness hero(渐变品牌卡) ---- */
  .sapc-hero { border:1px solid var(--sd-accent-border); border-radius:var(--sd-radius-lg);
    padding:18px 20px; background:var(--sd-panel-bg);
    background-image:radial-gradient(120% 140% at 0% 0%, var(--sd-accent-softer) 0%, transparent 55%);
    box-shadow:var(--sd-shadow-sm); }
  .sapc-hero .h-title { font-size:15px; font-weight:700; color:var(--sd-text-strong);
    display:flex; align-items:center; gap:8px; }
  .sapc-hero .h-title::before { content:''; width:4px; height:15px; border-radius:2px;
    background:linear-gradient(180deg, var(--sd-accent), var(--sd-accent-hover)); }
  .sapc-hero .h-sub { font-size:12px; color:var(--sd-text-muted); margin:5px 0 12px; }
  .sapc-hero textarea { width:100%; min-height:64px; resize:vertical; font-size:13.5px; font-family:inherit;
    line-height:1.6; padding:10px 12px; border:1.5px solid var(--sd-border-strong); border-radius:var(--sd-radius-md);
    outline:none; background:var(--sd-input-bg); color:var(--sd-text); transition:border-color var(--sd-dur) var(--sd-ease); }
  .sapc-hero textarea:focus { border-color:var(--sd-accent);
    box-shadow:0 0 0 3px var(--sd-accent-soft); }
  .sapc-hero .h-actions { display:flex; gap:10px; margin-top:10px; align-items:center; flex-wrap:wrap; }
  .sapc-hero select { padding:5px 9px; border:1px solid var(--sd-border-strong); border-radius:var(--sd-radius-sm);
    font-size:12.5px; background:var(--sd-input-bg); color:var(--sd-text); }
  .sapc-hero .h-ask { padding:7px 26px; font-size:13.5px; font-weight:600; border-radius:var(--sd-radius-md); }
  .sapc-hero .h-enter { font-size:11.5px; color:var(--sd-text-faint); }
  .sapc-presets { display:flex; gap:7px; flex-wrap:wrap; margin-top:12px; padding-top:11px;
    border-top:1px dashed var(--sd-border); }
  .sapc-presets .p-label { font-size:11.5px; color:var(--sd-text-faint); align-self:center; }
  .sapc-presets button { font-size:11.5px; padding:3px 11px; border-radius:var(--sd-radius-full);
    background:var(--sd-accent-softer); border-color:transparent; color:var(--sd-accent); }
  .sapc-presets button:hover { background:var(--sd-accent-soft); border-color:var(--sd-accent-border); }

  /* ---- 回答区 ---- */
  .sapc-answer { margin-top:12px; border:1px solid var(--sd-border); border-radius:var(--sd-radius-lg);
    background:var(--sd-panel-bg); padding:14px 16px; box-shadow:var(--sd-shadow-xs); }
  .sapc-answer .a-meta { display:flex; gap:12px; flex-wrap:wrap; font-size:11.5px; color:var(--sd-text-faint);
    margin-bottom:10px; padding-bottom:9px; border-bottom:1px solid var(--sd-border); align-items:center; }
  .sapc-answer .md { font-size:13px; line-height:1.7; color:var(--sd-text); }
  .sapc-answer .md h1,.sapc-answer .md h2 { font-size:14.5px; margin:12px 0 6px; color:var(--sd-text-strong); }
  .sapc-answer .md h3,.sapc-answer .md h4 { font-size:13.5px; margin:10px 0 5px; color:var(--sd-text-strong); }
  .sapc-answer .md table { border-collapse:collapse; font-size:12px; margin:9px 0; width:100%; }
  .sapc-answer .md th,.sapc-answer .md td { border:1px solid var(--sd-border); padding:5px 9px; text-align:left; }
  .sapc-answer .md th { background:var(--sd-accent-softer); color:var(--sd-text-strong); font-weight:600; }
  .sapc-answer .md code { background:var(--sd-accent-soft); padding:1px 5px; border-radius:4px;
    font-size:12px; color:var(--sd-accent-active); }
  .sapc-answer .md pre { background:var(--sd-code-bg); border:1px solid var(--sd-border); padding:10px;
    border-radius:var(--sd-radius-md); overflow:auto; font-size:11.5px; max-height:340px; }
  .sapc-answer .md blockquote { border-left:3px solid var(--sd-accent-border); margin:8px 0;
    padding:2px 12px; color:var(--sd-text-muted); }

  .sapc-steps { display:flex; gap:7px; flex-wrap:wrap; margin-top:12px; padding-top:11px;
    border-top:1px dashed var(--sd-border); }
  .sapc-steps .s-label { font-size:11.5px; color:var(--sd-text-faint); align-self:center; }
  .sapc-step { display:inline-flex; align-items:center; gap:6px; font-size:11.5px; padding:3px 11px;
    border-radius:var(--sd-radius-full); border:1px solid var(--sd-border); cursor:pointer;
    background:var(--sd-panel-bg); color:var(--sd-text-muted); transition:all var(--sd-dur) var(--sd-ease); }
  .sapc-step:hover { border-color:var(--sd-accent); color:var(--sd-accent); }
  .sapc-step .no { font-weight:700; color:var(--sd-accent); }
  .sapc-step.ok { background:var(--sd-success-soft); border-color:transparent; color:var(--sd-success-text); }
  .sapc-step.ok .no { color:var(--sd-success-text); }
  .sapc-step.fail { background:var(--sd-danger-soft); border-color:transparent; color:var(--sd-danger-text); }
  .sapc-step.fail .no { color:var(--sd-danger-text); }
  .sapc-stepdetail { margin-top:9px; }
  .sapc-stepdetail pre { max-height:300px; overflow:auto; font-size:11.5px; background:var(--sd-code-bg);
    border:1px solid var(--sd-border); padding:10px; border-radius:var(--sd-radius-md);
    white-space:pre-wrap; word-break:break-all; }

  .sapc-loading { padding:26px; text-align:center; color:var(--sd-text-muted); font-size:13px; }
  .sapc-loading .spin { display:inline-block; width:18px; height:18px; border:2.5px solid var(--sd-accent-border);
    border-top-color:var(--sd-accent); border-radius:50%; animation:sapc-spin .8s linear infinite; vertical-align:-4px; margin-right:8px; }
  @keyframes sapc-spin { to { transform:rotate(360deg); } }
  .sapc-loading .ph { margin-top:8px; font-size:12px; color:var(--sd-text-faint); }

  /* ---- 连接管理 ---- */
  .sapc-connect { border:1px solid var(--sd-accent-border); border-radius:var(--sd-radius-lg);
    padding:12px 14px; background:var(--sd-panel-bg); box-shadow:var(--sd-shadow-xs);
    display:flex; flex-direction:column; gap:9px; }
  .sapc-connect .row { display:flex; align-items:center; gap:9px; font-size:12.5px; flex-wrap:wrap; }
  .sapc-connect .sysname { width:44px; font-weight:700; color:var(--sd-text-strong); }
  .sapc-connect .rowstat { display:inline-flex; align-items:center; width:64px; font-size:11.5px;
    font-weight:600; color:var(--sd-text-faint); }
  .sapc-connect .rowstat.on { color:var(--sd-success-text); }
  .sapc-connect input,.sapc-connect select { padding:4px 9px; border:1px solid var(--sd-border-strong); border-radius:var(--sd-radius-sm);
    font-size:12.5px; background:var(--sd-input-bg); color:var(--sd-text); }
  .sapc-connect input:focus,.sapc-connect select:focus { outline:none; border-color:var(--sd-accent); box-shadow:0 0 0 3px var(--sd-accent-soft); }
  .sapc-hint { font-size:11.5px; color:var(--sd-text-faint); }

  /* ---- 能力目录 ---- */
  .sapc-cat > .cat-title { font-size:13px; font-weight:700; color:var(--sd-text-strong);
    margin:16px 2px 8px; display:flex; align-items:center; gap:7px; }
  .sapc-cat:first-child > .cat-title { margin-top:4px; }
  .sapc-cards { display:grid; grid-template-columns:repeat(auto-fill, minmax(240px,1fr)); gap:10px; }
  .sapc-card { border:1px solid var(--sd-border); border-radius:var(--sd-radius-lg); padding:10px 12px;
    cursor:pointer; background:var(--sd-panel-bg); transition:all var(--sd-dur) var(--sd-ease); }
  .sapc-card:hover { border-color:var(--sd-accent-border); transform:translateY(-1px); box-shadow:var(--sd-shadow-md); }
  .sapc-card.planned { opacity:.6; background:transparent; border-style:dashed; box-shadow:none; }
  .sapc-card.planned:hover { transform:none; border-color:var(--sd-border-strong); }
  .sapc-card .c-name { font-size:13px; font-weight:600; color:var(--sd-text-strong);
    display:flex; gap:8px; align-items:center; }
  .sapc-card .tile { width:27px; height:27px; border-radius:var(--sd-radius-sm); background:var(--sd-accent-soft);
    display:inline-flex; align-items:center; justify-content:center; font-size:14px; flex:none; }
  .sapc-card.planned .tile { background:var(--sd-tag-bg); }
  .sapc-card.cc .tile { background:var(--sd-tag-bg); }
  .sapc-card .c-desc { font-size:11.5px; color:var(--sd-text-muted); margin-top:6px; line-height:1.55; }
  .sapc-card .c-tags { margin-top:7px; display:flex; gap:5px; flex-wrap:wrap; }
  .sapc-tag { font-size:10.5px; padding:1px 8px; border-radius:var(--sd-radius-full);
    background:var(--sd-tag-bg); color:var(--sd-text-muted); border:none; }
  .sapc-tag.acc { background:var(--sd-accent-soft); color:var(--sd-accent-active); }
  .sapc-detail { margin-top:10px; border-top:1px dashed var(--sd-border); padding-top:10px; }
  .sapc-detail textarea { width:100%; min-height:110px; font-family:Consolas,monospace; font-size:12px;
    padding:8px 10px; border:1px solid var(--sd-border-strong); border-radius:var(--sd-radius-md);
    background:var(--sd-input-bg); color:var(--sd-text); }
  .sapc-detail textarea:focus { outline:none; border-color:var(--sd-accent); }
  .sapc-detail pre { max-height:300px; overflow:auto; font-size:11.5px; background:var(--sd-code-bg);
    border:1px solid var(--sd-border); padding:10px; border-radius:var(--sd-radius-md);
    white-space:pre-wrap; word-break:break-all; color:var(--sd-text); }
  .sapc-detail .actions { display:flex; gap:8px; margin-top:8px; align-items:center; }
  /* 一站式交付卡(2026-11-04 P3):BPM 待办下拉 + 接单话术 */
  .sapc-flow-row { display:flex; gap:8px; align-items:center; }
  .sapc-flow-select { flex:1; min-width:0; font-size:12px; padding:7px 9px;
    border:1px solid var(--sd-border-strong); border-radius:var(--sd-radius-md);
    background:var(--sd-input-bg); color:var(--sd-text); }
  .sapc-flow-select:focus { outline:none; border-color:var(--sd-accent); }

  /* ---- 时间线 ---- */
  .sapc-tl table { width:100%; border-collapse:collapse; font-size:12px; }
  .sapc-tl th { text-align:left; padding:6px 10px; color:var(--sd-text-faint); font-weight:600;
    font-size:11px; letter-spacing:.04em; border-bottom:1px solid var(--sd-border-strong); }
  .sapc-tl td { text-align:left; padding:5px 10px; border-bottom:1px solid var(--sd-border); color:var(--sd-text); }
  .sapc-tl tbody tr:nth-child(even) { background:var(--sd-hover-bg); }
  .sapc-tl td.num, .sapc-tl th.num { text-align:right; font-variant-numeric:tabular-nums; }
  .res-ok { color:var(--sd-success-text); } .res-error { color:var(--sd-danger-text); } .res-denied { color:var(--sd-warning-text); }
  .ch-mcp { color:var(--sd-text-faint); } .ch-pw { color:var(--sd-accent); font-weight:600; }
  .sapc-empty { padding:26px; text-align:center; color:var(--sd-text-faint); font-size:13px; }

  /* ---- 今日动态条(Agent Harness主页) ---- */
  .sapc-recent { margin-top:12px; border:1px solid var(--sd-border); border-radius:var(--sd-radius-lg);
    background:var(--sd-panel-bg); padding:10px 14px; box-shadow:var(--sd-shadow-xs); }
  .sapc-recent .rc-head { display:flex; align-items:center; justify-content:space-between;
    font-size:12.5px; font-weight:600; color:var(--sd-text-strong); margin-bottom:6px; }
  .sapc-recent .rc-head button { font-size:11.5px; padding:2px 10px; border-radius:var(--sd-radius-full); }
  .sapc-recent .rc-row { display:flex; gap:10px; align-items:center; font-size:11.5px;
    padding:3px 0; color:var(--sd-text-muted); }
  .sapc-recent .rc-row + .rc-row { border-top:1px dashed var(--sd-border); }
  .sapc-recent .rc-t { color:var(--sd-text-faint); font-variant-numeric:tabular-nums; }
  .sapc-recent .rc-tool { color:var(--sd-text); min-width:130px; }
  .sapc-recent .rc-sys { min-width:36px; }
  .sapc-recent .rc-ms { margin-left:auto; font-variant-numeric:tabular-nums; color:var(--sd-text-faint); }

  /* ---- 轮次条(v6) ---- */
  .sapc-rounds { display:flex; gap:6px; align-items:center; flex-wrap:wrap; margin-top:10px;
    padding-top:10px; border-top:1px dashed var(--sd-border); }
  .sapc-rounds .rt { font-size:11.5px; padding:2px 11px; border-radius:var(--sd-radius-full); min-width:30px; }
  .sapc-rounds .rt.active { background:var(--sd-accent-soft); border-color:var(--sd-accent-border);
    color:var(--sd-accent); font-weight:700; }

  /* ---- 产物区(v5,2026-09-14) ---- */
  .sapc-art { padding:4px 2px; }
  .sapc-art .art-bar { display:flex; gap:9px; align-items:center; flex-wrap:wrap; margin-bottom:10px; }
  .sapc-art .art-chip { font-size:11.5px; padding:3px 12px; border-radius:var(--sd-radius-full);
    border:1px solid var(--sd-border); background:transparent; color:var(--sd-text-muted); }
  .sapc-art .art-chip.active { background:var(--sd-accent-soft); border-color:var(--sd-accent-border); color:var(--sd-accent); font-weight:600; }
  .sapc-art .art-q { padding:5px 11px; border:1px solid var(--sd-border-strong); border-radius:var(--sd-radius-sm);
    font-size:12.5px; background:var(--sd-input-bg); color:var(--sd-text); width:200px; }
  .sapc-art .art-q:focus { outline:none; border-color:var(--sd-accent); box-shadow:0 0 0 3px var(--sd-accent-soft); }
  .sapc-art .art-name { max-width:0; width:52%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .sapc-art td.op button { font-size:11.5px; padding:2px 10px; }

  /* ---- 🧪 函数排查(v7,2026-09-14)---- */
  .sapc-probe { padding:4px 2px; display:flex; flex-direction:column; gap:10px; }
  .sapc-probe .pb-bar { display:flex; gap:9px; align-items:center; flex-wrap:wrap; }
  .sapc-probe select, .sapc-probe .pb-bar input { padding:5px 9px; border:1px solid var(--sd-border-strong);
    border-radius:var(--sd-radius-sm); font-size:12.5px; background:var(--sd-input-bg); color:var(--sd-text); }
  .sapc-probe select:focus, .sapc-probe input:focus, .sapc-probe textarea:focus {
    outline:none; border-color:var(--sd-accent); box-shadow:0 0 0 3px var(--sd-accent-soft); }
  .sapc-probe .pb-card { border:1px solid var(--sd-border); border-radius:var(--sd-radius-lg);
    background:var(--sd-panel-bg); padding:11px 13px; box-shadow:var(--sd-shadow-xs); }
  .sapc-probe .pb-card .pb-title { font-size:12.5px; font-weight:700; color:var(--sd-text-strong);
    margin-bottom:8px; display:flex; align-items:center; gap:8px; }
  .sapc-probe .pb-card .pb-title .sub { font-weight:400; font-size:11.5px; color:var(--sd-text-faint); }
  .sapc-probe .imp-row { display:flex; gap:8px; align-items:center; margin:5px 0; }
  .sapc-probe .imp-row .k { font-family:Consolas,monospace; font-size:12px; color:var(--sd-text-strong);
    width:210px; flex:none; overflow:hidden; text-overflow:ellipsis; }
  .sapc-probe .imp-row input { flex:1; min-width:0; padding:4px 9px; border:1px solid var(--sd-border-strong);
    border-radius:var(--sd-radius-sm); font-size:12.5px; background:var(--sd-input-bg); color:var(--sd-text); }
  .sapc-probe textarea.pb-json { width:100%; min-height:74px; font-family:Consolas,monospace; font-size:11.5px;
    padding:7px 9px; border:1px solid var(--sd-border-strong); border-radius:var(--sd-radius-md);
    background:var(--sd-input-bg); color:var(--sd-text); resize:vertical; }
  .sapc-probe textarea.pb-payload { min-height:88px; }
  .sapc-probe .pb-sets { font-size:12px; }
  .sapc-probe .pb-sets .set-row { display:flex; gap:9px; align-items:center; padding:4px 2px;
    border-bottom:1px dashed var(--sd-border); }
  .sapc-probe .pb-sets .set-row:last-child { border-bottom:none; }
  .sapc-probe .pb-sets .set-name { font-family:Consolas,monospace; color:var(--sd-accent-active); min-width:120px; }
  .sapc-probe .pb-sets .set-meta { color:var(--sd-text-faint); font-size:11px; flex:1; overflow:hidden;
    text-overflow:ellipsis; white-space:nowrap; }
  .sapc-probe .res-kv { display:flex; gap:10px; font-size:12.5px; padding:3px 0; }
  .sapc-probe .res-kv .k { font-family:Consolas,monospace; color:var(--sd-text-strong); min-width:170px; max-width:260px;
    overflow:hidden; text-overflow:ellipsis; flex:none; }
  .sapc-probe .res-kv .v { font-family:Consolas,monospace; word-break:break-all; color:var(--sd-text); }
  .sapc-probe .res-tbl { border-collapse:collapse; font-size:11.5px; margin:5px 0 9px; width:100%; }
  .sapc-probe .res-tbl th, .sapc-probe .res-tbl td { border:1px solid var(--sd-border); padding:4px 8px; text-align:left; }
  .sapc-probe .res-tbl th { background:var(--sd-accent-softer); color:var(--sd-text-strong); font-weight:600; }
  .sapc-probe .res-tbl tbody tr:nth-child(even) { background:var(--sd-hover-bg); }
  .sapc-probe .res-sec { font-size:12px; font-weight:700; color:var(--sd-text-strong); margin:10px 0 4px; }
  .sapc-probe .pb-err { border:1px solid var(--sd-danger-border, var(--sd-border)); background:var(--sd-danger-soft);
    color:var(--sd-danger-text); border-radius:var(--sd-radius-md); padding:9px 12px; font-size:12.5px;
    display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
  /* 🔍 诊断卡(v8) */
  .sapc-diag { border-left:3px solid var(--sd-accent); }
  .diag-badge { font-size:12px; font-weight:700; padding:2px 10px; border-radius:999px; }
  .diag-badge.uniq { background:var(--sd-success-soft); color:var(--sd-success-text); }
  .diag-badge.amb { background:var(--sd-accent-soft); color:var(--sd-text-strong); }
  .sapc-diag .md { font-size:13px; line-height:1.7; color:var(--sd-text); }
  .sapc-diag .md h1,.sapc-diag .md h2 { font-size:14.5px; margin:12px 0 6px; color:var(--sd-text-strong); }
  .sapc-diag .md h3,.sapc-diag .md h4 { font-size:13.5px; margin:10px 0 5px; color:var(--sd-text-strong); }
  .sapc-diag .md table { border-collapse:collapse; font-size:12px; margin:9px 0; width:100%; }
  .sapc-diag .md th,.sapc-diag .md td { border:1px solid var(--sd-border); padding:5px 9px; text-align:left; }
  .sapc-diag .md th { background:var(--sd-accent-softer); color:var(--sd-text-strong); font-weight:600; }
  .sapc-diag .md code { background:var(--sd-accent-soft); padding:1px 5px; border-radius:4px; }
  .sapc-diag .md pre { background:var(--sd-code-bg); border:1px solid var(--sd-border); padding:10px; border-radius:var(--sd-radius-md); overflow:auto; }
  /* ---- v12 引用影响分析树 ---- */
  .xref-sum { display:flex; flex-wrap:wrap; gap:8px; align-items:center; margin:2px 0 10px; }
  .xref-sum input { padding:3px 10px; border:1px solid var(--sd-border-strong); border-radius:999px;
    font-size:11.5px; background:var(--sd-input-bg); color:var(--sd-text); width:170px; }
  .xref-prog { border:1px solid var(--sd-border); border-radius:8px; margin:6px 0; overflow:hidden; }
  .xref-prog-hd { display:flex; gap:8px; align-items:center; padding:6px 10px; cursor:pointer;
    background:var(--sd-hover-bg); }
  .xref-prog-hd:hover { background:var(--sd-accent-soft); }
  .xref-tw { color:var(--sd-text-faint); font-size:11px; width:10px; flex:none; }
  .xref-pn { font-weight:700; font-family:Consolas,monospace; font-size:12.5px; color:var(--sd-text-strong); }
  .xref-pt { color:var(--sd-text-faint); font-size:11.5px; flex:1; min-width:0;
    overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .xref-badge { font-size:10px; padding:1px 7px; border-radius:999px; background:var(--sd-accent-soft);
    color:var(--sd-accent-active); font-weight:700; flex:none; }
  .xref-badge.std { background:var(--sd-tag-bg); color:var(--sd-text-muted); font-weight:400; }
  .xref-meta { font-size:11px; color:var(--sd-text-faint); white-space:nowrap; }
  .xref-incs { border-top:1px dashed var(--sd-border); }
  .xref-inc { display:flex; gap:8px; align-items:center; padding:4px 10px 4px 24px;
    border-bottom:1px dashed var(--sd-border); font-size:11.5px; flex-wrap:wrap; }
  .xref-inc:last-child { border-bottom:none; }
  .xref-in { font-family:Consolas,monospace; color:var(--sd-accent-active); }
  .xref-it { color:var(--sd-text-faint); flex:1; min-width:60px; overflow:hidden;
    text-overflow:ellipsis; white-space:nowrap; }
  .xref-inc button { font-size:10.5px; padding:1px 9px; }
  .xref-codebox { flex-basis:100%; margin-top:4px; }
  .xref-seg { margin:2px 0; }
  .xref-seg-h { font-size:10.5px; color:var(--sd-text-faint); margin:3px 0 1px; }
  .xref-codebox pre { font-family:Consolas,monospace; font-size:11px; line-height:1.5;
    background:var(--sd-code-bg); border:1px solid var(--sd-border); border-radius:6px;
    padding:7px 10px; overflow:auto; margin:2px 0 6px; white-space:pre; color:var(--sd-text); }
  .xref-ln { display:inline-block; width:34px; color:var(--sd-text-faint); user-select:none; }
  .xref-codebox mark { background:var(--sd-accent-soft); color:var(--sd-accent-active);
    font-weight:700; padding:0 1px; border-radius:2px; }
  .xref-td-name { font-family:Consolas,monospace; }

  /* ---- 🚰 交付驾驶舱(2026-11-04 P1;v2.1 五彩斑斓版) ---- */
  /* 图例条冻结(类似 Excel 冻结首行,滑动工单列表时 ①接单→…⑧交付 恒可见) */
  .flow-legend { display:flex; gap:6px; align-items:center; flex-wrap:wrap; padding:8px 2px 10px;
    font-size:11.5px; color:var(--sd-text-muted);
    position:sticky; top:0; z-index:5;
    background:var(--sd-bg, #fff);
    border-bottom:2px solid var(--sd-accent-border); margin-bottom:12px; padding-bottom:9px;
    box-shadow:0 3px 10px rgba(15,23,42,.06); }
  .flow-lg { padding:2.5px 10px; border-radius:999px; white-space:nowrap;
    font-weight:600; font-size:11px; border:1px solid transparent; }
  /* 图例胶囊彩虹化:八个节点各认一色(与节点条 fd 同色系,视觉呼应) */
  .flow-lg:nth-child(1) { background:#eef2ff; color:#4f46e5; border-color:#c7d2fe; }
  .flow-lg:nth-child(2) { background:#fdf4ff; color:#a21caf; border-color:#f5d0fe; }
  .flow-lg:nth-child(3) { background:#eff6ff; color:#1d4ed8; border-color:#bfdbfe; }
  .flow-lg:nth-child(4) { background:#fffbeb; color:#b45309; border-color:#fde68a; }
  .flow-lg:nth-child(5) { background:#ecfdf5; color:#047857; border-color:#a7f3d0; }
  .flow-lg:nth-child(6) { background:#f0fdfa; color:#0f766e; border-color:#99f6e4; }
  .flow-lg:nth-child(7) { background:#fdf2f8; color:#be185d; border-color:#fbcfe8; }
  .flow-lg:nth-child(8) { background:#fef2f2; color:#b91c1c; border-color:#fecaca; }
  .flow-lg.dim { opacity:.4; background:var(--sd-tag-bg); color:var(--sd-text-faint); border-color:var(--sd-border); font-weight:400; }
  .flow-arrow { color:var(--sd-slate-300, #cbd5e1); }
  .flow-btn-sm { font-size:11px; padding:2px 10px; border-radius:999px; }
  .flow-empty { padding:40px 10px; text-align:center; color:var(--sd-text-faint); font-size:12.5px; line-height:2;
    background:linear-gradient(135deg, var(--sd-accent-softer), var(--sd-success-soft));
    border-radius:var(--sd-radius-lg); border:1px dashed var(--sd-accent-border); }
  .flow-cards { display:flex; flex-direction:column; gap:12px; }
  .flow-card { border:1px solid var(--sd-border); border-radius:var(--sd-radius-lg);
    padding:12px 14px; background:var(--sd-panel-bg); cursor:pointer;
    background-image:linear-gradient(135deg, var(--sd-accent-softer), transparent 38%);
    transition:all var(--sd-dur) var(--sd-ease); }
  .flow-card:hover { border-color:var(--sd-accent); box-shadow:0 6px 20px rgba(99,102,241,.2);
    transform:translateY(-2px); }
  /* 卡片按状态换底色:正在动=天蓝氛围/完成=绿氛围/受阻=红氛围(顶部 2px 主题色条) */
  .flow-card.done { opacity:.78; background-image:linear-gradient(135deg, var(--sd-success-soft), transparent 45%); border-top:2px solid var(--sd-success); }
  .flow-card.bad { cursor:default; border-color:var(--sd-warning); border-top:2px solid var(--sd-warning); }
  .fc-head { display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
  .fc-head b { font-size:13px; color:var(--sd-text-strong); letter-spacing:-.01em; }
  .fc-sub { font-size:10.5px; color:var(--sd-text-faint); }
  /* 未接单待办区(还没建工单的 BPM 单,按提单人找)——换成琥珀色系"待办池" */
  .flow-unlinked { border:1px solid #fde68a; border-left:4px solid #f59e0b;
    border-radius:var(--sd-radius-md); padding:9px 12px; margin-bottom:14px;
    background:linear-gradient(135deg, var(--sd-warning-soft), var(--sd-accent-softer) 70%); }
  .fu-title { font-size:11.5px; color:#b45309; font-weight:700; margin-bottom:6px; }
  .fu-row { display:flex; gap:8px; align-items:center; padding:5px 0; font-size:11.5px;
    border-bottom:1px dashed #fde68a; flex-wrap:wrap; }
  .fu-row:last-child { border-bottom:none; }
  .fu-applyer { font-weight:700; color:#b45309; min-width:52px; }
  .fu-brief { flex:1; min-width:120px; color:var(--sd-text-muted); overflow:hidden;
    text-overflow:ellipsis; white-space:nowrap; font-size:11px; }
  .fu-node { font-size:10.5px; color:var(--sd-text-faint); }
  .fu-row .fc-badge.ok { background:var(--sd-success-soft); color:var(--sd-success-text); font-weight:700; font-size:10.5px; padding:1px 8px; border-radius:999px; }
  /* 使用说明折叠区 */
  .flow-help { margin-bottom:6px; }
  .flow-help-body { background:var(--sd-tag-bg); border-radius:var(--sd-radius-md); padding:11px 15px;
    margin-top:4px; font-size:11.5px; color:var(--sd-text-muted); line-height:1.8;
    border:1px solid var(--sd-border); border-left:3px solid var(--sd-accent); }
  .flow-help-body p { margin:4px 0; }
  .flow-help-body ul { margin:4px 0 4px 18px; padding:0; }
  .flow-help-body li { margin:3px 0; }
  .flow-help-body b { color:var(--sd-text); }
  /* 交付物区(接口文档/测试/检查产物路径可见可点) */
  .fc-arts { border:1px dashed var(--sd-border-strong); border-radius:var(--sd-radius-md); padding:6px 11px; margin:5px 0;
    background:var(--sd-tag-bg); }
  .fc-arts .fc-line { margin:1px 0; }
  .fc-art-row { display:flex; gap:8px; align-items:center; font-size:11.5px; margin:3px 0; }
  .fc-art-row .t { color:var(--sd-text-faint); flex:none; width:70px; }
  .fc-art-row button { font-size:11px; padding:2px 9px; max-width:70%; overflow:hidden;
    text-overflow:ellipsis; white-space:nowrap; border-radius:999px;
    background:var(--sd-accent-soft); border-color:var(--sd-accent-border); color:var(--sd-accent-active); }
  .fc-status { font-size:10.5px; padding:1.5px 9px; border-radius:999px;
    background:linear-gradient(135deg, #6366f1, #8b5cf6);
    color:#fff; font-weight:700; }
  .fc-badge { font-size:10.5px; padding:1.5px 9px; border-radius:999px; background:var(--sd-tag-bg); color:var(--sd-text-muted); }
  .fc-badge.err { background:var(--sd-danger-soft); color:var(--sd-danger-text); font-weight:700; }
  .fc-badge.warn { background:var(--sd-warning-soft); color:var(--sd-warning-text); font-weight:700; }
  .fc-badge.moss { background:#eff6ff; color:#1d4ed8; font-weight:600; }
  .fc-ch { font-size:12px; }
  /* 节点条 v2.1:地铁图风——圆角方块+各节点固有色+完成态点亮 */
  .fc-dots { display:flex; gap:5px; margin:9px 0 5px; font-size:14px; line-height:1; }
  .fd { width:23px; text-align:center; padding:3px 0; border-radius:7px;
    transition:all var(--sd-dur) var(--sd-ease); border:1px solid transparent; }
  .fd.na { color:var(--sd-text-faint); opacity:.4; }
  .fd.st-done { color:#047857; background:var(--sd-success-soft); border-color:#a7f3d0; }
  .fd.st-doing { color:#b45309; background:var(--sd-warning-soft); border-color:#fde68a;
    animation:fd-pulse 1.8s ease-in-out infinite; }
  .fd.st-pending { color:var(--sd-text-faint); background:var(--sd-tag-bg); border-color:transparent; }
  .fd.st-skipped { color:var(--sd-text-faint); background:transparent; border-color:var(--sd-border); border-style:dashed; }
  .fd.st-blocked { color:var(--sd-danger-text); background:var(--sd-danger-soft); border-color:#fecaca; }
  @keyframes fd-pulse { 0%,100% { box-shadow:0 0 0 0 rgba(245,158,11,.35); } 50% { box-shadow:0 0 0 5px rgba(245,158,11,0); } }
  .fc-next { font-size:11.5px; color:var(--sd-text-muted); display:flex; gap:8px; align-items:baseline; }
  .fc-next b { color:var(--sd-text); }
  .fc-upd { margin-left:auto; font-size:10.5px; color:var(--sd-text-faint); }
  .fc-detail { margin-top:11px; border-top:1px dashed var(--sd-accent-border); padding-top:9px; cursor:default; }
  .fc-line { font-size:11.5px; margin:3.5px 0; color:var(--sd-text); display:flex; gap:8px; align-items:baseline; flex-wrap:wrap; }
  .fc-line .k { color:var(--sd-text-faint); flex:none; width:62px; font-weight:600; }
  .fc-actions { display:flex; gap:8px; margin-top:9px; align-items:center; flex-wrap:wrap; }
  .fc-actions select { font-size:11.5px; padding:5px 8px; border:1px solid var(--sd-border-strong);
    border-radius:var(--sd-radius-md); background:var(--sd-input-bg); color:var(--sd-text); }
  /* 动作按钮分色:检查=teal/测试=sky/接口=violet/续跑=indigo/完工=emerald */
  .fc-actions button[data-act="flow-check"] { background:#f0fdfa; border-color:#99f6e4; color:#0f766e; font-weight:600; }
  .fc-actions button[data-act="flow-check"]:hover { background:#ccfbf1; border-color:#14b8a6; color:#115e59; }
  .fc-actions button[data-act="flow-test"] { background:#f0f9ff; border-color:#bae6fd; color:#0369a1; font-weight:600; }
  .fc-actions button[data-act="flow-test"]:hover { background:#e0f2fe; border-color:#38bdf8; color:#075985; }
  .fc-actions button[data-act="flow-itfdoc"] { background:#faf5ff; border-color:#e9d5ff; color:#7e22ce; font-weight:600; }
  .fc-actions button[data-act="flow-itfdoc"]:hover { background:#f3e8ff; border-color:#a855f7; color:#6b21a8; }
  .fc-actions button[data-act="flow-brief"] { background:var(--sd-accent-soft); border-color:var(--sd-accent-border); color:var(--sd-accent-active); font-weight:600; }
  .fc-actions button[data-act="flow-mark-done"] { background:var(--sd-success-soft); border-color:#a7f3d0; color:var(--sd-success-text); }
  .fc-actions button[data-act="flow-mark-done"]:hover { background:#d1fae5; border-color:var(--sd-success); color:#065f46; }
  .fc-hint { font-size:10.5px; color:var(--sd-text-faint); margin-top:6px; line-height:1.6; }
  /* 手工登记检查·按键选择条(2026-11-04 用户需求:不打字,点按钮) */
  .reg-check-bar { display:flex; gap:10px; align-items:center; flex-wrap:wrap; margin:8px 0 0;
    padding:8px 12px; border-radius:var(--sd-radius-md);
    background:var(--sd-accent-softer); border:1px solid var(--sd-accent-border); cursor:default; }
  .rcb-title { font-size:11.5px; font-weight:700; color:var(--sd-accent-active); }
  .rcb-tags { display:flex; gap:5px; flex-wrap:wrap; }
  .rcb-tags button { font-size:10.5px; padding:2px 9px; border-radius:999px;
    background:var(--sd-panel-bg); border:1px solid var(--sd-border); color:var(--sd-text-muted); }
  .rcb-tags button.on { background:var(--sd-accent-soft); border-color:var(--sd-accent); color:var(--sd-accent-active); font-weight:600; }
  .rcb-btns { display:flex; gap:6px; margin-left:auto; }
  .rcb-pass { background:var(--sd-success-soft) !important; border-color:#a7f3d0 !important; color:var(--sd-success-text) !important; font-weight:700; }
  .rcb-pass:hover { background:#d1fae5 !important; }
  .rcb-fail { background:var(--sd-danger-soft) !important; border-color:#fecaca !important; color:var(--sd-danger-text) !important; font-weight:700; }
  .rcb-fail:hover { background:#fee2e2 !important; }
  .rcb-cancel { color:var(--sd-text-faint) !important; }
  .fc-note { font-size:11.5px; color:var(--sd-text-muted); margin-top:6px; }
  .flow-done-box { margin-top:14px; border-top:2px solid var(--sd-success); padding-top:8px; }
`;
