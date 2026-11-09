// sap_dev_create — DVP-only phase-3 dev tool: create NEW Z/Y repository objects.
//   TABL (structure/transparent table) via DDIF_TABL_PUT
//   FUNC (function module)            via RPY_FUNCTIONMODULE_INSERT
//
// RED-LINE GUARDS (enforced in code, not by trust):
//   1. objectName MUST be customer namespace (Z/Y or /NSP/) — standard & enhancement refused
//   2. objectType whitelist: TABL / FUNC only (ENHA/SMOD/... can never pass schema)
//   3. create-only: probe existence first (DDIF_TABL_GET / RPY_FUNCTIONMODULE_READ);
//      if it exists -> refuse (never modify/overwrite)
//   4. devclass + trkorr REQUIRED per call — never cached, never defaulted
//
// Depends on Invoke-SapRfc.ps1 supporting STRUCTURE import params (DD02V_WA) —
// extended in this same phase. Tables params (DD03P_TAB, IMPORT_PARAMETER, SOURCE)
// were already supported by the bridge.
import { z } from 'zod';
import { checkFmAllowed } from '../governance/fm-check.js';
import { isCustomerNamespace } from '../governance/env-policy.js';

export default {
  name: 'sap_dev_create',
  description:
    'DVP 专用:新建 Z/Y 仓库对象(结构/表 ZLILY_DIAG_TBL_MK3、函数 RPY_FUNCTIONMODULE_INSERT、函数组 RS_FUNCTION_POOL_INSERT、源码改写 ZLILY_DIAG_SRC_PUT8)。护栏:对象名必须 Z/Y、类型白名单 TABL/FUNC/FUNCGROUP/SOURCE_UPDATE、只建不改(已存在则拒)、devclass+trkorr 必填每次给。TR 挂接:FUNC/FUNCGROUP 传 CORRNUM 出生即挂;TABL/SOURCE_UPDATE 的 trkorr 仅记录不落 TR,挂 TR 用 sap_dev_tr_put 或 SE10。',
  schema: {
    system: z.enum(['DVP']),
    objectType: z.enum(['TABL', 'FUNC', 'FUNCGROUP', 'SOURCE_UPDATE']).describe('TABL=结构/透明表, FUNC=函数模块, FUNCGROUP=函数组, SOURCE_UPDATE=就地改已建 Z/Y 源码(objectName=Z/Y函数→自动解析include; programName=Z/Y程序/include→直写; Z/Y护栏双层,增强/标准拒),走 ZLILY_DIAG_SRC_PUT8'),
    objectName: z.string().describe('对象名(必须 Z/Y 开头或 /NSP/ 客户命名空间)'),
    devclass: z.string().describe('Package 名(每次必填,不缓存不默认)'),
    trkorr: z.string().describe('传输请求号(每次必填,绝不缓存/猜。FUNC/FUNCGROUP 经 CORRNUM 出生即挂;TABL/SOURCE_UPDATE 仅记录,挂 TR 用 sap_dev_tr_put/SE10)'),
    shortText: z.string().optional().describe('对象短描述'),
    // --- TABL ---
    tabclass: z.string().optional().describe('[TABL] INTTAB=结构(默认) / TRANSP=透明表'),
    dd03p: z.array(z.any()).optional().describe('[TABL] 字段清单:每项 {POSITION?,FIELDNAME,ROLLNAME? | DATATYPE+LENG+INTTYPE,DDTEXT?}'),
    // --- FUNC ---
    funcPool: z.string().optional().describe('[FUNC] 函数组名'),
    remoteCall: z.string().optional().describe('[FUNC] X=RFC-enabled(默认X), 空格=否'),
    importParams: z.array(z.any()).optional().describe('[FUNC] IMPORT 参数 [{PARAMETER,TYP,DEFAULT?,OPTIONAL?}]'),
    exportParams: z.array(z.any()).optional().describe('[FUNC] EXPORT 参数 [{PARAMETER,TYP}]'),
    tablesParams: z.array(z.any()).optional().describe('[FUNC] TABLES 参数 [{PARAMETER,DBSTRUCT|STRUCTURE}]'),
    changingParams: z.array(z.any()).optional().describe('[FUNC] CHANGING 参数'),
    exceptions: z.array(z.any()).optional().describe('[FUNC] EXCEPTION 参数 [{PARAMETER}]'),
    source: z.string().optional().describe('[FUNC] 函数体(不含 FUNCTION/ENDFUNCTION 行,每行≤72); [SOURCE_UPDATE] 完整 include 源码(含 FUNCTION...ENDFUNCTION,每行≤72)'),
    programName: z.string().optional().describe('[SOURCE_UPDATE] Z/Y 程序/include 名(直写模式,与 objectName 二选一)'),
    overwrite: z.boolean().optional().describe('true=覆盖已存在 Z/Y 对象(修复污染/重建用;默认 false 只建不改。仍限 Z/Y 命名空间 + DVP)'),
  },
  allowedEnvs: ['DVP'],
  opClass: 'dev-write',
  needsRfc: true,
  underlying: [], // DDIF_TABL_PUT or RPY_FUNCTIONMODULE_INSERT, chosen by objectType
  async run(args, ctx) {
    const objType = String(args.objectType).toUpperCase();
    const objName = String(args.objectName).toUpperCase().trim();
    const devclass = String(args.devclass || '').trim();
    const trkorr = String(args.trkorr || '').trim().toUpperCase();

    // SOURCE_UPDATE: rewrite an existing program/include's source in place (fix it, don't
    // create a new name). Include names start with L (e.g. LZFG_LILY_DIAGU02), not Z/Y, so
    // this bypasses the namespace guard with its own devclass+trkorr check.
    if (objType === 'SOURCE_UPDATE') {
      if (!devclass) return { ok: false, code: 'MISSING_DEVCLASS', message: 'devclass 必填。' };
      if (!trkorr) return { ok: false, code: 'MISSING_TRKORR', message: 'trkorr 必填。' };
      return updateSource(ctx, args);
    }

    // guard 1: customer namespace only
    if (!isCustomerNamespace(objName)) {
      return { ok: false, code: 'NOT_CUSTOMER_NAMESPACE',
        message: `${objName} 不是客户命名空间(Z/Y 或 /NSP/)。dev 工具只建 Z/Y 对象,标准程序与增强绝不触碰。` };
    }
    // guard 4: devclass + trkorr required per call
    if (!devclass) return { ok: false, code: 'MISSING_DEVCLASS', message: 'devclass(Package)必填。' };
    if (!trkorr) return { ok: false, code: 'MISSING_TRKORR', message: 'trkorr(传输请求号)必填。' };

    // guard 3: create-only by default; overwrite=true skips the probe so existing
    // Z/Y objects can be corrected (e.g. fix a polluted function group). Standard
    // objects are still refused above by the namespace guard.
    const overwrite = args.overwrite === true;
    if (!overwrite) {
      const exists = await probeExists(ctx, objType, objName);
      if (exists) {
        return { ok: false, code: 'OBJECT_EXISTS',
          message: `${objType} ${objName} 已存在。dev 工具默认只建不改;要覆盖重建加 overwrite=true。` };
      }
    }

    if (objType === 'FUNCGROUP') return createFuncGroup(ctx, args, objName);
    if (objType === 'TABL') return createTabl(ctx, args, objName);
    return createFunc(ctx, args, objName);
  },
};

async function probeExists(ctx, objType, objName) {
  const step = objType === 'TABL'
    ? { id: 'probe', function: 'DDIF_TABL_GET', import: { NAME: objName } }
    : { id: 'probe', function: 'RPY_FUNCTIONMODULE_READ', import: { FUNCTIONNAME: objName } };
  try {
    const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
    if (!r.ok) return false;
    const p = r.results && r.results.probe;
    return !!(p && !p._error);
  } catch { return false; }
}

async function updateSource(ctx, args) {
  // Rewrite an existing Z/Y FUNCTION's source (derives its include L+pool+U+num from
  // TFDIR) OR a Z/Y PROGRAM/INCLUDE's source (direct) via RFC wrapper
  // ZLILY_DIAG_SRC_PUT8 (group ZFG_LILY_DEV). Wrapper does LOCAL INSERT REPORT.
  // Z/Y namespace guard runs BOTH here (isCustomerNamespace) and inside the wrapper —
  // standard programs / enhancements are hard-refused at two layers.
  //   objectName   = Z/Y function name → wrapper resolves include
  //   programName  = Z/Y program/include name → wrapper writes directly
  const fm = 'ZLILY_DIAG_SRC_PUT8';
  const chk = checkFmAllowed({ fm, system: ctx.system, opClass: 'dev-write' });
  if (!chk.ok) return { ok: false, code: chk.code, message: chk.message };
  const funcName = String(args.objectName || '').toUpperCase().trim();
  const progName = String(args.programName || '').toUpperCase().trim();
  if (!funcName && !progName) return { ok: false, code: 'MISSING_TARGET',
    message: 'SOURCE_UPDATE 需要 objectName(Z/Y 函数名)或 programName(Z/Y 程序/include 名)。' };
  if (funcName && !isCustomerNamespace(funcName)) return { ok: false, code: 'NOT_CUSTOMER_NAMESPACE',
    message: `${funcName} 不是 Z/Y 客户命名空间。只改客户自建对象,标准程序/增强绝不触碰。` };
  if (progName && !isCustomerNamespace(progName)) return { ok: false, code: 'NOT_CUSTOMER_NAMESPACE',
    message: `${progName} 不是 Z/Y 客户命名空间。只改客户自建对象。` };
  const warnings = [];
  const sourceRows = String(args.source || '').split(/\r?\n/).map((line, i) => {
    if (line.length > 72) warnings.push(`源码第 ${i + 1} 行 ${line.length}>72 已截断:${line.slice(0, 40)}…`);
    return { LINE: line.slice(0, 72) };
  });
  const imp = {
    IV_DEVCLASS: String(args.devclass || '').toUpperCase(),
    IV_TRKORR: String(args.trkorr || '').toUpperCase(),
  };
  if (funcName) imp.IV_FUNCNAME = funcName;
  if (progName) imp.IV_PROG = progName;
  const step = { id: 'upd', function: fm, import: imp, tables: { IT_SOURCE: sourceRows } };
  const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
  if (!r.ok) return { ok: false, code: 'UPDATE_FAILED', message: r.message, detail: r };
  const s = r.results && r.results.upd;
  if (s && s._error) return { ok: false, code: 'UPDATE_FAILED', message: `${fm} 失败:${s._error}` };
  if (s && s.EV_ERROR) return { ok: false, code: 'UPDATE_FAILED', message: `${fm}: ${s.EV_ERROR}` };
  return { ok: true, system: ctx.system, objectType: 'SOURCE_UPDATE',
    function: funcName || undefined, program: progName || undefined,
    target: s && s.EV_TARGET, devclass: args.devclass, fm,
    sourceWarnings: warnings.length ? warnings : undefined, result: s };
}

async function createFuncGroup(ctx, args, objName) {
  // Build a brand-new Z function group via RS_FUNCTION_POOL_INSERT (RPY refuses new
  // groups). Takes DEVCLASS + CORRNUM directly, so the group is born on the right
  // package/transport. Used to escape a polluted function group (SAPLZFG_LILY_MCP has
  // orphan-include syntax errors -> every function in it fails to load on execute).
  const fm = 'RS_FUNCTION_POOL_INSERT';
  const chk = checkFmAllowed({ fm, system: ctx.system, opClass: 'dev-write' });
  if (!chk.ok) return { ok: false, code: chk.code, message: chk.message };
  const imp = {
    FUNCTION_POOL: objName,
    SHORT_TEXT: args.shortText || objName,
    DEVCLASS: String(args.devclass).toUpperCase(),
    CORRNUM: String(args.trkorr).toUpperCase(),
    NAMESPACE: ' ',
  };
  const step = { id: 'create', function: fm, import: imp };
  const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
  if (!r.ok) return { ok: false, code: 'CREATE_FAILED', message: r.message, detail: r };
  const s = r.results && r.results.create;
  if (s && s._error) {
    const msg = String(s._error);
    if (/exist|already|dup/i.test(msg)) {
      return { ok: false, code: 'OBJECT_EXISTS',
        message: `函数组 ${objName} 已存在。dev 工具只建不改。` };
    }
    return { ok: false, code: 'CREATE_FAILED', message: `${fm} 失败:${msg}` };
  }
  return { ok: true, system: ctx.system, objectType: 'FUNCGROUP', objectName: objName,
    devclass: args.devclass, fm, result: s };
}

async function createTabl(ctx, args, objName) {
  // DDIF_TABL_PUT is NOT RFC-enabled, so creating a Z structure/table over RFC routes
  // through ZLILY_DIAG_TBL_MK3 (RFC-enabled wrapper in clean group ZFG_LILY_DIAG2, locally
  // calls DDIF_TABL_PUT + ACTIVATE + COMMIT WORK). Source = verified MK version + COMMIT.
  const fm = 'ZLILY_DIAG_TBL_MK3';
  const chk = checkFmAllowed({ fm, system: ctx.system, opClass: 'dev-write' });
  if (!chk.ok) return { ok: false, code: chk.code, message: chk.message };

  if (!Array.isArray(args.dd03p) || args.dd03p.length === 0) {
    return { ok: false, code: 'NO_FIELDS', message: 'TABL 需要 dd03p 字段清单(至少 1 个字段)。' };
  }
  const tabclass = (args.tabclass || 'INTTAB').toUpperCase();
  const dd03p = args.dd03p.map((f, i) => {
    const row = {
      TABNAME: objName,
      FIELDNAME: String(f.FIELDNAME).toUpperCase(),
      POSITION: String(f.POSITION || (i + 1)).padStart(4, '0'),
      DDLANGUAGE: 'ZH',
      DDTEXT: f.DDTEXT || String(f.FIELDNAME).toUpperCase(),
    };
    if (f.ROLLNAME) row.ROLLNAME = String(f.ROLLNAME).toUpperCase();
    if (f.DATATYPE) row.DATATYPE = String(f.DATATYPE).toUpperCase();
    if (f.LENG != null) row.LENG = String(f.LENG).padStart(6, '0');
    if (f.INTTYPE) row.INTTYPE = String(f.INTTYPE);
    if (f.INTLEN != null) row.INTLEN = String(f.INTLEN).padStart(6, '0');
    // DDIC field-level attributes MK3 won't derive — pass straight through to DDIF_TABL_PUT.
    // Critical for QUAN/CURR fields: DDIC hard-requires them to reference a unit/currency
    // field (REFTABLE+REFFIELD), else activation fails with "specify reference table/field".
    if (f.REFTABLE) row.REFTABLE = String(f.REFTABLE).toUpperCase();
    if (f.REFFIELD) row.REFFIELD = String(f.REFFIELD).toUpperCase();
    if (f.REFTYPE) row.REFTYPE = String(f.REFTYPE).toUpperCase();
    if (f.CHECKTABLE) row.CHECKTABLE = String(f.CHECKTABLE).toUpperCase();
    if (f.KEYFLAG) row.KEYFLAG = String(f.KEYFLAG).toUpperCase();
    if (f.MANDATORY) row.MANDATORY = String(f.MANDATORY).toUpperCase();
    if (f.CONVEXIT) row.CONVEXIT = String(f.CONVEXIT);
    if (f.LOWERCASE) row.LOWERCASE = String(f.LOWERCASE).toUpperCase();
    return row;
  });

  const step = {
    id: 'create', function: fm,
    import: {
      IV_TABLE_NAME: objName,
      IV_TABCLASS: tabclass,
      IV_DDTEXT: args.shortText || objName,
    },
    tables: { IT_FIELDS: dd03p },
  };
  const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
  if (!r.ok) return { ok: false, code: 'CREATE_FAILED', message: r.message, detail: r };
  const s = r.results && r.results.create;
  // ZLILY_TBL_MK raises DDIC_ERROR and fills EV_ERROR on failure.
  if (s && s._error) return { ok: false, code: 'CREATE_FAILED', message: `${fm} 失败:${s._error}` };
  if (s && s.EV_ERROR) return { ok: false, code: 'CREATE_FAILED', message: `${fm} DDIC 失败:${s.EV_ERROR}` };
  return { ok: true, system: ctx.system, objectType: 'TABL', objectName: objName,
    devclass: args.devclass, tabclass, fm, result: s };
}

async function createFunc(ctx, args, objName) {
  const fm = 'RPY_FUNCTIONMODULE_INSERT';
  const chk = checkFmAllowed({ fm, system: ctx.system, opClass: 'dev-write' });
  if (!chk.ok) return { ok: false, code: chk.code, message: chk.message };

  if (!args.funcPool) return { ok: false, code: 'MISSING_FUNCPOOL', message: 'FUNC 需要 funcPool(函数组名)。' };

  const imp = {
    FUNCNAME: objName,
    FUNCTION_POOL: String(args.funcPool).toUpperCase(),
    REMOTE_CALL: (args.remoteCall || 'X').toUpperCase(),
    SHORT_TEXT: args.shortText || objName,
    NAMESPACE: ' ',
    // Pin the transport + suppress correction check so RPY does NOT pop the
    // TR-selection dialog over RFC (no GUI => "Screen output without connection").
    CORRNUM: String(args.trkorr || '').toUpperCase(),
    SUPPRESS_CORR_CHECK: 'X',
  };

  const tables = {};
  if (Array.isArray(args.importParams) && args.importParams.length)
    tables.IMPORT_PARAMETER = args.importParams.map(toRsimp);
  if (Array.isArray(args.exportParams) && args.exportParams.length)
    tables.EXPORT_PARAMETER = args.exportParams.map(toRsimp);
  if (Array.isArray(args.tablesParams) && args.tablesParams.length)
    // RSTBL: ONLY PARAMETER+DBSTRUCT (setting TYP=<structname> makes RPy treat the
    // structure name as a type name and refuse to create the tables param).
    tables.TABLES_PARAMETER = args.tablesParams.map((t) => ({
      PARAMETER: t.PARAMETER,
      DBSTRUCT: String(t.DBSTRUCT || t.STRUCTURE || t.TYP || '').toUpperCase(),
    }));
  if (Array.isArray(args.changingParams) && args.changingParams.length)
    tables.CHANGING_PARAMETER = args.changingParams.map(toRsimp);
  if (Array.isArray(args.exceptions) && args.exceptions.length)
    // RSEXC runtime field is EXCEPTION (not PARAMETER)
    tables.EXCEPTION_LIST = args.exceptions.map((e) => ({ EXCEPTION: e.PARAMETER || e.EXCEPTION || e }));

  const sourceWarnings = [];
  if (args.source) {
    tables.SOURCE = String(args.source).split(/\r?\n/).map((line, i) => {
      if (line.length > 72) sourceWarnings.push(`源码第 ${i + 1} 行 ${line.length}>72 字符已截断,请改 & 续行:${line.slice(0, 50)}…`);
      return { LINE: line.slice(0, 72) };
    });
  }

  const step = { id: 'create', function: fm, import: imp, tables };
  const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
  if (!r.ok) return { ok: false, code: 'CREATE_FAILED', message: r.message, detail: r };
  const s = r.results && r.results.create;
  if (s && s._error) return { ok: false, code: 'CREATE_FAILED', message: `${fm} 失败:${s._error}` };
  return {
    ok: true, system: ctx.system, objectType: 'FUNC', objectName: objName,
    funcPool: imp.FUNCTION_POOL, remoteCall: imp.REMOTE_CALL, fm,
    functionInclude: s && s.FUNCTION_INCLUDE,
    sourceWarnings: sourceWarnings.length ? sourceWarnings : undefined,
    result: s,
  };
}

function toRsimp(p) {
  // ONLY PARAMETER+TYP(+DEFAULT). Setting OPTIONAL/REFERENCE here was tolerated
  // by NCo set but interfered with RPy downstream; RPy defaults them sensibly
  // (REFERENCE pass-by-ref, OPTIONAL when DEFAULT present). Verified by probe.
  const row = {
    PARAMETER: p.PARAMETER,
    TYP: String(p.TYP || p.TYPE || '').toUpperCase(),
  };
  if (p.DEFAULT != null) row.DEFAULT = String(p.DEFAULT);
  return row;
}
