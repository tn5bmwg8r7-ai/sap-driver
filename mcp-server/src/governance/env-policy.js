// env-policy.js — system enum, env-lock (PRD read-only enabled, mirrors QAS),
// customer-vs-standard namespace detection (for phase-3 write guard; this release
// also tags read results).
import fs from 'node:fs';

let systems = null;

export function loadSystems(file) {
  const p = file || process.env.SAP_MCP_SYSTEMS;
  systems = JSON.parse(fs.readFileSync(p, 'utf8'));
  return systems;
}

export function getSystems() {
  if (!systems) loadSystems();
  return systems;
}

export function checkEnv(system, allowedEnvs) {
  const s = (system || '').trim().toUpperCase();
  if (!s) return { ok: false, code: 'MISSING_SYSTEM', message: 'system 参数必填（DVP / QAS / PRD）。' };
  const sys = getSystems();
  if (s === 'PRD' && !sys.prdEnabled) {
    return { ok: false, code: 'PRD_FORBIDDEN', message: 'PRD 生产机本版本已禁用（仅支持 DVP / QAS）。' };
  }
  if (!(allowedEnvs || []).includes(s)) {
    return { ok: false, code: 'ENV_NOT_ALLOWED', message: `${s} 不允许此操作（允许: ${(allowedEnvs || []).join(', ')}）。` };
  }
  if (!sys.envs[s]) {
    return { ok: false, code: 'UNKNOWN_SYSTEM', message: `未知系统 ${s}（systems.json 未配置）。` };
  }
  return { ok: true, system: s };
}

// Z-prefixed / Y-prefixed, or /NSP/ customer namespace => true; else SAP standard.
export function isCustomerNamespace(objName) {
  if (!objName) return false;
  const n = objName.toUpperCase();
  return /^(Z|Y)/.test(n) || /^\/[A-Z0-9]{3,}\/.+/.test(n);
}
