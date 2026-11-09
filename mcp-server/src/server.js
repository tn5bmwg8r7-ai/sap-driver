// server.js — SAP MCP stdio server.
// Loads governance + systems, registers every tool from tools/index.js, and wraps
// each handler with: env-lock -> credential check -> audit(started/finished) -> scrub.
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

import { TOOLS } from './tools/index.js';
import { maskResult } from './util/mask.js';
import { loadSystems, getSystems, checkEnv } from './governance/env-policy.js';
import { writeAudit, scrub, nextRequestId, pruneAudit } from './governance/audit.js';
import { getCredential } from './credentials.js';
import { runSteps, killAll } from './ps/workerpool.js';

// bootstrap: load config, prune old audit files
loadSystems();
pruneAudit(getSystems().audit?.retentionDays || 30);

const server = new McpServer({
  name: 'sap',
  version: '0.1.0',
});

function toText(obj) {
  return { content: [{ type: 'text', text: JSON.stringify(obj, null, 2) }] };
}
function toError(err) {
  return { isError: true, content: [{ type: 'text', text: JSON.stringify(err, null, 2) }] };
}

for (const def of TOOLS) {
  server.tool(def.name, def.description, def.schema, async (args) => {
    const requestId = nextRequestId();
    const sysInput = ((args && args.system) || '').toString().toUpperCase();

    // 1) env lock (PRD forbidden this release; allowedEnvs per tool).
    //    Tools that don't touch SAP (help/env_status) set requiresSystem:false
    //    to skip env-lock + credential; they self-manage any access.
    let system = null;
    if (def.requiresSystem !== false) {
      const env = checkEnv(sysInput, def.allowedEnvs);
      if (!env.ok) {
        writeAudit({ ts: Date.now(), requestId, tool: def.name, system: sysInput,
          operationClass: def.opClass, stage: 'finished', result: 'denied', code: env.code,
          params: scrub(args) });
        return toError({ ok: false, code: env.code, message: env.message });
      }
      system = env.system;
    } else {
      system = sysInput || 'N/A';
    }

    // 2) credential check (meta tools inject creds; non-RFC tools skip)
    let cred = null;
    if (def.requiresSystem !== false && def.opClass !== 'meta' && def.needsRfc !== false) {
      cred = getCredential(system);
      if (!cred) {
        writeAudit({ ts: Date.now(), requestId, tool: def.name, system,
          operationClass: def.opClass, stage: 'finished', result: 'denied', code: 'NEED_CREDENTIAL',
          params: scrub(args) });
        return toError({ ok: false, code: 'NEED_CREDENTIAL',
          message: `${system} 未注入凭证。请先调用 sap_connect({system:'${system}', password:'...'})（密码仅内存，不落盘）。` });
      }
    }

    // 3) audit started (params scrubbed of credential keys)
    const startedAt = Date.now();
    writeAudit({ ts: startedAt, requestId, tool: def.name, system,
      operationClass: def.opClass, stage: 'started',
      params: scrub(args), underlyingFms: def.underlying || [] });

    // 4) run the tool
    //    ctx.runSteps centrally injects the session's effective login identity
    //    (client/user/language overrides from sap_connect, cached on the
    //    credential) into every RFC call, so all tools transparently follow the
    //    identity chosen at connect time.
    const ctx = {
      systems: getSystems(), requestId, system, cred, writeAudit, scrub,
      runSteps: (opts) => runSteps({
        ...opts,
        client: opts.client ?? (cred ? cred.client : undefined),
        user: opts.user ?? (cred ? cred.user : undefined),
        language: opts.language ?? (cred ? cred.language : undefined),
      }),
    };
    try {
      // Mask PII the instant a tool result is produced — before it leaves the MCP
      // server. One chokepoint covers all tools; maskResult masks PRODUCTION only
      // (system==='PRD'); DVP/QAS returned untouched. Source-code tools
      // (sap_prog_read/sap_fm_read) are exempt — see util/mask.js SOURCE_TOOLS.
      const result = maskResult(await def.run(args, ctx), system, def.name);
      const rows = (result && typeof result === 'object') ? result._auditRows : undefined;
      if (result && result.ok === false) {
        writeAudit({ ts: Date.now(), requestId, tool: def.name, system,
          stage: 'finished', result: 'denied', code: result.code,
          durationMs: Date.now() - startedAt });
        return toError(result);
      }
      writeAudit({ ts: Date.now(), requestId, tool: def.name, system,
        stage: 'finished', result: 'ok', rowsReturned: rows,
        durationMs: Date.now() - startedAt });
      return toText(result);
    } catch (e) {
      const msg = (e && e.message) ? e.message : String(e);
      const code = (e && e.code) ? e.code : 'TOOL_ERROR';
      writeAudit({ ts: Date.now(), requestId, tool: def.name, system,
        stage: 'finished', result: 'error', code, error: msg,
        durationMs: Date.now() - startedAt });
      return toError({ ok: false, code, message: msg });
    }
  });
}

const transport = new StdioServerTransport();
await server.connect(transport);

// MCP client disconnect (stdin closes) -> tear down the resident worker pool so
// no powershell.exe workers outlive the server. (workerpool.js also hooks
// process exit/SIGINT/SIGTERM; this covers the stdio-end case.)
process.stdin.on('end', () => { killAll(); process.exit(0); });
