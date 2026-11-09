import { skey, featureEnabled } from '../shell/app-config.js';

const registry = new Map();
const disabled = new Set(JSON.parse(localStorage.getItem(skey('disabled-widgets')) || '[]'));

function persistDisabled() {
  localStorage.setItem(skey('disabled-widgets'), JSON.stringify([...disabled]));
}

export const WidgetRegistry = {
  register(manifest) {
    if (!featureEnabled(manifest.feature)) return;   // 分发闸门(P3):未分发 feature 注册即丢弃
    if (registry.has(manifest.id)) {
      console.warn('[widget] duplicate registration, overriding:', manifest.id);
    }
    registry.set(manifest.id, manifest);
  },
  get(id) { return registry.get(id); },
  all() { return [...registry.values()]; },
  byCategory(category) {
    return this.all().filter(w => w.category === category && !disabled.has(w.id));
  },
  isEnabled(id) { return !disabled.has(id); },
  setEnabled(id, enabled) {
    if (enabled) disabled.delete(id); else disabled.add(id);
    persistDisabled();
  }
};
