// sap_variant_write FT 名修复回归(2026-09-17 接口定位一键链前置)
// FT 名口径 = 函数名右补 '=' 到 30 位 + 'FT'(REPOSRC 实查);旧代码写死 7 个 '='
// 只有 23 字符函数碰巧对——ZIF_HR_001(21 字符)实爆。
import assert from 'node:assert';
import { ftProgramName, buildFtFormSource } from '../src/tools/sap_variant_write.js';

let n = 0;
function ok(cond, label) { n++; assert.ok(cond, label); console.log(`  ok ${n} - ${label}`); }

// 1) FT 名:不同长度函数的补齐
ok(ftProgramName('ZIF_HR_001') === 'ZIF_HR_001==========FT', '20字符 → 10个= (实爆案例,旧代码只有7个=)');
ok(ftProgramName('ZIF_MM_MATNR') === 'ZIF_MM_MATNR=======FT', '23字符 → 7个= (旧代码唯一碰巧对的)');
ok(ftProgramName('ZABCDEF') === 'ZABCDEF=======================FT', '7字符 → 23个=');
ok(ftProgramName('ZTEST_LONG_NAME_FUNC_30XX') === 'ZTEST_LONG_NAME_FUNC_30XX==FT', '28字符 → 2个=');
ok(ftProgramName('X'.repeat(30)) === 'X'.repeat(30) + 'FT', '30字符顶格 → 0个=');
ok(ftProgramName('ZIF_MM_MATNR').length === 32, 'FT 名总长 32');

// 2) buildFtFormSource 回归:报文填充 + FORM 结构不破
const imports = [{ name: 'IV_USER', type: 'CHAR10' }, { name: 'HEADER', type: 'ZS_HEADER' }];
const tables = [{ name: 'T_DATA', dbstruct: 'ZS_DATA' }];
const ftFake = ['PROGRAM.', 'FORM export_import USING p1 p2 p3.', 'ENDFORM.'];
const src = buildFtFormSource(
  ftFake,
  { IV_USER: 'u01', HEADER: { FIELD1: 'v1' }, T_DATA: [{ KEY: 'k1', VAL: 'x' }] },
  imports, tables, '<你的SAP用户名>',
).map((l) => l.LINE);
ok(src[0] === 'PROGRAM.', 'FT 无 REPORT 头时补 PROGRAM.');
ok(src.some((l) => l.includes("%_iIV_USER = 'u01'")), '标量入参填充');
ok(src.some((l) => l.includes("%_iHEADER-FIELD1 = 'v1'")), '结构入参填充');
ok(src.some((l) => l.includes("ls_T_DATA-KEY = 'k1'")), '表行字段填充');
ok(src.some((l) => l.includes('APPEND ls_T_DATA TO %_iT_DATA')), '表 APPEND(ECC 语法)');
ok(src.every((l) => l.length <= 72), '每行 ≤72(Q3 池子截断口径)');
ok(src.some((l) => l.includes("autor = '<你的SAP用户名>'")), 'EUFUNC 回写作者=凭证用户');
ok(!src.some((l) => /=`/i.test(l)), '无反引号残留(模板串未求值指纹)');

console.log(`\nvariant-write-ft: ${n} assertions passed`);
