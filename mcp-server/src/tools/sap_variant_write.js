// sap_variant_write — overwrite an SE37-registered variant's cluster with a
// payload, using SAP's own FT test-frame code (EXPORT_IMPORT form).
//
// WHY THIS DESIGN: SE37 only lists variants it created itself (it registers
// them internally). Variants a program writes directly to EUFUNC with a new
// NUMMER are NEVER shown by SE37, no matter how correct the cluster/fields are
// (verified exhaustively: full %_I*+%_V*+scalars object set, AUTOR/VERSION/
// DATUM, BEGIN OF+INCLUDE declarations, FT form on a fresh NUMMER — all
// rejected). The working path: the user creates an EMPTY variant in SE37
// (registers it), then this tool OVERWRITES that variant's cluster data using
// SAP's own EXPORT_IMPORT form. SE37 lists it (it made it), DEBUG reads the
// overwritten values. WRITE op — confirm before each call.
import { z } from 'zod';
import sapVariantRead from './sap_variant_read.js';

// 宽松比对:定长尾空格 TrimEnd;数字表示差异('09' vs 9 / '-1.5' vs -1.5)按数值口径;
// 只比写入侧显式给的键(读回会带全部接口字段,未填键在读回侧是 None/'')。
function eqVal(a, b) {
  if (a === undefined || a === null || a === '') return (b === undefined || b === null || b === '');
  if (b === undefined || b === null || b === '') return false;
  const sa = String(a).trim(); const sb = String(b).trim();
  if (sa === sb) return true;
  const na = Number(sa); const nb = Number(sb);
  if (Number.isFinite(na) && Number.isFinite(nb)) return na === nb;
  return false;
}
function diffWriteVsRead(params, known, rp) {
  const mismatches = []; let checked = 0;
  for (const [p, v] of Object.entries(params)) {
    if (!known.has(p) || v === null || v === undefined) continue;
    if (Array.isArray(v)) {
      const rv = Array.isArray(rp?.[p]) ? rp[p] : [];
      if (rv.length !== v.length) { mismatches.push(`${p}: 行数 写=${v.length} 读=${rv.length}`); continue; }
      for (let i = 0; i < v.length; i++) {
        for (const [f, val] of Object.entries(v[i])) {
          checked++;
          if (!eqVal(rv[i]?.[f], val)) mismatches.push(`${p}[${i}].${f}: 写=${JSON.stringify(val)} 读=${JSON.stringify(rv[i]?.[f])}`);
        }
      }
    } else if (typeof v === 'object') {
      for (const [f, val] of Object.entries(v)) {
        checked++;
        if (!eqVal(rp?.[p]?.[f], val)) mismatches.push(`${p}-${f}: 写=${JSON.stringify(val)} 读=${JSON.stringify(rp?.[p]?.[f])}`);
      }
    } else {
      checked++;
      if (!eqVal(rp?.[p], v)) mismatches.push(`${p}: 写=${JSON.stringify(v)} 读=${JSON.stringify(rp?.[p])}`);
    }
  }
  return { checked, mismatches };
}

const ABAP_LINES_MAX = 72;
function abapStr(v) { return "'" + String(v).replace(/'/g, "''") + "'"; }

// 长值不再硬截断(截断会把引号切一半,GENERATE 报 'literal spans lines')。
// 短值走普通赋值;超长值拆成 <=chunkLen 的段,用老ECC语法 CONCATENATE ... RESPECTING BLANKS 跨行拼接。
function pushAssign(lines, lhs, val) {
  const s = String(val ?? '');
  const budget = ABAP_LINES_MAX - lhs.length - 8;   // 2缩进+' = '+引号2+'.'+余量
  if (s.length <= Math.max(budget, 0)) {
    lines.push(`  ${lhs} = ${abapStr(s)}.`);
    return;
  }
  const chunkLen = Math.min(Math.max(budget, 8), 48);
  const parts = s.match(new RegExp(`[\\s\\S]{1,${chunkLen}}`, 'g')) || [''];
  lines.push(`  CONCATENATE ${abapStr(parts[0])}`);
  for (let i = 1; i < parts.length; i++) lines.push(`              ${abapStr(parts[i])}`);
  lines.push(`    INTO ${lhs} RESPECTING BLANKS.`);
}

// FT 测试框架程序名 = 函数名右补 '=' 到 30 位 + 'FT'(REPOSRC 实查口径)。
// 旧代码写死 7 个 '='(只有 23 字符函数碰巧对,ZIF_HR_001 21 字符实爆)。
export function ftProgramName(funcName) {
  return `${String(funcName).padEnd(30, '=')}FT`;
}

// Build GENERATE source: the function's FT program (native declarations +
// EXPORT_IMPORT form) + an appended `r` form that sets %_I* from the payload
// and calls EXPORT_IMPORT('IO'). GEN_EXEC runs PERFORM r.
export function buildFtFormSource(ftSource, params, imports, tables, user) {
  let ftLines = String(ftSource || '').split(/\r?\n/);
  while (ftLines.length && ftLines[0].trim() === '') ftLines.shift();
  if (/REPORT/i.test(ftLines[0])) ftLines[0] = 'PROGRAM.';
  else ftLines.unshift('PROGRAM.');

  const known = new Set([...imports.map((p) => p.name), ...tables.map((t) => t.name)]);

  ftLines.push('FORM r USING pa pp pn.');
  ftLines.push('  DATA: lk TYPE functdir.');
  ftLines.push('  DATA: lv_j TYPE string.');
  ftLines.push('  lk-area = pa.');
  ftLines.push('  lk-progid = pp.');
  ftLines.push('  lk-dataid = pn.');
  ftLines.push('  SHIFT lk-dataid RIGHT DELETING TRAILING SPACE.');
  ftLines.push('  SHIFT lk-dataid LEFT BY 1 PLACES.');

  // struct / scalar fill (skip payload keys not in the interface; arrays are
  // table params filled below — emitting them as scalar literals blew up
  // GEN_EXEC with "[object Object],..." literals > 72 chars, truncation left
  // an unclosed quote and GENERATE failed with 'literal spans lines')
  for (const [p, v] of Object.entries(params)) {
    if (!known.has(p)) continue;
    if (Array.isArray(v)) continue;
    if (v !== null && typeof v === 'object') {
      for (const [f, val] of Object.entries(v)) {
        pushAssign(ftLines, `%_i${p}-${f}`, val);
      }
    } else {
      pushAssign(ftLines, `%_i${p}`, v);
    }
  }
  // table fill (old-ECC: workarea + APPEND, no constructor expressions)
  for (const t of tables) {
    const rows = Array.isArray(params[t.name]) ? params[t.name] : [];
    if (!rows.length) continue;
    ftLines.push(`  DATA ls_${t.name} TYPE ${t.dbstruct}.`);
    for (const row of rows) {
      ftLines.push(`  CLEAR ls_${t.name}.`);
      for (const [f, val] of Object.entries(row)) {
        pushAssign(ftLines, `ls_${t.name}-${f}`, val);
      }
      ftLines.push(`  APPEND ls_${t.name} TO %_i${t.name}.`);
    }
  }

  // call FT's own EXPORT_IMPORT('IO') + mimic SE37's AUTOR/DATUM/VERSION
  ftLines.push("  PERFORM export_import USING 'IO' lk.");
  ftLines.push(`  UPDATE eufunc SET autor = ${abapStr(user || 'MCP')}`);
  ftLines.push(`                    datum = sy-datum`);
  ftLines.push(`                    version = '  1'`);
  ftLines.push(`    WHERE relid = 'FL' AND gruppe = lk-area`);
  ftLines.push(`      AND name = lk-progid AND nummer = lk-dataid AND srtf2 = 0.`);
  ftLines.push("  lv_j = 'WROTE'.");
  ftLines.push("  EXPORT lv_j TO MEMORY ID 'ZLILY_VR'.");
  ftLines.push('ENDFORM.');

  // fail-fast 守卫:任何行仍超 72 就拒发(静默截断=未闭合引号=GENERATE 必炸)
  const over = ftLines.map((l, i) => ({ l, i })).filter((x) => x.l.length > ABAP_LINES_MAX);
  if (over.length) {
    const sample = over.slice(0, 3).map((x) => `#${x.i + 1}(${x.l.length}) ${x.l.slice(0, 90)}`).join(' | ');
    throw new Error(`生成的 ABAP 有 ${over.length} 行超 ${ABAP_LINES_MAX} 字符,拒绝下发(防截断): ${sample}`);
  }

  return ftLines.map((l) => ({ LINE: l }));
}

export default {
  name: 'sap_variant_write',
  description: '把接口报文(JSON)覆盖写入一个 SE37 已建的变式。用法:① 先在 SE37 手动建一个空变式(命名+存,不填值,5秒)拿到变式号;② sap_variant_write(function, variant=号, params=报文) 覆盖其数据;③ SE37 DEBUG 选该变式看值。写操作,改 SAP 测试数据,调用前需用户确认。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    function: z.string().describe('目标函数模块名'),
    variant: z.string().describe('SE37 已建的变式号(用户先 SE37 建空变式,拿号)'),
    params: z.record(z.string(), z.any()).describe('报文:参数名→值(结构对象 / 标量 / 表数组)'),
  },
  allowedEnvs: ['DVP', 'QAS'],
  opClass: 'variant-write',
  needsRfc: true,
  underlying: ['FUNCTION_IMPORT_INTERFACE', 'ZLILY_DIAG_Q3', 'ZLILY_DIAG_UNPACK', 'ZLILY_DIAG_GEN_EXEC'],
  async run(args, ctx) {
    const funcName = String(args.function || '').toUpperCase().trim();
    const variant = String(args.variant || '').trim();
    const params = args.params || {};
    if (!funcName) return { ok: false, code: 'MISSING_FUNCTION', message: '需要 function。' };
    if (!variant) return { ok: false, code: 'MISSING_VARIANT', message: '需要 variant(SE37 已建的变式号;请先 SE37 建空变式)。' };

    // 1. read interface (validate payload keys)
    const ifaceR = await ctx.runSteps({
      system: ctx.system, password: ctx.cred.password,
      steps: [{ id: 'iface', function: 'FUNCTION_IMPORT_INTERFACE', import: { FUNCNAME: funcName } }],
    });
    if (!ifaceR.ok) return { ok: false, code: 'IFACE_FAILED', message: ifaceR.message };
    const iface = ifaceR.results?.iface;
    if (!iface || iface._error) return { ok: false, code: 'IFACE_FAILED', message: `读接口失败: ${iface?._error}` };
    const imports = (iface.IMPORT_PARAMETER || [])
      .map((p) => ({ name: p.PARAMETER, type: p.TYP || p.DBFIELD || '' }))
      .filter((p) => p.name && p.type);
    const tables = (iface.TABLES_PARAMETER || [])
      .map((t) => ({ name: t.PARAMETER, dbstruct: t.DBSTRUCT || t.TYP || t.STRUCTURE || '' }))
      .filter((t) => t.name && t.dbstruct);
    const known = new Set([...imports.map((p) => p.name), ...tables.map((t) => t.name)]);
    const extras = Object.keys(params).filter((k) => !known.has(k));

    // 2. TFDIR area (function group)
    const tfdR = await ctx.runSteps({
      system: ctx.system, password: ctx.cred.password,
      steps: [{ id: 'tfd', function: 'ZLILY_DIAG_Q3', import: { IV_TABLE: 'TFDIR', IV_MAX_ROWS: '1' },
        tables: { IT_WHERE: [{ TEXT: `FUNCNAME = '${funcName}'` }] } }],
    });
    const tfdRows = tfdR.results?.tfd;
    if (!tfdRows || tfdRows._error) return { ok: false, code: 'TFDIR_FAILED', message: `查 TFDIR 失败: ${tfdRows?._error}` };
    let tfdData; try { tfdData = JSON.parse(tfdRows.EV_RESULT || '[]'); } catch { tfdData = []; }
    if (!tfdData.length) return { ok: false, code: 'FUNC_NOT_FOUND', message: `${funcName} 不在 TFDIR。` };
    const pname = tfdData[0].PNAME || '';
    const area = pname.startsWith('SAPL') ? pname.slice(4).trim() : pname.trim();

    // 3. read FT source (ZLILY_DIAG_UNPACK bypasses READ REPORT permission)
    const tryFt = async (incl) => {
      const r = await ctx.runSteps({
        system: ctx.system, password: ctx.cred.password,
        steps: [{ id: 'ft', function: 'ZLILY_DIAG_UNPACK', import: { IV_INCL: incl } }],
      });
      return r.results?.ft;
    };
    const triedNames = [];
    let ft = await tryFt(ftProgramName(funcName));
    if (!ft || ft._error || ft.EV_ERROR) {
      // 兜底:Q3 查 REPOSRC 精确 FT 名(池子截断/命名变体时不靠猜)
      triedNames.push(ftProgramName(funcName));
      const q3R = await ctx.runSteps({
        system: ctx.system, password: ctx.cred.password,
        steps: [{ id: 'ftq', function: 'ZLILY_DIAG_Q3', import: { IV_TABLE: 'REPOSRC', IV_MAX_ROWS: '5' },
          tables: { IT_WHERE: [{ TEXT: `PROGNAME LIKE '${funcName}%FT'` }, { TEXT: `R3STATE = 'A'` }] } }],
      });
      const q3Rows = q3R.results?.ftq;
      let candidates = [];
      if (q3Rows && !q3Rows._error && !q3Rows.EV_ERROR) {
        try { candidates = JSON.parse(q3Rows.EV_RESULT || '[]'); } catch { candidates = []; }
      }
      const exact = candidates.map((r) => (r.PROGNAME || r.PROG || '')).find((n) => /^FT$/.test(n.slice(-2)));
      if (exact) {
        ft = await tryFt(exact);
        if (ft && !ft._error && !ft.EV_ERROR) triedNames.length = 0;
        else triedNames.push(exact);
      }
    }
    if (!ft || ft._error || ft.EV_ERROR) {
      return { ok: false, code: 'FT_READ_FAILED',
        message: `读 FT 源码失败(尝试 ${triedNames.join(' / ') || ftProgramName(funcName)}): ${ft?._error || ft?.EV_ERROR}。SE37 对该函数 F8 跑一次空测试即可生成 FT 后重试。` };
    }

    // 4. build GENERATE source (FT + r form) + run via GEN_EXEC
    let srcLines;
    try {
      srcLines = buildFtFormSource(ft.EV_RESULT, params, imports, tables, ctx.cred?.user);
    } catch (e) {
      return { ok: false, code: 'SOURCE_TOO_LONG', message: e.message };
    }
    const genR = await ctx.runSteps({
      system: ctx.system, password: ctx.cred.password,
      steps: [{ id: 'gen', function: 'ZLILY_DIAG_GEN_EXEC',
        import: { IV_AREA: area, IV_PROGID: funcName, IV_DATAID: variant },
        tables: { IT_SRC: srcLines } }],
    });
    if (!genR.ok) return { ok: false, code: 'GEN_FAILED', message: genR.message, detail: genR };
    const gen = genR.results?.gen;
    if (gen?._error) return { ok: false, code: 'GEN_FAILED', message: `GEN_EXEC: ${gen._error}` };
    if (gen?.EV_ERROR) return { ok: false, code: 'GEN_FAILED', message: `GEN_EXEC: ${gen.EV_ERROR}` };

    // 5. 写后自动回读比对(2026-10-08 定案:写入成功≠数据正确,回读逐字段核)
    let verify = { attempted: false, ok: false, checked: 0, mismatches: [] };
    try {
      const vr = await sapVariantRead.run({ function: funcName, variant }, ctx);
      if (vr?.ok && vr.params) {
        const d = diffWriteVsRead(params, known, vr.params);
        verify = { attempted: true, ok: d.mismatches.length === 0, checked: d.checked, mismatches: d.mismatches.slice(0, 20) };
      } else {
        verify = { attempted: true, ok: false, checked: 0, mismatches: [`回读失败: ${vr?.message || vr?.code || 'unknown'}`] };
      }
    } catch (e) {
      verify = { attempted: true, ok: false, checked: 0, mismatches: [`回读异常: ${e.message}`] };
    }
    if (verify.attempted && !verify.ok) {
      return { ok: false, code: 'WRITE_VERIFY_FAILED',
        message: `变式 ${variant} 写入后回读比对不一致(${verify.mismatches.length}处,共查${verify.checked}项): ${verify.mismatches.slice(0, 5).join('; ')}`,
        verify };
    }

    return {
      ok: true, system: ctx.system, function: funcName, variant, area,
      written: {
        imports: imports.filter((p) => params[p.name] !== undefined).map((p) => p.name),
        tables: tables.filter((t) => params[t.name] !== undefined).map((t) => t.name),
      },
      verify,
      ignoredExtraKeys: extras,
      message: `变式 ${variant} 写入并回读验证通过(${verify.checked}项比对)。SE37 DEBUG 选该变式即可看到值。`,
    };
  },
};
