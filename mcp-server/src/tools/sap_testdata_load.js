// sap_testdata_load — read a saved local param set (see its import/tables/note).
import { z } from 'zod';
import { loadParamSet } from '../testdata.js';

export default {
  name: 'sap_testdata_load',
  description: '读取已存的本地参数集(变式)完整内容：import / tables / 备注 / 保存时间。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    function: z.string(),
    name: z.string(),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',
  needsRfc: false,
  requiresSystem: true,
  underlying: [],
  async run(args, ctx) {
    const d = loadParamSet(ctx.system, args.function, args.name);
    if (!d) {
      return { ok: false, code: 'PARAMSET_NOT_FOUND',
        message: `参数集不存在：${ctx.system}/${args.function}/${args.name}。用 sap_testdata_list 查看已有参数集。` };
    }
    return { ok: true, ...d };
  },
};
