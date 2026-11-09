const handlers = new Map();

export const bus = {
  on(event, handler) {
    if (!handlers.has(event)) handlers.set(event, new Set());
    handlers.get(event).add(handler);
    return () => this.off(event, handler);
  },
  off(event, handler) {
    handlers.get(event)?.delete(handler);
  },
  emit(event, payload) {
    const set = handlers.get(event);
    if (!set) return;
    for (const h of set) {
      try { h(payload); } catch (e) { console.error('[bus] handler error', event, e); }
    }
  }
};

export const EVENTS = {
  BRIDGE_STATUS: 'bridge:status',
  COMMAND_EXECUTED: 'command:executed',
  TODO_CHANGED: 'todo:changed',
  NOTE_ADDED: 'note:added',
  WIDGET_NAVIGATE: 'widget:navigate',
  THEME_CHANGED: 'theme:changed',
  PRIVACY_CHANGED: 'privacy:changed',
  INTL_PROJECT_CHANGED: 'intl-project:changed',
  KNOWLEDGE_CHANGED: 'knowledge:changed',
  INTERACTION_CHANGED: 'interaction:changed',
  COACH_CHANGED: 'coach:changed',
  // 分发闸门(2026-09-02):调用未分发路由(bridge 返回 FEATURE_LOCKED)时由 bridge-client 发出,
  // 壳层可监听统一提示「功能解锁中」。开源版无锁定路由,此事件不会触发。
  FEATURE_LOCKED: 'feature:locked'
};
