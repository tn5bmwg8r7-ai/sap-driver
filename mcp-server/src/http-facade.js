// http-facade.js — SAP MCP 本地 HTTP 门面(PW SAP Driver P1,2026-09-14)。
//
// 目的:把 TOOLS 注册表原样暴露给 PW bridge(127.0.0.1 + Bearer),让 SAP Driver tab
// 与 Claude Code 走**同一套工具实现与治理**(env-policy / fm-check / audit / workerpool
// 热连接池)。CC 的 stdio 通道零改动——两个进程各有各的 worker 池,互不干扰。
//
// 安全:
//   - 只绑 127.0.0.1;所有路由校验 Authorization: Bearer <token>(facade.local.json,不进git不分发)
//   - 白名单放行(只读/测试类);dev-write 类工具(dev_create/dev_delete/dev_tr/variant_write)不暴露
//   - 密码仅经 sap_connect 进本进程内存(credentials.js Map),审计 scrub 脱敏,绝不落盘
// 性能:
//   - 复用 ps/workerpool.js 按系统长驻 PS worker(NCo 一次性加载),PW 调用走热连接
//
// 与 server.js 的管线保持同构(env-lock -> credential -> audit -> run -> mask)。
// 两处注释性重复是有意的:CC 通道零触碰优先于 DRY。
//
// 环境变量(缺省时自动解析,与 .claude.json mcpServers.sap.env 对齐):
//   SAP_MCP_SYSTEMS / SAP_MCP_BIN / SAP_MCP_AUDIT_DIR
// 配置文件 facade.local.json: { "port": 8439, "token": "<random-hex>" }

import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

// ---- 环境变量缺省解析(必须在动态 import 之前:audit.js 在 import 期读 env) ----
process.env.SAP_MCP_SYSTEMS = process.env.SAP_MCP_SYSTEMS || path.join(ROOT, 'systems.json');
process.env.SAP_MCP_BIN = process.env.SAP_MCP_BIN || path.join(ROOT, 'rfc-frontend', 'RfcCli');

// ---- 配置(端口 + token;文件不存在则明确报错,不猜) ----
const cfgPath = process.env.SAP_MCP_FACADE_CONFIG || path.join(ROOT, 'facade.local.json');
let CFG;
try {
  CFG = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
} catch (e) {
  console.error(`[facade] 配置缺失/不可读: ${cfgPath} (${e.message})`);
  console.error('[facade] 请创建 facade.local.json: {"port":8439,"token":"<64位hex>"}');
  process.exit(1);
}
const PORT = Number(CFG.port) || 8439;
const TOKEN = String(CFG.token || '');
if (!TOKEN || TOKEN.length < 16) {
  console.error('[facade] token 缺失或过短(facade.local.json),拒绝启动');
  process.exit(1);
}

// ---- 动态 import:env 就位后再加载工具与治理 ----
const { TOOLS } = await import('./tools/index.js');
const { maskResult } = await import('./util/mask.js');
const { loadSystems, getSystems, checkEnv } = await import('./governance/env-policy.js');
const { writeAudit, scrub, nextRequestId, pruneAudit } = await import('./governance/audit.js');
const { getCredential, cachedSystems } = await import('./credentials.js');
const { runSteps, killAll, killSystem } = await import('./ps/workerpool.js');

loadSystems();
pruneAudit(getSystems().audit?.retentionDays || 30);

// ---- PW 门面白名单:P1 只读/测试类。dev-write 全家不暴露(卡片灰显"走CC") ----
const FACADE_TOOLS = new Set([
  'sap_connect', 'sap_env_status', 'sap_help',
  'sap_query', 'sap_object_meta', 'sap_fm_read', 'sap_prog_read', 'sap_variant_read',
  'sap_fm_exec',
  'sap_testdata_save', 'sap_testdata_load', 'sap_testdata_list',
  'sap_deepseek',
  // 变式覆盖写(接口定位一键链):工具自带 allowedEnvs=['DVP','QAS'] + opClass=variant-write,
  // PRD 在分发层就被 checkEnv 拒;写操作仍由调用方确认闸把守(sap-interface-diag 步骤4)
  'sap_variant_write',
]);

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function authed(req) {
  const h = req.headers.authorization || '';
  return h === `Bearer ${TOKEN}`;
}

function readBody(req, limit = 2 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { reject(new Error('BODY_TOO_LARGE')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

// 与 server.js 同构的执行管线(channel 标 pw,时间线里与 CC 的调用区分)
async function runTool(toolName, args) {
  // /run/* 一律 HTTP 200 + ok:false 表达应用层错误:bridge 侧 Invoke-RestMethod 遇
  // 4xx 会抛异常,会把真实 code(TOOL_NOT_EXPOSED 等)吞成 FACADE_HTTP_FAILED。
  const OK = { status: 200 };
  const def = TOOLS.find((t) => t.name === toolName);
  if (!def) return { ...OK, body: { ok: false, code: 'UNKNOWN_TOOL', message: `未知工具 ${toolName}` } };
  if (!FACADE_TOOLS.has(toolName)) {
    return { ...OK, body: { ok: false, code: 'TOOL_NOT_EXPOSED',
      message: `${toolName} 未对 PW 门面开放(写类工具请走 Claude Code)。` } };
  }

  const requestId = nextRequestId();
  const sysInput = ((args && args.system) || '').toString().toUpperCase();

  let system = null;
  if (def.requiresSystem !== false) {
    const env = checkEnv(sysInput, def.allowedEnvs);
    if (!env.ok) {
      writeAudit({ ts: Date.now(), requestId, channel: 'pw', tool: def.name, system: sysInput,
        operationClass: def.opClass, stage: 'finished', result: 'denied', code: env.code,
        params: scrub(args) });
      return { status: 200, body: { ok: false, code: env.code, message: env.message } };
    }
    system = env.system;
  } else {
    system = sysInput || 'N/A';
  }

  let cred = null;
  if (def.requiresSystem !== false && def.opClass !== 'meta' && def.needsRfc !== false) {
    cred = getCredential(system);
    if (!cred) {
      writeAudit({ ts: Date.now(), requestId, channel: 'pw', tool: def.name, system,
        operationClass: def.opClass, stage: 'finished', result: 'denied', code: 'NEED_CREDENTIAL',
        params: scrub(args) });
      return { status: 200, body: { ok: false, code: 'NEED_CREDENTIAL',
        message: `${system} 未注入凭证。请在 SAP Driver 状态条「🔑 连接管理」里输入密码连接(密码仅内存,不落盘)。` } };
    }
  }

  const startedAt = Date.now();
  writeAudit({ ts: startedAt, requestId, channel: 'pw', tool: def.name, system,
    operationClass: def.opClass, stage: 'started',
    params: scrub(args), underlyingFms: def.underlying || [] });

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
    // maskResult: PRD-only PII 脱敏;源码读取工具豁免(字节级保真,见 util/mask.js SOURCE_TOOLS)
    const result = maskResult(await def.run(args, ctx), system, def.name);
    const rows = (result && typeof result === 'object') ? result._auditRows : undefined;
    if (result && result.ok === false) {
      writeAudit({ ts: Date.now(), requestId, channel: 'pw', tool: def.name, system,
        stage: 'finished', result: 'denied', code: result.code,
        durationMs: Date.now() - startedAt });
      return { status: 200, body: { ok: false, code: result.code || 'TOOL_DENIED', message: result.message || '工具拒绝', result } };
    }
    writeAudit({ ts: Date.now(), requestId, channel: 'pw', tool: def.name, system,
      stage: 'finished', result: 'ok', rowsReturned: rows,
      durationMs: Date.now() - startedAt });
    return { status: 200, body: { ok: true, tool: def.name, durationMs: Date.now() - startedAt, result } };
  } catch (e) {
    const msg = (e && e.message) ? e.message : String(e);
    const code = (e && e.code) ? e.code : 'TOOL_ERROR';
    writeAudit({ ts: Date.now(), requestId, channel: 'pw', tool: def.name, system,
      stage: 'finished', result: 'error', code, error: msg,
      durationMs: Date.now() - startedAt });
    return { status: 200, body: { ok: false, code, message: msg } };
  }
}

const startedAt = Date.now();

const server = http.createServer(async (req, res) => {
  try {
    if (!authed(req)) return json(res, 401, { ok: false, code: 'UNAUTHORIZED', message: 'Bearer token 不匹配' });
    const url = new URL(req.url, 'http://127.0.0.1');
    const p = url.pathname;

    if (req.method === 'GET' && p === '/health') {
      const envs = getSystems().envs || {};
      return json(res, 200, {
        ok: true,
        pid: process.pid,
        uptimeMs: Date.now() - startedAt,
        credCached: cachedSystems(),
        systems: Object.fromEntries(Object.entries(envs).map(([k, v]) => [k, {
          appServerHost: v.appServerHost, systemNumber: v.systemNumber,
          client: v.client, user: v.user, role: v.role, language: v.language,
        }])),
        exposedTools: [...FACADE_TOOLS],
      });
    }

    if (req.method === 'GET' && p === '/tools') {
      return json(res, 200, {
        ok: true,
        tools: TOOLS.filter((t) => FACADE_TOOLS.has(t.name)).map((t) => ({
          name: t.name, description: t.description, opClass: t.opClass,
          allowedEnvs: t.allowedEnvs, underlying: t.underlying || [],
          requiresSystem: t.requiresSystem !== false, needsRfc: t.needsRfc !== false,
          params: Object.entries(t.schema || {}).map(([k, z]) => ({
            name: k, optional: z.isOptional?.() ?? true, desc: z.description || '',
          })),
        })),
      });
    }

    if (req.method === 'POST' && p.startsWith('/run/')) {
      const tool = decodeURIComponent(p.slice('/run/'.length));
      let args = {};
      try {
        const raw = await readBody(req);
        const parsed = raw.trim() ? JSON.parse(raw) : {};
        args = parsed.args ?? parsed;   // 兼容 {args:{...}} 与裸参数两种包法
      } catch (e) {
        return json(res, 400, { ok: false, code: 'BAD_JSON', message: `请求体解析失败: ${e.message}` });
      }
      const out = await runTool(tool, args);
      return json(res, out.status, out.body);
    }

    if (req.method === 'POST' && p === '/disconnect') {
      let body = {};
      try { body = JSON.parse((await readBody(req)) || '{}'); } catch { /* 保持 {} */ }
      const sys = String(body.system || '').toUpperCase();
      if (!['DVP', 'QAS', 'PRD'].includes(sys)) {
        return json(res, 400, { ok: false, code: 'BAD_SYSTEM', message: 'system 须为 DVP/QAS/PRD' });
      }
      const had = cachedSystems().includes(sys);
      killSystem(sys);                       // 杀该系统热 worker,连接真断
      const { clearCredential } = await import('./credentials.js');
      clearCredential(sys);
      writeAudit({ ts: Date.now(), requestId: nextRequestId(), channel: 'pw',
        tool: 'facade_disconnect', system: sys, stage: 'finished', result: 'ok' });
      return json(res, 200, { ok: true, system: sys, hadCredential: had,
        message: `${sys} 凭证已清除、连接已断开。` });
    }

    if (req.method === 'POST' && p === '/shutdown') {
      json(res, 200, { ok: true, message: 'facade shutting down' });
      killAll();
      setTimeout(() => process.exit(0), 100);
      return;
    }

    json(res, 404, { ok: false, code: 'NOT_FOUND', message: `未知路由 ${req.method} ${p}` });
  } catch (e) {
    json(res, 500, { ok: false, code: 'FACADE_ERROR', message: e.message || String(e) });
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[facade] SAP MCP http-facade on http://127.0.0.1:${PORT} (pid=${process.pid}, tools=${FACADE_TOOLS.size})`);
});

process.on('exit', () => killAll());
process.on('SIGINT', () => { killAll(); process.exit(130); });
process.on('SIGTERM', () => { killAll(); process.exit(143); });
