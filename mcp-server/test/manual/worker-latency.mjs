// test/manual/worker-latency.mjs — verify the resident worker pool speeds up
// hot calls against a real SAP system.
// Usage: SAP_MCP_TEST_PW=<password> node test/manual/worker-latency.mjs
//   (env var keeps the password off the process command line / tasklist)
import { runSteps, killAll } from '../../src/ps/workerpool.js';

const password = process.env.SAP_MCP_TEST_PW || process.argv[2];
if (!password) {
  console.error('Usage: SAP_MCP_TEST_PW=<password> node test/manual/worker-latency.mjs');
  process.exit(2);
}
const systemsPath = process.env.SAP_MCP_SYSTEMS || '../systems.json';
const sapBin = process.env.SAP_MCP_BIN || '../../rfc-frontend/RfcCli';

async function timed(label, fn) {
  const t = Date.now();
  const r = await fn();
  const ms = Date.now() - t;
  console.log(`${label.padEnd(28)} ${ms}ms`);
  return { r, ms };
}

// call #1 — COLD: spawn worker + NCo load + DConfig compile + register + first TCP + RFC
const c1 = await timed('call#1 cold ping', () =>
  runSteps({ system: 'QAS', password, systemsPath, sapBin, timeoutMs: 60000,
    steps: [{ id: 'ping', function: 'STFC_CONNECTION', import: { REQUTEXT: 'cold' } }] }));
console.log('  ->', c1.r.ok, c1.r.results?.ping?.ECHOTEXT ?? c1.r.results?.ping?._error);

// call #2 — HOT: worker reused, only the RFC runs
const c2 = await timed('call#2 hot ping', () =>
  runSteps({ system: 'QAS', password, systemsPath, sapBin,
    steps: [{ id: 'ping', function: 'STFC_CONNECTION', import: { REQUTEXT: 'hot' } }] }));
console.log('  ->', c2.r.ok, c2.r.results?.ping?.ECHOTEXT ?? c2.r.results?.ping?._error);

// call #3 — HOT real query
const c3 = await timed('call#3 hot query T000', () =>
  runSteps({ system: 'QAS', password, systemsPath, sapBin,
    steps: [{ id: 'q', function: 'ZLILY_DIAG_Q3', import: { IV_TABLE: 'T000', IV_MAX_ROWS: '5' } }] }));
let rows = '?';
try { rows = JSON.parse(c3.r.results?.q?.EV_RESULT || '[]').length; } catch {}
console.log('  ->', c3.r.ok, 'rows=', rows, c3.r.results?.q?._error ?? '');

killAll();
setTimeout(() => {
  const allOk = c1.r.ok && c2.r.ok && c3.r.ok;
  const fast = c2.ms < c1.ms * 0.4;       // hot must be < 40% of cold
  console.log(`\nASSERT ok=${allOk}  fast=${fast}  (hot ${c2.ms}ms vs cold ${c1.ms}ms)`);
  process.exit(allOk && fast ? 0 : 1);
}, 500);
