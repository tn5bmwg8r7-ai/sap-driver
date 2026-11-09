import { commandLog } from '../dal/repositories/command-log.js';
import { bus, EVENTS } from './event-bus.js';

// Shared command execution pipeline used by both the command palette and the
// command-launcher widget. Centralises: destructive confirm → execute → log → emit event,
// so callers only need to provide (cmd, input, dryRun) and handle thrown errors.

// 全局在跑注册表(2026-09-04,模块级):切 TAB 会销毁 command-launcher 组件实例,
// 其 this.running 是实例状态 → 切走再回来"执行中"状态全丢(用户反馈②)。
// 长任务(接口文档生成等)promise 不随组件销毁,继续在后台跑完——这里按 commandId
// 记录在跑信息,launcher 重新挂载时用它恢复状态并重新接管 promise 渲染结果。
const activeRuns = new Map();   // commandId -> { cmd, input, dryRun, startedAt, promise }

export function getActiveRun(commandId) {
  return activeRuns.get(commandId) || null;
}

export function listActiveRuns() {
  return [...activeRuns.values()];
}

export async function runCommand(cmd, input, { dryRun = false, confirmFn = null } = {}) {
  if (!cmd) throw new Error('Command not found');

  if (!dryRun && cmd.destructive) {
    const confirmed = typeof confirmFn === 'function'
      ? confirmFn(cmd)
      : window.confirm(`"${cmd.title}" 是有副作用的指令，确认执行？`);
    if (!confirmed) {
      const e = new Error('用户取消执行');
      e.code = 'CANCELLED';
      throw e;
    }
  }

  const executedAt = Date.now();
  // 来源标记(2026-09-04):快捷指令发起的执行带 _pwSrc=quick-cmd,随 input 传到桥端,
  // worker 写进槽位/结果存档 → JOB 管理「只看我的」过滤用。路由对未知 input 键无感。
  const markedInput = Object.assign({}, input, { _pwSrc: 'quick-cmd' });
  const execPromise = (async () => {
    try {
      // 透传 manifest 声明的 timeoutMs(仅慢 command 声明;普通 command 为 undefined -> bridge.run 走 120s 默认)
      const result = await cmd.execute(markedInput, { dryRun, timeoutMs: cmd.timeoutMs });
      await commandLog.record({
        commandId: cmd.id,
        input: markedInput,
        result,
        dryRun,
        executedAt,
        durationMs: result?._durationMs || 0
      });
      bus.emit(EVENTS.COMMAND_EXECUTED, { commandId: cmd.id, dryRun, ok: true });
      return result;
    } catch (e) {
      if (e.code === 'CANCELLED') throw e;
      await commandLog.record({
        commandId: cmd.id,
        input: markedInput,
        error: { message: e.message, code: e.code },
        dryRun,
        executedAt,
        durationMs: 0
      });
      bus.emit(EVENTS.COMMAND_EXECUTED, { commandId: cmd.id, dryRun, ok: false, error: e.message });
      throw e;
    }
  })();

  const entry = { cmd, input, dryRun, startedAt: executedAt, promise: execPromise };
  activeRuns.set(cmd.id, entry);
  const settle = () => { if (activeRuns.get(cmd.id) === entry) activeRuns.delete(cmd.id); };
  execPromise.then(settle, settle);

  return execPromise;
}
