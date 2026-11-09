// test: chunk72 word-boundary behavior (09-16 R3STATE fix regression suite)
// imports the REAL implementation from src/tools/sap_query.js (named export)
// run: node test/chunk72.mjs  (expect ALL OK, exit 0)
import { chunk72 } from '../src/tools/sap_query.js';

let fail = 0;
function check(name, cond, detail) {
  if (cond) console.log('  PASS ' + name);
  else { fail++; console.log('  FAIL ' + name + ' :: ' + detail); }
}

// case 1: 83-char real-world REPOSRC WHERE (ZUTIL_002 banner)
const w1 = "( PROGNAME LIKE 'SAPLZUTIL_002%' OR PROGNAME LIKE 'LZUTIL_002%' ) AND R3STATE = 'A'";
const c1 = chunk72(w1);
const j1 = c1.map((x) => x.TEXT).join(' ');
check('case1 每行<=72', c1.every((x) => x.TEXT.length <= 72), c1.map((x) => x.TEXT.length).join(','));
check('case1 拼回==原文', j1 === w1, JSON.stringify(j1));
check('case1 不切R3STATE', c1.every((x) => !x.TEXT.endsWith('R3') || x.TEXT.includes('R3 =')), c1.map((x) => x.TEXT).join(' | '));

// case 2: long E070 batch OR (~300 chars, multiple TRKORR)
const trs = Array.from({ length: 10 }, (_, i) => "TRKORR = 'ABCK12345" + i + "'");
const w2 = trs.join(' OR ');
const c2 = chunk72(w2);
const j2 = c2.map((x) => x.TEXT).join(' ');
check('case2 每行<=72', c2.every((x) => x.TEXT.length <= 72), c2.map((x) => x.TEXT.length).join(','));
check('case2 拼回==原文', j2 === w2, JSON.stringify(j2));

// case 3: literal containing spaces + escaped quote
const w3 = "PROGNAME = 'AB CD''S' AND R3STATE = 'A' AND DEVCLASS = 'ZFOO'";
const c3 = chunk72(w3);
const j3 = c3.map((x) => x.TEXT).join(' ');
check('case3 拼回==原文(含空格字面量)', j3 === w3, JSON.stringify(j3));
check('case3 每行<=72', c3.every((x) => x.TEXT.length <= 72), c3.map((x) => x.TEXT.length).join(','));

// case 4: single token > 72 (pathological) hard-split fallback — 每行<=72 且零字符丢失
// (注:硬切边界拼回时会补一个空格,仅影响 >72 词元的病理输入,正常 WHERE 不受影响)
const w4 = 'A'.repeat(100) + " = '1'";
const c4 = chunk72(w4);
check('case4 硬切每行<=72', c4.every((x) => x.TEXT.length <= 72), JSON.stringify(c4.map((x) => x.TEXT)));
const aCount = c4.map((x) => x.TEXT).join('').split('A').length - 1;
check('case4 硬切零字符丢失', aCount === 100 && c4[c4.length - 1].TEXT === "= '1'", JSON.stringify(c4.map((x) => x.TEXT)));

// case 5: <=72 stays single line
const w5 = "PROGNAME LIKE 'ZRPT1003%' AND R3STATE = 'A'";
const c5 = chunk72(w5);
check('case5 短WHERE单行', c5.length === 1 && c5[0].TEXT === w5, JSON.stringify(c5));

console.log(fail === 0 ? 'ALL OK' : fail + ' FAILED');
process.exit(fail === 0 ? 0 : 1);
