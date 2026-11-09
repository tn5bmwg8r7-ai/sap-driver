// FT-form strategy (ZMM, customer program — UNPACK can read it):
// Node reads the function's FT program via ZLILY_DIAG_UNPACK, tweaks first line
// to PROGRAM, appends mywrite form (set %_I* from payload + call FT's own
// EXPORT_IMPORT('IO')). GEN_EXEC runs it.
import { runSteps, killAll } from '../../src/ps/workerpool.js';

const password = process.env.SAP_MCP_TEST_PW;
if (!password) { console.error('need SAP_MCP_TEST_PW'); process.exit(2); }
const systemsPath = process.env.SAP_MCP_SYSTEMS || '../systems.json';
const sapBin = process.env.SAP_MCP_BIN || '../../rfc-frontend/RfcCli';
const FUNC = 'ZIF_MM_MATNR';
const FT_PROG = 'ZIF_MM_MATNR=======FT';
const VARIANT = '11';
const params = {
  PLANT: { ZSTR_PLANT: '9310' },
  HEADDATA: { ACCOUNT_VIEW: 'X', PURCHASE_VIEW: 'X', MATERIAL: '000000007000000049' },
  VALUATIONDATA: { STD_PRICE: '589.96', PRICE_UNIT: '1', MOVING_PR: '589.96' },
  PLANTDATAX: { MINLOTSIZE: 'X', PLND_DELRY: 'X', SOURCELIST: 'X', ROUND_VAL: 'X' },
  PLANTDATA: { MINLOTSIZE: '150', PLND_DELRY: '180', SOURCELIST: 'X', ROUND_VAL: '10' },
};

// 1. read FT source
const ftR = await runSteps({ system: 'QAS', password, systemsPath, sapBin, timeoutMs: 60000,
  steps: [{ id: 'ft', function: 'ZLILY_DIAG_UNPACK', import: { IV_INCL: FT_PROG } }] });
if (ftR.results?.ft?._error || ftR.results?.ft?.EV_ERROR) {
  console.error('UNPACK fail:', ftR.results?.ft?._error || ftR.results?.ft?.EV_ERROR); process.exit(1);
}
let ftLines = String(ftR.results.ft.EV_RESULT || '').split(/\r?\n/);
while (ftLines.length && ftLines[0].trim() === '') ftLines.shift();
if (/REPORT/i.test(ftLines[0])) ftLines[0] = 'PROGRAM.';
else ftLines.unshift('PROGRAM.');

// 2. mywrite form: set key + set %_I* + call EXPORT_IMPORT('IO')
ftLines.push('FORM r USING pa pp pn.');
ftLines.push('  DATA: lk TYPE functdir.');
ftLines.push('  DATA: lv_j TYPE string.');
ftLines.push('  lk-area = pa.');
ftLines.push('  lk-progid = pp.');
ftLines.push('  lk-dataid = pn.');
ftLines.push('  SHIFT lk-dataid RIGHT DELETING TRAILING SPACE.');
ftLines.push('  SHIFT lk-dataid LEFT BY 1 PLACES.');
for (const [p, v] of Object.entries(params)) {
  if (v && typeof v === 'object' && !Array.isArray(v)) {
    for (const [f, val] of Object.entries(v)) {
      ftLines.push(`  %_i${p}-${f} = '${String(val).replace(/'/g, "''")}'.`);
    }
  }
}
ftLines.push("  PERFORM export_import USING 'IO' lk.");
ftLines.push("  UPDATE eufunc SET autor = '<你的SAP用户名>'");
ftLines.push("                    datum = sy-datum");
ftLines.push("                    version = '  1'");
ftLines.push("    WHERE relid = 'FL' AND gruppe = lk-area");
ftLines.push("      AND name = lk-progid AND nummer = lk-dataid AND srtf2 = 0.");
ftLines.push("  lv_j = 'WROTE'.");
ftLines.push("  EXPORT lv_j TO MEMORY ID 'ZLILY_VR'.");
ftLines.push('ENDFORM.');

const srcLines = ftLines.map((l) => ({ LINE: l.slice(0, 72) }));
console.log('lines:', srcLines.length, 'first:', JSON.stringify(srcLines[0].LINE));

// 3. GEN_EXEC generate + PERFORM mywrite
const genR = await runSteps({ system: 'QAS', password, systemsPath, sapBin,
  steps: [{ id: 'gen', function: 'ZLILY_DIAG_GEN_EXEC',
    import: { IV_AREA: FUNC, IV_PROGID: FUNC, IV_DATAID: VARIANT },
    tables: { IT_SRC: srcLines } }] });
const gen = genR.results?.gen;
console.log('write:', gen?.EV_RESULT || gen?.EV_ERROR || gen?._error);
killAll();
setTimeout(() => process.exit(0), 500);
