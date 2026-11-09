// deepseek.js — 公司内网 DeepSeek 调用封装(OpenAI /chat/completions 兼容)。
// 仅走内网 endpoint,数据不经过公网。供 sap_deepseek 工具使用:把 SAP 真值喂给
// DeepSeek 分析,只拿回结论。原始数据绝不 return 给 Claude(公网)。
//
// 零新依赖:Node 20+ 原生 fetch。

const BASE_URL = process.env.SAP_DEEPSEEK_URL || '';
const KEY = process.env.SAP_DEEPSEEK_KEY || '';
const MODEL = process.env.SAP_DEEPSEEK_MODEL || 'DeepSeek-V3.2';
const TIMEOUT_MS = Number(process.env.SAP_DEEPSEEK_TIMEOUT_MS) || 120000;

/**
 * 调 DeepSeek /chat/completions。
 * @param {object} opts
 * @param {string} opts.systemPrompt  系统提示(角色 + 输出格式约束)
 * @param {string} opts.userPrompt    用户提示(数据 JSON + 分析意图)
 * @param {number} [opts.maxTokens=4096]
 * @param {number} [opts.temperature=0.3]
 * @returns {Promise<{text:string, inputTokens:number, outputTokens:number, model:string}>}
 */
export async function chat({ systemPrompt, userPrompt, maxTokens = 4096, temperature = 0.3 }) {
  if (!BASE_URL || !KEY) {
    throw new Error('DEEPSEEK_NOT_CONFIGURED: 未配置 SAP_DEEPSEEK_URL / SAP_DEEPSEEK_KEY(内网通道;未配置时 sap_deepseek 工具不可用,其余工具不受影响)');
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  let resp;
  try {
    resp = await fetch(`${BASE_URL}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        Authorization: `Bearer ${KEY}`,
      },
      body: JSON.stringify({
        model: MODEL,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userPrompt },
        ],
        temperature,
        max_tokens: maxTokens,
        response_format: { type: 'json_object' }, // 强制 JSON 输出(DeepSeek-V3 支持)
      }),
      signal: controller.signal,
    });
  } catch (e) {
    clearTimeout(timer);
    const aborted = e.name === 'AbortError';
    throw new Error(
      `DEEPSEEK_${aborted ? 'TIMEOUT' : 'NETWORK'}: ${e.message} (endpoint=${BASE_URL})`
    );
  }
  clearTimeout(timer);

  if (!resp.ok) {
    const body = await resp.text().catch(() => '');
    throw new Error(`DEEPSEEK_HTTP_${resp.status}: ${body.slice(0, 500)} (endpoint=${BASE_URL})`);
  }

  const data = await resp.json();
  const text = data?.choices?.[0]?.message?.content ?? '';
  if (!text) throw new Error('DEEPSEEK_EMPTY_RESPONSE: choices[0].message.content 为空');

  return {
    text,
    inputTokens: data?.usage?.prompt_tokens ?? 0,
    outputTokens: data?.usage?.completion_tokens ?? 0,
    model: data?.model || MODEL,
  };
}

export const DEEPSEEK_MODEL = MODEL;
