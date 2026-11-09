// sap_object_meta — one-shot DDIC meta for table / structure / data element.
// Reuses the sap-interface-doc.ps1 (lines 98-143) DDIC reader:
//   DDIF_FIELDINFO_GET -> DFIES_TAB field catalog (table-type Z*_T_* falls back to Z*_S_*)
//   RFC_READ_TABLE(DD07T) -> ZZ_* domain fixed values
// Adds check-table + customer-vs-standard namespace tagging.
import { z } from 'zod';
import { isCustomerNamespace } from '../governance/env-policy.js';
import { asArray, parseRfcReadTable, withAuditRows } from '../util/result-shape.js';

export default {
  name: 'sap_object_meta',
  description:
    '一站式读取表/结构/数据元素的 DDIC 元信息：字段目录 + ZZ_* 域固定值 + 检查表 + 是否标准命名空间。表类型 Z*_T_* 自动回退行类型 Z*_S_*。开发前调研首选（配合 sap_fm_read）。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']),
    object: z.string().describe('表名 / 结构名 / 数据元素名'),
    language: z.string().optional().describe('语言，默认 ZH'),
    includeEnums: z.boolean().optional().describe('是否查 ZZ_* 域固定值，默认 true'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',
  needsRfc: true,
  underlying: ['DDIF_FIELDINFO_GET', 'RFC_READ_TABLE'],
  async run(args, ctx) {
    const object = String(args.object).toUpperCase().trim();
    const language = args.language || ctx.cred.language || 'ZH';
    const includeEnums = args.includeEnums !== false;
    const isTableType = /^Z._T_/i.test(object);
    const fallback = isTableType ? object.replace(/_T_/, '_S_') : null;

    // step 1: field catalog (object + maybe row-type fallback in one spawn)
    const steps1 = [{ id: 'fields', function: 'DDIF_FIELDINFO_GET', import: { TABNAME: object, LANGU: language } }];
    if (fallback) steps1.push({ id: 'fields_fb', function: 'DDIF_FIELDINFO_GET', import: { TABNAME: fallback, LANGU: language } });

    const r1 = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: steps1 });
    if (!r1.ok) return { ok: false, code: 'META_FAILED', message: r1.message, detail: r1 };
    const sFields = r1.results && r1.results.fields;
    const sFb = r1.results && r1.results.fields_fb;
    if (sFields && sFields._error && (!sFb || sFb._error)) {
      // v18.2:传进来的可能是函数名而非表/结构(实爆:FM 名当结构名→DDIF NOT_FOUND)——查 TFDIR 给可读提示
      let fmHint = '';
      try {
        const q = await ctx.runSteps({
          system: ctx.system, password: ctx.cred.password,
          steps: [{
            id: 'tfd', function: 'RFC_READ_TABLE',
            import: { QUERY_TABLE: 'TFDIR', DELIMITER: '|', ROWCOUNT: 1 },
            tables: {
              OPTIONS: [{ TEXT: `FUNCNAME = '${object}'` }],
              FIELDS: [{ FIELDNAME: 'FUNCNAME' }],
            },
          }],
        });
        const st = q && q.results && q.results.tfd;
        if (st && !st._error) {
          const rows = parseRfcReadTable({ data: st.DATA, fields: ['FUNCNAME'], delimiter: '|' });
          if (rows.rows && rows.rows.length) {
            fmHint = `（${object} 是函数模块名，不是表/结构；读它的源码用 sap_fm_read，其 interface tables/exporting 里的 DBSTRUCT 才是结构名）`;
          }
        }
      } catch { /* 提示拿不到就算了,原始错误照报 */ }
      return { ok: false, code: 'META_FAILED', message: `DDIF_FIELDINFO_GET 失败：${sFields._error}${fmHint}` };
    }
    const dfiesPrimary = (sFields && !sFields._error) ? asArray(sFields.DFIES_TAB) : [];
    const dfiesFallback = (sFb && !sFb._error) ? asArray(sFb.DFIES_TAB) : [];
    const dfies = dfiesPrimary.length ? dfiesPrimary : dfiesFallback;
    const usedName = dfiesPrimary.length ? object : (fallback || object);

    if (!dfies.length) {
      return { ok: false, code: 'META_EMPTY', message: `${object} 无字段目录（可能是内置类型、对象不存在、或非字典对象）。` };
    }

    // build field list, collect ZZ_* domains
    const fields = [];
    const zzDoms = new Set();
    for (const f of dfies) {
      const dom = String(f.DOMNAME || '').toUpperCase();
      if (dom.startsWith('ZZ_')) zzDoms.add(dom);
      const field = {
        name: String(f.FIELDNAME || ''),
        datatype: String(f.DATATYPE || ''),
        leng: String(f.LENG || ''),
        rollname: String(f.ROLLNAME || ''),
        domname: dom || undefined,
        text: String(f.FIELDTEXT || '') || String(f.REPTEXT || '') || undefined,
      };
      // 转换出口(ALPHA/MATN1…):内外码转换、取数空结果诊断都靠它
      if (String(f.CONVEXIT || '').trim()) field.convexit = String(f.CONVEXIT).toUpperCase();
      if (String(f.CHECKTABLE || '').trim()) field.checkTable = String(f.CHECKTABLE).toUpperCase();
      if (String(f.KEYFLAG || '') === 'X') field.keyFlag = true;
      fields.push(field);
    }

    // step 2: ZZ_* domain fixed values (batch in one spawn)
    let enums = [];
    if (includeEnums && zzDoms.size) {
      const steps2 = [];
      for (const dom of zzDoms) {
        steps2.push({
          id: `dom_${dom}`,
          function: 'RFC_READ_TABLE',
          import: { QUERY_TABLE: 'DD07T', DELIMITER: '|' },
          tables: {
            OPTIONS: [
              { TEXT: `DOMNAME = '${dom}'` },
              { TEXT: `AND DDLANGUAGE = '1'` },
              { TEXT: `AND AS4LOCAL = 'A'` },
            ],
            FIELDS: [{ FIELDNAME: 'DOMVALUE_L' }, { FIELDNAME: 'DDTEXT' }],
          },
        });
      }
      const r2 = await ctx.runSteps({ system: ctx.system, password: ctx.cred.password, steps: steps2 });
      if (r2.ok && r2.results) {
        for (const dom of zzDoms) {
          const st = r2.results[`dom_${dom}`];
          if (!st || st._error) { enums.push({ domain: dom, error: st ? st._error : 'no result' }); continue; }
          const parsed = parseRfcReadTable({ data: st.DATA, fields: ['DOMVALUE_L', 'DDTEXT'], delimiter: '|' });
          enums.push({
            domain: dom,
            values: parsed.rows.map((r) => ({ code: r.DOMVALUE_L, text: r.DDTEXT })),
          });
        }
      }
    }

    return withAuditRows({
      ok: true,
      system: ctx.system,
      object: usedName,
      requestedObject: object,
      isCustomerNamespace: isCustomerNamespace(usedName),
      fieldCount: fields.length,
      fields,
      enums,
    }, fields.length);
  },
};
