// mask-workload.mjs — workload exemption tests (2026-09-17; +sap_query table exemption)
import { maskResult } from '../src/util/mask.js';
let pass = 0, fail = 0;
function check(name, cond, detail = '') {
  (cond ? pass++ : fail++);
  console.log(`${cond ? '[PASS]' : '[FAIL]'} ${name} ${detail}`);
}

// 1) workload fm_exec on PRD: account names survive untouched
const wl = { ok: true, system: 'PRD', function: 'SWNC_GET_WORKLOAD_STATISTIC',
  result: { USERTCODE: [{ ACCOUNT: '<你的SAP用户名>', ENTRY_ID: 'VA01 T', COUNT: '100' }] } };
maskResult(wl, 'PRD', 'sap_fm_exec');
check('wl-account-kept', wl.result.USERTCODE[0].ACCOUNT === '<你的SAP用户名>');
check('wl-no-maskstats', !wl._maskStats);

// 2) even a value that LOOKS like PII inside workload result stays (byte-exact report data)
const wl2 = { ok: true, system: 'PRD', function: 'SAPWL_WORKLOAD_GET_SUMMARY',
  result: { SUMMARY: [{ TASKTYPE: 'DIALOG', COUNT: '1', RESPTI: '1381234567812345678' }] } };
maskResult(wl2, 'PRD', 'sap_fm_exec');
check('wl-byte-exact', wl2.result.SUMMARY[0].RESPTI === '1381234567812345678');

// 3) sap_query exempt tables (workload report + health digest sources): SNAP/VBMOD/TBTCO/USR21/ADRP/TSTCT/TRDIRT
for (const t of ['SNAP', 'VBMOD', 'TBTCO', 'USR21', 'ADRP', 'TSTCT', 'TRDIRT', 'VBHDR']) {
  const q = { ok: true, system: 'PRD', table: t,
    result: { rows: [{ UNAME: '<你的SAP用户名>', BNAME: '<你的SAP用户名>', NAME_FIRST: 'TEST', TTEXT: '创建销售订单', VBKEY: '0000012345' }] } };
  maskResult(q, 'PRD', 'sap_query');
  check(`q-exempt-${t}`, q.result.rows[0].UNAME === '<你的SAP用户名>' && q.result.rows[0].NAME_FIRST === 'TEST');
}
// lowercase table name also exempt (defensive)
const ql = { ok: true, system: 'PRD', table: 'tbtcO', result: { rows: [{ JOBNAME: 'Z_JOB' }] } };
maskResult(ql, 'PRD', 'sap_query');
check('q-exempt-lowercase', ql.result.rows[0].JOBNAME === 'Z_JOB');

// 4) regression: normal business table query on PRD still masks (Luhn-valid 18-digit)
const tbl = { ok: true, system: 'PRD', table: 'BSIK', function: undefined,
  result: { rows: [{ BANKN: '6222020200112233445' }] } };
maskResult(tbl, 'PRD', 'sap_query');
check('normal-still-masked', tbl.result.rows[0].BANKN.includes('*'), JSON.stringify(tbl.result.rows[0]));

// 5) regression: non-PRD untouched
const dev = { ok: true, system: 'DVP', function: 'ZLILY_DIAG_Q3', result: { rows: [{ BANKN: '6222020200112233445' }] } };
maskResult(dev, 'DVP', 'sap_fm_exec');
check('dvp-untouched', dev.result.rows[0].BANKN === '6222020200112233445');

console.log(`\n== ${pass} passed / ${fail} failed ==`);
process.exit(fail ? 1 : 0);
