import { bus, EVENTS } from './event-bus.js';
import { APP_CONFIG, skey } from './app-config.js';

const TOKEN_KEY = skey('bridge-token');
const BASE_KEY = skey('bridge-base');

class BridgeClient {
  constructor() {
    // 2026-09-02 分发架构改造:端口不再硬编码——bridgeBase 配置优先(空=按 hostname+bridgePort 派生)。
    // PW 走默认(8421);MOOD 同源部署(bridge 由 8422 自己 serve 前端)派生结果与 location.origin 一致。
    const expectedBase = APP_CONFIG.bridgeBase || `http://${location.hostname}:${APP_CONFIG.bridgePort}`;
    const storedBase = localStorage.getItem(BASE_KEY);
    if (!storedBase) {
      this.base = expectedBase;
    } else {
      try {
        this.base = new URL(storedBase).hostname === location.hostname ? storedBase : expectedBase;
      } catch { this.base = expectedBase; }
    }
    this.token = localStorage.getItem(TOKEN_KEY) || '';
    this.connected = false;
  }

  setBase(base) {
    this.base = base.replace(/\/$/, '');
    localStorage.setItem(BASE_KEY, this.base);
  }

  setToken(token) {
    this.token = token.trim();
    localStorage.setItem(TOKEN_KEY, this.token);
  }

  hasToken() { return !!this.token; }

  async _fetch(path, options = {}) {
    const headers = {
      'Content-Type': 'application/json',
      Origin: location.origin,
      ...(options.headers || {})
    };
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    let res = await fetch(this.base + path, { ...options, headers });
    // 2026-08-26 对抗审计: 清站点数据会把 token 一起清掉 → 一键恢复自身 401(死结)。
    // 401 时自动从 bridge 拉 token(同源/白名单校验)重试一次, 失败才走「重新配置」。
    if (res.status === 401 && !options._retriedToken) {
      const got = await this._refreshTokenFromBridge();
      if (got) {
        return this._fetch(path, { ...options, _retriedToken: true });
      }
    }
    if (res.status === 401) {
      this.connected = false;
      bus.emit(EVENTS.BRIDGE_STATUS, { connected: false, reason: 'unauthorized' });
      throw new Error('Bridge token 无效或丢失，请重新配置');
    }
    return res;
  }

  // GET /bridge-token 自动补 token(对齐同源桥实现; 空 Origin=同源本机, 非空走白名单)
  async refreshTokenFromBridge() { return this._refreshTokenFromBridge(); }
  async _refreshTokenFromBridge() {
    try {
      const res = await fetch(this.base + '/bridge-token');
      const d = await res.json();
      if (d?.ok && d?.result?.token) {
        this.setToken(d.result.token);
        return true;
      }
    } catch (e) { /* bridge 不在线等情况, 静默 */ }
    return false;
  }

  async health() {
    // 在途去重(2026-09-01 审计):shell-element 与 main.js 启动各调一次 health,
    // 两份 BRIDGE_STATUS 事件会把下游(auto-recap/qa-candidate 补导)整队双跑。
    if (this._healthInflight) return this._healthInflight;
    this._healthInflight = this._healthOnce().finally(() => { this._healthInflight = null; });
    return this._healthInflight;
  }

  async _healthOnce() {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 5000);
    try {
      const res = await this._fetch('/health', { method: 'POST', body: '{}', signal: ctrl.signal });
      const data = await res.json();
      const ok = !!data?.ok;
      this.connected = ok;
      bus.emit(EVENTS.BRIDGE_STATUS, { connected: ok });
      return ok;
    } catch (e) {
      this.connected = false;
      bus.emit(EVENTS.BRIDGE_STATUS, { connected: false, reason: e.name === 'AbortError' ? 'timeout' : e.message });
      return false;
    } finally {
      clearTimeout(timer);
    }
  }

  // 裸文本 POST:body 直接是文本本体(text/plain),不经 JSON 双重嵌套。
  // 用于 MB 级备份 payload(/pw-backup-raw)——/run 通道的 ConvertFrom-Json/hashtable
  // 解析层对真实全量数据屡次失败,直通通道把解析环节全部拿掉(2026-08-26)。
  async postRaw(path, text, { timeoutMs = 60000 } = {}) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await this._fetch(path, {
        method: 'POST',
        body: text,
        headers: { 'Content-Type': 'text/plain;charset=utf-8' },
        signal: ctrl.signal,
      });
      const data = await res.json();
      if (!data?.ok) {
        const err = new Error(data?.error?.message || 'postRaw failed');
        err.code = data?.error?.code || 'RAW_FAILED';
        throw err;
      }
      return data.result || {};
    } finally {
      clearTimeout(timer);
    }
  }

  // 一键恢复:拉最新备份原文(响应体=备份 JSON 本体, X-Backup-File 头=文件名)
  async fetchLatestBackup({ timeoutMs = 30000 } = {}) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await this._fetch('/pw-backup-latest', { method: 'POST', body: '', signal: ctrl.signal });   // body 必带(http.sys 对无 Content-Length 的 POST 回 411)
      if (!res.ok) {
        let msg = `HTTP ${res.status}`;
        try { const d = await res.json(); if (d?.error?.message) msg = d.error.message; } catch (e) {}
        const err = new Error(msg);
        err.code = (res.status === 404) ? 'NO_BACKUP' : 'FETCH_FAILED';
        throw err;
      }
      return { fileName: res.headers.get('X-Backup-File') || '(未知文件)', blob: await res.json() };
    } finally {
      clearTimeout(timer);
    }
  }

  async listRoutes() {
    const res = await this._fetch('/routes', { method: 'POST', body: '{}' });
    const data = await res.json();
    return data?.result?.routes || [];
  }

  async run(commandId, input, { dryRun = false, timeoutMs = 120000 } = {}) {
    const body = JSON.stringify({ input, dryRun, callId: crypto.randomUUID() });
    const t0 = performance.now();
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    let res;
    try {
      res = await this._fetch(`/run/${commandId}`, { method: 'POST', body, signal: ctrl.signal });
    } catch (e) {
      if (ctrl.signal.aborted) {
        // 慢任务(阈值 > 默认 120s)超时通常是 AI/网络抖动,而非 QuickEdit 冻结;
        // 按阈值分支文案,避免误导用户去翻 bridge 控制台。
        const slow = timeoutMs > 120000;
        const reason = slow
          ? '该任务需调 AI 总结、耗时较长,若超时通常是网络/AI 抽风,建议直接重试'
          : '可能 bridge 控制台被 QuickEdit 冻结(回车/Esc 解除)、或正在处理超慢请求,请检查 bridge 窗口或重启后重试';
        const err = new Error(`Bridge 无响应超过 ${Math.round(timeoutMs / 1000)} 秒。${reason}。`);
        err.code = 'TIMEOUT';
        err.durationMs = Math.round(performance.now() - t0);
        throw err;
      }
      throw e;
    } finally {
      clearTimeout(timer);
    }
    const data = await res.json();
    const durationMs = Math.round(performance.now() - t0);
    if (!data?.ok) {
      const err = new Error(data?.error?.message || 'Execution failed');
      err.code = data?.error?.code || 'EXEC_FAILED';
      err.details = data?.error || {};   // 透传 rawHead/diagFile 等给上层展示
      err.durationMs = durationMs;
      // 分发闸门(2026-09-02):未分发路由返回 FEATURE_LOCKED「功能解锁中」,广播给壳层统一提示;
      // 调用方已有 catch 照常工作(err.message 即用户文案),无需改动。
      if (err.code === 'FEATURE_LOCKED') { bus.emit(EVENTS.FEATURE_LOCKED, { commandId }); }
      throw err;
    }
    data.result = data.result || {};
    data.result._durationMs = durationMs;
    return data.result;
  }
}

export const bridge = new BridgeClient();

// ============================================================
// 异步作业「提交 + 轮询」共用骨架(2026-08-31 整合,原三处手抄:
// 宿主问答组件 的 _runChatJob/_runActionJob、测试报告命令 的 poll)。
// 模式:bridge 单线程,重活在 dispatcher 起的独立 worker 里跑,提交秒回 jobId,
// 前端隔 pollMs 轮询 pollRoute 直到 done。
// 语义:业务终态错误(WORKER_FAILED 等,带 code)直接抛;网络抖动/TIMEOUT 计
// failStreak,连败 failLimit 次放弃;not_found 报作业丢失;超 maxMs 报 timeoutMsg。
// ============================================================
export async function runPollingJob({
  submit,              // async () => { jobId } —— 提交作业(自带 30s 秒回 timeoutMs)
  pollRoute,           // 轮询路由名,如 'qa-chat-job'
  pollMs = 2500,
  maxMs = 360000,
  failLimit = 4,
  timeoutMsg = '作业超时,请重试',
  onPoll               // (st) => void —— 每次轮询后回调(running 时可读 st.stage 显示进度,2026-09-01)
}) {
  const sub = await submit();
  const jobId = sub?.jobId;
  if (!jobId) throw new Error('提交失败:未返回作业号');
  const t0 = Date.now();
  let failStreak = 0;
  while (Date.now() - t0 < maxMs) {
    await new Promise(r => setTimeout(r, pollMs));
    let st = null;
    try {
      st = await bridge.run(pollRoute, { jobId }, { timeoutMs: 15000 });
      failStreak = 0;
    } catch (pollErr) {
      // BRIDGE_BUSY(503,队列≥8)是设计给瞬时过载重试的,与 TIMEOUT 同走 failStreak;
      // 直接 throw 会把"后台还在跑的作业"报成前端失败(2026-09-11 审计 #4)
      const retryable = pollErr.code === 'TIMEOUT' || pollErr.code === 'BRIDGE_BUSY';
      if (pollErr.code && !retryable) throw pollErr;
      if (++failStreak >= failLimit) throw new Error('轮询失败:' + pollErr.message);
      continue;
    }
    if (st?.status === 'done') return st.result;
    if (st?.status === 'not_found') throw new Error('作业丢失(bridge 可能重启过),请重试');
    if (typeof onPoll === 'function') { try { onPoll(st); } catch {} }
  }
  throw new Error(timeoutMsg);
}
