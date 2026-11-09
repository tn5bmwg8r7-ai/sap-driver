#!/bin/bash
# facade smoke test (P1) — start, health, tools, auth-neg, allowlist-neg, shutdown
NODE="${SAP_MCP_NODE:-node}"
ROOT=/d/Claude/Project/sap-mcp
TOKEN=$(grep -o '"[a-f0-9]\{64\}"' "$ROOT/facade.local.json" | tr -d '"')
[ -z "$TOKEN" ] && { echo "NO TOKEN"; exit 1; }

sed -i 's/\r*$/\r/' "$ROOT/Start-SapFacade.vbs"
file "$ROOT/Start-SapFacade.vbs"

cd "$ROOT" && "$NODE" src/http-facade.js > /tmp/facade-test.log 2>&1 &
FACADE_PID=$!
sleep 2

echo "---HEALTH---"
curl -s -m 5 http://127.0.0.1:8439/health -H "Authorization: Bearer $TOKEN" | head -c 500; echo
echo "---TOOLS---"
curl -s -m 5 http://127.0.0.1:8439/tools -H "Authorization: Bearer $TOKEN" > /tmp/tools.json
"$NODE" -e "const j=require('/tmp/tools.json');console.log('tools:',j.tools.length);const q=j.tools.find(t=>t.name==='sap_query');console.log('sap_query params:',q.params.map(p=>p.name).join(','))"
echo "---AUTH-NEG(expect 401)---"
curl -s -m 5 -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8439/health -H "Authorization: Bearer wrong"
echo "---DEVWRITE-NEG(expect TOOL_NOT_EXPOSED)---"
curl -s -m 5 -X POST http://127.0.0.1:8439/run/sap_dev_tr -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d '{"args":{"system":"DVP"}}' | head -c 200; echo
echo "---BADTOOL-NEG(expect UNKNOWN_TOOL)---"
curl -s -m 5 -X POST http://127.0.0.1:8439/run/sap_nope -H "Authorization: Bearer $TOKEN" -d '{}' | head -c 150; echo
echo "---SHUTDOWN---"
curl -s -m 5 -X POST http://127.0.0.1:8439/shutdown -H "Authorization: Bearer $TOKEN"; echo
sleep 1
if netstat -ano | grep -q ":8439"; then echo "PORT STILL UP (kill test proc)"; kill -9 $FACADE_PID 2>/dev/null; else echo "PORT CLEAN"; fi
echo "---FACADE LOG---"; cat /tmp/facade-test.log
