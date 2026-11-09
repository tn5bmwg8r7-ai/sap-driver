// Markdown → 独立 HTML 文档 共享模块(2026-09-14)。
// PW 各处的「导出 HTML」此前各自拼壳(work-journal EXPORT_CSS / kb 分享壳),视觉与
// 实现漂移。这里收敛为同一套文档壳:正文由共享 renderMarkdown 渲染(表格/代码/列表
// 全覆盖),样式内联、零外部依赖,导出的 .html 双击即可读、可打印、可发人。
// 调用方:sap-copilot.widget(结论导出 HTML);后续其它「结论/报告导出」一律走这里。
import { renderMarkdown } from './markdown-renderer.js';
import { escapeHtml } from './html-utils.js';

const DOC_CSS = `
  body { font-family:'Microsoft YaHei','PingFang SC','Segoe UI',sans-serif; color:#222;
    max-width:860px; margin:0 auto; padding:36px 28px 64px; line-height:1.75; font-size:14.5px; }
  header.doc-head { border-bottom:2px solid #1E3A8A; padding-bottom:12px; margin-bottom:22px; }
  header.doc-head h1 { font-size:21px; margin:0 0 6px; color:#1E3A8A; }
  header.doc-head .sub { font-size:12px; color:#888; }
  .md-body h1,.md-body h2 { font-size:17.5px; margin:20px 0 8px; color:#1E3A8A;
    border-bottom:1px solid #e5e7eb; padding-bottom:5px; }
  .md-body h3,.md-body h4 { font-size:15.5px; margin:16px 0 6px; color:#111; }
  .md-body table { border-collapse:collapse; width:100%; font-size:13px; margin:12px 0; }
  .md-body th,.md-body td { border:1px solid #d1d5db; padding:6px 10px; text-align:left; }
  .md-body th { background:#EEF2FF; color:#1E3A8A; font-weight:600; }
  .md-body tr:nth-child(even) td { background:#FAFAFB; }
  .md-body code { background:#F1F5F9; padding:1px 6px; border-radius:4px; font-size:12.5px; color:#0f766e; }
  .md-body pre { background:#1e293b; color:#e2e8f0; padding:12px 14px; border-radius:8px;
    overflow:auto; font-size:12.5px; line-height:1.6; }
  .md-body pre code { background:transparent; color:inherit; padding:0; }
  .md-body blockquote { border-left:3px solid #93c5fd; margin:10px 0; padding:4px 14px;
    background:#F8FAFC; color:#475569; }
  footer.doc-foot { margin-top:36px; padding-top:10px; border-top:1px solid #e5e7eb;
    font-size:11.5px; color:#aaa; }
`;

/**
 * 生成完整 HTML 文档字符串。
 * @param {string} md        markdown 原文
 * @param {object} opts      { title, subtitle }  文档标题 / 头部副标题(如生成时间、来源)
 */
export function markdownToDocumentHtml(md, opts = {}) {
  const title = String(opts.title || '导出文档');
  const subtitle = String(opts.subtitle || '');
  const body = renderMarkdown(String(md || ''));
  const now = new Date().toLocaleString('zh-CN', { hour12: false });
  return `<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(title)}</title><style>${DOC_CSS}</style></head><body>
<header class="doc-head"><h1>${escapeHtml(title)}</h1>
${subtitle ? `<div class="sub">${escapeHtml(subtitle)}</div>` : ''}</header>
<div class="md-body">${body}</div>
<footer class="doc-foot">由 Lily Wang · 个人工作台 导出于 ${escapeHtml(now)}</footer>
</body></html>`;
}
