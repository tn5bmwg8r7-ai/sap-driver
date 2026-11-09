// sap_variant_read — read SE37 test variant input params.
// Architecture: Node side reads target function interface (FUNCTION_IMPORT_INTERFACE
// via RFC, which works) + builds GENERATE SUBROUTINE POOL source (in JS, easy),
// then passes the pre-built source to ZLILY_DIAG_GEN_EXEC (simple Z wrapper:
// GENERATE + PERFORM + IMPORT from EUFUNC + ZCL_JSON + memory). The Z wrapper
// has NO CALL FUNCTION inside (avoids old-ECC CALL_FUNCTION param issues).
import { z } from 'zod';

const ABAP_LINES_MAX = 72;

function trunc72(s) { return s.length > ABAP_LINES_MAX ? s.slice(0, ABAP_LINES_MAX) : s; }

/**
 * Build the GENERATE SUBROUTINE POOL source that:
 * 1. Declares typed import/tables params of the target function.
 * 2. IMPORTs them from EUFUNC(FL) cluster.
 * 3. Serializes to JSON via ZCL_JSON.
 * 4. EXPORTs JSON to MEMORY ID 'ZLILY_VR'.
 */
// Cluster object-name prefix used by SAP's generated FT test-frame program:
// each parameter's input-side value is stored under "%_I" + parameter name
// (param FI_HEAD -> cluster object %_IFI_HEAD; TABLES FT_BOM -> %_IFT_BOM).
// IMPORT must name these exactly — the plain parameter name returns sy-subrc=0
// (key hits) but every field stays empty (that object isn't in the cluster).
// Old-ECC IMPORT also requires the receiving variable to share the object name,
// so we declare same-named locals — FT does exactly this, and %_ identifiers
// compile fine in a generated subroutine pool (FT is the living proof).
const VAR_IN_PREFIX = '%_i';

// DATA declaration that wraps TYPE to the next line if >72 chars (never truncate
// a DATA statement — a cut identifier silently breaks the matching IMPORT).
function pushDataDecl(lines, varName, typeName) {
  const single = `DATA ${varName} TYPE ${typeName}.`;
  if (single.length <= ABAP_LINES_MAX) { lines.push(single); return; }
  lines.push(`DATA: ${varName}`);
  lines.push(`  TYPE ${typeName}.`);
}
function pushTableDecl(lines, varName, rowType) {
  const single = `DATA ${varName} TYPE TABLE OF ${rowType}.`;
  if (single.length <= ABAP_LINES_MAX) { lines.push(single); return; }
  lines.push(`DATA: ${varName}`);
  lines.push(`  TYPE TABLE OF ${rowType}.`);
}

function buildGenSource(imports, tables) {
  const lines = [];

  // PROGRAM + EUFUNC cluster key type (area / progid / dataid / seqid)
  lines.push('PROGRAM.');
  lines.push('TYPES: BEGIN OF ty_k,');
  lines.push('  a TYPE c LENGTH 30,');
  lines.push('  p TYPE c LENGTH 30,');
  lines.push('  d TYPE c LENGTH 30,');
  lines.push('  s TYPE c LENGTH 1,');
  lines.push('END OF ty_k.');

  // DATA: one local per cluster object, SAME name (%_I + param). This is the fix
  // — old code declared plain param-name locals and IMPORT failed to populate them.
  for (const p of imports) {
    if (p.type) pushDataDecl(lines, `${VAR_IN_PREFIX}${p.name}`, p.type);
  }
  for (const t of tables) {
    if (t.dbstruct) pushTableDecl(lines, `${VAR_IN_PREFIX}${t.name}`, t.dbstruct);
  }

  // working vars
  lines.push('DATA: lv_k TYPE ty_k.');
  lines.push('DATA: lv_j TYPE string.');
  lines.push('DATA: lo TYPE REF TO zcl_json.');

  // Combined structure for serialization (plain field names)
  lines.push('DATA: BEGIN OF ls_a,');
  for (const p of imports) {
    if (p.type) lines.push(trunc72(`  ${p.name} TYPE ${p.type},`));
  }
  for (const t of tables) {
    if (t.dbstruct) lines.push(trunc72(`  ${t.name} TYPE TABLE OF ${t.dbstruct},`));
  }
  lines.push('END OF ls_a.');

  // FORM
  lines.push('FORM r USING pa pp pn.');
  lines.push('  lv_k-a = pa.');
  lines.push('  lv_k-p = pp.');
  lines.push('  lv_k-d = pn.');
  // EUFUNC-NUMMER is CHAR30 but SAP right-justifies the variant id to position
  // 29 (position 30 stays blank) — verified from QAS data: variant 18 reads as
  // 27 spaces + "18" = 29 chars, NOT 30. So right-justify, then shift LEFT one
  // so the digits land at position 29. A plain right-justify (pos 30) leaves
  // the whole cluster key off-by-one and IMPORT silently misses.
  lines.push('  SHIFT lv_k-d RIGHT DELETING TRAILING SPACE.');
  lines.push('  SHIFT lv_k-d LEFT BY 1 PLACES.');

  // IMPORT — object names are "%_I" + param (the real cluster layout). Tolerant
  // additions match what FT itself uses (length/conversion drift between systems).
  lines.push('  IMPORT');
  for (const p of imports) { if (p.type) lines.push(`    ${VAR_IN_PREFIX}${p.name}`); }
  for (const t of tables) { if (t.dbstruct) lines.push(`    ${VAR_IN_PREFIX}${t.name}`); }
  lines.push('    FROM DATABASE eufunc(fl) ID lv_k');
  lines.push('    ACCEPTING PADDING IGNORING CONVERSION ERRORS.');

  // Move into combined structure
  for (const p of imports) {
    if (p.type) lines.push(`  ls_a-${p.name} = ${VAR_IN_PREFIX}${p.name}.`);
  }
  for (const t of tables) {
    if (t.dbstruct) lines.push(`  ls_a-${t.name}[] = ${VAR_IN_PREFIX}${t.name}[].`);
  }

  // Serialize + export to memory
  lines.push('  CREATE OBJECT lo.');
  lines.push('  CALL METHOD lo->serialize EXPORTING data = ls_a');
  lines.push('    RECEIVING r_json = lv_j.');
  lines.push("  EXPORT lv_j TO MEMORY ID 'ZLILY_VR'.");
  lines.push('ENDFORM.');

  return lines.map(l => ({ LINE: trunc72(l) }));
}

export default {
  name: 'sap_variant_read',
  description:
    '读 SE37 测试变式的入参值(Node 侧读接口→拼 GENERATE SUBROUTINE POOL 源码→传 ZLILY_DIAG_GEN_EXEC 执行 IMPORT FROM EUFUNC + ZCL_JSON 序列化→返回 JSON)。只读,DVP+QAS。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    function: z.string().describe('目标函数模块名'),
    variant: z.string().describe('SE37 变式号,如 999'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',
  needsRfc: true,
  underlying: ['FUNCTION_IMPORT_INTERFACE', 'ZLILY_DIAG_GEN_EXEC'],
  async run(args, ctx) {
    const funcName = String(args.function || '').toUpperCase().trim();
    const variant = String(args.variant || '').trim();
    if (!funcName) return { ok: false, code: 'MISSING_FUNCTION', message: '需要 function(函数名)。' };

    // Step 1: read target function interface via FUNCTION_IMPORT_INTERFACE
    const ifaceStep = {
      id: 'iface', function: 'FUNCTION_IMPORT_INTERFACE',
      import: { FUNCNAME: funcName },
    };
    const ifaceR = await ctx.runSteps({
      system: ctx.system, password: ctx.cred.password, steps: [ifaceStep],
    });
    if (!ifaceR.ok) return { ok: false, code: 'IFACE_FAILED', message: ifaceR.message, detail: ifaceR };
    const iface = ifaceR.results?.iface;
    if (!iface || iface._error) return { ok: false, code: 'IFACE_FAILED', message: `读接口失败: ${iface?._error || 'unknown'}` };

    // Extract typed import + tables params
    const impArr = iface.IMPORT_PARAMETER || [];
    const tabArr = iface.TABLES_PARAMETER || [];
    const imports = impArr
      .map(p => ({ name: p.PARAMETER, type: p.TYP || p.DBFIELD || '' }))
      .filter(p => p.name && p.type);
    // TABLES row type is inconsistent in FUNCTION_IMPORT_INTERFACE: some params
    // carry it in DBSTRUCT (e.g. FT_BOM), others in TYP with TYPES='O' (table-of).
    // Fall back through TYP so all table params are picked up.
    const tables = tabArr
      .map(t => ({ name: t.PARAMETER, dbstruct: t.DBSTRUCT || t.TYP || t.STRUCTURE || '' }))
      .filter(t => t.name && t.dbstruct);

    if (imports.length === 0 && tables.length === 0) {
      return { ok: false, code: 'NO_TYPED_PARAMS', message: '该函数没有类型化的参数(无法生成 IMPORT)。' };
    }

    // Step 2: resolve function group from TFDIR (for EUFUNC key AREA)
    const tfdirStep = {
      id: 'tfd', function: 'ZLILY_DIAG_Q3',
      import: { IV_TABLE: 'TFDIR', IV_MAX_ROWS: '1' },
      tables: { IT_WHERE: [{ TEXT: `FUNCNAME = '${funcName}'` }] },
    };
    const tfdR = await ctx.runSteps({
      system: ctx.system, password: ctx.cred.password, steps: [tfdirStep],
    });
    if (!tfdR.ok) return { ok: false, code: 'TFDIR_FAILED', message: tfdR.message };
    const tfdRows = tfdR.results?.tfd;
    if (!tfdRows || tfdRows._error) return { ok: false, code: 'TFDIR_FAILED', message: `查 TFDIR 失败: ${tfdRows?._error}` };
    // Parse JSON from Q3
    let tfdData;
    try { tfdData = JSON.parse(tfdRows.EV_RESULT || '[]'); } catch { tfdData = []; }
    if (!tfdData.length) return { ok: false, code: 'FUNC_NOT_FOUND', message: `${funcName} 不在 TFDIR。` };
    const pname = tfdData[0].PNAME || '';
    // SAPLZFG_LILY_DIAG4 → ZFG_LILY_DIAG4 (strip SAPL prefix)
    const area = pname.startsWith('SAPL') ? pname.slice(4).trim() : pname.trim();

    // Step 3: build GENERATE source
    const srcLines = buildGenSource(imports, tables);

    // Step 4: call GEN_EXEC with the source + EUFUNC key
    const genStep = {
      id: 'gen', function: 'ZLILY_DIAG_GEN_EXEC',
      import: { IV_AREA: area, IV_PROGID: funcName, IV_DATAID: variant },
      tables: { IT_SRC: srcLines },
    };
    const genR = await ctx.runSteps({
      system: ctx.system, password: ctx.cred.password, steps: [genStep],
    });
    if (!genR.ok) return { ok: false, code: 'GEN_FAILED', message: genR.message, detail: genR };
    const gen = genR.results?.gen;
    if (gen?._error) return { ok: false, code: 'GEN_FAILED', message: `ZLILY_DIAG_GEN_EXEC: ${gen._error}` };
    if (gen?.EV_ERROR) return { ok: false, code: 'GEN_FAILED', message: `ZLILY_DIAG_GEN_EXEC: ${gen.EV_ERROR}` };

    const json = gen?.EV_RESULT || '';
    let parsed;
    try { parsed = JSON.parse(json); } catch { parsed = null; }

    return {
      ok: true, system: ctx.system, function: funcName, variant,
      area, typedParams: { imports: imports.length, tables: tables.length },
      raw: parsed ? undefined : json,
      params: parsed,
    };
  },
};
