// fm-check.js — FM whitelist (QAS/PRD GET-class; DVP read-class) + global blocklist.
// Runs after env-lock, before any RFC step is dispatched.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { getSystems, isCustomerNamespace } from './env-policy.js';

// PRD exec whitelist: query-class customer FMs the user explicitly allows to run
// on PRD for triage (排查场景:查询类接口偶尔要在 PRD 执行定位). Hot file — re-read
// on mtime change so edits take effect without a facade restart. Missing file = empty.
let prdWlCache = null;
let prdWlMtimeMs = 0;
function prdExecWhitelist() {
  try {
    const p = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'prd-exec-whitelist.json');
    const st = fs.statSync(p);
    if (!prdWlCache || st.mtimeMs !== prdWlMtimeMs) {
      prdWlCache = JSON.parse(fs.readFileSync(p, 'utf8'));
      prdWlMtimeMs = st.mtimeMs;
    }
    return prdWlCache;
  } catch {
    return { fms: [] };
  }
}

function isRegexPattern(p) {
  return /[\^\$\.\*\+\?\[\]\{\}\(\)\\\|]/.test(p);
}
function matchAny(name, patterns) {
  return (patterns || []).some((p) => {
    if (isRegexPattern(p)) {
      try { return new RegExp(p).test(name); } catch { return false; }
    }
    return p.toUpperCase() === name;
  });
}

/**
 * @param {object} a { fm, system, opClass }
 * @returns {{ok:boolean, code?:string, message?:string}}
 */
export function checkFmAllowed({ fm, system, opClass }) {
  const name = (fm || '').trim().toUpperCase();
  if (!name) return { ok: false, code: 'MISSING_FM', message: 'function 名必填。' };
  const sys = getSystems();

  // 0) dev-write (phase-3 DVP dev tools): explicit write-FM whitelist.
  //    Bypasses the TR_ blocklist for THREE named FMs only, DVP only.
  //    Object-level guards (Z/Y namespace, type whitelist, create-not-modify,
  //    required devclass+trkorr) live in the dev tools themselves.
  if (opClass === 'dev-write') {
    if (system !== 'DVP') {
      return { ok: false, code: 'DEV_WRITE_DVP_ONLY',
        message: '写对象工具仅限 DVP 开发机（QAS/PRD 一概禁写入）。' };
    }
    // RS_FUNCTION_POOL_INSERT = build a Z function group (RPY refuses brand-new groups
    // with INVALID_FUNCTION_POOL, so this is the only remote way to create one).
    // ZLILY_DIAG_TBL_MK3 = RFC-enabled wrapper (clean group ZFG_LILY_DIAG2) that locally
    // calls DDIF_TABL_PUT + ACTIVATE + COMMIT WORK (DDIF_TABL_PUT itself is NOT RFC-enabled;
    // DDIC changes need explicit COMMIT or the stateless RFC LUW rolls them back). Source is
    // the verified MK version + COMMIT WORK — no CONCATENATE-style pitfalls.
    // NOTE: RPY_PROGRAM_UPDATE (change source) & FUNCTION_DELETE are NOT RFC-enabled, so
    // remote SAP allows CREATE + READ only, not MODIFY/DELETE — build right the first time.
    const DEV_WRITE_FMS = ['RPY_FUNCTIONMODULE_INSERT', 'RS_FUNCTION_POOL_INSERT', 'DDIF_TABL_PUT', 'TR_OBJECT_INSERT', 'ZLILY_DEV_TR_PUT', 'ZLILY_DIAG_TBL_MK2', 'ZLILY_DIAG_TBL_MK3', 'ZLILY_DIAG_SRC_PUT8', 'ZLILY_DIAG_DEL'];
    if (DEV_WRITE_FMS.includes(name)) return { ok: true };
    return { ok: false, code: 'FM_NOT_DEV_WRITE',
      message: `${name} 不在 dev-write 白名单（仅 RPY_FUNCTIONMODULE_INSERT / DDIF_TABL_PUT / TR_OBJECT_INSERT）。` };
  }

  // 1) global blocklist (commit / rollback / transport / update)
  if (matchAny(name, sys.fmBlocklist)) {
    return { ok: false, code: 'FM_BLOCKED',
      message: `${name} 命中黑名单（提交/传输/写类 FM，全局禁用）。` };
  }

  // 2) QAS / PRD (triage): same GET whitelist + regex. PRD mirrors QAS.
  //    QAS additionally allows customer-namespace FMs (Z/Y//NSP/) — the interface
  //    triage main line replays third-party payloads on QAS800, and QAS business
  //    data is allowed to change by design (test env). Global blocklist above still
  //    applies. PRD stays read-only except the hot user-maintained prd-exec-whitelist.
  if (system === 'QAS' || system === 'PRD') {
    if ((sys.qasGetWhitelist || []).includes(name) || matchAny(name, sys.qasGetWhitelistRegex)) {
      return { ok: true };
    }
    if (system === 'QAS' && isCustomerNamespace(name)) return { ok: true };
    if (system === 'PRD' && matchAny(name, prdExecWhitelist().fms)) return { ok: true };
    const code = system === 'PRD' ? 'FM_NOT_ALLOWED_ON_PRD' : 'FM_NOT_ALLOWED_ON_QAS';
    const hint = system === 'PRD'
      ? '标准 FM 仅允许读表 / 读 DDIC / GET 类 BAPI;查询类自定义函数可加入 prd-exec-whitelist.json(改完即生效)。'
      : '标准 FM 仅允许读表 / 读 DDIC / GET 类 BAPI;Z/Y 自定义函数已放行。';
    return { ok: false, code, message: `${name} 不在 ${system} 白名单(${hint})。` };
  }

  // 3) DVP exec-readonly: read-FM whitelist + customer-namespace FMs
  //    (dev box — 跑数据 800/900 client triage needs real Z interface FMs).
  if (system === 'DVP' && opClass === 'exec-readonly') {
    if (matchAny(name, sys.dvpReadFmWhitelistRegex) || isCustomerNamespace(name)) return { ok: true };
    return { ok: false, code: 'FM_NOT_READ_ON_DVP',
      message: `${name} 不在 DVP 只读白名单（exec 工具仅放行只读 FM 与 Z/Y 自定义函数；开发写入请用阶段 3 的 dev 工具）。` };
  }

  // read tools (sap_query/object_meta/fm_read) use their own fixed read FMs and
  // bypass this check (their underlying FMs are already read-only by construction).
  return { ok: true };
}

export function isWritePattern(fm) {
  const name = (fm || '').trim().toUpperCase();
  return matchAny(name, getSystems().writePatternsForceTestrun);
}
