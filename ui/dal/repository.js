import { withStore } from './db.js';

// ── 删除探针(2026-09-18,日报第三轮丢失:库侧删除者三轮未定案)──────────────
// interactions 的任何 delete/clear 都落一条留痕到 pw:recap-log(复用导入留痕表,
// window.pwDiagRecap() 会一并吐出),带调用栈前 2 帧——「一键恢复/从文件恢复」
// 会走 clear,单条手动删走 delete,下次再丢直接看留痕定位入口,不再考古。
function logDeleteTrail(storeName, op, detail) {
  if (storeName !== 'interactions') return;
  try {
    const stack = (new Error().stack || '')
      .split('\n').filter(l => l.includes('at ')).slice(1, 3).join(' <- ');
    const arr = JSON.parse(localStorage.getItem('pw:recap-log') || '[]');
    arr.push({
      at: new Date().toISOString().slice(5, 19).replace('T', ' '),
      kind: `db-${op}`,
      msg: `${String(detail).slice(0, 80)} | ${stack.slice(0, 160)}`,
    });
    localStorage.setItem('pw:recap-log', JSON.stringify(arr.slice(-30)));
  } catch (e) { /* 探针失败绝不影响删除主流程 */ }
}

export class Repository {
  constructor(storeName) {
    this.storeName = storeName;
  }

  async put(entity) {
    return withStore(this.storeName, 'readwrite', (os) => {
      const req = os.put(entity);
      return new Promise((resolve, reject) => {
        req.onsuccess = () => resolve(entity);
        req.onerror = () => reject(req.error);
      });
    });
  }

  async get(id) {
    return withStore(this.storeName, 'readonly', (os) => {
      return new Promise((resolve, reject) => {
        const req = os.get(id);
        req.onsuccess = () => resolve(req.result || null);
        req.onerror = () => reject(req.error);
      });
    });
  }

  async getAll() {
    return withStore(this.storeName, 'readonly', (os) => {
      return new Promise((resolve, reject) => {
        const req = os.getAll();
        req.onsuccess = () => resolve(req.result || []);
        req.onerror = () => reject(req.error);
      });
    });
  }

  async delete(id) {
    logDeleteTrail(this.storeName, 'delete', id);
    return withStore(this.storeName, 'readwrite', (os) => {
      const req = os.delete(id);
      return new Promise((resolve, reject) => {
        req.onsuccess = () => resolve(true);
        req.onerror = () => reject(req.error);
      });
    });
  }

  async queryByIndex(indexName, value) {
    return withStore(this.storeName, 'readonly', (os) => {
      const idx = os.index(indexName);
      return new Promise((resolve, reject) => {
        const req = idx.getAll(value);
        req.onsuccess = () => resolve(req.result || []);
        req.onerror = () => reject(req.error);
      });
    });
  }

  async clear() {
    logDeleteTrail(this.storeName, 'clear', 'store.clear() 全清(恢复操作走这里)');
    return withStore(this.storeName, 'readwrite', (os) => {
      const req = os.clear();
      return new Promise((resolve, reject) => {
        req.onsuccess = () => resolve(true);
        req.onerror = () => reject(req.error);
      });
    });
  }

  async bulkPut(entities) {
    return withStore(this.storeName, 'readwrite', (os) => {
      for (const e of entities) os.put(e);
      return entities.length;
    });
  }

  // 通用局部更新：get → 合并 updates → setUpdatedAt → put。子类有特殊逻辑可覆盖。
  // 注：两段事务（get readonly + put readwrite），与既有 update 实现一致；非原子，
  // 但本项目的 update 历来如此，行为完全等价于纯样板的 update(id, patch)。
  async patch(id, updates, { setUpdatedAt = true } = {}) {
    const cur = await this.get(id);
    if (!cur) throw new Error(`${this.storeName}/${id} not found`);
    const next = { ...cur, ...updates };
    if (setUpdatedAt) next.updatedAt = Date.now();
    await this.put(next);
    return next;
  }

  // 批量删除（单事务，避免 N+1）。fn 返回非 promise → withStore 在 oncomplete 解析。
  async deleteMany(ids) {
    logDeleteTrail(this.storeName, 'deleteMany', `n=${(ids || []).length} [${String(ids).slice(0, 60)}]`);
    return withStore(this.storeName, 'readwrite', (os) => {
      for (const id of ids) os.delete(id);
      return ids.length;
    });
  }
}
