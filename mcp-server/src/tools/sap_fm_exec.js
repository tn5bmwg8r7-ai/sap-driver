// sap_fm_exec — run a read-only FM/BAPI to see actual return (locate issues /
// reproduce third-party payloads). FM governance runs here:
//   - DVP: dvpReadFmWhitelistRegex (any read FM)
//   - QAS: qasGetWhitelist + qasGetWhitelistRegex (GET-class only) else FM_NOT_ALLOWED_ON_QAS
//   - global blocklist (COMMIT/ROLLBACK/TR_/UPDATE) always rejected
// Write-class FMs are NOT served here (phase-3 dev tools, two-phase confirm).
// paramSet: load a locally saved param set (sap_testdata_save) as base; caller's
// import/tables overlay it — enables one-click reproduce of a saved payload.
import { z } from 'zod';
import { checkFmAllowed } from '../governance/fm-check.js';
import { loadParamSet } from '../testdata.js';

export default {
  name: 'sap_fm_exec',
  description:
    '执行只读 FM/BAPI 看实际返回(定位问题 / 复现第三方报文)。治理：DVP 放行只读 FM 白名单；QAS 仅 GET 白名单(读表/读DDIC/GET类BAPI)，其余 FM_NOT_ALLOWED_ON_QAS；黑名单(COMMIT/ROLLBACK/TR_)全局拒。支持 paramSet 一键载入本地保存的参数集复现。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    function: z.string().describe('函数模块名（须 RFC-enabled）'),
    paramSet: z.string().optional().describe('本地参数集名(sap_testdata_save 存的)；有则以其 import/tables 为基础，下方传入的覆盖补充'),
    import: z.any().optional().describe('IMPORT 标量参数对象 {PARAM_NAME: value}（覆盖 paramSet 同名字段）'),
    tables: z.any().optional().describe('TABLES 参数对象 {TAB_NAME: [{COL: value}, ...]}（覆盖 paramSet 同名表）'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'exec-readonly',
  needsRfc: true,
  underlying: [], // user-specified FM; governed by fm-check + recorded in audit params.function
  async run(args, ctx) {
    const fm = String(args.function).toUpperCase().trim();

    const chk = checkFmAllowed({ fm, system: ctx.system, opClass: 'exec-readonly' });
    if (!chk.ok) return { ok: false, code: chk.code, message: chk.message };

    // base from param set, then overlay caller's import/tables
    let importParam = {};
    let tablesParam = {};
    if (args.paramSet) {
      const ps = loadParamSet(ctx.system, fm, args.paramSet);
      if (!ps) {
        return { ok: false, code: 'PARAMSET_NOT_FOUND',
          message: `参数集不存在：${ctx.system}/${fm}/${args.paramSet}。用 sap_testdata_list 查看。` };
      }
      importParam = { ...(ps.import || {}) };
      tablesParam = { ...(ps.tables || {}) };
    }
    if (args.import) {
      const imp = (typeof args.import === 'string' && args.import.trim().startsWith('{'))
        ? JSON.parse(args.import) : args.import;
      if (imp && typeof imp === 'object') importParam = { ...importParam, ...imp };
    }
    if (args.tables) {
      const tab = (typeof args.tables === 'string' && args.tables.trim().startsWith('{'))
        ? JSON.parse(args.tables) : args.tables;
      if (tab && typeof tab === 'object') tablesParam = { ...tablesParam, ...tab };
    }

    const step = { id: 'exec', function: fm };
    if (Object.keys(importParam).length) step.import = importParam;
    if (Object.keys(tablesParam).length) step.tables = tablesParam;

    const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
    if (!r.ok) return { ok: false, code: 'FM_EXEC_FAILED', message: r.message, detail: r };
    const st = r.results && r.results.exec;
    if (st && st._error) {
      return { ok: false, code: 'FM_EXEC_FAILED',
        message: `${fm} 执行失败：${st._error}（若提示不可调用/RFC 相关，该函数可能未启用 RFC）。` };
    }

    return {
      ok: true,
      system: ctx.system,
      function: fm,
      ...(args.paramSet ? { paramSet: args.paramSet } : {}),
      result: st, // Invoke-SapRfc returns all EXPORT/CHANGING/TABLES params as a plain object
    };
  },
};
