// sap_dev_tr — DEPRECATED channel (kept for tool-contract stability; never fires RFC).
// TR_OBJECT_INSERT is NOT remote-enabled (README「Known SAP-side remote-ABAP boundaries」):
// governance used to let it through and the RFC layer failed with an opaque _error.
// Since 2026-09-16 run() fast-fails locally (CHANNEL_NOT_RFC) without dispatching doomed
// steps. Real paths:
//   1. FUNC/FUNCGROUP creation auto-attaches via CORRNUM (sap_dev_create)
//   2. everything else → sap_dev_tr_put (ZLILY_DEV_TR_PUT wrapper: TRINT_OBJECTS_CHECK_
//      AND_INSERT + COMMIT WORK; KO200 bare keys PGMID/OBJECT/OBJ_NAME, E071K empty,
//      IV_APPEND_TO_ORDER='X' — recipe proven on ZREP003)
//   3. anything the wrapper refuses → SE10 manual (programs: LIMU REPS+REPT pair)
import { z } from 'zod';

export default {
  name: 'sap_dev_tr',
  description:
    '【已弃用通道】TR_OBJECT_INSERT 非 RFC,本工具恒拒(CHANNEL_NOT_RFC),不再发射必败调用。正道:①建 FUNC/FUNCGROUP 用 sap_dev_create(CORRNUM 出生挂 TR)②其它对象用 sap_dev_tr_put(ZLILY_DEV_TR_PUT 包装器)③探不通的对象 SE10 手工挂(程序类 LIMU REPS+REPT 成对)。',
  schema: {
    system: z.enum(['DVP']),
    trkorr: z.string().describe('传输请求号(每次必填)'),
    objects: z.array(z.any()).min(1).describe('要挂的对象清单:每项 {objectType, objectName, pgmid?(默认R3TR)}'),
  },
  allowedEnvs: ['DVP'],
  opClass: 'dev-write',
  needsRfc: true,
  underlying: ['TR_OBJECT_INSERT'],
  async run() {
    // M2(2026-09-16) 快速失败:TR_OBJECT_INSERT 非 remote-enabled,治理放行但 RFC 层必败,
    // 且失败只吐不透明 _error。本地直接拒绝,零 RFC 往返;对象级护栏由 sap_dev_tr_put 承接。
    return {
      ok: false,
      code: 'CHANNEL_NOT_RFC',
      message: 'TR_OBJECT_INSERT 不是 remote-enabled FM,本通道物理必败(治理放行但 RFC 层拒绝)。' +
        '改用:sap_dev_create(建 FUNC/FUNCGROUP 时 CORRNUM 出生挂 TR)/ sap_dev_tr_put(ZLILY_DEV_TR_PUT ' +
        '包装器)/ SE10 手工挂(程序类 LIMU REPS+REPT 成对)。',
    };
  },
};
