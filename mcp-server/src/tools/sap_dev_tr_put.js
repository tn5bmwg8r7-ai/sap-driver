// sap_dev_tr_put — DVP-only: attach ONE existing Z/Y repository object to a transport
// request via RFC wrapper ZLILY_DEV_TR_PUT (group ZFG_LILY_DEV, devclass ZBC), which
// locally calls TRINT_OBJECTS_CHECK_AND_INSERT + COMMIT WORK. TR_OBJECT_INSERT itself
// is NOT RFC-enabled; this wrapper recipe was proven on ZREP003: KO200 carries ONLY
// PGMID/OBJECT/OBJ_NAME, WT_E071K stays EMPTY, IV_APPEND_TO_ORDER='X', and COMMIT WORK
// is REQUIRED or the stateless RFC LUW rolls the insert back.
// Z/Y namespace hard-guarded at TWO layers (here via isCustomerNamespace + inside the
// wrapper). Single object per call — batch = loop at the caller, per-object errors stay
// attributable. Supported pgmid/object combos follow the wrapper's probed type matrix:
//   LIMU REPS / LIMU REPT — verified (ZREP003 baseline)
//   LIMU FUNC / R3TR PROG / R3TR TABL — probed on DVP, see ticket tr.attached/manualPending
// Anything the wrapper refuses falls back to SE10 manual (non-blocking for delivery).
import { z } from 'zod';
import { checkFmAllowed } from '../governance/fm-check.js';
import { isCustomerNamespace } from '../governance/env-policy.js';

export default {
  name: 'sap_dev_tr_put',
  description:
    'DVP 专用:把一个已存在的 Z/Y 对象挂到传输请求(内部走 ZLILY_DEV_TR_PUT 包装器;结果以包装器内置 E071 实查终判为准,杜绝假 OK)。实测矩阵(2026-09-16):LIMU REPS/REPT=已注册对象可用(ZREP003 基线);R3TR 级注册+挂接=无 RFC 通道(RPY CORRNUM/TRINT/RS_CORR_INSERT 无弹窗路径三 API 全拒)→SE10 手工,登记 tr.manualPending 不阻塞交付。护栏:对象名必须 Z/Y 双层校验、trkorr 必填每次给(用前 E070 验真)。单对象单调用,批量请逐个循环。',
  schema: {
    system: z.enum(['DVP']),
    trkorr: z.string().describe('传输请求号(每次必填,绝不缓存/复用记忆里的号)'),
    pgmid: z.string().optional().describe('PGMID:R3TR(默认)或 LIMU'),
    object: z.string().describe('对象类型,如 TABL/FUNC/FUGR/PROG/REPS/REPT'),
    objName: z.string().describe('对象名(必须 Z/Y 客户命名空间)'),
  },
  allowedEnvs: ['DVP'],
  opClass: 'dev-write',
  needsRfc: true,
  underlying: ['ZLILY_DEV_TR_PUT'],
  async run(args, ctx) {
    const fm = 'ZLILY_DEV_TR_PUT';
    const chk = checkFmAllowed({ fm, system: ctx.system, opClass: 'dev-write' });
    if (!chk.ok) return { ok: false, code: chk.code, message: chk.message };

    const trkorr = String(args.trkorr || '').trim().toUpperCase();
    if (!trkorr) return { ok: false, code: 'MISSING_TRKORR', message: 'trkorr 必填(每次现给,绝不复用旧号)。' };
    const pgmid = String(args.pgmid || 'R3TR').trim().toUpperCase();
    const object = String(args.object || '').trim().toUpperCase();
    const objName = String(args.objName || '').trim().toUpperCase();
    if (!object || !objName) return { ok: false, code: 'MISSING_OBJECT', message: 'object 与 objName 必填。' };
    if (!isCustomerNamespace(objName)) {
      return { ok: false, code: 'NOT_CUSTOMER_NAMESPACE',
        message: `${objName} 非 Z/Y 客户命名空间,拒挂(标准/增强对象禁动)。` };
    }

    const step = {
      id: 'trput',
      function: fm,
      import: { IV_ORDER: trkorr, IV_PGMID: pgmid, IV_OBJECT: object, IV_OBJ_NAME: objName },
    };
    const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
    if (!r.ok) return { ok: false, code: 'TR_PUT_FAILED', message: r.message, detail: r };

    const s = r.results && r.results.trput;
    if (s && s._error) return { ok: false, code: 'TR_PUT_FAILED', message: `${fm} 失败:${s._error}` };
    if (s && s.EV_ERROR) {
      return { ok: false, code: 'TR_PUT_FAILED', message: `${fm}: ${s.EV_ERROR}`,
        manualFallback: 'SE10 手工挂(程序类 LIMU REPS+REPT 成对),并登记工单 tr.manualPending。' };
    }
    return {
      ok: true, system: ctx.system, trkorr,
      attached: { pgmid, object, objName },
      fm,
      note: (s && s.EV_MSG) || undefined,
    };
  },
};
