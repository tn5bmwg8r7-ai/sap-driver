// sap_fm_read — function module interface + ABAP source.
// FUNCTION_IMPORT_INTERFACE -> parameter signature; RPY_FUNCTIONMODULE_READ ->
// source + parameter descriptions. Source-read failure (some Z FMs raise
// ERROR_MESSAGE) falls back to: ENLFDIR(函数组) -> ZLILY_DIAG_UNPACK 批扫
// L<组>U01..U10 -> 含目标 FUNCTION 块的 include 即源码(v18.2, 2026-09-18;
// ZIF_HR 集成组 Z FM 在 DVP/PRD 均被 RPY 拒读实爆驱动)。
import { z } from 'zod';
import { asArray, parseRfcReadTable } from '../util/result-shape.js';
import { isCustomerNamespace } from '../governance/env-policy.js';

const MAX_SOURCE_CHARS = 12000;

// RPY 拒读时的源码绕行:ENLFDIR 查函数组 → 一次 spawn 批扫组内 include(≤10)
async function fallbackSource(fm, ctx) {
  const q = await ctx.runSteps({
    system: ctx.system, password: ctx.cred.password,
    steps: [{
      id: 'grp', function: 'RFC_READ_TABLE',
      import: { QUERY_TABLE: 'ENLFDIR', DELIMITER: '|', ROWCOUNT: 2 },
      tables: {
        OPTIONS: [{ TEXT: `FUNCNAME = '${fm}'` }],
        FIELDS: [{ FIELDNAME: 'AREA' }],
      },
    }],
  });
  const st = q && q.results && q.results.grp;
  if (!st || st._error) return null;
  const rows = parseRfcReadTable({ data: st.DATA, fields: ['AREA'], delimiter: '|' });
  const area = rows && rows.rows && rows.rows[0] && String(rows.rows[0].AREA || '').toUpperCase().trim();
  if (!area) return null;

  const pad = (i) => String(i).padStart(2, '0');
  const scanSteps = [];
  for (let i = 1; i <= 10; i++) {
    scanSteps.push({ id: `u${i}`, function: 'ZLILY_DIAG_UNPACK', import: { IV_INCL: `L${area}U${pad(i)}` } });
  }
  const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: scanSteps });
  if (!r.ok || !r.results) return null;
  const re = new RegExp(`FUNCTION\\s+${fm}\\s*\\.`, 'i');
  for (let i = 1; i <= 10; i++) {
    const s = r.results[`u${i}`];
    if (!s || s._error || s.EV_ERROR) continue;
    const text = String(s.EV_RESULT || '');
    if (re.test(text)) return { include: `L${area}U${pad(i)}`, source: text };
  }
  return null;
}

export default {
  name: 'sap_fm_read',
  description:
    '读 SAP 函数模块的接口签名(importing/exporting/changing/tables) + ABAP 源码。开发前调研首选。接口来自 FUNCTION_IMPORT_INTERFACE；源码来自 RPY_FUNCTIONMODULE_READ,RPY 拒读的 Z FM(集成组常见)自动绕行 ENLFDIR→组内 include 扫描(sourceVia 注明来路),再不行才回退仅接口。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    function: z.string().describe('函数模块名'),
    includeSource: z.boolean().optional().describe('是否读源码，默认 true'),
    language: z.string().optional().describe('语言，默认 ZH'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',
  needsRfc: true,
  underlying: ['FUNCTION_IMPORT_INTERFACE', 'RPY_FUNCTIONMODULE_READ', 'RFC_READ_TABLE', 'ZLILY_DIAG_UNPACK'],
  async run(args, ctx) {
    const fm = String(args.function).toUpperCase().trim();
    const includeSource = args.includeSource !== false;

    const steps = [{ id: 'iface', function: 'FUNCTION_IMPORT_INTERFACE', import: { FUNCNAME: fm } }];
    if (includeSource) steps.push({ id: 'rpy', function: 'RPY_FUNCTIONMODULE_READ', import: { FUNCTIONNAME: fm } });

    const r = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps });
    if (!r.ok) return { ok: false, code: 'FM_READ_FAILED', message: r.message, detail: r };

    const sIface = r.results && r.results.iface;
    const sRpy = r.results && r.results.rpy;
    if (sIface && sIface._error) {
      return { ok: false, code: 'FM_NOT_FOUND', message: `FUNCTION_IMPORT_INTERFACE 失败（函数可能未部署到 ${ctx.system}）：${sIface._error}` };
    }

    // parameter descriptions (PTEXT) from RPY
    const ptext = {};
    if (sRpy && !sRpy._error) {
      for (const tbl of ['IMPORT_PARAMETER', 'EXPORT_PARAMETER', 'CHANGING_PARAMETER', 'TABLES_PARAMETER']) {
        for (const p of asArray(sRpy[tbl])) {
          if (p.PARAMETER) ptext[String(p.PARAMETER)] = String(p.PTEXT || '');
        }
      }
    }

    const sect = (params, typeField) => asArray(params)
      .map((p) => ({
        name: String(p.PARAMETER || ''),
        type: String(p[typeField] || '') || undefined,
        default: String(p.DEFAULT || '') || undefined,
        text: ptext[String(p.PARAMETER)] || undefined,
      }))
      .filter((x) => x.name);

    const iface = {
      importing: sect(sIface.IMPORT_PARAMETER, 'TYP'),
      exporting: sect(sIface.EXPORT_PARAMETER, 'TYP'),
      changing: sect(sIface.CHANGING_PARAMETER, 'DBSTRUCT'),
      tables: sect(sIface.TABLES_PARAMETER, 'DBSTRUCT'),
    };

    // source
    let source = null;
    let sourceError = null;
    let sourceTruncated = false;
    let sourceVia = null;
    if (includeSource) {
      if (sRpy && sRpy._error) {
        sourceError = sRpy._error;
        // v18.2 绕行:RPY 拒读 → ENLFDIR+UNPACK 找 include(成功时 source 照常返回,sourceVia 注明来路)
        try {
          const fb = await fallbackSource(fm, ctx);
          if (fb && fb.source) {
            let joined = fb.source;
            if (joined.length > MAX_SOURCE_CHARS) {
              joined = joined.slice(0, MAX_SOURCE_CHARS) + `\n... [源码截断：共 ${joined.length} 字符，已显示前 ${MAX_SOURCE_CHARS}]`;
              sourceTruncated = true;
            }
            source = joined;
            sourceVia = fb.include;
          }
        } catch { /* 绕行失败保持 sourceError,降级仅接口 */ }
      } else if (sRpy && sRpy.SOURCE) {
        const lines = asArray(sRpy.SOURCE).map((l) => String(l.LINE || ''));
        let joined = lines.join('\n');
        if (joined.trim()) {
          if (joined.length > MAX_SOURCE_CHARS) {
            joined = joined.slice(0, MAX_SOURCE_CHARS) + `\n... [源码截断：共 ${joined.length} 字符，已显示前 ${MAX_SOURCE_CHARS}]`;
            sourceTruncated = true;
          }
          source = joined;
        }
      }
    }

    return {
      ok: true,
      system: ctx.system,
      function: fm,
      isCustomerNamespace: isCustomerNamespace(fm),
      interface: iface,
      ...(source !== null ? { source } : {}),
      ...(sourceError ? { sourceError } : {}),
      ...(sourceVia ? { sourceVia } : {}),
      ...(sourceTruncated ? { sourceTruncated } : {}),
      ...(includeSource && source === null && !sourceError ? { hint: '源码为空（FM 可能是空壳或仅有定义）。' } : {}),
    };
  },
};
