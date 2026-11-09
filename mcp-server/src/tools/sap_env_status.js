// sap_env_status — reachability + credential-cache + 24h audit counts.
// Pings each cached system (STFC_CONNECTION); uncached systems are reported as
// such (no ping). Does not require a credential to call (self-manages).
import { z } from 'zod';
import { getCredential, maskUser, cachedSystems } from '../credentials.js';
import { countAuditRecent } from '../governance/audit.js';

export default {
  name: 'sap_env_status',
  description: '查看 DVP/QAS/PRD 系统可达性、凭证缓存状态、24 小时审计调用计数与拒绝计数。不传 system 则查全部 DVP/QAS/PRD。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']).optional().describe('单个系统；不填则查全部 DVP/QAS/PRD'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',
  needsRfc: false,
  requiresSystem: false,
  underlying: ['STFC_CONNECTION'],
  async run(args, ctx) {
    const sys = ctx.systems;
    const targets = args.system ? [String(args.system).toUpperCase()] : ['DVP', 'QAS', 'PRD'];
    const envs = [];
    for (const s of targets) {
      const cfg = sys.envs[s];
      if (!cfg) { envs.push({ system: s, error: '未知系统' }); continue; }
      const cred = getCredential(s);
      let reachable;
      if (cred) {
        try {
          const r = await ctx.runSteps({
            system: s,
            password: cred.password,
            steps: [{ id: 'ping', function: 'STFC_CONNECTION', import: { REQUTEXT: 'ping' } }],
          });
          const pingErr = r.ok && r.results && r.results.ping && r.results.ping._error;
          reachable = (!r.ok || pingErr)
            ? `不可达: ${pingErr || r.message || '未知'}`
            : true;
        } catch (e) {
          reachable = `不可达: ${e.message}`;
        }
      } else {
        reachable = '未缓存凭证（先 sap_connect）';
      }
      envs.push({
        system: s,
        role: cfg.role,
        appServerHost: cfg.appServerHost,
        client: (cred && cred.client) || cfg.client,
        clientSource: (cred && cred.client) ? 'sap_connect override' : 'systems.json default',
        user: cred ? maskUser(cred.user) : cfg.user,
        credentialCached: !!cred,
        reachable,
      });
    }

    const audit24h = {
      calls: countAuditRecent((e) => e.stage === 'finished', 24),
      denied: countAuditRecent((e) => e.stage === 'finished' && e.result === 'denied', 24),
    };

    return {
      ok: true,
      envs,
      cachedSystems: cachedSystems(),
      audit24h,
      prdEnabled: !!sys.prdEnabled,
    };
  },
};
