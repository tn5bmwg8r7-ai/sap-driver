// sap_dev_delete — DVP-only: delete a Z/Y FUNCTION MODULE via RFC wrapper
// ZLILY_DIAG_DEL (group ZFG_LILY_DEV), which locally calls FUNCTION_DELETE
// (not RFC-enabled). Z/Y namespace is hard-guarded at TWO layers (here via
// isCustomerNamespace + inside the wrapper). Standard programs / enhancements
// are never touched. Function-group / program delete can be added later.
import { z } from 'zod';
import { checkFmAllowed } from '../governance/fm-check.js';
import { isCustomerNamespace } from '../governance/env-policy.js';

export default {
  name: 'sap_dev_delete',
  description:
    'DVP 专用:删 Z/Y 函数模块(内部走 ZLILY_DIAG_DEL 包装器本地调 FUNCTION_DELETE)。护栏:对象名必须 Z/Y、MCP+包装器双层校验、标准程序/增强一概拒。【硬规则】每次调用前必须先征得用户明确确认(删除不可逆)。删函数组/程序/include 暂不支持(后续可加)。',
  schema: {
    system: z.enum(['DVP']),
    objectName: z.string().describe('要删的 Z/Y 函数名(如 ZLILY_TEST_SRCEDIT)'),
  },
  allowedEnvs: ['DVP'],
  opClass: 'dev-write',
  needsRfc: true,
  underlying: ['ZLILY_DIAG_DEL'],
  async run(args, ctx) {
    const fm = 'ZLILY_DIAG_DEL';
    const chk = checkFmAllowed({ fm, system: ctx.system, opClass: 'dev-write' });
    if (!chk.ok) return { ok: false, code: chk.code, message: chk.message };
    const funcName = String(args.objectName || '').toUpperCase().trim();
    if (!funcName) return { ok: false, code: 'MISSING_OBJECTNAME', message: '需要 objectName(Z/Y 函数名)。' };
    if (!isCustomerNamespace(funcName)) {
      return { ok: false, code: 'NOT_CUSTOMER_NAMESPACE',
        message: `${funcName} 不是 Z/Y 客户命名空间。只删客户自建对象,标准程序/增强绝不触碰。` };
    }
    const step = { id: 'del', function: fm, import: { IV_FUNCNAME: funcName } };
    const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
    if (!r.ok) return { ok: false, code: 'DELETE_FAILED', message: r.message, detail: r };
    const s = r.results && r.results.del;
    if (s && s._error) return { ok: false, code: 'DELETE_FAILED', message: `${fm} 失败:${s._error}` };
    if (s && s.EV_ERROR) return { ok: false, code: 'DELETE_FAILED', message: `${fm}: ${s.EV_ERROR}` };
    return { ok: true, system: ctx.system, deleted: funcName, fm };
  },
};
