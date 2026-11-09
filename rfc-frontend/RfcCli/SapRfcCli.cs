// ============================================================
// SapRfcCli.exe - standalone SAP RFC CLI host (no PowerShell)
//
// Purpose: on machines where endpoint security silently filters
// powershell.exe's SAP traffic (TCP ok, RFC payload no answer),
// this tool talks RFC from its own process image instead.
// Also gives a hung RFC call a bounded, self-diagnosing exit
// (VERDICT=SUSPECT_LOCAL_INTERCEPT) instead of blocking forever.
//
// Build (in-box compiler, no admin, no download):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo ^
//     /optimize+ /r:sapnco.dll /out:SapRfcCli.exe SapRfcCli.cs
// Runtime needs: sapnco.dll + sapnco_utils.dll next to the exe.
//
// Usage:
//   SapRfcCli ping  -host H -sysnr NN -client CCC -user U [-lang ZH]
//   SapRfcCli query -host H -sysnr NN -client CCC -user U
//                   -table TAB [-where "F = 'V'"] [-fields A,B,C]
//                   [-maxrows 100] [-timeout 45]
// Password: masked prompt (interactive) or one stdin line when
//   input is redirected. NEVER argv, never written anywhere.
//
// Exit codes: 0 ok | 2 args/credential | 3 logon rejected
//             | 4 rfc error | 9 rfc timeout (suspect intercept)
// Output: ASCII key=value lines on stdout (AI-parse friendly).
// ============================================================

using System;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Threading;
using SAP.Middleware.Connector;

static class SapRfcCli
{
    sealed class DConfig : IDestinationConfiguration
    {
        public RfcConfigParameters Params;
        public event RfcDestinationManager.ConfigurationChangeHandler ConfigurationChanged
        {
            add { }
            remove { }
        }
        public bool ChangeEventsSupported() { return false; }
        public RfcConfigParameters GetParameters(string name) { return Params; }
    }

    static string _mode, _host, _sysnr, _client, _user, _pwd, _lang = "ZH";
    static string _table, _where, _fields, _maxRows = "100";
    static int _timeoutSec = 45;
    static int _exit;

    static int Main(string[] args)
    {
        try
        {
            Parse(args);
        }
        catch (Exception ex)
        {
            return Fail(2, "ARGS", ex.Message, "check command line, see --help");
        }

        var t = new Thread(Run, 8 * 1024 * 1024);
        t.IsBackground = true;
        t.Start();
        if (!t.Join(_timeoutSec * 1000))
        {
            // payload hung: bounded exit with a verdict (thread dies with process)
            Emit("RESULT=TIMEOUT");
            Emit("STAGE=RFC");
            Emit("VERDICT=SUSPECT_LOCAL_INTERCEPT");
            Emit("HINT=TCP was reachable but SAP protocol payload got no answer within "
                + _timeoutSec + "s. Typical cause: local endpoint security silently filtering "
                + "scripting hosts' SAP traffic. Not a wrong password (logon never reached the "
                + "server, no failed-logon counter). Next: try PowerShell ISE route, or report "
                + "to manual author, or fall back to GUI scripting channel.");
            return 9;
        }
        return _exit;
    }

    static void Parse(string[] a)
    {
        if (a.Length == 0 || Array.IndexOf(a, "-h") >= 0 || Array.IndexOf(a, "--help") >= 0)
        {
            Emit("SapRfcCli - standalone SAP RFC CLI (ping / query)");
            Emit("  ping  -host H -sysnr NN -client CCC -user U [-lang ZH] [-timeout 45]");
            Emit("  query -host H -sysnr NN -client CCC -user U -table TAB");
            Emit("        [-where \"F = 'V'\"] [-fields A,B,C] [-maxrows 100]");
            Emit("Password: masked prompt, or one stdin line when redirected. Never argv.");
            if (a.Length == 0) throw new ApplicationException("no mode given");
            throw new ApplicationException("help shown");
        }
        _mode = a[0].ToLowerInvariant();
        if (_mode != "ping" && _mode != "query")
            throw new ApplicationException("mode must be ping or query: " + a[0]);
        for (var i = 1; i < a.Length; i++)
        {
            var k = a[i];
            if (i + 1 >= a.Length && k.StartsWith("-")) throw new ApplicationException("missing value for " + k);
            switch (k)
            {
                case "-host": _host = a[++i]; break;
                case "-sysnr": _sysnr = a[++i]; break;
                case "-client": _client = a[++i]; break;
                case "-user": _user = a[++i]; break;
                case "-lang": _lang = a[++i]; break;
                case "-table": _table = a[++i]; break;
                case "-where": _where = a[++i]; break;
                case "-fields": _fields = a[++i]; break;
                case "-maxrows": _maxRows = a[++i]; break;
                case "-timeout": _timeoutSec = int.Parse(a[++i]); break;
                default: throw new ApplicationException("unknown arg: " + k);
            }
        }
        if (string.IsNullOrEmpty(_host)) throw new ApplicationException("-host required");
        if (string.IsNullOrEmpty(_sysnr)) throw new ApplicationException("-sysnr required");
        if (string.IsNullOrEmpty(_client)) throw new ApplicationException("-client required");
        if (string.IsNullOrEmpty(_user)) throw new ApplicationException("-user required");
        if (_mode == "query" && string.IsNullOrEmpty(_table))
            throw new ApplicationException("-table required for query");
    }

    static void Run()
    {
        try
        {
            // ---- stage 1: TCP pre-check (5s) - no password needed for diagnosis ----
            var port = 3200 + int.Parse(_sysnr);
            try
            {
                using (var c = new TcpClient())
                {
                    var ar = c.BeginConnect(_host, port, null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(5000) || !c.Connected)
                    {
                        Fail(4, "TCP", "cannot connect " + _host + ":" + port + " within 5s",
                            "check intranet/VPN; port open but RFC hangs later is a different case");
                        return;
                    }
                }
            }
            catch (Exception ex)
            {
                Fail(4, "TCP", "connect " + _host + ":" + port + " failed: " + ex.Message,
                    "server down or network blocked; GUI test decides who to call (Basis or network team)");
                return;
            }
            Emit("STAGE=TCP STATUS=OK PORT=" + port);

            // ---- stage 2: resolve password (never argv, never persisted) ----
            if (string.IsNullOrEmpty(_pwd))
            {
                if (!Console.IsInputRedirected)
                {
                    _pwd = ReadMasked();
                }
                else
                {
                    var line = Console.ReadLine();
                    _pwd = line == null ? "" : line.TrimEnd('\r', '\n');
                }
            }
            if (string.IsNullOrEmpty(_pwd))
            {
                Fail(2, "CREDENTIAL", "password required",
                    "run in an interactive console for masked input, or pipe one line via stdin");
                return;
            }

            // ---- stage 3: load NCo from exe folder ----
            var here = PathOf(Assembly.GetExecutingAssembly().Location);
            Assembly.LoadFrom(PathCombine(here, "sapnco.dll"));
            Assembly.LoadFrom(PathCombine(here, "sapnco_utils.dll"));

            // ---- stage 4: register destination + ping (logon happens here) ----
            var p = new RfcConfigParameters();
            p.Add(RfcConfigParameters.Name, "CLICLI");
            p.Add(RfcConfigParameters.AppServerHost, _host);
            p.Add(RfcConfigParameters.SystemNumber, _sysnr);
            p.Add(RfcConfigParameters.Client, _client);
            p.Add(RfcConfigParameters.User, _user);
            p.Add(RfcConfigParameters.Password, _pwd);
            p.Add(RfcConfigParameters.Language, _lang);
            p.Add(RfcConfigParameters.PoolSize, "1");
            var cfg = new DConfig { Params = p };
            RfcDestinationManager.RegisterDestinationConfiguration(cfg);
            var dest = RfcDestinationManager.GetDestination("CLICLI");
            try
            {
                dest.Ping();
            }
            catch (Exception ex)
            {
                var inner = ex.InnerException;
                if (inner is RfcLogonException)
                {
                    Fail(3, "LOGON", "rejected by server (" + _host + " client=" + _client + " user=" + _user + ")",
                        "wrong password / locked / expired. Do NOT spam retries (each feeds the fail counter); verify in SAP GUI first");
                    return;
                }
                var msg = inner == null ? ex.Message : "[" + inner.GetType().Name + "] " + inner.Message;
                Fail(4, "RFC", Clean(msg), "see manual section 9/10");
                return;
            }
            Emit("STAGE=LOGON STATUS=OK USER=" + _user + " CLIENT=" + _client);

            // ---- stage 5: payload ----
            var repo = dest.Repository;
            if (_mode == "ping")
            {
                var fn = repo.CreateFunction("STFC_CONNECTION");
                fn.SetValue("REQUTEXT", "ping");
                fn.Invoke(dest);
                Emit("ECHOTEXT=" + fn.GetString("ECHOTEXT"));
                Emit("RESULT=OK");
                _exit = 0;
                return;
            }

            var q = repo.CreateFunction("RFC_READ_TABLE");
            q.SetValue("QUERY_TABLE", _table);
            q.SetValue("DELIMITER", "|");
            q.SetValue("ROWCOUNT", _maxRows);
            q.SetValue("ROWSKIPS", "0");
            if (!string.IsNullOrEmpty(_where))
            {
                var opt = q.GetTable("OPTIONS");
                opt.Append();
                opt.SetValue("TEXT", _where);
            }
            var flds = q.GetTable("FIELDS");
            if (string.IsNullOrEmpty(_fields))
            {
                var probe = q.GetTable("FIELDS");
                probe.Append();
                probe.SetValue("FIELDNAME", "*");
            }
            else
            {
                foreach (var f in _fields.Split(','))
                {
                    var fname = f.Trim();
                    if (fname.Length == 0) continue;
                    flds.Append();
                    flds.SetValue("FIELDNAME", fname);
                }
            }
            q.Invoke(dest);
            int n = 0;
            try { n = q.GetInt("ROWCOUNT"); } catch { }
            Emit("ROWCOUNT=" + n);
            Emit("NOTE=WA may truncate at 512 chars (standard RFC_READ_TABLE limit)");
            foreach (var r in q.GetTable("DATA")) Emit("ROW=" + r.GetString("WA"));
            Emit("RESULT=OK");
            _exit = 0;
        }
        catch (Exception ex)
        {
            Fail(4, "INTERNAL", Clean(ex.ToString()), "unexpected; report to manual author with full output");
        }
    }

    static string ReadMasked()
    {
        Console.Write("SAP password (masked input): ");
        var sb = new StringBuilder();
        while (true)
        {
            var k = Console.ReadKey(true);
            if (k.Key == ConsoleKey.Enter) { Console.WriteLine(); break; }
            if (k.Key == ConsoleKey.Backspace)
            {
                if (sb.Length > 0) { sb.Length--; Console.Write("\b \b"); }
            }
            else if (!char.IsControl(k.KeyChar)) sb.Append(k.KeyChar);
        }
        return sb.ToString();
    }

    static string Clean(string s) { return s == null ? "" : s.Replace('\0', ' '); }
    static string PathOf(string full) { var i = full.LastIndexOf('\\'); return i < 0 ? "." : full.Substring(0, i); }
    static string PathCombine(string a, string b) { return a.EndsWith("\\") ? a + b : a + "\\" + b; }
    static void Emit(string s) { Console.WriteLine(s); }
    static int Fail(int code, string stage, string error, string hint)
    {
        Emit("RESULT=FAIL");
        Emit("STAGE=" + stage);
        Emit("ERROR=" + error);
        Emit("HINT=" + hint);
        _exit = code;
        return code;
    }
}
