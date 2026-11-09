# SAP Driver

让 Claude(或任意 MCP 客户端)直接、安全、带治理地操作 SAP 的开源工具链:RFC 直连 + MCP 服务器 + HTTP 桥 + Web UI 三层合一。

> 源自作者日常使用的 SAP AI 助手工具页,开源时做了配置外置与脱敏(所有 IP/账号/凭证均为占位)。

## 它解决什么问题

SAP 日常运维/开发里大量「查表、跑报表、对比传输、生成接口文档、跑测试」动作,传统路径是登录 GUI → SE16N/SE37 手点。SAP Driver 把这些动作封装成:

- **MCP 工具**:Claude 直接调用(`sap_query` 读表、`sap_fm_exec` 跑只读函数、`sap_prog_read` 读源码……)
- **桥路由**:Web 页面一键触发(排查/体检/负载周报/接口文档/测试报告/交付驾驶舱)
- **治理闸门**:三环境分级(开发可写、测试只读白名单、生产多层锁死),密码仅内存、全量审计

## 架构

```
浏览器 UI(ui/ — ES modules,无构建)
   │  POST /run/<route>(Bearer token)
   ▼
HTTP 桥(bridge/ — PowerShell 5.1 HttpListener,3 worker runspace)
   │  Invoke-SapRfc(NCo 3.1)          │  HTTP → facade
   ▼                                    ▼
SAP RFC(ZLILY_DIAG_Q3 等自研 RFC)   mcp-server/(Node.js MCP stdio + http-facade)
                                          │
                                          ▼
                                        Claude(MCP 客户端)
```

- **ui/** — SAP Driver 全部前端页签:排查、体检、负载周报、Agent 智能体、产物、Skill 地图、交付驾驶舱
- **bridge/** — 本地 HTTP 桥(22+ 条 SAP 路由 + 交付台账窄写),token 鉴权 + Origin 白名单 + worker 池并发
- **mcp-server/** — MCP 服务器(19 个工具):读表/读元数据/读源码/跑只读 FM/变式读写 + 开发机 Z/Y 对象 CRUD,三环境治理 + JSONL 审计
- **rfc-frontend/** — NCo 3.1 RFC 前端(PowerShell `Invoke-SapRfc` + C# `SapRfcCli`)
- **mcp-server/z-rfc/** — SAP 侧 12 个自研 RFC 的 ABAP 源码(诊断查询引擎 Q3 / 变式读写 / 报表族)
- **docs/** — 部署文档

## 快速开始

完整步骤见 **[docs/部署.md](docs/部署.md)**,概要:

1. **装 NCo 3.1**(SAP 官方 DLL,版权原因需自行从 SAP Support Portal 下载 + GAC 注册)
2. **部署 SAP 侧 RFC**(把 `mcp-server/z-rfc/*.abap` 在你的开发机/测试机激活)
3. **配置环境**(`mcp-server/systems.json` + `bridge/routes/_sap-conn.ps1` 填你的三环境地址;全部密码走会话注入,绝不落盘)
4. **起桥**(`bridge/Start-Bridge.ps1`,token 自动生成)
5. **起 MCP**(`mcp-server/`,`npm install` 后在 Claude Code 注册)
6. **打开 UI**(任意静态服务器 serve `ui/`,或挂进你自己的工作台)

## 安全设计

- **密码零落盘**:所有密码只在进程内存流转(工具入参 → stdin → RFC),审计日志自动剥离凭证字段
- **三环境治理**:开发机(读+写白名单)、测试机(读+GET 类 FM 白名单)、生产机(只读镜像测试机,`prdEnabled` 默认关)
- **全局 FM 黑名单**:COMMIT/ROLLBACK/TR_* 一律拒绝
- **传输/删除硬护栏**:Z/Y 命名空间双层校验,标准对象禁改,删除必逐次人工确认
- **桥鉴权**:Bearer token(自动生成)+ Origin 白名单,只监听本机或内网

## 环境语义说明

仓内 `DVP/QAS/PRD` 键名来自作者环境(开发/测试/生产的德语缩写习惯),是治理体系的**协议键**——部署者按自己环境填 `systems.json` 与 `_sap-conn.ps1` 即可,client 号/实例号/角色语义全部自定义。

## License

MIT
