// Smoke: sap_connect client override via spawn path (no MCP server involved).
// Password arrives via stdin (never a CLI arg). Usage:
//   echo <pw> | node test/manual/client-override-smoke.js [client]
import { runSteps } from '../../src/ps/spawn.js';

const pw = (await new Promise((res) => {
  let d = '';
  process.stdin.on('data', (c) => { d += c; });
  process.stdin.on('end', () => res(d.trim()));
}));
const client = process.argv[2] || undefined;
const r = await runSteps({
  system: 'DVP', password: pw, client,
  systemsPath: 'D:\\Claude\\Project\\sap-mcp\\systems.json',
  sapBin: 'D:\\Claude\\Bin\\Sap',
  steps: [
    { id: 'ping', function: 'STFC_CONNECTION', import: { REQUTEXT: 'client-smoke' } },
    { id: 'whoami', function: 'RFC_SYSTEM_INFO' },
  ],
});
const info = r.results && r.results.whoami;
console.log(JSON.stringify({
  ok: r.ok,
  pingErr: r.results && r.results.ping && r.results.ping._error || null,
  sysid: info && info.SYSID, host: info && info.HOST, client_implicit: 'see SAPGUI',
  requestedClient: client || '(default 200)',
}));
