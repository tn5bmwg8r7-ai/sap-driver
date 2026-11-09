import { Repository } from '../repository.js';
import { touchAssetMirror } from '../asset-mirror.js';

class TodosRepository extends Repository {
  constructor() { super('todos'); }

  // 服务端镜像推送(2026-09-03 问答「PW资产」源的数据面):所有变更路径(add/toggle/
  // update/sync 的 bulkPut/删除/墓碑)都经这四个基类方法,统一在此挂防抖推送,
  // 业务方法零改动;推送失败静默,绝不影响业务链路(见 asset-mirror.js)
  async put(e) { const r = await super.put(e); touchAssetMirror('todos'); return r; }
  async bulkPut(es) { const r = await super.bulkPut(es); touchAssetMirror('todos'); return r; }
  async delete(id) { const r = await super.delete(id); touchAssetMirror('todos'); return r; }
  async deleteMany(ids) { const r = await super.deleteMany(ids); touchAssetMirror('todos'); return r; }

  async add(partial) {
    const now = Date.now();
    const done = !!partial.done;
    const entity = {
      id: partial.id || crypto.randomUUID(),
      title: partial.title || '',
      note: partial.note || '',
      category: partial.category || 'work',
      done,
      due: partial.due || null,
      createdAt: partial.createdAt || now,
      updatedAt: now,
      completedAt: done ? (partial.completedAt || now) : null,
      source: partial.source || null,      // origin system: 'dingtalk' | 'bpm' | null (manual)
      sourceId: partial.sourceId || null,  // id in source system (e.g. dingtalk taskId)
      // last note written by sync (dingtalk/bpm). If note still equals this on next sync,
      // the user hasn't edited it -> remote note updates may flow through; once edited, never overwrite.
      _srcNote: partial._srcNote || null
    };
    return this.put(entity);
  }

  async today() {
    const all = await this.getAll();
    const start = new Date(); start.setHours(0, 0, 0, 0);
    const end = new Date(start); end.setDate(end.getDate() + 1);
    return all.filter(t => {
      if (t.done) return false;
      if (!t.due) return true;
      const d = new Date(t.due);
      return d >= start && d < end;
    }).sort((a, b) => (a.due || 0) - (b.due || 0));
  }

  async pending() {
    const all = await this.getAll();
    return all.filter(t => !t.done).sort((a, b) => (a.due || Infinity) - (b.due || Infinity));
  }

  async toggle(id) {
    const t = await this.get(id);
    if (!t) return null;
    t.done = !t.done;
    t.updatedAt = Date.now();
    t.completedAt = t.done ? Date.now() : null;
    return this.put(t);
  }

  async update(id, patch) {
    const t = await this.get(id);
    if (!t) return null;
    const wasDone = !!t.done;
    Object.assign(t, patch);
    const nowDone = !!t.done;
    if (nowDone && !wasDone) t.completedAt = Date.now();
    if (!nowDone && wasDone) t.completedAt = null;
    t.updatedAt = Date.now();
    return this.put(t);
  }
}

export const todos = new TodosRepository();
