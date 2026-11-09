// sap_query — read business table data.
// Engine: ZLILY_DIAG_QUERY if deployed (no 512 truncation, full WHERE incl.
// parens/OR, dynamic SQL) — auto-detected per system via FUNCTION_IMPORT_INTERFACE
// and cached. Falls back to RFC_READ_TABLE (WHERE simplified, 512 truncation watch).
import { z } from 'zod';
import { buildOptions, coerceWhere } from '../util/where-builder.js';
import { parseRfcReadTable, asArray, withAuditRows } from '../util/result-shape.js';

// per-system availability cache for ZLILY_DIAG_QUERY
const zDiagQuery = new Map();

async function detectZDiagQuery(ctx) {
  if (zDiagQuery.has(ctx.system)) return zDiagQuery.get(ctx.system);
  try {
    const r = await ctx.runSteps({
      system: ctx.system, password: ctx.cred.password,
      steps: [{ id: 'probe', function: 'FUNCTION_IMPORT_INTERFACE', import: { FUNCNAME: 'ZLILY_DIAG_Q3' } }],
    });
    const avail = !!(r.ok && r.results && r.results.probe && !r.results.probe._error);
    zDiagQuery.set(ctx.system, avail);
    return avail;
  } catch {
    zDiagQuery.set(ctx.system, false);
    return false;
  }
}

// ZLILY accepts the full WHERE (dynamic SQL supports parens/OR); chunk into <=72-char
// RFC_DB_OPT TEXT rows — the FM joins lines back with a single space. Blind 72-slicing
// split tokens mid-word (09-16 field report: R3STATE -> R3 + STATE => "column R3 unknown"),
// so cut ONLY at spaces outside quotes and never leave trailing spaces; the space-join
// then reconstructs the exact WHERE. A single token longer than 72 (pathological) is
// hard-split as a fallback.
function chunk72(s) {
  const toks = [];
  let cur = '';
  let inQ = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '\'') { inQ = !inQ; cur += c; continue; }   // '' 转义偶数次,切换计数自洽
    if (c === ' ' && !inQ) { if (cur) { toks.push(cur); cur = ''; } continue; }
    cur += c;
  }
  if (cur) toks.push(cur);
  const out = [];
  let line = '';
  for (const t of toks) {
    if (t.length > 72) {
      if (line) { out.push({ TEXT: line }); line = ''; }
      for (let i = 0; i < t.length; i += 72) out.push({ TEXT: t.slice(i, i + 72) });
      continue;
    }
    if (!line) line = t;
    else if (line.length + 1 + t.length <= 72) line += ' ' + t;
    else { out.push({ TEXT: line }); line = t; }
  }
  if (line) out.push({ TEXT: line });
  return out;
}
// named export for regression test (test/chunk72.mjs) — default export is the tool registry entry
export { chunk72 };

function buildZWhereLines(where) {
  where = coerceWhere(where);
  if (!where) return [];
  if (typeof where === 'string') {
    const w = where.trim();
    return w ? chunk72(w) : [];
  }
  if (Array.isArray(where)) {
    const parts = where.map((c) => {
      const op = String(c.op || '=').toUpperCase();
      const v = String(c.value ?? '').replace(/'/g, "''");
      return `${String(c.field).toUpperCase()} ${op} '${v}'`;
    });
    return parts.length ? chunk72(parts.join(' AND ')) : [];
  }
  return [];
}

export default {
  name: 'sap_query',
  description:
    '读 SAP 业务表数据。自动用 ZLILY_DIAG_QUERY(若已部署：无512截断、支持括号/OR复杂WHERE) ，否则回退 RFC_READ_TABLE(WHERE仅简单等值/LIKE、拒括号/OR)。maxRows 上限 1000；达上限返回 moreAvailable。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    table: z.string().describe('表名，如 EKPO / T000 / DD03L'),
    fields: z.array(z.string()).optional().describe('字段名数组(RFC_READ_TABLE 用；ZLILY 当前返回全字段)'),
    where: z.any().optional().describe("条件数组 [{field,op,value}] 或 WHERE 字符串。ZLILY 支持括号/OR；RFC_READ_TABLE 仅简单 AND 等值"),
    maxRows: z.number().int().min(1).max(1000).optional().describe('最大行数，默认 100，上限 1000'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',
  needsRfc: true,
  underlying: ['ZLILY_DIAG_QUERY', 'RFC_READ_TABLE'],
  async run(args, ctx) {
    const cfg = (ctx.systems && ctx.systems.rfcReadTable) || {};
    const maxRows = Math.min(args.maxRows || cfg.defaultMaxRows || 100, cfg.absoluteMaxRows || 1000);
    const table = String(args.table).toUpperCase();

    const useZ = await detectZDiagQuery(ctx);

    // ===== ZLILY_DIAG_QUERY path =====
    if (useZ) {
      const whereLines = buildZWhereLines(args.where);
      const step = { id: 'q', function: 'ZLILY_DIAG_Q3', import: { IV_TABLE: table, IV_MAX_ROWS: String(maxRows) } };
      if (whereLines.length) step.tables = { IT_WHERE: whereLines };
      const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
      if (!r.ok) return { ok: false, code: 'QUERY_FAILED', message: r.message, detail: r };
      const st = r.results && r.results.q;
      if (st && st._error) return { ok: false, code: 'QUERY_FAILED', message: `ZLILY_DIAG_QUERY: ${st._error}` };
      if (st.EV_ERROR) return { ok: false, code: 'QUERY_FAILED', message: `ZLILY_DIAG_QUERY: ${st.EV_ERROR}` };
      // ZLILY_DIAG_QUERY returns a JSON array string in EV_RESULT (STRING EXPORT). This
      // avoids needing a DDIC Z structure — stateless RFC won't persist DDIC creates, so
      // the FM serializes the result set to a STRING instead of returning a typed table.
      const json = String(st.EV_RESULT || '[]');
      let rows;
      try {
        rows = JSON.parse(json);
      } catch (e) {
        return { ok: false, code: 'QUERY_FAILED', message: `ZLILY JSON 解析失败:${e.message}`, raw: json.slice(0, 500) };
      }
      const columns = rows.length ? Object.keys(rows[0]) : [];
      const rowCount = Number(st.EV_ROW_COUNT != null ? st.EV_ROW_COUNT : rows.length);
      const more = rowCount >= maxRows;
      return withAuditRows({
        ok: true, system: ctx.system, table, rowCount, columns, rows,
        truncated: false, engine: 'ZLILY_DIAG_QUERY', moreAvailable: more,
        notes: more ? [`结果达上限 ${maxRows}，可能还有更多；请收窄 WHERE。`] : [],
      }, rows.length);
    }

    // ===== RFC_READ_TABLE fallback path =====
    const whereRes = buildOptions(args.where);
    if (!whereRes.ok) return { ok: false, code: 'WHERE_REJECTED', message: whereRes.error };

    const fieldsTable = (args.fields && args.fields.length)
      ? args.fields.map((f) => ({ FIELDNAME: String(f).toUpperCase() }))
      : [];
    const importParam = { QUERY_TABLE: table, DELIMITER: '|', ROWCOUNT: String(maxRows), ROWSKIPS: '0' };
    const tablesParam = { OPTIONS: whereRes.options };
    if (fieldsTable.length) tablesParam.FIELDS = fieldsTable;

    const r = await ctx.runSteps({
      system: ctx.system, password: ctx.cred.password,
      steps: [{ id: 'read', function: 'RFC_READ_TABLE', import: importParam, tables: tablesParam }],
    });
    if (!r.ok) return { ok: false, code: 'QUERY_FAILED', message: r.message, detail: r };
    const step = r.results && r.results.read;
    if (step && step._error) return { ok: false, code: 'QUERY_FAILED', message: `RFC_READ_TABLE 执行失败：${step._error}` };

    const returnedFields = asArray(step.FIELDS).map((f) => f.FIELDNAME).filter(Boolean);
    const fieldNames = returnedFields.length ? returnedFields : (args.fields || []).map((f) => String(f).toUpperCase());
    const { rows, truncated } = parseRfcReadTable({ data: step.DATA, fields: fieldNames, delimiter: '|' });
    const moreAvailable = rows.length >= maxRows;
    const notes = [];
    if (truncated) notes.push('部分行 WA 达 512 字符上限，可能被 RFC_READ_TABLE 截断；建议减少字段数或部署 ZLILY_DIAG_QUERY。');
    if (moreAvailable) notes.push(`结果达上限 ${maxRows}，可能还有更多；请收窄 WHERE（QAS 无 ROWSKIP 偏移分页）。`);

    return withAuditRows({
      ok: true, system: ctx.system, table, rowCount: rows.length, columns: fieldNames, rows,
      truncated, engine: 'RFC_READ_TABLE', moreAvailable, ...(notes.length ? { notes } : {}),
    }, rows.length);
  },
};
