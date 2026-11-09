// sap_deepseek.js — 极敏感 SAP 数据走公司内网 DeepSeek 分析,真值不进 Claude(公网)。
// 流程: fetchTableRows 拉 PRD 真值(不 return) → 构造 prompt → 调内网 DeepSeek →
//       DeepSeek 出 {detail, conclusion} → detail 落本地文件 → 只 return conclusion。
// 安全: 原始数据只在内存→DeepSeek(内网闭环),从不 return,server.js 的 maskResult
//       看不到它;return 的 conclusion 被 maskResult 兜底再脱敏。
import { z } from 'zod';
import fs from 'node:fs';
import path from 'node:path';
import { fetchTableRows } from '../util/sap-fetch.js';
import { chat as deepseekChat, DEEPSEEK_MODEL } from '../util/deepseek.js';

const DETAIL_DIR = process.env.SAP_DEEPSEEK_DIR || './data/sap-deepseek';
const MAX_ROWS_TO_LLM = 50; // 喂给 LLM 的行数上限(防 token 爆;多列表建议传 fields 精简)

// ---- Prompt 工程(最关键) ----
const SYSTEM_PROMPT = `你是一名资深 SAP HR/财务数据分析专家。你会收到一份 SAP 表数据(JSON 数组)和一个分析意图。

你必须返回严格的 JSON,且只包含两个字符串字段:
{
  "detail": "...",        // 详细 Markdown 分析报告,给业务用户看
  "conclusion": "..."     // 脱敏定性结论,给 AI 助手看
}

## detail 字段规则(给业务用户,落本地文件,可含敏感细节)
- 写详细的 Markdown 分析报告:概述 → 分布统计 → 关键发现 → 异常清单。
- 可以包含具体数值、人名、工号、金额、日期等细节,用 Markdown 表格呈现关键数据。

## conclusion 字段规则(给 AI 助手,严禁含具体敏感值)
这是唯一会被 AI 助手看到的内容,必须脱敏:
- 严禁出现: 具体薪酬金额(如"张三 50000")、身份证号、手机号、银行账号、具体姓名+敏感值的组合。
- 只用汇总/区间/定性描述: "薪酬中位数在 1.5-2 万区间""3 条记录高于均值 50%""异常集中在高级职级"。
- 可以说: 行数、分布特征、异常数量、区间范围、百分比、排名(不点名)。
- 长度控制在 200-500 字。

## 输出格式
只返回 JSON 对象,不要包裹在 markdown code block 中,不要有任何前后缀文字。`;

function buildUserPrompt(rows, table, intent, fields) {
  const subset = rows.length > MAX_ROWS_TO_LLM ? rows.slice(0, MAX_ROWS_TO_LLM) : rows;
  const dataNote = rows.length > MAX_ROWS_TO_LLM
    ? `\n(注: 共 ${rows.length} 行,以下仅展示前 ${MAX_ROWS_TO_LLM} 行供分析)` : '';
  const dataJson = JSON.stringify(subset, null, 2);
  return `## 分析意图
${intent}

## 数据(SAP 表 ${table}${fields ? `, 字段: ${fields.join(', ')}` : ''})${dataNote}

\`\`\`json
${dataJson}
\`\`\`

请按系统提示要求的 JSON 格式输出 detail 和 conclusion。`;
}

// ---- JSON 容错解析 ----
function parseDeepSeekJson(text) {
  try { return { ok: true, obj: JSON.parse(text) }; } catch {}
  const m = text.match(/\{[\s\S]*\}/);
  if (m) {
    try { return { ok: true, obj: JSON.parse(m[0]) }; } catch {}
  }
  return {
    ok: false,
    fallback: {
      detail: text,
      conclusion: 'DeepSeek 返回内容无法解析为 JSON,已将原始响应存入 detail 文件,请人工查看。',
    },
  };
}

// ---- detail 落文件 ----
function writeDetail({ table, detail, rowCount, engine, model, tokens, intent }) {
  fs.mkdirSync(DETAIL_DIR, { recursive: true });
  const now = new Date();
  const p = (n) => String(n).padStart(2, '0');
  const ts = `${now.getFullYear()}${p(now.getMonth() + 1)}${p(now.getDate())}` +
             `-${p(now.getHours())}${p(now.getMinutes())}${p(now.getSeconds())}`;
  const file = path.join(DETAIL_DIR, `${ts}-${table}.md`);
  const header = [
    `# SAP DeepSeek 分析报告 — ${table}`,
    '',
    `- 生成时间: ${now.toISOString()}`,
    `- 表名: ${table}`,
    `- 行数: ${rowCount}`,
    `- 引擎: ${engine}`,
    `- 模型: ${model}`,
    `- Tokens: 输入 ${tokens.input} / 输出 ${tokens.output}`,
    `- 分析意图: ${intent}`,
    '',
    '---',
    '',
  ].join('\n');
  fs.writeFileSync(file, header + detail + '\n', 'utf8');
  return file;
}

export default {
  name: 'sap_deepseek',
  description:
    '极敏感 SAP 数据(薪酬/绩效等)走公司内网 DeepSeek 分析,真值不进 AI 上下文。' +
    'sap-mcp 进程内拉 PRD 真值 → 喂内网 DeepSeek → 只回脱敏结论;detail 落本地文件给用户看。' +
    '凭证复用 sap_connect 缓存。例:sap_deepseek({system:PRD, table:PA0008, intent:"分析薪酬分布找异常"})',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']).describe('SAP 系统(一般 PRD)'),
    table: z.string().describe('SAP 表名,如 PA0001(人员基本信息) / PA0008(薪酬)'),
    where: z.any().optional().describe('WHERE 条件,同 sap_query(数组 [{field,op,value}] 或字符串)'),
    fields: z.array(z.string()).optional().describe('字段列表(可选;ZLILY 返回全字段)'),
    intent: z.string().describe('自然语言分析意图,如"分析薪酬分布/找出异常"'),
    maxRows: z.number().int().min(1).max(1000).optional().describe('最大拉取行数,默认 100,上限 1000'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',      // 本质是读 SAP 数据(只是不 return)
  needsRfc: true,       // 需要 SAP 连接拉数(强制先 sap_connect)
  underlying: ['ZLILY_DIAG_QUERY', 'RFC_READ_TABLE'],

  async run(args, ctx) {
    const table = String(args.table).toUpperCase();
    const { intent } = args;

    // ① 拉 PRD 真值(仅存内存,不 return)
    const fetched = await fetchTableRows(ctx, {
      table, where: args.where, fields: args.fields, maxRows: args.maxRows,
    });
    if (!fetched.ok) return { ok: false, code: fetched.code, message: fetched.message };
    const { rows, engine, rowCount, moreAvailable } = fetched;

    if (!rows.length) {
      return { ok: true, conclusion: `${table} 无匹配数据。`, detailPath: null, table, rowCount: 0, _auditRows: 0 };
    }

    // ② 构造 prompt
    const userPrompt = buildUserPrompt(rows, table, intent, args.fields);

    // ③ 调内网 DeepSeek
    let llmResult;
    try {
      llmResult = await deepseekChat({
        systemPrompt: SYSTEM_PROMPT,
        userPrompt,
        maxTokens: 4096,
        temperature: 0.3,
      });
    } catch (e) {
      return {
        ok: false,
        code: (e.message || '').split(':')[0] || 'DEEPSEEK_FAILED',
        message: `DeepSeek 调用失败: ${e.message}(已拉取 ${rowCount} 行但未分析,数据未落盘未外泄)`,
        table, rowCount, engine, _auditRows: rows.length,
      };
    }

    // ④ parse JSON(容错)
    const parsed = parseDeepSeekJson(llmResult.text);
    const detail = (parsed.ok ? parsed.obj.detail : parsed.fallback.detail) || '(空)';
    const conclusion = (parsed.ok ? parsed.obj.conclusion : parsed.fallback.conclusion) || '(空)';
    const parseWarn = parsed.ok ? null : 'DeepSeek 返回非标准 JSON,已容错处理。';

    // ⑤ detail 落本地文件(含具体值,只给用户看,不进 Claude)
    const detailPath = writeDetail({
      table, detail, rowCount, engine,
      model: llmResult.model,
      tokens: { input: llmResult.inputTokens, output: llmResult.outputTokens },
      intent,
    });

    // ⑥ 只 return 脱敏 conclusion + 元数据(原始 rows 从不 return)
    //    server.js 的 maskResult 会对 conclusion 再做 PII regex 兜底脱敏。
    return {
      ok: true,
      conclusion,          // 脱敏定性结论 — 唯一会被 AI 看到的分析内容
      detailPath,          // 本地文件路径 — 用户自行打开看详情
      table,
      rowCount,
      engine,
      moreAvailable,
      ...(parseWarn ? { warning: parseWarn } : {}),
      _deepseek: {
        model: llmResult.model,
        inputTokens: llmResult.inputTokens,
        outputTokens: llmResult.outputTokens,
      },
      _auditRows: rows.length, // 审计:从 PRD 读了 N 行(虽然没 return 原始数据)
    };
  },
};
