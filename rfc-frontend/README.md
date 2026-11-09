# rfc-frontend — SAP NCo 3.1 RFC 前端

PowerShell / C# 直连 SAP RFC 的前端层,SAP Driver 的底层传输通道。不经过 SAP GUI 脚本桥,直调 RFC 函数模块(结构化数据、快、可批量)。

## 文件

| 文件 | 用途 |
|---|---|
| `Invoke-SapRfc.ps1` | PowerShell RFC 前端(262 行)。编译一次性 DConfig,`Invoke-SapRfc -Destination QAS -Function XXX` 直调 |
| `RfcCli/SapRfcCli.cs` | C# 命令行 RFC 客户端源码。带两段式诊断(TCP 预检 5s → 凭证解析),密码永不进 argv |

## 前置:NCo 3.1 安装(必读)

**SAP NCo(NetWeaver RFC Library)DLL 受 SAP 版权保护,本仓不分发,需自行下载:**

1. 从 SAP Support Portal(support.sap.com)下载 **SAP NetWeaver RFC SDK / NCo 3.1**(x64 版,搜 "NCO 3.1" 或 Note 2516885)。需要 S-user 账号。
2. 两个 DLL:`sapnco.dll`、`sapnco_utils.dll`
3. **GAC 注册**(管理员 PowerShell):
   ```powershell
   # 把 DLL 放到任意目录后,注册进全局程序集缓存(x64)
   [System.Reflection.Assembly]::Load("sapnco, Version=3.1.0.42, Culture=neutral, PublicKeyToken=<见DLL属性>")  # 或用 gacutil:
   gacutil /i sapnco.dll
   gacutil /i sapnco_utils.dll
   ```
   无 gacutil 时可用 `Add-Type -Path` 或把 DLL 目录加入进程探测路径(`Invoke-SapRfc.ps1` 默认走 GAC)。
4. 验证:
   ```powershell
   . .\Invoke-SapRfc.ps1
   $r = Invoke-SapRfc -Destination QAS -Function STFC_CONNECTION -Import @{ REQUTEXT = "ping" } `
        -AppServerHost <你的SAP服务器> -SystemNumber 00 -Client <客户端号> `
        -User <用户名> -Password <密码> -Language ZH
   $r.ECHOTEXT   # 应回显 "ping"
   ```

## 编译 SapRfcCli(可选)

```
csc /target:exe /out:SapRfcCli.exe /r:sapnco.dll /r:sapnco_utils.dll SapRfcCli.cs
```

(csc 来自 .NET Framework,`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`)

## 安全约定

- 密码仅内存参数传递,**绝不落盘、绝不进命令行参数**(tasklist 可见)、绝不进日志
- SapRfcCli 密码从 stdin 掩码输入或环境变量读取,argv 里只出现占位
- 连续登录失败会喂 SAP 失败计数器(逼近锁号)——失败时先在 SAP GUI 验证,勿重试连打
