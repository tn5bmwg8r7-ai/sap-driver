// sap_connect — inject + verify SAP credential (per session, per system).
// Pings STFC_CONNECTION; on success caches {user,password,language} in the
// process-memory Map. Password never persisted, never logged (scrubbed).
import { z } from 'zod';
import { setCredential, maskUser } from '../credentials.js';

export default {
  name: 'sap_connect',
  description:
    '注入并验证 SAP 凭证（每会话每系统首次使用前调一次）。ping STFC_CONNECTION 验证密码，缓存到进程内存（绝不落盘/不进日志/不进 settings），会话结束失效。后续只读工具自动复用。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']).describe('SAP 系统：DVP(开发机) / QAS(测试机) / PRD(生产机，只读排查，镜像 QAS 治理)'),
    password: z.string().describe('SAP 密码。仅内存使用，绝不落盘；会话结束即失效。'),
    user: z.string().optional().describe('覆盖 systems.json 中的默认用户'),
    client: z.string().regex(/^\d{3}$/, 'client 必须是 3 位数字').optional()
      .describe('登录客户端覆盖（3 位数字）。默认取 systems.json：DVP=200（可改 800/900）、QAS=800、PRD=800。覆盖后本会话内该系统的所有工具调用都走此客户端，直至重新 sap_connect。'),
    language: z.string().optional().describe('登录语言，默认 ZH'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'meta',
  needsRfc: true,
  requiresSystem: true,
  underlying: ['STFC_CONNECTION'],
  async run(args, ctx) {
    const { system } = ctx;
    const sys = ctx.systems.envs[system];
    const user = args.user || sys.user;
    const language = args.language || sys.language || 'ZH';
    const client = (args.client || sys.client || '').toString();
    if (!/^\d{3}$/.test(client)) {
      return { ok: false, code: 'BAD_CLIENT', message: `client 无效：「${client}」（须 3 位数字）。` };
    }

    const r = await ctx.runSteps({
      system,
      password: args.password,
      client,
      user,
      language,
      steps: [{ id: 'ping', function: 'STFC_CONNECTION', import: { REQUTEXT: 'sap-mcp-connect-ping' } }],
    });
    if (!r.ok) {
      return { ok: false, code: 'CONNECT_FAILED', message: r.message || 'STFC_CONNECTION 调用失败', detail: r };
    }
    const ping = r.results && r.results.ping;
    if (ping && ping._error) {
      return { ok: false, code: 'CONNECT_FAILED', message: `${system} 连接/验证失败：${ping._error}` };
    }

    setCredential(system, { user, password: args.password, language, client });
    return {
      ok: true,
      system,
      user,
      masked: maskUser(user),
      language,
      client,
      message: `${system} (${sys.appServerHost}/${client}) 凭证已验证并缓存到内存（会话结束失效）。本会话该系统的所有调用走 client=${client}。`,
    };
  },
};
