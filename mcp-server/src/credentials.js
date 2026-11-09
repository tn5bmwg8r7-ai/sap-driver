// credentials.js — in-memory credential cache (per system).
// Passwords live only in this process's Map; never persisted, never exported raw.
// Session end (Claude Code restart / disconnect) = process death = cache cleared.

/** @type {Map<string, {user:string,password:string,language:string,validatedAt:number}>} */
const cache = new Map();

export function getCredential(system) {
  return cache.get(system) || null;
}

export function setCredential(system, cred) {
  cache.set(system, {
    user: cred.user,
    password: cred.password,
    language: cred.language || 'ZH',
    client: cred.client || null,   // effective login client (sap_connect override or systems.json default)
    validatedAt: Date.now(),
  });
}

export function isCached(system) {
  return cache.has(system);
}

/** PW http-facade「断开连接」用:清除某系统的内存凭证(仅内存操作,无盘上状态)。 */
export function clearCredential(system) {
  cache.delete(system);
}

export function cachedSystems() {
  return Array.from(cache.keys());
}

/** JDOE.A.B.C -> J***C ; tom -> t***m (日志/审计输出里脱敏用户名) */
export function maskUser(user) {
  if (!user) return '?';
  const u = String(user);
  const parts = u.split(/[.\-_]/).filter(Boolean);
  if (parts.length >= 2) return parts[0][0] + '***' + parts[parts.length - 1][0];
  if (u.length >= 2) return u[0] + '***' + u[u.length - 1];
  return u[0] + '***';
}
