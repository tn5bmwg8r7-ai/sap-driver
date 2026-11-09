// where-builder.js — build RFC_READ_TABLE OPTIONS rows from simple conditions.
// QAS RFC_READ_TABLE rejects parenthesized / OR WHERE, so we only emit
// `FIELD op 'VAL'` joined by AND. Complex conditions are rejected up-front
// (the caller can refine or filter client-side).
const OPS = new Set(['=', '<>', '<', '<=', '>', '>=', 'LIKE', 'CP', 'EQ', 'NE', 'GT', 'LT', 'GE', 'LE']);

function normalizeOp(op) {
  const o = String(op || '=').toUpperCase();
  switch (o) {
    case 'EQ': return '=';
    case 'NE': return '<>';
    case 'GT': return '>';
    case 'LT': return '<';
    case 'GE': return '>=';
    case 'LE': return '<=';
    case 'CP': return 'LIKE';
    default: return o;
  }
}

/**
 * Some MCP clients/harnesses pass a structured `where` (array/object) through a
 * z.any() schema as a JSON STRING (e.g. `'[{"field":"MANDT",...}]'`). Detect that
 * shape and parse it back to a real array/string so the builders below work.
 * A real SQL-string WHERE never starts with `[` or `{`, so this is safe.
 */
export function coerceWhere(where) {
  if (typeof where === 'string') {
    const w = where.trim();
    if (w.startsWith('[') || w.startsWith('{')) {
      try { return JSON.parse(w); } catch { return where; }
    }
  }
  return where;
}

/**
 * @param {Array<{field:string,op?:string,value:string}> | string | undefined} where
 * @returns {{ok:true, options:Array<{TEXT:string}>} | {ok:false, error:string}}
 */
export function buildOptions(where) {
  where = coerceWhere(where);
  if (!where) return { ok: true, options: [] };

  if (typeof where === 'string') {
    const w = where.trim();
    if (!w) return { ok: true, options: [] };
    if (/[()]/.test(w) || /\bOR\b/i.test(w)) {
      return { ok: false, error: "RFC_READ_TABLE 不支持括号 / OR（QAS 限制）。请改用简单条件数组 [{field,op,value}]，或在结果集上客户端过滤。" };
    }
    const parts = w.split(/\s+AND\s+/i).map((s) => s.trim()).filter(Boolean);
    return { ok: true, options: parts.map((p) => ({ TEXT: p })) };
  }

  if (Array.isArray(where)) {
    const options = [];
    for (const c of where) {
      if (!c || !c.field) {
        return { ok: false, error: '条件缺少 field：' + JSON.stringify(c) };
      }
      const op = normalizeOp(c.op);
      if (!OPS.has(op === 'LIKE' ? 'LIKE' : op) && !['=', '<>', '<', '<=', '>', '>=', 'LIKE'].includes(op)) {
        return { ok: false, error: `不支持的操作符 ${c.op}（仅 = / <> / < / <= / > / >= / LIKE）。` };
      }
      const v = String(c.value ?? '');
      const quoted = `'${v.replace(/'/g, "''")}'`;
      options.push({ TEXT: `${String(c.field).toUpperCase()} ${op} ${quoted}` });
    }
    return { ok: true, options };
  }

  return { ok: false, error: 'where 必须是条件数组 [{field,op,value}] 或简单 SQL 字符串。' };
}
