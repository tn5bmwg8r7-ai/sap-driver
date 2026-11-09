#!/usr/bin/env node
// test/manual/mcp-smoke.mjs — MCP handshake smoke test (no SAP connection).
// Spawns src/server.js, sends initialize + tools/list, prints the tool catalog.
// Run from project root:  node test/manual/mcp-smoke.mjs
import { spawn } from 'node:child_process';
import path from 'node:path';

const CWD = process.cwd();
const env = {
  ...process.env,
  SAP_MCP_SYSTEMS: path.join(CWD, 'systems.json'),
  SAP_MCP_BIN: process.env.SAP_MCP_BIN || 'D:\\Claude\\Bin\\Sap',
  SAP_MCP_AUDIT_DIR: process.env.SAP_MCP_AUDIT_DIR || 'D:\\Claude\\Cache\\sap-mcp-audit',
};

const child = spawn(process.execPath, ['src/server.js'], { cwd: CWD, env, stdio: ['pipe', 'pipe', 'pipe'] });
let buf = '';
const pending = new Map();
let nextId = 1;
let done = false;

child.stdout.on('data', (d) => {
  buf += d.toString('utf8');
  let idx;
  while ((idx = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (!line) continue;
    try {
      const m = JSON.parse(line);
      if (m.id != null && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    } catch {}
  }
});
child.stderr.on('data', (d) => process.stderr.write('[srv-err] ' + d.toString('utf8')));
child.on('close', (c) => { if (!done) console.log('[server exited]', c); });
child.on('error', (e) => { console.error('SPAWN ERROR:', e.message); process.exit(1); });

const send = (method, params) => {
  const id = nextId++;
  return new Promise((res) => {
    pending.set(id, res);
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
};
const notify = (method, params) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method, params }) + '\n');

(async () => {
  await new Promise((r) => setTimeout(r, 1200));
  const init = await send('initialize', {
    protocolVersion: '2024-11-05', capabilities: {},
    clientInfo: { name: 'smoke', version: '0.0.1' },
  });
  console.log('INIT serverInfo:', JSON.stringify(init.result?.serverInfo));
  if (init.error) { console.log('INIT ERROR:', JSON.stringify(init.error)); child.kill(); process.exit(1); }
  notify('notifications/initialized');
  const list = await send('tools/list', {});
  const tools = list.result?.tools || [];
  console.log(`TOOLS/LIST (${tools.length}):`);
  for (const t of tools) {
    const props = t.inputSchema?.properties ? Object.keys(t.inputSchema.properties) : [];
    console.log('  - ' + t.name + ' :: ' + (props.join(', ') || '(no params)'));
  }
  done = true;
  child.kill();
  process.exit(0);
})();
