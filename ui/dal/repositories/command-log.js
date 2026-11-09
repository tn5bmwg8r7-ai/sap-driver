import { Repository } from '../repository.js';

const RESULT_KEEP = 4 * 1024;               // >24h 旧记录 result 摘要预算(字符)
const AGE_MS = 24 * 60 * 60 * 1000;         // 24h:快捷指令区 hydrate 只回填这个窗口

class CommandLogRepository extends Repository {
  constructor() {
    super('command-log');
    // 2026-09-11 审计 #18:本仓库无写入上限,pw-backup 单文件 16 天涨 4.8 倍
    // (3.1→14.8MB,大头是旧记录整份 result)。每会话一次惰性收缩:>24h 的记录把
    // result 换成 4KB 内摘要;24h 内保全量。只收缩不删行,执行痕迹
    // (命令/入参/时间/耗时/错误)完整保留。失败静默不影响业务。
    this._swept = false;
    this.sweepOld().catch(() => {});
  }

  _shrinkResult(result) {
    try {
      const s = typeof result === 'string' ? result : JSON.stringify(result);
      if (s == null) return '(空)';
      if (s.length <= RESULT_KEEP) return result;   // 本来就小,原对象原样保留
      return { truncated: true, originLen: s.length, preview: s.slice(0, 400) };
    } catch (e) {
      return '(不可序列化,已省略)';
    }
  }

  async sweepOld() {
    if (this._swept) return;
    this._swept = true;
    const all = await this.getAll();
    const cutoff = Date.now() - AGE_MS;
    const puts = [];
    for (const t of all) {
      if (!t || t.executedAt >= cutoff || t.result == null) continue;
      const shrunk = this._shrinkResult(t.result);
      if (shrunk === t.result) continue;
      t.result = shrunk;
      puts.push(t);
    }
    if (puts.length) await this.bulkPut(puts);
  }

  async record(entry) {
    const entity = {
      id: entry.id || crypto.randomUUID(),
      commandId: entry.commandId,
      input: entry.input || {},
      result: entry.result || null,
      error: entry.error || null,
      dryRun: !!entry.dryRun,
      executedAt: entry.executedAt || Date.now(),
      durationMs: entry.durationMs || 0
    };
    return this.put(entity);
  }

  async recent(limit = 50) {
    const all = await this.getAll();
    return all.sort((a, b) => b.executedAt - a.executedAt).slice(0, limit);
  }

}

export const commandLog = new CommandLogRepository();
