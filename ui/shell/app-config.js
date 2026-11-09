// ============================================================
// 部署配置单例(2026-09-02 分发架构改造 P0)。
// PW 走默认值;MOOD 分发形态由其生成的 index.html 内联
// window.__APP_CONFIG__ 覆盖,让 packages/core 同一份文件在两种部署下
// 逐字流动(消灭移植手术:存储前缀/库名/端口不再硬编码散落)。
// 本文件禁止 import 任何模块(widget-registry 等在 import 期就要读它)。
// 不变量:两侧 storagePrefix/dbName 数值不变(pw:/personal-workspace vs
// mood:/mood-standalone),同事端 IndexedDB/localStorage 数据零迁移。
// ============================================================
const DEFAULTS = {
  storagePrefix: 'pw:',           // localStorage 键前缀(MOOD='mood:')
  dbName: 'personal-workspace',   // IndexedDB 库名(MOOD='mood-standalone')
  bridgeBase: '',                 // bridge 根;空=按 hostname+bridgePort 派生(MOOD 同源='')
  bridgePort: 8421,               // bridgeBase 为空时的派生端口(MOOD=8422)
  author: '',                     // 署名/联系名(分享导出页);PW 由 apps/pwa/index.html 注入,MOOD 生成时注入
  licenseNameKey: 'pw:license-name',  // 分发形态:持授权人名字的 localStorage 键,存在时优先于 author 署名
  defaultColleagues: [],          // 日报组件:已知同事种子清单(部署注入;MOOD=空由用户自建)
  defaultProjects: [],            // 日报组件:项目维度种子清单(同上)
  weeklyReportFixedTo: [],        // 项目周报:固定收件人种子名单(部署注入;2026-09-11 用户定=PW 个性化逻辑,仅 apps/pwa/index.html 注入,MOOD=空→逻辑不生效)
  features: null                  // null=全部启用;数组=feature 白名单(Registry 注册过滤,P3)
};
const injected = (typeof window !== 'undefined' && window.__APP_CONFIG__) || {};
export const APP_CONFIG = Object.freeze(Object.assign({}, DEFAULTS, injected));

// 分享/导出署名(2026-09-02 分发收敛,2026-09-21 审查收拢单源):分发形态优先持授权人名
// (licenseNameKey),否则部署 author。原 kb-view/projects-lifecycle-view(SIGN_AUTH)与
// work-journal(WJ_SIGN)三处同式各写一份,已改引本常量。
export const SIGN_AUTH = (APP_CONFIG.licenseNameKey && localStorage.getItem(APP_CONFIG.licenseNameKey)) || APP_CONFIG.author || 'Author';

// localStorage 键助手:skey('appearance') 即 'pw:appearance'(MOOD 侧自动='mood:appearance')
export const skey = (k) => APP_CONFIG.storagePrefix + k;

// 分发闸门(2026-09-02 P3):feature 白名单过滤。APP_CONFIG.features 为 null(全量形态,PW)时
// 恒放行;为数组(分发形态)时,manifest 标了 feature 且不在名单里的注册直接丢弃 —— 导航/深链/
// 命令面板一处封死全部入口。未标 feature 的入口不受影响(镜像文件必在清单内,归属即标记)。
export function featureEnabled(f) {
  if (!APP_CONFIG.features || !f) return true;
  return APP_CONFIG.features.includes(f);
}
