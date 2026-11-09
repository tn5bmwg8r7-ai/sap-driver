// result-shape.js — normalize dispatcher step results.
// Guards against PS single-element array unwrap and empty-array-as-null, and
// parses RFC_READ_TABLE DATA rows (WA delimited strings) into objects with
// 512-char WA truncation detection.

export function asArray(v) {
  if (v === null || v === undefined) return [];
  return Array.isArray(v) ? v : [v];
}

/**
 * Parse RFC_READ_TABLE DATA rows ({WA:"f1|f2|..."} delimited by DELIMITER) using
 * the requested FIELDS order. Sets truncated=true when any WA hits the 512-char
 * limit (RFC_READ_TABLE WA is CHAR512 — a length of 512 means the row may have
 * been silently truncated).
 */
export function parseRfcReadTable({ data, fields, delimiter = '|' }) {
  const rows = [];
  let truncated = false;
  const fieldNames = asArray(fields)
    .map((f) => (f && typeof f === 'object' ? (f.fieldName || f.FIELDNAME) : f))
    .filter(Boolean);

  for (const r of asArray(data)) {
    const wa = typeof r === 'string' ? r : (r && (r.WA || r.wa)) || '';
    if (String(wa).length >= 512) truncated = true;
    let parts = String(wa).split(delimiter);
    // tolerate a leading empty cell when WA starts with the delimiter
    if (parts.length === fieldNames.length + 1 && parts[0] === '') parts = parts.slice(1);
    const row = {};
    fieldNames.forEach((fn, i) => { row[fn] = (parts[i] || '').trimEnd(); });
    rows.push(row);
  }
  return { rows, truncated };
}

/** Mark a result with how many rows were returned (for audit). Mutates + returns. */
export function withAuditRows(obj, count) {
  if (obj && typeof obj === 'object') obj._auditRows = count;
  return obj;
}
