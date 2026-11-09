// testdata.js — local test-parameter-set store (the "variant" substitute).
// Third-party payloads get saved as local JSON; sap_fm_exec loads them by name to
// reproduce a call instantly. Never touches SAP (QAS zero-write).
// Layout: ROOT/{SYSTEM}/{FUNCTION}/{name}.json
import fs from 'node:fs';
import path from 'node:path';

export const ROOT = process.env.SAP_MCP_TESTDATA_DIR || 'D:\\Claude\\Cache\\sap-mcp-testdata';

export function safeName(s) {
  return String(s || '').trim().replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 80) || 'unnamed';
}

function fileFor(system, fn, name) {
  return path.join(ROOT, safeName(system), safeName(fn).toUpperCase(), safeName(name) + '.json');
}

export function saveParamSet({ system, fn, name, import: imp, tables, note }) {
  const file = fileFor(system, fn, name);
  const data = {
    system: String(system).toUpperCase(),
    function: String(fn).toUpperCase(),
    name: String(name),
    import: imp || {},
    tables: tables || {},
    note: note || '',
    savedAt: new Date().toISOString(),
  };
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2), 'utf8');
  return { file, ...data };
}

export function loadParamSet(system, fn, name) {
  const file = fileFor(system, fn, name);
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

export function listParamSets(system, fn) {
  const sysDir = path.join(ROOT, safeName(system));
  const out = [];
  if (!fs.existsSync(sysDir)) return out;
  const fnDirs = fn
    ? [safeName(fn).toUpperCase()]
    : fs.readdirSync(sysDir).filter((f) => fs.statSync(path.join(sysDir, f)).isDirectory());
  for (const fdir of fnDirs) {
    const d = path.join(sysDir, fdir);
    if (!fs.existsSync(d)) continue;
    for (const f of fs.readdirSync(d)) {
      if (!f.endsWith('.json')) continue;
      try {
        const j = JSON.parse(fs.readFileSync(path.join(d, f), 'utf8'));
        out.push({
          function: j.function,
          name: j.name,
          savedAt: j.savedAt,
          note: j.note,
          importKeys: Object.keys(j.import || {}),
          tableNames: Object.keys(j.tables || {}),
        });
      } catch {}
    }
  }
  return out;
}
