// sap_testdata_save — save a third-party payload / test params as a local param set.
// Stored as JSON under Cache\sap-mcp-testdata\{SYSTEM}\{FUNCTION}\{name}.json.
// Never writes to SAP (QAS zero-write). sap_fm_exec(paramSet) reproduces it.
import { z } from 'zod';
import { saveParamSet } from '../testdata.js';

export default {
  name: 'sap_testdata_save',
  description:
    '把第三方报文/测试参数一键存为本地参数集(变式替代)。存为本地 JSON，不写 SAP、QAS 零写入。之后 sap_fm_exec({system,function,paramSet}) 秒级复现该次调用。典型用法：拿到第三方发的报文 → 按函数接口映射成 import/tables → 存为参数集 → 随时复现定位问题。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    function: z.string().describe('函数模块名'),
    name: z.string().describe('参数集名（如 case48 / 报文20260728 / issue-xxx）'),
    import: z.any().optional().describe('IMPORT 参数对象 {PARAM_NAME: value}'),
    tables: z.any().optional().describe('TABLES 参数对象 {TAB_NAME: [{COL: value}, ...]}'),
    note: z.string().optional().describe('备注：问题现象 / 报文来源 / 触发场景'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'meta',
  needsRfc: false,
  requiresSystem: true,
  underlying: [],
  async run(args, ctx) {
    const saved = saveParamSet({
      system: ctx.system,
      fn: args.function,
      name: args.name,
      import: args.import,
      tables: args.tables,
      note: args.note,
    });
    return {
      ok: true,
      system: saved.system,
      function: saved.function,
      name: saved.name,
      file: saved.file,
      importKeys: Object.keys(saved.import),
      tableNames: Object.keys(saved.tables),
      message: `参数集已存。复现：sap_fm_exec({system:'${saved.system}', function:'${saved.function}', paramSet:'${saved.name}'})`,
    };
  },
};
