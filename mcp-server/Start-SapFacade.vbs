' Start-SapFacade.vbs - hidden launcher for sap-mcp http-facade (SW_HIDE, no console window).
' Pattern: wscript wrapper (pure ASCII, CRLF) - avoids the console flash / QuickEdit
' freeze of a visible node.exe window when spawned via WMI Win32_Process.Create.
' Config (port/token) is read by http-facade.js from facade.local.json next to it.
Option Explicit
Dim sh, fso, here, nodeExe, facadeJs, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
' node 路径:优先取环境变量 SAP_MCP_NODE,否则回退 PATH 里的 node.exe
nodeExe = sh.Environment("PROCESS")("SAP_MCP_NODE")
If nodeExe = "" Then nodeExe = "node.exe"
facadeJs = fso.BuildPath(here, "src\http-facade.js")
If InStr(nodeExe, "\") > 0 And Not fso.FileExists(nodeExe) Then
  MsgBox "node.exe not found: " & nodeExe, 16, "Start-SapFacade"
  WScript.Quit 1
End If
If Not fso.FileExists(nodeExe) Then
  MsgBox "node.exe not found: " & nodeExe, 16, "Start-SapFacade"
  WScript.Quit 1
End If
cmd = """" & nodeExe & """ """ & facadeJs & """"
sh.Run cmd, 0, False
