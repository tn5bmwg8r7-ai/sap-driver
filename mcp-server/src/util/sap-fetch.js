// sap-fetch.js — 共享的 SAP 表查询逻辑(从 sap_query.js 抽出)。
// 引擎: ZLILY_DIAG_Q3(优先,无 512 截断,支持括号/OR) / RFC_READ_TABLE(回退)。
// sap_deepseek 用它拉真值(不 return,仅喂 DeepSeek);sap_query 暂保留原内联逻辑,
// 未来可迁移到这里共享。
import { buildOptions, coerceWhere } from './where-builder.js';
import { parseRfcReadTable, asArray } from './result-shape.js';

const zDiagQuery = new Map(); // 各系统的 ZLILY 可用性缓存

export async function detectZDiagQuery(ctx) {
  if (zDiagQuery.has(ctx.system)) return zDiagQuery.get(ctx.system);
  try {
    const r = await ctx.runSteps({
      system: ctx.system, password: ctx.cred.password,
      steps: [{ id: 'probe', function: 'FUNCTION_IMPORT_INTERFACE',
                import: { FUNCNAME: 'ZLILY_DIAG_Q3' } }],
    });
    const avail = !!(r.ok && r.results?.probe && !r.results.probe._error);
    zDiagQuery.set(ctx.system, avail);
    return avail;
  } catch {
    zDiagQuery.set(ctx.system, false);
    return false;
  }
}

function chunk72(s) {
  const out = [];
  for (let i = 0; i < s.length; i += 72) out.push({ TEXT: s.slice(i, i + 72) });
  return out;
}

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

/**
 * 拉表数据(不包装审计/notes)。供 sap_deepseek 用:拉真值喂 DeepSeek,rows 不 return。
 * @returns {Promise<{ok:true,rows:object[],engine:string,rowCount:number,moreAvailable:boolean}
 *                     | {ok:false,code:string,message:string}>}
 */
export async function fetchTableRows(ctx, { table, where, fields, maxRows }) {
  const cfg = (ctx.systems && ctx.systems.rfcReadTable) || {};
  const cap = Math.min(maxRows || cfg.defaultMaxRows || 100, cfg.absoluteMaxRows || 1000);
  const tbl = String(table).toUpperCase();

  const useZ = await detectZDiagQuery(ctx);

  if (useZ) {
    const whereLines = buildZWhereLines(where);
    const step = { id: 'q', function: 'ZLILY_DIAG_Q3',
                   import: { IV_TABLE: tbl, IV_MAX_ROWS: String(cap) } };
    if (whereLines.length) step.tables = { IT_WHERE: whereLines };
    const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
    if (!r.ok) return { ok: false, code: 'QUERY_FAILED', message: r.message };
    const st = r.results?.q;
    if (st?._error) return { ok: false, code: 'QUERY_FAILED', message: `ZLILY: ${st._error}` };
    if (st?.EV_ERROR) return { ok: false, code: 'QUERY_FAILED', message: `ZLILY: ${st.EV_ERROR}` };
    let rows;
    try { rows = JSON.parse(String(st.EV_RESULT || '[]')); }
    catch (e) { return { ok: false, code: 'QUERY_FAILED', message: `ZLILY JSON 解析失败: ${e.message}` }; }
    const rowCount = Number(st.EV_ROW_COUNT != null ? st.EV_ROW_COUNT : rows.length);
    return { ok: true, rows, engine: 'ZLILY_DIAG_QUERY', rowCount, moreAvailable: rowCount >= cap };
  }

  // RFC_READ_TABLE 回退
  const whereRes = buildOptions(where);
  if (!whereRes.ok) return { ok: false, code: 'WHERE_REJECTED', message: whereRes.error };
  const fieldsTable = (fields?.length) ? fields.map((f) => ({ FIELDNAME: String(f).toUpperCase() })) : [];
  const importParam = { QUERY_TABLE: tbl, DELIMITER: '|', ROWCOUNT: String(cap), ROWSKIPS: '0' };
  const tablesParam = { OPTIONS: whereRes.options };
  if (fieldsTable.length) tablesParam.FIELDS = fieldsTable;
  const r = await ctx.runSteps({
    system: ctx.system, password: ctx.cred.password,
    steps: [{ id: 'read', function: 'RFC_READ_TABLE', import: importParam, tables: tablesParam }],
  });
  if (!r.ok) return { ok: false, code: 'QUERY_FAILED', message: r.message };
  const step = r.results?.read;
  if (step?._error) return { ok: false, code: 'QUERY_FAILED', message: `RFC_READ_TABLE: ${step._error}` };
  const returnedFields = asArray(step.FIELDS).map((f) => f.FIELDNAME).filter(Boolean);
  const fieldNames = returnedFields.length ? returnedFields : (fields || []).map((f) => String(f).toUpperCase());
  const { rows } = parseRfcReadTable({ data: step.DATA, fields: fieldNames, delimiter: '|' });
  return { ok: true, rows, engine: 'RFC_READ_TABLE', rowCount: rows.length, moreAvailable: rows.length >= cap };
}
