// Shared toast helper. Pure DOM, no PW-internal deps — safe to import anywhere.
//
// 统一全项目 9 份复制的 _toast / showToast（代码自查 kb-2026-08-07-pwaudit 重构1续）。
// 历史三变体（KB 原记 7 份，实测 9 份）：
//   A) body-append 居中浮层：main.js / growth-wall / work-journal /
//      today-todos 各自 new 一个 position:fixed 居中 div，3~4s 后自移除；bg 颜色 / 时长
//      各自漂移（amber / css-var / 红 / green-red-dark 四套色）。
//   B) in-element 切类：command-launcher(#toast) / ppt-studio(#ppt-toast) 在自己模板里放
//      一个常驻 toast 容器，切 `${baseClass} ${type} show` 类显隐（position:fixed 右下白卡片）。
//   C) host-stack 堆叠：projects-lifecycle(#dialog-host) / knowledge-base(#toast-host) 往
//      容器里 append 子 div，rAF 加 show，计时移除（多条可同时堆叠，各自独立计时）。
// 统一为 showToast({ msg, type, host, baseClass, duration, stack })：参数决定走哪变体，
// 各 widget/view 的视觉样式（颜色 / 位置 / 卡片）仍由其自身 scoped CSS 决定，本 helper 只统一 JS 逻辑。

// A 变体 body-append 的底色（按 type）。B/C 变体不用这套，走各自组件 CSS。
const BG = {
  ok: 'rgba(22, 163, 74, 0.95)',
  err: 'rgba(220, 38, 38, 0.95)',
  info: 'rgba(15, 23, 42, 0.92)',
};

/**
 * @param {object} opts
 * @param {string} opts.msg        文案
 * @param {string} [opts.type]     'ok' | 'err' | 'info'（默认 info）
 * @param {Element|null} [opts.host] 容器元素。给了就走 in-element（B/C），不给走 body-append（A）
 * @param {string}  [opts.baseClass] B/C 变体的基础类名（默认 'toast'）
 * @param {number}  [opts.duration]  存活毫秒（默认 3400）
 * @param {boolean} [opts.stack]     true=C 堆叠（每次新建子 div），false=B 单个常驻切类
 */
export function showToast({ msg, type = 'info', host = null, baseClass = 'toast', duration = 3400, stack = false } = {}) {
  // C 变体：往 host 内堆叠子 div（各自独立计时，互不影响——共享 timer 会让前一条卡死）。
  if (host && stack) {
    const el = document.createElement('div');
    el.className = `${baseClass} ${baseClass}-${type}`;
    el.textContent = msg;
    host.appendChild(el);
    requestAnimationFrame(() => el.classList.add('show'));
    setTimeout(() => {
      el.classList.remove('show');
      setTimeout(() => { if (el.parentNode) el.parentNode.removeChild(el); }, 300);
    }, duration);
    return;
  }

  // B 变体：在单个常驻 host 上切类显隐。
  if (host) {
    host.textContent = msg;
    host.className = `${baseClass} ${type} show`;
    clearTimeout(host._pwToastTimer);
    host._pwToastTimer = setTimeout(() => { host.className = `${baseClass} ${type}`; }, duration);
    return;
  }

  // A 变体：body-append 居中浮层。
  const el = document.createElement('div');
  el.textContent = msg;
  el.style.cssText = `
    position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
    background: ${BG[type] || BG.info}; color: white;
    padding: 8px 18px; border-radius: 8px;
    font-size: 12.5px; z-index: 10000;
    box-shadow: 0 4px 12px rgba(0,0,0,0.2);
    animation: pw-fade-in 0.2s ease-out;
  `;
  document.body.appendChild(el);
  const fadeAt = Math.max(duration - 400, 0);
  setTimeout(() => { el.style.opacity = '0'; el.style.transition = 'opacity 0.3s'; }, fadeAt);
  setTimeout(() => { if (el.parentNode) el.parentNode.removeChild(el); }, duration);
}
