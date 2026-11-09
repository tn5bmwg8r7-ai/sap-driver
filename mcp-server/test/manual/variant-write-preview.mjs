// Preview what sap_variant_write would generate for the ZMM payload (no write).
import { runSteps, killAll } from '../../src/ps/workerpool.js';
import { buildWriteSource } from '../../src/tools/sap_variant_write.js';

const password = process.env.SAP_MCP_TEST_PW;
if (!password) { console.error('need SAP_MCP_TEST_PW'); process.exit(2); }
const systemsPath = process.env.SAP_MCP_SYSTEMS || '../systems.json';
const sapBin = process.env.SAP_MCP_BIN || '../../rfc-frontend/RfcCli';

const params = {
  PLANT: { ZSTR_PLANT: '9310' },
  HEADDATA: { ACCOUNT_VIEW: 'X', PURCHASE_VIEW: 'X', MATERIAL: '000000007000000049' },
  VALUATIONDATA: { STD_PRICE: 589.96, PRICE_UNIT: '1', MOVING_PR: 589.96 },
  PLANTDATAX: { MINLOTSIZE: 'X', PLND_DELRY: 'X', SOURCELIST: 'X', ROUND_VAL: 'X' },
  VALUATIONDATAX: { STD_PRICE: 'X', PRICE_UNIT: 'X', MOVING_PR: 'X' },  // extra — not in interface
  PLANTDATA: { MINLOTSIZE: 150, PLND_DELRY: 180, SOURCELIST: 'X', ROUND_VAL: 10 },
};

const r = await runSteps({ system: 'DVP', password, systemsPath, sapBin, timeoutMs: 60000,
  steps: [{ id: 'iface', function: 'FUNCTION_IMPORT_INTERFACE', import: { FUNCNAME: 'ZIF_MM_MATNR' } }] });
const iface = r.results.iface;
const imports = (iface.IMPORT_PARAMETER || []).map(p => ({ name: p.PARAMETER, type: p.TYP || p.DBFIELD || '' })).filter(p => p.name && p.type);
const tables = (iface.TABLES_PARAMETER || []).map(t => ({ name: t.PARAMETER, dbstruct: t.DBSTRUCT || t.TYP || t.STRUCTURE || '' })).filter(t => t.name && t.dbstruct);
const exports = (iface.EXPORT_PARAMETER || []).map(e => ({ name: e.PARAMETER, type: e.TYP || e.DBFIELD || '' })).filter(e => e.name && e.type);
console.log('imports:', JSON.stringify(imports));
console.log('tables:', JSON.stringify(tables));
console.log('exports:', JSON.stringify(exports));
const known = new Set([...imports.map(p => p.name), ...tables.map(t => t.name)]);
console.log('extras (ignored):', Object.keys(params).filter(k => !known.has(k)));

const src = buildWriteSource(imports, tables, exports, params, '<你的SAP用户名>');
let bad = 0;
src.forEach((l, i) => { if (l.LINE.length > 72) bad++; console.log(`${String(i + 1).padStart(3)} ${l.LINE.length > 72 ? 'OVER' : 'ok '} (${String(l.LINE.length).padStart(2)}) ${l.LINE}`); });
console.log(`\n${src.length} lines, ${bad} over 72`);
killAll();
setTimeout(() => process.exit(0), 500);
