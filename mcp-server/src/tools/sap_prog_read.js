// sap_prog_read — read ANY program/include/function-include source via the RFC
// wrapper ZLILY_DIAG_UNPACK (group ZFG_LILY_READ). The wrapper SELECTs the
// compressed source straight from REPOSRC and gzip-decompresses it, bypassing
// RPY_FUNCTIONMODULE_READ (which checks S_DEVELOP and fails for some FMs whose
// source it refuses to return). Read-only; DVP+QAS. Complements sap_fm_read
// (which reads FUNCTION source via RPY — fails for some Z FMs).
import { z } from 'zod';

export default {
  name: 'sap_prog_read',
  description:
    '读任意程序/include/函数 include 的源码:直接 SELECT REPOSRC 解压(绕开 RPY 的 S_DEVELOP,补 fm_read 读不了的函数)。入参 program=程序/include 名(如 LZIF_PP_RTG、ZREPORT);返回源码全文 + 行数。system 选源码所在系统。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    program: z.string().describe('程序/include 名,如 LZIF_PP_RTG(函数 include)、ZREPORT(程序)'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',
  needsRfc: true,
  underlying: ['ZLILY_DIAG_UNPACK'],
  async run(args, ctx) {
    const prog = String(args.program || '').toUpperCase().trim();
    if (!prog) return { ok: false, code: 'MISSING_PROGRAM', message: '需要 program(程序/include 名)。' };
    const step = { id: 'read', function: 'ZLILY_DIAG_UNPACK', import: { IV_INCL: prog } };
    const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: [step] });
    if (!r.ok) return { ok: false, code: 'READ_FAILED', message: r.message, detail: r };
    const s = r.results && r.results.read;
    if (s && s._error) return { ok: false, code: 'READ_FAILED', message: `ZLILY_DIAG_UNPACK 失败:${s._error}` };
    if (s && s.EV_ERROR) return { ok: false, code: 'READ_FAILED', message: `ZLILY_DIAG_UNPACK: ${s.EV_ERROR}` };
    const source = String(s.EV_RESULT || '');
    const lines = source ? source.split(/\r?\n/) : [];
    return { ok: true, system: ctx.system, program: prog, lineCount: lines.length, source };
  },
};
