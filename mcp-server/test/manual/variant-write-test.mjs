// Write a ZIF_MM_MATNR variant from the payload, then we read it back.
import { runSteps, killAll } from '../../src/ps/workerpool.js';
import { buildWriteSource } from '../../src/tools/sap_variant_write.js';

const password = process.env.SAP_MCP_TEST_PW;
if (!password) { console.error('need SAP_MCP_TEST_PW'); process.exit(2); }
const systemsPath = process.env.SAP_MCP_SYSTEMS || '../systems.json';
const sapBin = process.env.SAP_MCP_BIN || '../../rfc-frontend/RfcCli';
const FUNC = 'ZIF_MM_MATNR';
const VARIANT = '901';

const params = {
  PLANT: { ZSTR_PLANT: '9310' },
  HEADDATA: { ACCOUNT_VIEW: 'X', PURCHASE_VIEW: 'X', MATERIAL: '000000007000000049' },
  VALUATIONDATA: { STD_PRICE: 589.96, PRICE_UNIT: '1', MOVING_PR: 589.96 },
  PLANTDATAX: { MINLOTSIZE: 'X', PLND_DELRY: 'X', SOURCELIST: 'X', ROUND_VAL: 'X' },
  PLANTDATA: { MINLOTSIZE: 150, PLND_DELRY: 180, SOURCELIST: 'X', ROUND_VAL: 10 },
};

const ifaceR = await runSteps({ system: 'DVP', password, systemsPath, sapBin, timeoutMs: 60000,
  steps: [{ id: 'iface', function: 'FUNCTION_IMPORT_INTERFACE', import: { FUNCNAME: FUNC } }] });
const iface = ifaceR.results.iface;
const imports = (iface.IMPORT_PARAMETER || []).map(p => ({ name: p.PARAMETER, type: p.TYP || p.DBFIELD || '' })).filter(p => p.name && p.type);
const tables = (iface.TABLES_PARAMETER || []).map(t => ({ name: t.PARAMETER, dbstruct: t.DBSTRUCT || t.TYP || t.STRUCTURE || '' })).filter(t => t.name && t.dbstruct);

const tfdR = await runSteps({ system: 'DVP', password, systemsPath, sapBin,
  steps: [{ id: 'tfd', function: 'ZLILY_DIAG_Q3', import: { IV_TABLE: 'TFDIR', IV_MAX_ROWS: '1' },
    tables: { IT_WHERE: [{ TEXT: `FUNCNAME = '${FUNC}'` }] } }] });
const tfd = JSON.parse(tfdR.results.tfd.EV_RESULT || '[]');
const pname = tfd[0]?.PNAME || '';
const area = pname.startsWith('SAPL') ? pname.slice(4).trim() : pname.trim();

const src = buildWriteSource(imports, tables, params);
const genR = await runSteps({ system: 'DVP', password, systemsPath, sapBin,
  steps: [{ id: 'gen', function: 'ZLILY_DIAG_GEN_EXEC',
    import: { IV_AREA: area, IV_PROGID: FUNC, IV_DATAID: VARIANT },
    tables: { IT_SRC: src } }] });
const gen = genR.results.gen;
console.log('area:', area);
console.log('write result:', gen?.EV_RESULT || gen?.EV_ERROR || gen?._error);
killAll();
setTimeout(() => process.exit(0), 500);
