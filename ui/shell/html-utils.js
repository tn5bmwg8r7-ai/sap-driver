// Shared HTML escaping helpers. Pure module — no PW-internal deps, safe to import
// from any widget/view/shell/dal.
//
// 统一全项目的 HTML 转义，消除各 widget/view 各自复制的 esc / escAttr / escapeHtml
// （历史上有 4 字符 / 5 字符两派；4 字符派漏转义单引号 '，在单引号属性拼接时是潜在
// 断裂隐患）。代码自查 kb-2026-08-07-pwaudit 重构 1。

// 文本内容转义：5 字符（& < > " '）。
// ' 转义在文本节点里浏览器会解码回 '，显示无差异；在属性里更安全。统一用 5 字符安全集。
export function esc(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// 双引号属性值转义：4 字符（& < > "）。单引号在双引号属性里无需转义。
export function escAttr(s) {
  return String(s ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// 别名：部分文件历史用 escapeHtml 命名，导入时用原名减少改动（与 esc 等价，5 字符）。
export { esc as escapeHtml };

// 空态 markup：统一各组件 `<div class="empty"><div class="big">ICON</div><div>MSG</div></div>`
// 这套结构（icon 大表情 + 一句文案）。.empty / .big 的具体样式仍由各组件 scoped CSS 决定，
// 本函数只统一 DOM 骨架，不做转义——调用方传入的 msg 可含受控 HTML（如 <br/>）。
// 仅迁结构完全一致的站点；带按钮/多段提示/组件专属类名(.ppl-empty 等)的空态保持原样。
export function emptyState({ icon = '', msg = '', hint = '' } = {}) {
  return `<div class="empty"><div class="big">${icon}</div><div>${msg}</div>${hint ? `<div class="hint">${hint}</div>` : ''}</div>`;
}

// 输入框安全绑定：封装中文输入法（IME）composition 守卫 + 可选 debounce。
// 统一各处复制的 compositionstart/compositionend/input 三段式（people / today-todos /
// projects-lifecycle 搜索 & 邮件报告 body 共 4 处）。拼音输入中途不触发，compositionend
// 立即触发（用户确认字符要反馈），input 按 debounce（默认 0=立即）触发。
// handler 是无参闭包，调用方在其中读 el.value 并刷新——与原各站点行为一致。
export function bindSafeInput(el, handler, { debounce = 0 } = {}) {
  if (!el) return;
  let composing = false;
  let t = null;
  const fire = () => {
    if (debounce > 0) { clearTimeout(t); t = setTimeout(handler, debounce); }
    else handler();
  };
  el.addEventListener('compositionstart', () => { composing = true; });
  el.addEventListener('compositionend', () => { composing = false; handler(); });
  el.addEventListener('input', () => { if (composing) return; fire(); });
}
