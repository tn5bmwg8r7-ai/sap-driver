# Start-SapMcp.ps1 - launcher for the SAP MCP stdio server.
#
# Disables Windows console QuickEdit (mouse selection freezes the stdio loop),
# then hands off to node. Node cannot call SetConsoleMode without a native
# addon, so we wrap with PowerShell. Pattern reused from a personal-project
# bridge launcher.
$ErrorActionPreference = 'Stop'

try {
    $k32 = Add-Type -Name 'SapMcpK32' -Namespace 'Win32' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
'@ -PassThru
    $stdIn = $k32::GetStdHandle(-10)   # STD_INPUT_HANDLE
    $curMode = 0
    if ($k32::GetConsoleMode($stdIn, [ref]$curMode)) {
        # clear ENABLE_QUICK_EDIT_MODE(0x0040); set ENABLE_EXTENDED_MODE(0x0080)
        [void]$k32::SetConsoleMode($stdIn, ($curMode -band (-bnot 0x0040)) -bor 0x0080)
    }
} catch { Write-Host "[sap-mcp] skip disable QuickEdit: $($_.Exception.Message)" }

$node   = $env:SAP_MCP_NODE
$server = $env:SAP_MCP_SERVER
if (-not $node -or -not $server) {
    throw "SAP_MCP_NODE / SAP_MCP_SERVER env vars not set. Configure them in .claude.json mcpServers.sap.env."
}
& $node $server
