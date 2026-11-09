// Shared browser-side export utilities: file download + clipboard + filename helpers.
// Pure module — no PW-internal deps, safe to import from any widget/view/dal.

// base64 → Blob 下载(2026-09-21 审查收拢:atob→Uint8Array→Blob 五行连在 mask-doc/
// interface-doc/test-report 等四处逐字抄,仅 mime 不同)
export function downloadBase64(b64, filename, mime = 'application/octet-stream') {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  downloadBlob(new Blob([bytes], { type: mime }), filename);
}

export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  // Defer revoke: some browsers (especially when the download triggers an OS dialog
  // or "Save As") haven't read the blob yet by the time click() returns.
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

export function downloadText(filename, text, mime = 'text/plain') {
  const blob = new Blob([text], { type: `${mime};charset=utf-8` });
  downloadBlob(blob, filename);
}

export function downloadMarkdown(filename, md) {
  downloadText(filename, md, 'text/markdown');
}

export function downloadHtml(filename, html) {
  downloadText(filename, html, 'text/html');
}

export function downloadJson(filename, data) {
  const text = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
  downloadText(filename, text, 'application/json');
}

// Returns true on success, false on failure. Caller decides fallback UX
// (toast / textarea dialog / inline error).
export async function copyText(text) {
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {
    // fall through to legacy path
  }
  try {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(ta);
    return ok;
  } catch {
    return false;
  }
}

// 富文本复制(2026-09-14):text/html + text/plain 双格式写入剪贴板。
// 粘到钉钉/Word/邮件等富文本目标 = 保留排版(加粗/表格/列表);粘到纯文本框 = 回退 text。
// text 兜底位建议传 dingtalkFriendly(src) 的结果,纯文本落点也不露 md 记号。
// 失败(非安全上下文/无权限)自动退 copyText 纯文本,调用方零分支。
export async function copyRich(text, html) {
  try {
    if (navigator.clipboard && window.ClipboardItem) {
      const item = { 'text/plain': new Blob([String(text ?? '')], { type: 'text/plain' }) };
      if (html) item['text/html'] = new Blob([String(html)], { type: 'text/html' });
      await navigator.clipboard.write([new ClipboardItem(item)]);
      return true;
    }
  } catch {
    // fall through to plain-text path
  }
  return copyText(text);
}

export function safeFilename(s, maxLen = 60) {
  const cleaned = String(s ?? '').replace(/[\\/:*?"<>|]/g, '_').trim().replace(/\s+/g, ' ');
  return cleaned.slice(0, maxLen) || 'export';
}

// ---- 极简 xlsx 生成(零依赖,2026-09-15):sheets=[{name,rows:[{col:val},…]}] → 多 SHEET 工作簿 ----
// xlsx = zip(store 不压缩)包 OOXML;手写 CRC32 + zip 目录,几千行毫秒级。与 docx OOXML 直写同思路。
const _xmlEsc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const _colLetter = (i) => { let s = ''; for (i += 1; i > 0; i = Math.floor((i - 1) / 26)) s = String.fromCharCode(65 + ((i - 1) % 26)) + s; return s; };

function _sheetXml(rows) {
  const cols = [...new Set(rows.slice(0, 50).flatMap((r) => (r && typeof r === 'object') ? Object.keys(r) : ['值']))];
  // 字符串数值化仅限"短且无前导零"的数字:SAP 单号/公司码/PERNR 等是带前导零的
  // 定长文本("0010"/"00000001"),数值单元格会静默剥零(09-18 审查 A4,Excel NumberFormat=@ 同红线);
  // 长度>10 收紧为文本,防长卡号/凭证号进科学计数与精度域
  const isNum = (v) => typeof v === 'number' || (typeof v === 'string'
    && v.trim().length <= 10 && !/^-?0\d/.test(v.trim())
    && /^-?\d{1,14}(\.\d+)?$/.test(v.trim()));
  const cell = (ref, v) => {
    if (v == null || v === '') return '';
    return isNum(v) ? `<c r="${ref}"><v>${v}</v></c>`
      : `<c r="${ref}" t="inlineStr"><is><t xml:space="preserve">${_xmlEsc(v)}</t></is></c>`;
  };
  const head = `<row>${cols.map((c, ci) => `<c r="${_colLetter(ci)}1" t="inlineStr"><is><t>${_xmlEsc(c)}</t></is></c>`).join('')}</row>`;
  const body = rows.map((r, ri) => `<row>${cols.map((c, ci) => cell(`${_colLetter(ci)}${ri + 2}`, r && typeof r === 'object' ? r[c] : r)).join('')}</row>`).join('');
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>${head}${body}</sheetData></worksheet>`;
}

function _crc32(u8) {
  let crc = -1;
  for (let i = 0; i < u8.length; i++) {
    crc ^= u8[i];
    for (let k = 0; k < 8; k++) crc = (crc >>> 1) ^ (0xEDB88320 & -(crc & 1));
  }
  return ~crc;
}

export function buildXlsx(sheets) {
  const enc = new TextEncoder();
  const clean = (n) => String(n).replace(/[\\/*?:[\]]/g, '_').slice(0, 31) || 'Sheet';
  const used = new Set();
  const names = sheets.map((s, i) => {
    let n = clean(s.name || `Sheet${i + 1}`); let k = 2;
    while (used.has(n)) { n = clean(`${s.name || 'Sheet'}_${k++}`); }
    used.add(n); return n;
  });
  const ct = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>${names.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')}</Types>`;
  const rels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>`;
  const wb = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${names.map((n, i) => `<sheet name="${_xmlEsc(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('')}</sheets></workbook>`;
  const wbRels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">${names.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')}</Relationships>`;
  const parts = [
    ['[Content_Types].xml', ct], ['_rels/.rels', rels], ['xl/workbook.xml', wb],
    ['xl/_rels/workbook.xml.rels', wbRels],
    ...names.map((_, i) => [`xl/worksheets/sheet${i + 1}.xml`, _sheetXml(sheets[i].rows || [])]),
  ];
  const chunks = []; const central = []; let offset = 0;
  for (const [name, content] of parts) {
    const nb = enc.encode(name); const db = enc.encode(content);
    const crc = _crc32(db);
    const h = new DataView(new ArrayBuffer(30));
    h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true);
    h.setUint32(14, crc, true); h.setUint32(18, db.length, true); h.setUint32(22, db.length, true);
    h.setUint16(26, nb.length, true);
    chunks.push(new Uint8Array(h.buffer), nb, db);
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true);
    c.setUint32(16, crc, true); c.setUint32(20, db.length, true); c.setUint32(24, db.length, true);
    c.setUint16(28, nb.length, true); c.setUint32(42, offset, true);
    central.push(new Uint8Array(c.buffer), nb);
    offset += 30 + nb.length + db.length;
  }
  const cdSize = central.reduce((a, u) => a + u.length, 0);
  const eocd = new DataView(new ArrayBuffer(22));
  eocd.setUint32(0, 0x06054b50, true); eocd.setUint16(8, parts.length, true); eocd.setUint16(10, parts.length, true);
  eocd.setUint32(12, cdSize, true); eocd.setUint32(16, offset, true);
  const all = [...chunks, ...central, new Uint8Array(eocd.buffer)];
  const out = new Uint8Array(all.reduce((a, u) => a + u.length, 0));
  let p = 0; for (const u of all) { out.set(u, p); p += u.length; }
  return out;
}

export function downloadXlsx(filename, sheets) {
  downloadBlob(new Blob([buildXlsx(sheets)], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), filename);
}

export function todayStamp() {
  const d = new Date();
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
