# ============================================================
# Invoke-SapRfc.ps1  - SAP NCo 3.1 RFC front-end for PowerShell (x64)
# Calls RFC function modules directly (accurate structured data,
# fast, batchable) WITHOUT going through the SAP GUI scripting bridge.
#
# POLICY: read-only diagnostics only (QAS). Never call write BAPIs.
#   Password is taken as an in-memory param and is NEVER persisted.
#
# Requires: sapnco.dll + sapnco_utils.dll registered in GAC_64.
#
# Usage:
#   . .\Invoke-SapRfc.ps1
#   $r = Invoke-SapRfc -Destination QAS -Function STFC_CONNECTION `
#        -Import @{ REQUTEXT = "ping" } `
#        -AppServerHost <你的SAP应用服务器> -SystemNumber 00 -Client 800 `
#        -User <你的SAP用户名> -Password <pw> -Language ZH
#   $r.ECHOTEXT          # exporting scalar
#   $r.DFIES_TAB         # table -> array of pscustomobject (cols = field names)
# ============================================================

# --- load NCo assemblies from GAC (x64 process) ---
if (-not ([System.Management.Automation.PSTypeName]'SAP.Middleware.Connector.RfcDestinationManager').Type) {
    [void][Reflection.Assembly]::LoadWithPartialName('sapnco')
    [void][Reflection.Assembly]::LoadWithPartialName('sapnco_utils')
}

# --- compile a minimal IDestinationConfiguration implementation (once) ---
if (-not ([System.Management.Automation.PSTypeName]'SapRfc.DConfig').Type) {
    $sapncoDll = ([Reflection.Assembly]::LoadWithPartialName('sapnco')).Location
    $cs = @'
using System;
using SAP.Middleware.Connector;

namespace SapRfc {
  public class DConfig : IDestinationConfiguration {
    // Multi-destination support: NCo allows exactly ONE RegisterDestinationConfiguration
    // per process. Bridge routes dot-source this script repeatedly, so parameters are
    // kept per destination NAME in a static table and the config object is registered
    // only once for the whole process life (see the Registered flag).
    public static System.Collections.Concurrent.ConcurrentDictionary<string, RfcConfigParameters> Params =
      new System.Collections.Concurrent.ConcurrentDictionary<string, RfcConfigParameters>();
    public static bool Registered = false;

    // 2026-09-04: GetDestination() 返回的是**首次创建时参数的快照**,之后 Set() 改密码
    // 对已存在的 destination 不生效(除非 ChangeEventsSupported()=true 且在参数变化时
    // 触发 ConfigurationChanged)。2026-11-04 毒化实验修订:CHANGED 事件确实触发、参数
    // 快照确实更新,但**坏密码污染过的连接池不会重建**——同名 destination 之后用正确
    // 密码照样 RfcLogonException;UnregisterDestinationConfiguration 池存活时被拒
    // ("cannot unregister");NCo 3.1 无 DestroyDestination API。
    // => 事件路径留着无害但**不是自愈**;真实自愈 = PS 侧 Invoke-SapRfc 登录失败时
    //    换世代名重试(DVP -> DVP#2,新名 = 新池,绕开毒化)。
    private static RfcDestinationManager.ConfigurationChangeHandler _onChange;

    public static void Set(string name, string host, string sysNr, string client,
                           string user, string pass, string lang) {
      var p = new RfcConfigParameters();
      p.Add(RfcConfigParameters.Name,            name);
      p.Add(RfcConfigParameters.AppServerHost,   host);
      p.Add(RfcConfigParameters.SystemNumber,    sysNr);
      p.Add(RfcConfigParameters.Client,          client);
      p.Add(RfcConfigParameters.User,            user);
      p.Add(RfcConfigParameters.Password,        pass);
      p.Add(RfcConfigParameters.Language,        lang);
      p.Add(RfcConfigParameters.PoolSize,        "3");
      RfcConfigParameters old;
      bool existed = Params.TryGetValue(name, out old);
      Params[name] = p;
      if (existed && _onChange != null && !ParamsEqual(old, p)) {
        _onChange(name, new RfcConfigurationEventArgs(RfcConfigParameters.EventType.CHANGED));
      }
    }

    private static bool ParamsEqual(RfcConfigParameters a, RfcConfigParameters b) {
      foreach (string k in b.Keys) {
        string av; a.TryGetValue(k, out av);
        if (!string.Equals(av, b[k], StringComparison.Ordinal)) return false;
      }
      return true;
    }

    public RfcConfigParameters GetParameters(string name) {
      RfcConfigParameters p;
      return Params.TryGetValue(name, out p) ? p : null;
    }
    public bool ChangeEventsSupported() { return true; }
    public event RfcDestinationManager.ConfigurationChangeHandler ConfigurationChanged
    {
      add    { _onChange = (RfcDestinationManager.ConfigurationChangeHandler)Delegate.Combine(_onChange, value); }
      remove { _onChange = (RfcDestinationManager.ConfigurationChangeHandler)Delegate.Remove(_onChange, value); }
    }
  }
}
'@
    Add-Type -TypeDefinition $cs -ReferencedAssemblies @($sapncoDll)
}

function Invoke-SapRfc {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $Destination,
        [Parameter(Mandatory)] [string]   $Function,
        [hashtable] $Import,
        [hashtable] $Tables,
        # connection params (used the FIRST time a destination is registered)
        [string] $AppServerHost,
        [string] $SystemNumber,
        [string] $Client,
        [string] $User,
        [string] $Password,
        [string] $Language = 'ZH'
    )

    # password policy: NEVER persisted. Prompt interactively only when not
    # supplied AND we are in a real interactive console; otherwise hard-fail
    # (never block a non-interactive host).
    if ([string]::IsNullOrWhiteSpace($Password)) {
        if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
            $sec = Read-Host -Prompt "RFC 密码 (用户 $User @ $AppServerHost)" -AsSecureString
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        } else {
            throw 'RFC 需要密码：请在 -Password 传入，或在交互式 PowerShell 中运行以弹出掩码输入。密码不会被保存。'
        }
    }

    # Update the per-destination parameter table (idempotent), then make sure the
    # single process-wide config is registered exactly once. Re-registering would
    # throw "destination configuration already initialized" (bridge re-runs).
    # 2026-11-04 毒化自愈:同一 destination 名在进程内被坏密码打过一次 RfcLogonException
    # 后,其连接池被服务器侧会话缓存污染,同名+正确密码照样被拒(实测 CHANGED 事件/
    # Unregister/Destroy 全无效)——唯一进程内自愈 = 换世代名(DVP -> DVP#2,新名新池)。
    # 失败世代表按「host|sysnr|client|user」记录,lastGen 记该连接已用到的最大世代。
    $connKey = "$AppServerHost|$SystemNumber|$Client|$User"
    if (-not [string]::IsNullOrWhiteSpace($AppServerHost)) {
        $script:_sapRfcLogonFailGen = $(if ($script:_sapRfcLogonFailGen) { $script:_sapRfcLogonFailGen } else { @{} })
        $gen = 0
        if ($script:_sapRfcLogonFailGen.ContainsKey($connKey)) { $gen = [int]$script:_sapRfcLogonFailGen[$connKey] }
        $effDest = if ($gen -gt 0) { "$Destination#$gen" } else { $Destination }
        [SapRfc.DConfig]::Set($effDest, $AppServerHost, $SystemNumber, $Client,
                              $User, $Password, $Language)
    } else {
        $effDest = $Destination
        $script:_sapRfcLogonFailGen = $(if ($script:_sapRfcLogonFailGen) { $script:_sapRfcLogonFailGen } else { @{} })
    }
    if (-not [SapRfc.DConfig]::Registered) {
        $cfg = New-Object SapRfc.DConfig
        [void][SAP.Middleware.Connector.RfcDestinationManager]::RegisterDestinationConfiguration($cfg)
        [SapRfc.DConfig]::Registered = $true
    }

    $dest = [SAP.Middleware.Connector.RfcDestinationManager]::GetDestination($effDest)
    if (-not $dest) {
        throw "RFC 目标 '$effDest' 未注册(内部错误:destination 参数未生效,请检查 -AppServerHost/-SystemNumber/-Client)"
    }
    # Ping() 才会真正建连登录——NCo 的真实失败原因(密码错/账号锁定/密码过期/网络)只在
    # 这里抛;不 Ping 直接取 Repository,登录失败只会静默返回 null,报错变成
    # "无法初始化元数据库"这种看不出原因的话(2026-09-04 用户反复撞墙,密码到底对不对
    # 都无从判断)。Ping 后 Repository 仍为 null 则是元数据层问题,另行报错。
    try {
        $dest.Ping()
    } catch {
        # 09-09 加固:MethodInvocationException 的 Message 只有 PS 包装话术,某次只剩".,"
        # 完全看不出真因(密码错/账号锁定/密码到期/网络)——把内层异常类型+消息完整透出
        # 09-10 增强:RfcLogonException 的服务器原文经 NCo codepage 转换后中文全变 NUL 字节
        # (sap-test-report ZREP001 四连败实证:消息逐字节恒为 7 个 NUL+空格+句点,零可读
        # 信息,排障只能靠字节对比反推)。故 RfcLogonException 单列:按拒绝原因给结构化
        # 人话;其余异常保留原透出路径,但一律清掉 NUL。
        # 2026-11-04 毒化自愈:RfcLogonException 时把本连接世代 +1,下次调用自动换新名
        # (DVP#1/DVP#2…)——新 destination = 新连接池,绕开坏密码留下的毒化池。同一进程内
        # 同名 destination 无任何 API 可重建池(11-04 实验三连败实锤),这是唯一通路。
        $inner = $_.Exception.InnerException
        if ($inner -is [SAP.Middleware.Connector.RfcLogonException]) {
            if ($script:_sapRfcLogonFailGen.ContainsKey($connKey)) {
                $script:_sapRfcLogonFailGen[$connKey] = [int]$script:_sapRfcLogonFailGen[$connKey] + 1
            } else {
                $script:_sapRfcLogonFailGen[$connKey] = 1
            }
            $newGen = [int]$script:_sapRfcLogonFailGen[$connKey]
            throw "RFC 登录被服务器拒绝($AppServerHost client=$Client user=$User)。服务器返回文本乱码不可读(NCo codepage 转换缺陷),按概率排查:①密码值不对(最常见——以 GUI 当前能登录的密码为准,在表单里重新完整输入,勿用历史/记忆值)②账号被锁(连续失败 3-5 次即触发,勿反复重试,管理员 SU01 解锁)③密码已过期(GUI 登录会弹改密框,RFC 不弹直接拒)。本进程内 destination『$Destination』已毒化,下次调用自动换『$Destination#$newGen』新池重试;若新密码正确仍报错,大概率是账号已被锁(SU01 解锁)。注意:每次失败都喂 SAP 失败计数,接近锁号阈值时先去 GUI 验证密码再回来。"
        }
        $why = if ($inner) { "[$($inner.GetType().Name)] " + (([string]$inner.Message) -replace '\x00', '') } else { ([string]$_.Exception.Message) -replace '\x00', '' }
        throw "RFC 登录失败($AppServerHost client=$Client user=$User):$why"
    }
    $repo = $dest.Repository
    if (-not $repo) {
        throw "RFC 连接/登录失败($AppServerHost client=$Client user=$User):无法初始化元数据库。请核对密码是否正确、账号是否被锁、系统是否可达。"
    }
    $fn   = $repo.CreateFunction($Function)

    # importing scalars + structures (NCo parses string -> declared type).
    # A hashtable value => STRUCTURE parameter: get IRfcStructure, set each field.
    # (Backward compatible: scalars still flow through the original SetValue path,
    #  so existing read-only callers that only pass string imports are unaffected.)
    if ($Import) {
        foreach ($k in $Import.Keys) {
            $val = $Import[$k]
            if ($val -is [hashtable]) {
                $struc = $fn.GetStructure($k)
                foreach ($col in $val.Keys) { $struc.SetValue($col, [string]$val[$col]) }
            } else {
                $fn.SetValue($k, [string]$val)
            }
        }
    }
    # importing tables (array of hashtables -> rows)
    # NCo 3.1 RfcTable: only Append()/Insert()/Clear() - NO AppendRow/AddRow/CurrentRow.
    # Append() (no-arg) appends an empty row + moves cursor; then SetValue() on the table itself.
    if ($Tables) {
        foreach ($tname in $Tables.Keys) {
            $tbl = $fn.GetTable($tname)
            foreach ($row in @($Tables[$tname])) {
                $tbl.Append()
                # tolerate fields the runtime table metadata doesn't expose
                # (e.g. RSIMP.OPTIONAL/REFERENCE exist in DDIC but not in the
                #  runtime parameter row view) — skip silently, core fields win.
                foreach ($col in $row.Keys) {
                    try { $tbl.SetValue($col, [string]$row[$col]) } catch { }
                }
            }
        }
    }

    $fn.Invoke($dest)

    # build a structured PS object: tables -> arrays of objects, scalars -> strings.
    # NCo 3.1 RfcFunctionMetadata exposes ParameterCount + Item[i]; param .Name is a FIELD.
    $out  = [ordered]@{}
    $meta = $fn.Metadata
    for ($i = 0; $i -lt $meta.ParameterCount; $i++) {
        $p   = $meta[$i]
        $nm  = $p.Name
        $dir = [string]$p.Direction              # IMPORT / EXPORT / CHANGING / TABLES / EXCEPTION
        if ($dir -eq 'IMPORT' -or $dir -eq 'EXCEPTION') { continue }
        if ($p.DataType -eq [SAP.Middleware.Connector.RfcDataType]::TABLE) {
            $t    = $fn.GetTable($nm)
            $rows = @()
            foreach ($r in $t) {
                $o = [ordered]@{}
                for ($j = 0; $j -lt $r.Metadata.FieldCount; $j++) {
                    $cn     = $r.Metadata[$j].Name
                    $o[$cn] = $r.GetString($cn)
                }
                $rows += ,([pscustomobject]$o)
            }
            $out[$nm] = $rows
        }
        elseif ($p.DataType -eq [SAP.Middleware.Connector.RfcDataType]::STRUCTURE) {
            $s = $fn.GetStructure($nm)
            $o = [ordered]@{}
            for ($j = 0; $j -lt $s.Metadata.FieldCount; $j++) {
                $cn     = $s.Metadata[$j].Name
                $o[$cn] = $s.GetString($cn)
            }
            $out[$nm] = [pscustomobject]$o
        }
        else {
            $out[$nm] = $fn.GetString($nm)
        }
    }
    return [pscustomobject]$out
}
