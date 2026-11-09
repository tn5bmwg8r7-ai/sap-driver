import { APP_CONFIG } from '../shell/app-config.js';

// 2026-09-02 分发架构改造:库名参数化(PW='personal-workspace',MOOD 注入 'mood-standalone',数值不变零迁移)
const DB_NAME = APP_CONFIG.dbName;
const DB_VERSION = 11;

const SCHEMA = [
  {
    store: 'todos',
    keyPath: 'id',
    indexes: [
      { name: 'by_due',  keyPath: 'due' },
      { name: 'by_done', keyPath: 'done' }
    ]
  },
  {
    store: 'notes',
    keyPath: 'id'
  },
  {
    store: 'command-log',
    keyPath: 'id',
    indexes: [
      { name: 'by_executedAt', keyPath: 'executedAt' }
    ]
  },
  {
    store: 'settings',
    keyPath: 'key'
  },
  {
    store: 'projects',
    keyPath: 'id',
    indexes: [
      { name: 'by_domain', keyPath: 'domain' }
    ]
  },
  {
    store: 'pages',
    keyPath: 'id',
    indexes: [
      { name: 'by_parentId', keyPath: 'parentId' }
    ]
  },
  {
    // bot-tools 仓储退役 2026-10-29(机器人 TAB 并入技能市场);store 结构与历史数据
    // 软删除保留——IndexedDB store 删了会连带清数据且版本不可回退,恢复见
    // _trash\bot-platform-retired-20261029\README.md。仓储文件已移 _trash。
    store: 'bot-tools',
    keyPath: 'id'
  },
  {
    store: 'intl-projects',
    keyPath: 'id'
  },
  {
    store: 'intl-snapshots',
    keyPath: 'id',
    indexes: [
      { name: 'by_project', keyPath: 'projectId' }
    ]
  },
  {
    store: 'kb-docs',
    keyPath: 'id',
    indexes: [
      { name: 'by_folder',    keyPath: 'folder' },
      { name: 'by_updatedAt', keyPath: 'updatedAt' }
    ]
  },
  {
    store: 'interactions',
    keyPath: 'id',
    indexes: [
      { name: 'by_counterparty', keyPath: 'counterparty' },
      { name: 'by_timestamp',    keyPath: 'timestamp' }
    ]
  },
  {
    store: 'coach-profile',
    keyPath: 'id'
  },
  {
    store: 'coach-diagnosis',
    keyPath: 'id'
  },
  {
    store: 'coach-memory',
    keyPath: 'id'
  },
  {
    store: 'growth-events',
    keyPath: 'id'
  },
  {
    store: 'people',
    keyPath: 'id',
    indexes: [
      { name: 'by_name', keyPath: 'name' }
    ]
  },
  {
    store: 'decisions',
    keyPath: 'id'
  },
  {
    store: 'okrs',
    keyPath: 'id'
  }
];

let _dbPromise = null;

function _applySchema(e) {
  const db = e.target.result;
  for (const def of SCHEMA) {
    let os = db.objectStoreNames.contains(def.store)
      ? e.target.transaction.objectStore(def.store)
      : db.createObjectStore(def.store, { keyPath: def.keyPath });
    const want = new Set((def.indexes || []).map(i => i.name));
    if (def.indexes) {
      for (const idx of def.indexes) {
        if (!os.indexNames.contains(idx.name)) {
          os.createIndex(idx.name, idx.keyPath, { unique: false, ...(idx.options || {}) });
        }
      }
    }
    // reconcile: 删除 SCHEMA 不再定义的幽灵索引(每个 store 都查, 含已无索引的 store),
    // 否则浏览器里旧索引继续占空间 + 拖慢写入。光改 SCHEMA 不删, 旧索引会幽灵留存。
    // try/catch 兜底: 单条 deleteIndex 失败不阻塞 upgrade(最坏 DB 留旧版本, 数据不丢)。
    for (const oldName of [...os.indexNames]) {
      if (!want.has(oldName)) {
        try { os.deleteIndex(oldName); } catch (_) { /* 已删/不存在, 忽略 */ }
      }
    }
  }
}

export function openDb() {
  if (_dbPromise) return _dbPromise;
  _dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = _applySchema;
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
    // 2026-08-26 对抗审计: 清站点数据会把连接强制关闭, 缓存的 _dbP 变死连接
    // (transaction 抛 "connection is closing" 且 onclose 不触发、缓存打不破)。
    // 导出/恢复通道一律改用 openDbFresh() 绕开缓存。
    req.onclose = () => { _dbPromise = null; };
  });
  return _dbPromise;
}

// 新鲜连接(不走 _dbPromise 缓存, 每次真实 open 带 DB_VERSION):
// 供备份导出/恢复专用 —— 浏览器数据被清后, 缓存连接已死、库可能只剩无 store 的 v1 空壳,
// 带版本重新 open 会触发 _applySchema 自动重建全部 store+索引, 天然自愈。
export function openDbFresh() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = _applySchema;
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

export async function withStore(store, mode, fn) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(store, mode);
    const os = tx.objectStore(store);
    let result;
    tx.oncomplete = () => resolve(result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error);
    const handler = fn(os);
    if (handler && typeof handler.then === 'function') {
      handler.then(r => { result = r; });
    } else {
      result = handler;
    }
  });
}
