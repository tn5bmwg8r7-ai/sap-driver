// 钉钉文本适配共享模块(2026-09-14 自 宿主问答组件 下沉,原实现 2026-09-03)。
// LLM 产出的 markdown 直发钉钉会变形——表格渲染成乱线、```代码块渲染成突兀的灰框、
// # 标题/--- 分隔线不识别,收信人读不动。这里做确定性转换(无 LLM、毫秒级、结果可预期):
//   ①「✨ 美化格式」第一步立即落框(智能问答发送弹窗),AI 深度润色走 qa-format-polish 路由;
//   ②富文本复制兜底:剪贴板 text/plain 回退位用本函数结果,粘到纯文本框也不露 md 记号。
// 调用方:宿主问答组件(_beautifySendText)、sap-copilot.widget(复制结论/转智能问答)。
export function dingtalkFriendly(src) {
  let s = String(src || '').replace(/\r\n?/g, '\n');
  // 1) 代码围栏 → 引用行(钉钉里 > 渲染为灰底引用;语言标记丢弃)。先于表格处理,
  //    免得围栏里的 | 行被当成表格误转换
  s = s.replace(/```[^\n]*\n?([\s\S]*?)```/g, (m, code) =>
    code.replace(/\n+$/, '').split('\n').map(l => '> ' + l).join('\n'));
  // 2) 表格 → 每行一条「- **表头**: 值;表头: 值」(手机上表格必变形,最疼的一处)
  s = s.replace(/(^[ \t]*\|.+\|[ \t]*\n)+/gm, (block) => {
    const rows = block.trim().split('\n').map(r => r.trim()).filter(Boolean)
      .map(r => r.replace(/^\|/, '').replace(/\|$/, '').split('|').map(c => c.trim().replace(/\*\*/g, '')));
    if (rows.length < 2) return block;
    const sepIdx = rows.findIndex(r => r.length > 0 && r.every(c => /^:?-{2,}:?$/.test(c) || c === ''));
    if (sepIdx < 1) return block;   // 找不到表头分隔线,不敢断定是表格,原样保留
    const head = rows[sepIdx - 1];
    const bodyRows = rows.slice(sepIdx + 1);
    if (!head.some(h => h) || !bodyRows.length) return block;
    return bodyRows.map(r => '- ' + head.map((h, i) => (h ? `**${h}**: ` : '') + (r[i] || '')).join(';')).join('\n');
  });
  // 3) # 标题 → 粗体行;--- 分隔线删除(钉钉不渲染,残留一排减号)
  s = s.replace(/^#{1,6}[ \t]+(.+)$/gm, '**$1**');
  s = s.replace(/^[ \t*]*-{3,}[ \t]*$/gm, '');
  // 4) 行内反引号剥掉(钉钉不渲染,露原始记号)
  s = s.replace(/`([^`\n]+)`/g, '$1');
  // 5) 3+ 连续空行收敛为 1 空行
  s = s.replace(/\n{3,}/g, '\n\n');
  return s.trim();
}
