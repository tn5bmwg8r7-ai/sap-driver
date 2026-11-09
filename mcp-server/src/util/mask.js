// mask.js — PII masking for SAP tool results.
// Applied at the single exit of server.js so EVERY tool result is scrubbed before it
// leaves the MCP server (before the data reaches the AI context / cloud model).
//
// Two layers:
//   1) VALUE masking — any string value matched by phone / id-card(checksum) /
//      bank-card(Luhn) / email / IPv4 patterns. Validators keep false positives low,
//      so MATNR (18-digit material) / BELNR (10-digit doc) survive untouched.
//   2) FIELD masking — values sitting under known sensitive FIELD NAMES (PERNR work
//      no., names, ID-card no., user id) are masked regardless of format. This catches
//      SAP PII that value-patterns miss (e.g. an 8-digit PERNR, a CN name).
//
// Metadata keys (ok/system/table/columns/_auditRows/...) are not field-sensitive and
// their string values ("QAS", "PA0001", field names) don't match PII patterns, so they
// pass through unchanged.

const RE_PHONE  = /(?<!\d)1[3-9]\d{9}(?!\d)/g;
const RE_IDCARD = /(?<!\d)\d{17}[\dXx](?!\d)/g;
const RE_BANK   = /(?<!\d)\d{16,19}(?!\d)/g;
const RE_EMAIL  = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const RE_IP     = /\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b/g;

function idChecksumValid(s) {
  if (s.length !== 18) return false;
  const body = s.slice(0, 17);
  if (!/^\d{17}$/.test(body)) return false;
  const w = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  const m = '10X98765432';
  let sum = 0;
  for (let i = 0; i < 17; i++) sum += parseInt(body[i], 10) * w[i];
  return s[17].toUpperCase() === m[sum % 11];
}

function luhnValid(s) {
  if (!/^\d+$/.test(s)) return false;
  let sum = 0, alt = false;
  for (let i = s.length - 1; i >= 0; i--) {
    let d = parseInt(s[i], 10);
    if (alt) { d *= 2; if (d > 9) d -= 9; }
    sum += d; alt = !alt;
  }
  return sum % 10 === 0;
}

// Mask PII patterns inside a single string value. Mutates the stats counter.
function maskValue(str, stats) {
  if (typeof str !== 'string' || str === '') return str;
  let s = str;
  s = s.replace(RE_EMAIL, (m) => { stats.email++; return m[0] + '***@' + m.slice(m.indexOf('@') + 1); });
  s = s.replace(RE_PHONE, (m) => { stats.phone++; return m.slice(0, 3) + '****' + m.slice(7); });
  s = s.replace(RE_IDCARD, (m) => { if (!idChecksumValid(m)) return m; stats.idcard++; return m.slice(0, 6) + '********' + m.slice(14); });
  s = s.replace(RE_BANK, (m) => { if (!luhnValid(m)) return m; stats.bank++; return m.slice(0, 4) + '*'.repeat(m.length - 8) + m.slice(-4); });
  s = s.replace(RE_IP, (m) => {
    const p = m.split('.');
    if (p.some((x) => +x > 255)) return m;
    stats.ip++; return p[0] + '.' + p[1] + '.*.*';
  });
  return s;
}

// Sensitive field NAMES (uppercased). Direct-PII fields → fully masked by field name.
// User rule 2026-08-07 (option A): KEEP business keys — PERNR (work no.) / names /
// phones / user ids — so analysis that joins or matches by them stays accurate.
// Only mask true direct-PII (ID-card / passport / bank-account no.) by field NAME.
// Phone / id-card / bank-card / email / IP are still value-masked everywhere via the
// regex layer (maskValue), so a 138xxxxxxxx in any field still gets scrubbed.
const ID_FIELDS = new Set([
  'ICNUM', 'ICN', 'PERID', 'PASSP',   // 身份证 / 护照号
  'BANKN', 'BKREF',                    // 银行账号
]);
const NAME_FIELDS = new Set([]);       // 姓名 保留(业务键,不脱敏)

function isSensitiveField(key) {
  const k = String(key || '').toUpperCase();
  if (ID_FIELDS.has(k) || NAME_FIELDS.has(k)) return true;
  return false;
}

// Mask a value by field semantics: ID-ish fully masked, name-ish keeps first char.
function maskField(key, v) {
  if (v === null || v === undefined || v === '') return v;
  const s = String(v).trim();
  if (s === '') return s;
  const K = String(key).toUpperCase();
  if (K.startsWith('PERNR') || ID_FIELDS.has(K) || K.startsWith('TEL') || K.startsWith('MOB')) {
    return '*'.repeat(Math.min(s.length, 10));     // 全打码
  }
  if (s.length <= 1) return '*';
  return s[0] + '*'.repeat(Math.min(s.length - 1, 5)); // 姓名首字 + 星
}

// Deep-walk in place: field-mask sensitive keys, value-mask everything else.
function walkInPlace(node, stats) {
  if (Array.isArray(node)) {
    for (let i = 0; i < node.length; i++) node[i] = walkInPlace(node[i], stats);
    return node;
  }
  if (node && typeof node === 'object') {
    for (const k of Object.keys(node)) {
      const v = node[k];
      if (isSensitiveField(k) && v !== null && typeof v !== 'object') {
        stats.field++;
        node[k] = maskField(k, v);
      } else {
        node[k] = walkInPlace(v, stats);
      }
    }
    return node;
  }
  if (typeof node === 'string') return maskValue(node, stats);
  return node;
}

// Tools whose results must stay BYTE-EXACT: source-code reads. Masking PRD source
// corrupts it silently and wrecks content-level transport comparison — 2026-09-16
// incident: the bank-card rule (Luhn-valid 18-digit run) rewrote a material-range
// literal '000000005799999999' → '0000**********9999', and the IPv4 rule rewrote
// comment numbering '2.2.1.1' → '2.2.*.*'; three ZRPT1003 objects were then falsely
// flagged "PRD 落后/真传输缺口". Source code is not business table data (PII lives
// in tables); these tools are exempt from masking for ALL systems.
const SOURCE_TOOLS = new Set(['sap_prog_read', 'sap_fm_read']);

// Workload statistics via sap_fm_exec (SWNC_GET_WORKLOAD_* / SAPWL_WORKLOAD_*): read-only
// aggregate performance data — no business PII lives in MONI/SWNC aggregates, and per-user
// load (ACCOUNT/USERNAME) IS the payload of the ops workload report. Masking would replace
// real accounts with garbled lookalikes and defeat the whole report. User-approved exempt
// 2026-09-17 (same rationale as SOURCE_TOOLS: these are not business table data).
const WORKLOAD_FM_RE = /^(SWNC_|SAPWL_)/;

// sap_query tables feeding the same ops workload report + health digest: SNAP (dump
// records, UNAME per user is the payload), VBMOD/VBHDR (failed updates), TBTCO (jobs),
// USR21/ADRP (account→real-name mapping so the report can show 中文姓名), TSTCT/TRDIRT
// (tcode/report texts). No business PII; user ruled 2026-09-17 「负载周报所有数据都要真实
// 不脱敏」— masked accounts/names made the report unreadable.
const QUERY_EXEMPT_TABLES = new Set([
  'SNAP', 'VBMOD', 'VBHDR', 'TBTCO', 'USR21', 'ADRP', 'TSTCT', 'TRDIRT',
]);

// Entry: mask a tool result object. Returns the same object (mutated) with a
// _maskStats summary attached only when something was actually masked.
export function maskResult(result, system, toolName) {
  if (!result || typeof result !== 'object') return result;
  if (SOURCE_TOOLS.has(String(toolName || ''))) return result;
  if (String(toolName || '') === 'sap_fm_exec' && WORKLOAD_FM_RE.test(String(result.function || ''))) return result;
  if (String(toolName || '') === 'sap_query' && QUERY_EXEMPT_TABLES.has(String(result.table || '').toUpperCase())) return result;
  // Only mask PRODUCTION data. DVP (dev) / QAS (test) hold non-production data and are
  // returned untouched so dev/debugging sees real field values. User rule 2026-08-07.
  if (system !== 'PRD') return result;
  const stats = { phone: 0, idcard: 0, bank: 0, email: 0, ip: 0, field: 0 };
  walkInPlace(result, stats);
  const total = stats.phone + stats.idcard + stats.bank + stats.email + stats.ip + stats.field;
  if (total > 0) result._maskStats = stats;
  return result;
}
