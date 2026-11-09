// workerpool.js — per-system long-lived PS worker pool (replaces spawn-per-call).
// Reuses the one-time NCo load + DConfig compile + destination registration
// across many exec requests. Falls back to spawn.js (runStepsSpawn) on ANY
// worker failure, so it is never worse than the old spawn-per-call path.
//
// Hard constraint: one worker = one system (DConfig public-static + NCo single
// registration). Per-system serial queue (depth 1); cross-system parallel.
//
// Protocol with worker.ps1 (one JSON line per message):
//   INIT  -> {"system","password","conn"}  ... {"ready":true} | {"ready":false,...}
//   EXEC  -> {"steps":[...]}               ... {"ok":true,"results":{...}}
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { runSteps as runStepsSpawn } from './spawn.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const workerPs1 = path.join(__dirname, 'worker.ps1');

const POOL_DISABLED = process.env.SAP_MCP_POOL === '0';
const INIT_TIMEOUT_MS = Number(process.env.SAP_MCP_POOL_INIT_TIMEOUT_MS) || 60000;
const EXEC_TIMEOUT_MS = Number(process.env.SAP_MCP_POOL_EXEC_TIMEOUT_MS) || 90000;
const MAX_FAILS = Number(process.env.SAP_MCP_POOL_MAX_FAILS) || 2;

const pools = new Map();       // system -> Entry
const connCache = new Map();   // system|client -> conn (systems.json rarely changes)

// client/user/languageOverride: sap_connect 的登录参数覆盖（undefined = systems.json 默认）。
// 缓存键带上三者，同一系统不同组合的 conn 并存，切换时靠下方的 recycle 重建 worker。
function readConn(system, systemsPath, clientOverride, userOverride, languageOverride) {
  const cacheKey = system + '|' + (clientOverride || '') + '|' + (userOverride || '') + '|' + (languageOverride || '');
  if (connCache.has(cacheKey)) return connCache.get(cacheKey);
  const sys = JSON.parse(readFileSync(systemsPath, 'utf8'));
  const cfg = sys.envs?.[system];
  if (!cfg) throw new Error(`system ${system} not in systems.json`);
  const conn = {
    AppServerHost: cfg.appServerHost,
    SystemNumber: cfg.systemNumber,
    Client: clientOverride || cfg.client,
    User: userOverride || cfg.user,
    Language: languageOverride || cfg.language || 'ZH',
  };
  connCache.set(cacheKey, conn);
  return conn;
}

function createEntry(system, password, conn, systemsPath, sapBin) {
  return {
    system, password, conn,
    _systemsPath: systemsPath, _sapBin: sapBin,
    proc: null,
    state: 'starting',          // starting | ready | dead
    queue: [],                  // FIFO of pending jobs
    currentJob: null,
    busy: false,
    stdoutBuf: '', stderrBuf: '',
    failCount: 0, disabled: false,
    readyResolvers: [], readyRejecters: [],
    initTimer: null,
  };
}

function spawnWorker(entry) {
  const proc = spawn('powershell.exe', [
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', workerPs1,
  ], {
    env: { ...process.env, SAP_MCP_SYSTEMS: entry._systemsPath, SAP_MCP_BIN: entry._sapBin },
    windowsHide: true,
  });
  entry.proc = proc;
  // Guard every callback with `entry.proc === proc` so a killed/stale proc's
  // late close/data events cannot corrupt the replacement worker bound to entry.
  proc.stdout.on('data', (d) => { if (entry.proc === proc) onStdout(entry, d); });
  proc.stderr.on('data', (d) => { if (entry.proc === proc) entry.stderrBuf += d.toString('utf8'); });
  proc.on('close', (code) => { if (entry.proc === proc) onProcClose(entry, code); });
  proc.on('error', (e) => { if (entry.proc === proc) onProcError(entry, e); });
  // INIT line — password via stdin only, never on CLI args
  proc.stdin.write(JSON.stringify({
    system: entry.system, password: entry.password, conn: entry.conn,
  }) + '\n');
}

function ensureReady(entry) {
  if (entry.state === 'ready') return Promise.resolve();
  return new Promise((resolve, reject) => {
    entry.readyResolvers.push(resolve);
    entry.readyRejecters.push(reject);
    if (!entry.initTimer) {
      entry.initTimer = setTimeout(() => {
        failInit(entry, 'DISPATCHER_INIT_TIMEOUT', `worker not ready in ${INIT_TIMEOUT_MS}ms`);
      }, INIT_TIMEOUT_MS);
    }
  });
}

function markReady(entry) {
  entry.state = 'ready';
  if (entry.initTimer) { clearTimeout(entry.initTimer); entry.initTimer = null; }
  const rs = entry.readyResolvers; entry.readyResolvers = [];
  entry.readyRejecters = [];
  rs.forEach((r) => r());
  drain(entry);   // run anything queued during init / after respawn
}

function failInit(entry, code, msg) {
  entry.state = 'dead';
  if (entry.initTimer) { clearTimeout(entry.initTimer); entry.initTimer = null; }
  const rjs = entry.readyRejecters; entry.readyRejecters = [];
  entry.readyResolvers = [];
  const err = new Error(`${code}: ${msg}`); err.code = code;
  rjs.forEach((r) => r(err));
}

function onStdout(entry, chunk) {
  entry.stdoutBuf += chunk.toString('utf8');
  let idx;
  while ((idx = entry.stdoutBuf.indexOf('\n')) >= 0) {
    const line = entry.stdoutBuf.slice(0, idx).trim();
    entry.stdoutBuf = entry.stdoutBuf.slice(idx + 1);
    if (!line) continue;
    let parsed;
    try { parsed = JSON.parse(line); } catch { continue; }   // skip non-JSON (shouldn't happen)
    if (entry.state === 'starting') {
      if (parsed.ready) markReady(entry);
      else failInit(entry, parsed.code || 'INIT_FAILED', parsed.message || '');
    } else if (entry.state === 'ready' && entry.busy && entry.currentJob) {
      completeHead(entry, parsed);
    }
  }
}

function drain(entry) {
  if (entry.busy || entry.state !== 'ready' || entry.queue.length === 0) return;
  const job = entry.queue.shift();
  entry.currentJob = job;
  entry.busy = true;
  job.timer = setTimeout(() => onTimeout(entry, job), job.timeoutMs);
  try {
    entry.proc.stdin.write(JSON.stringify(job.req) + '\n');
  } catch (e) {
    if (job.timer) clearTimeout(job.timer);
    entry.busy = false; entry.currentJob = null;
    job.reject(new Error('DISPATCHER_SPAWN_ERROR: ' + e.message));
    handleDeath(entry);
  }
}

function completeHead(entry, parsed) {
  const job = entry.currentJob;
  if (!job) return;
  entry.currentJob = null;
  if (job.timer) { clearTimeout(job.timer); job.timer = null; }
  entry.busy = false;
  // Match spawn.js: structured {ok:false} resolves (callers may catch rejection
  // for transport errors only).
  job.resolve(parsed);
  drain(entry);
}

function onTimeout(entry, job) {
  // NCo Invoke is uninterruptible — kill the worker, reject this job, respawn
  // for the rest of the queue.
  killWorker(entry);
  if (entry.currentJob === job) { entry.currentJob = null; entry.busy = false; }
  job.reject(new Error(`DISPATCHER_TIMEOUT after ${job.timeoutMs}ms`));
  handleDeath(entry);
}

function failAllQueued(entry, err) {
  if (entry.currentJob) {
    if (entry.currentJob.timer) clearTimeout(entry.currentJob.timer);
    entry.currentJob.reject(err);
    entry.currentJob = null;
  }
  while (entry.queue.length) {
    const j = entry.queue.shift();
    if (j.timer) clearTimeout(j.timer);
    j.reject(err);
  }
  entry.busy = false;
}

function handleDeath(entry) {
  // called after a mid-exec death; respawn if work remains, else drop the entry
  if (entry.queue.length > 0 || entry.currentJob) {
    respawn(entry);
  } else {
    pools.delete(entry.system);
  }
}

function respawn(entry) {
  entry.proc = null;
  entry.state = 'starting';
  entry.stdoutBuf = '';
  entry.stderrBuf = '';
  entry.busy = false;
  entry.currentJob = null;
  try {
    spawnWorker(entry);
  } catch (e) {
    failAllQueued(entry, new Error('DISPATCHER_RESPAWN_FAILED: ' + e.message));
    pools.delete(entry.system);
  }
}

function onProcClose(entry, code) {
  if (entry.state === 'starting') {
    failInit(entry, 'DISPATCHER_CRASH', `worker exited during init (code=${code})`);
    return;
  }
  if (entry.state === 'ready') {
    const err = new Error(`DISPATCHER_CRASH: worker exited (code=${code})`);
    err.code = 'DISPATCHER_CRASH';
    failAllQueued(entry, err);
    pools.delete(entry.system);   // next call lazy-spawns a fresh worker
  }
}

function onProcError(entry, e) {
  if (entry.state === 'starting') {
    failInit(entry, 'DISPATCHER_SPAWN_ERROR', e.message);
    return;
  }
  failAllQueued(entry, new Error('DISPATCHER_SPAWN_ERROR: ' + e.message));
  pools.delete(entry.system);
}

function killWorker(entry) {
  if (entry.proc) {
    try { entry.proc.kill('SIGKILL'); } catch {}
    entry.proc = null;
  }
}

export function killAll() {
  for (const [, entry] of pools) {
    if (entry.proc) { try { entry.proc.kill('SIGKILL'); } catch {} }
  }
  pools.clear();
}

/** PW http-facade「断开连接」用:只杀某系统的热 worker 并清池(其余系统不受影响)。 */
export function killSystem(system) {
  const entry = pools.get(system);
  if (!entry) return;
  killWorker(entry);
  pools.delete(system);
}

// Shutdown hooks — prevent orphaned worker processes outliving the server.
process.on('exit', () => killAll());
process.on('SIGINT', () => { killAll(); process.exit(130); });
process.on('SIGTERM', () => { killAll(); process.exit(143); });

export async function runSteps(opts) {
  if (POOL_DISABLED) return runStepsSpawn(opts);

  const { system, password, steps, client, user, language } = opts;
  const timeoutMs = opts.timeoutMs || EXEC_TIMEOUT_MS;
  const systemsPath = opts.systemsPath || process.env.SAP_MCP_SYSTEMS;
  const sapBin = opts.sapBin || process.env.SAP_MCP_BIN;

  let entry = pools.get(system);

  // circuit breaker tripped for this system -> spawn fallback
  if (entry?.disabled) return runStepsSpawn(opts);

  // password changed (sap_connect re-validated) -> recycle worker
  if (entry && entry.password !== password) {
    killWorker(entry);
    pools.delete(system);
    entry = undefined;
  }

  // client/user/language override changed (sap_connect) -> recycle worker so the
  // new conn takes effect; one worker = one NCo registration.
  if (entry && client && String(entry.conn.Client) !== String(client)) {
    killWorker(entry);
    pools.delete(system);
    entry = undefined;
  }
  if (entry && user && String(entry.conn.User) !== String(user)) {
    killWorker(entry);
    pools.delete(system);
    entry = undefined;
  }
  if (entry && language && String(entry.conn.Language) !== String(language)) {
    killWorker(entry);
    pools.delete(system);
    entry = undefined;
  }

  // lazy spawn
  if (!entry) {
    let conn;
    try { conn = readConn(system, systemsPath, client, user, language); }
    catch { return runStepsSpawn(opts); }   // can't read conn -> fallback
    entry = createEntry(system, password, conn, systemsPath, sapBin);
    pools.set(system, entry);
    try { spawnWorker(entry); }
    catch (e) {
      pools.delete(system);
      return runStepsSpawn(opts);
    }
  }

  // wait for READY; on failure, fallback this call to spawn and bump failCount
  try {
    await ensureReady(entry);
  } catch (e) {
    entry.failCount += 1;
    if (entry.failCount >= MAX_FAILS) entry.disabled = true;
    pools.delete(system);
    return runStepsSpawn(opts);
  }
  entry.failCount = 0;

  // enqueue + drain (per-system serial)
  return new Promise((resolve, reject) => {
    entry.queue.push({ req: { steps }, resolve, reject, timer: null, timeoutMs });
    drain(entry);
  });
}
