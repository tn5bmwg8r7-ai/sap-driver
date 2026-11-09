import { featureEnabled } from '../shell/app-config.js';

const registry = new Map();

function normalize(s) {
  return String(s || '').toLowerCase().trim();
}

export function fuzzyMatch(query, target) {
  const q = normalize(query);
  const t = normalize(target);
  if (!q) return 0;
  if (t.startsWith(q)) return 100 - (t.length - q.length);
  if (t.includes(q)) return 60;
  let qi = 0;
  for (let i = 0; i < t.length && qi < q.length; i++) {
    if (t[i] === q[qi]) qi++;
  }
  return qi === q.length ? 30 : 0;
}

export const CommandRegistry = {
  register(manifest) {
    if (!featureEnabled(manifest.feature)) return;   // 分发闸门(P3):未分发 feature 注册即丢弃
    if (registry.has(manifest.id)) {
      console.warn('[command] duplicate registration, overriding:', manifest.id);
    }
    registry.set(manifest.id, manifest);
  },
  get(id) { return registry.get(id); },
  all() { return [...registry.values()].filter(c => !c.hidden); },
  search(query) {
    if (!normalize(query)) return this.all();
    const scored = [];
    for (const cmd of this.all()) {
      let best = fuzzyMatch(query, cmd.title);
      for (const a of (cmd.aliases || [])) {
        best = Math.max(best, fuzzyMatch(query, a));
      }
      if (best > 0) scored.push({ cmd, score: best });
    }
    return scored.sort((a, b) => b.score - a.score).map(s => s.cmd);
  }
};
