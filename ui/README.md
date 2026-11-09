# ui — SAP Driver 前端层

原生 ES Modules + 无构建步骤的浏览器前端。来自作者内部使用的 SAP AI 助手工具页,抽出为可独立部署的子集。

## 结构

```
ui/
├── widgets/                    # SAP Driver 业务组件(11 个)
│   ├── sap-copilot.widget.js   # 主壳:页签框架 + 装配(bindSapShared 注入)
│   ├── sap-copilot.styles.js   # 全部样式(CSS-in-JS)
│   ├── sap-copilot.catalog.js  # Skill 地图数据(SAP_CATALOG/SAP_CATEGORIES)
│   ├── sap-copilot-probe.js    # 🔍 排查页签(混入)
│   ├── sap-copilot-diagpk.js   # 🩺 体检页签(混入)
│   ├── sap-copilot-wk.js       # 📊 负载周报页签(混入)
│   ├── sap-copilot-ask.js      # 🤖 Agent 智能体页签(混入)
│   ├── sap-copilot-art.js      # 📦 产物+Trace 页签(混入)
│   ├── sap-copilot-catalog.js  # 🗺️ Skill 地图页签(混入)
│   ├── sap-flow.widget.js      # 🚰 交付驾驶舱(工单状态机前端)
│   └── sap-flow.pipeline.js    # 交付流水线节点/闸门定义
├── shell/                      # 壳层共用件(10 个)
│   ├── bridge-client.js        # 桥 HTTP 客户端(token/Bearer/健康检查/自动补 token)
│   ├── app-config.js           # 部署配置单例(window.__APP_CONFIG__ 注入点)
│   ├── event-bus.js / toast.js / html-utils.js / export-utils.js
│   ├── markdown-renderer.js / md-document.js / dingtalk-text.js / command-runner.js
├── dal/                        # IndexedDB 数据层
│   ├── db.js / repository.js / asset-mirror.js
│   └── repositories/todos.js, command-log.js
└── registry/                   # 组件/命令注册表(feature 白名单分发闸)
    ├── widget-registry.js / command-registry.js
```

## 接入方式

这个 UI 层需要一个壳页面(HTML + 导航框架)来挂载。两种用法:

### A. 嵌入你自己的工作台

模仿原壳的注册模式:

```js
import { WidgetRegistry } from './registry/widget-registry.js';
import './widgets/sap-copilot.widget.js';   // import 即自注册(id='sap-copilot', feature='sap')

// 挂载:任何容器都行
const manifest = WidgetRegistry.get('sap-copilot');
const ctx = manifest.mount(container, settings);
```

配置注入(在 HTML 里):

```html
<script>
window.__APP_CONFIG__ = {
  storagePrefix: 'sapdriver:',
  dbName: 'sap-driver',
  bridgePort: 8421,        // bridge 端口(见 ../bridge/)
  features: ['sap'],       // feature 白名单(只开 SAP Driver)
};
</script>
```

### B. 壳框架自行实现

原壳是 Custom Element + 导航/页签框架,本仓不含壳本身;按 A 方式在自己的壳里挂载即可,widget 的 `mount(host)` 协议是自包含的。

## 与 bridge 的协议

widget 全部经 `bridge-client.js` 走 `POST /run/<route>`,载荷 `{ result: ... }` 包装(详见 `../bridge/README.md`)。首次连接自动 `GET /bridge-token` 补 token(同源免配置)。

## 浏览器兼容

ES2020+(可选链/空值合并),目标 Chrome/Edge 90+。无打包器:`<script type="module">` 直载。

## 缓存注意

带 `?v=` 后缀的 import 是**缓存爆破链**——改了被引文件必须同步升版本号,否则 Edge 的 module 缓存会攥着旧文件不放(实爆教训)。部署时统一改。
