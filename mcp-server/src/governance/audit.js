// audit.js — JSONL audit log + credential scrubber + retention.
// Every tool call writes a `started` line (before spawn) and a `finished` line
// (after). Credential keys are recursively scrubbed before any line hits disk.
import fs from 'node:fs';
import path from 'node:path';

const auditDir = process.env.SAP_MCP_AUDIT_DIR || 'D:\\Claude\\Cache\\sap-mcp-audit';
const SCRUB_RE = /password|passwd|pwd|secret|token|credential/i;

export function scrub(value) {
  if (value === null || value === undefined) return value;
  if (Array.isArray(value)) return value.map(scrub);
  if (typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      out[k] = SCRUB_RE.test(k) ? '***SCRUBBED***' : scrub(v);
    }
    return out;
  }
  return value;
}

let reqCounter = 0;
export function nextRequestId() {
  reqCounter += 1;
  return `${Date.now()}-${reqCounter}`;
}

function dayStamp(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${dd}`;
}

function fileForDate(d) {
  return path.join(auditDir, `audit-${dayStamp(d)}.jsonl`);
}

export function writeAudit(entry) {
  try {
    fs.mkdirSync(auditDir, { recursive: true });
    fs.appendFileSync(fileForDate(new Date()), JSON.stringify(entry) + '\n', 'utf8');
  } catch {
    // best-effort: audit failure must never break a tool call
  }
}

/** count entries within the last `hours` matching predicate(entry) */
export function countAuditRecent(predicate, hours = 24) {
  const now = Date.now();
  const cutoff = now - hours * 3600 * 1000;
  let count = 0;
  const daysToScan = Math.ceil(hours / 24) + 1;
  for (let i = 0; i <= daysToScan; i++) {
    const d = new Date(now - i * 86400000);
    let lines = [];
    try { lines = fs.readFileSync(fileForDate(d), 'utf8').split(/\r?\n/); } catch { continue; }
    for (const ln of lines) {
      const trimmed = ln.trim();
      if (!trimmed) continue;
      try {
        const e = JSON.parse(trimmed);
        const ts = typeof e.ts === 'number' ? e.ts : Date.parse(e.ts);
        if (!ts || ts < cutoff || ts > now) continue;
        if (predicate(e)) count += 1;
      } catch {}
    }
  }
  return count;
}

/** delete audit files older than retentionDays */
export function pruneAudit(retentionDays = 30) {
  try {
    const files = fs.readdirSync(auditDir).filter((f) => /^audit-\d{4}-\d{2}-\d{2}\.jsonl$/.test(f));
    const cutoff = Date.now() - retentionDays * 86400000;
    for (const f of files) {
      const m = f.match(/audit-(\d{4}-\d{2}-\d{2})/);
      if (!m) continue;
      const t = Date.parse(m[1]);
      if (t && t < cutoff) { try { fs.unlinkSync(path.join(auditDir, f)); } catch {} }
    }
  } catch {}
}
