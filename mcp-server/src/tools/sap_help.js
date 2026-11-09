// sap_help — static tool catalog + routing heuristics. Pure info, no SAP call.
import { z } from 'zod';

export default {
  name: 'sap_help',
  description: '查看 SAP MCP 工具目录、选择启发式与治理规则（不连接 SAP）。不确定用哪个工具时调用。',
  schema: {
    system: z.enum(['DVP', 'QAS', 'PRD']).optional().describe('占位字段（help 不连 SAP，可不传）'),
  },
  allowedEnvs: ['DVP', 'QAS', 'PRD'],
  opClass: 'read',
  needsRfc: false,
  requiresSystem: false,
  underlying: [],
  async run() {
    return {
      ok: true,
      tools: [
        { name: 'sap_connect', when: '每会话每系统首次使用前调一次——注入+验证凭证（密码仅内存，会话结束失效）。' },
        { name: 'sap_env_status', when: '查看系统可达性 / 凭证缓存 / 24h 审计调用计数。' },
        { name: 'sap_query', when: '读业务表数据(RFC_READ_TABLE)。WHERE 仅简单等值/LIKE，拒括号/OR；maxRows 上限 1000。' },
        { name: 'sap_object_meta', when: '摸清表/结构/数据元素：字段目录、域固定值、检查表、是否标准命名空间。' },
        { name: 'sap_fm_read', when: '读函数模块的接口签名 + ABAP 源码（开发前调研首选）。' },
        { name: 'sap_fm_exec', when: '执行只读 FM/BAPI 看实际返回。QAS/PRD 仅 GET 白名单；DVP 放行只读 FM。' },
      ],
      routing: {
        '读表数据': 'sap_query',
        '字段/结构/域元信息': 'sap_object_meta',
        '函数接口 / 源码': 'sap_fm_read',
        '跑只读 BAPI 看实际返回': 'sap_fm_exec',
        '开发前调研': 'sap_fm_read + sap_object_meta + 本地知识库偏好(ALV模板/ECC语法/命名约定)',
      },
      governance: {
        DVP: '读 + 只读FM执行；新建 Z 对象直写(阶段3 sap_dev_create)；改现有 Z / 增强 → 只生成代码',
        QAS: '读 + 仅 GET 白名单 FM；禁一切写入与配置',
        PRD: '读 + 仅 GET 白名单 FM（镜像 QAS 治理）；禁一切写入与配置',
      },
      tips: [
        '通道选择：默认走 RFC(sap_query/object_meta/fm_read/exec)；GUI 桥(阶段3 sap_gui)仅在 RFC 做不了时用。',
        'QAS RFC_READ_TABLE 无 ROWSKIP：结果达上限时收窄 WHERE，不做偏移分页。',
        '开发前先 sap_fm_read 读现有 Z FM 源码 + sap_object_meta 读依赖结构，再按 ECC 语法生成代码。',
      ],
    };
  },
};
