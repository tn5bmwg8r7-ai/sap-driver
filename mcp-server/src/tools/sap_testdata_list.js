// sap_testdata_list — list saved local param sets (variants) for a system/function.
import { z } from 'zod';
import { listParamSets } from '../testdata.js';

export default {
  name: 'sap_testdata_list',
  description: '列出某系统(可选限定某函数)下已存的本地参数集(变式)。不传 function 则列该系统全部。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    function: z.string().optional().describe('函数名；不填则列该系统所有函数的参数集'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',
  needsRfc: false,
  requiresSystem: true,
  underlying: [],
  async run(args, ctx) {
    const list = listParamSets(ctx.system, args.function);
    return { ok: true, system: ctx.system, count: list.length, paramSets: list };
  },
};
