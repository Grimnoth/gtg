#!/bin/bash
# HTTP face for gtg. Scratch dirs only: this must never see the live log,
# the live plan, or a model.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD

TMP=$(mktemp -d)
SRV_PID=""
# run.sh fingerprints the live files and then points HOME at a scratch dir
# before it calls this script, so $HOME here is not the real one. The passwd
# entry is. This check is the whole window in which the server runs.
REAL_HOME=$(/usr/bin/python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
LIVE="$TMP/live-before"
for f in "$REAL_HOME/.local/state/gtg/log.tsv" \
         "$REAL_HOME/.local/state/gtg/history.html" \
         "$REAL_HOME/.local/state/gtg/last-nudge" \
         "$REAL_HOME/.config/gtg/plan.txt" \
         "$REAL_HOME/.config/gtg/token" \
         "$REAL_HOME/.config/gtg/gcal-key.json" \
         "$REAL_HOME/.local/state/gtg/gcal-token.json" \
         "$REAL_HOME/.config/gtg/oura-client.json" \
         "$REAL_HOME/.config/gtg/oura-tokens.json" \
         "$REAL_HOME/.local/state/gtg/oura-energy.json"; do
  printf '%s\t%s\n' "$f" "$(md5 -q "$f" 2>/dev/null || echo ABSENT)" >>"$LIVE"
done
OURA_STUB_PID=""
cleanup() {
  if [ -n "${OURA_STUB_PID:-}" ]; then
    kill "$OURA_STUB_PID" 2>/dev/null || true
    wait "$OURA_STUB_PID" 2>/dev/null || true
  fi
  if [ -n "${SRV_PID:-}" ]; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n         got  [%s]\n         want [%s]\n' "$1" "$2" "$3"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

# $1 name, $2 file, $3 python expression over the parsed JSON object d
json_ok() {
  local result
  result=$(/usr/bin/python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print("yes" if eval(sys.argv[2]) else "no")
' "$2" "$3" 2>&1) || result="error: $result"
  is "$1" "$result" "yes"
}

rows() { wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' '; }

# A process that exits on purpose still has to say why. Port 9 is a trap:
# binding there would also fail, so the assertion is the message, not the rc.
refuse() {
  local name="$1" conf="$2"
  GTG_CONF_DIR="$conf" GTG_STATE_DIR="$TMP/refuse-state" GTG_PORT=9 \
    GTG_NO_CALENDAR=1 \
    /usr/bin/python3 "$REPO/bin/gtg-server" >"$TMP/refuse.out" 2>"$TMP/refuse.err" &
  local pid=$! i=0
  # Polled, not a fixed 0.3s: on a loaded machine Python can take longer than
  # that just to start, and the check failed with nothing wrong.
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    bad "$name" "still running" "exited"
    return
  fi
  wait "$pid" || true
  if grep -q 'missing or empty' "$TMP/refuse.err"; then
    ok "$name"
  else
    bad "$name" "$(cat "$TMP/refuse.err")" "a missing-or-empty token message"
  fi
}

echo "== gtg-server =="

mkdir -p "$TMP/empty-conf" "$TMP/refuse-state"
: >"$TMP/empty-conf/token"
refuse "empty token refuses to start" "$TMP/empty-conf"

mkdir -p "$TMP/missing-conf"
refuse "missing token refuses to start" "$TMP/missing-conf"

export GTG_CONF_DIR="$TMP/conf" GTG_STATE_DIR="$TMP/state"
export GTG_NO_CALENDAR=1 GTG_NO_PAGE=1
# No INTERPRET=off and no GTG_INTERPRET_CMD. The parent suite sets that
# command to /usr/bin/true; leave it on and this test cannot tell whether
# the server suppressed the model itself. The stub is what `claude` resolves
# to if a log still asks. It prints nothing, so a leak fails open and is
# counted, and it is never the real client.
unset GTG_INTERPRET_CMD
mkdir -p "$TMP/bin" "$GTG_CONF_DIR" "$GTG_STATE_DIR"
cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
printf 'called\n' >>"$GTG_STUB_LOG"
EOF
chmod +x "$TMP/bin/claude"
: >"$TMP/stub-log"
export GTG_STUB_LOG="$TMP/stub-log"
export PATH="$TMP/bin:$PATH"
cat >"$GTG_CONF_DIR/plan.txt" <<'P'
WAKE_START=9
WAKE_END=21
every: pull-ups x5 | push-ups x20 | dead hang 30s
away: pull-ups x5 | push-ups x20 | dead hang 30s
P
: >"$GTG_STATE_DIR/log.tsv"
printf '%s\n' 'test-token' >"$GTG_CONF_DIR/token"

cat >"$TMP/oura-stub.py" <<'OURASTUB'
#!/usr/bin/python3
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

PORT_FILE = os.environ["GTG_OURA_STUB_PORT"]
DAY = os.environ.get("GTG_OURA_STUB_DAY", "2026-10-05")


class H(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _read(self):
        n = int(self.headers.get("Content-Length") or "0")
        return self.rfile.read(n) if n else b""

    def _json(self, status, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._read().decode("utf-8")
        form = parse_qs(body)
        if path != "/oauth/token":
            self._json(404, {"error": "not found"})
            return
        grant = (form.get("grant_type") or [""])[0]
        if grant == "authorization_code":
            if (form.get("code") or [""])[0] != "good-code":
                self._json(400, {"error": "invalid_grant"})
                return
            if (form.get("code_verifier") or [""])[0] == "":
                self._json(400, {"error": "missing_verifier"})
                return
            self._json(200, {
                "token_type": "bearer",
                "access_token": "access-1",
                "refresh_token": "refresh-1",
                "expires_in": 3600,
                "scope": "daily",
            })
            return
        if grant == "refresh_token":
            if (form.get("refresh_token") or [""])[0] not in ("refresh-1", "refresh-2"):
                self._json(400, {"error": "invalid_grant"})
                return
            self._json(200, {
                "token_type": "bearer",
                "access_token": "access-2",
                "refresh_token": "refresh-2",
                "expires_in": 7200,
                "scope": "daily",
            })
            return
        self._json(400, {"error": "bad_grant"})

    def do_GET(self):
        path = urlparse(self.path).path
        auth = self.headers.get("Authorization") or ""
        if not auth.startswith("Bearer "):
            self._json(401, {"error": "unauthorized"})
            return
        token = auth.split(" ", 1)[1]
        if token not in ("access-1", "access-2"):
            self._json(401, {"error": "unauthorized"})
            return
        qs = parse_qs(urlparse(self.path).query)
        day = (qs.get("start_date") or [DAY])[0]
        if path == "/v2/usercollection/daily_readiness":
            self._json(200, {"data": [{
                "id": "r1", "day": day, "score": 88,
                "contributors": {"previous_night": 90, "sleep_balance": 80},
                "timestamp": day + "T08:00:00-04:00",
            }]})
            return
        if path == "/v2/usercollection/daily_sleep":
            self._json(200, {"data": [{
                "id": "s1", "day": day, "score": 82,
                "contributors": {"efficiency": 91, "total_sleep": 85},
                "timestamp": day + "T08:00:00-04:00",
            }]})
            return
        if path == "/v2/usercollection/daily_activity":
            self._json(200, {"data": [{
                "id": "a1", "day": day, "score": 75,
                "timestamp": day + "T08:00:00-04:00",
            }]})
            return
        if path == "/v2/usercollection/sleep":
            self._json(200, {"data": [{
                "id": "p1", "day": day,
                "total_sleep_duration": 25200,
                "efficiency": 92,
            }]})
            return
        if path == "/v2/usercollection/rest_mode_period":
            self._json(200, {"data": []})
            return
        self._json(404, {"error": "not found"})


httpd = HTTPServer(("127.0.0.1", 0), H)
with open(PORT_FILE, "w", encoding="utf-8") as fh:
    fh.write(str(httpd.server_address[1]))
httpd.serve_forever()
OURASTUB

export GTG_OURA_STUB_PORT="$TMP/oura-stub.port"
export GTG_OURA_STUB_DAY="$(/usr/bin/python3 -c 'from datetime import datetime; from zoneinfo import ZoneInfo; print(datetime.now(ZoneInfo("America/New_York")).date().isoformat())')"
/usr/bin/python3 "$TMP/oura-stub.py" >/dev/null 2>&1 &
OURA_STUB_PID=$!
i=0
while [ "$i" -lt 50 ] && [ ! -s "$GTG_OURA_STUB_PORT" ]; do sleep 0.1; i=$((i+1)); done
OURA_PORT=$(cat "$GTG_OURA_STUB_PORT")
export GTG_OURA_API="http://127.0.0.1:$OURA_PORT"
export GTG_OURA_AUTH="http://127.0.0.1:$OURA_PORT"

PORT=$(/usr/bin/python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
export GTG_PORT="$PORT"
/usr/bin/python3 "$REPO/bin/gtg-server" >"$TMP/server.out" 2>"$TMP/server.err" &
SRV_PID=$!

BASE="http://127.0.0.1:$PORT"
AUTH=( -H "Authorization: Bearer test-token" )
ready=0
i=0
while [ "$i" -lt 50 ]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/" || true)
  if [ -n "$code" ] && [ "$code" != "000" ]; then ready=1; break; fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then break; fi
  i=$((i + 1))
  sleep 0.2
done
if [ "$ready" != 1 ]; then
  echo "server did not start on $PORT" >&2
  cat "$TMP/server.err" >&2
  exit 1
fi

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/api/log" -H 'Content-Type: application/json' \
  -d '{"text":"pull-ups x5"}')
is "missing token is 401" "$code" "401"
is "  and it logged nothing" "$(rows)" "0"

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/api/log" -H 'Authorization: Bearer nope' \
  -H 'Content-Type: application/json' -d '{"text":"pull-ups x5"}')
is "wrong token is 401" "$code" "401"
is "  and it logged nothing" "$(rows)" "0"

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/gtg/mcp" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
is "mcp without a token is 401" "$code" "401"

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/api/log" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"text":"pull-ups x5"}')
is "known movement is 200" "$code" "200"
json_ok "  body ok and names the set" "$TMP/body" 'd["ok"] is True and "pull-ups" in d["output"]'
is "  one new row" "$(rows)" "1"
is "  movement column" "$(cut -f2 "$GTG_STATE_DIR/log.tsv")" "pull-ups"
is "  reps column" "$(cut -f3 "$GTG_STATE_DIR/log.tsv")" "5"

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/gtg/api/log" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"text":"sled push x5"}')
is "unknown movement is 422" "$code" "422"
json_ok "  refused, and the known list names pull-ups" "$TMP/body" \
  'd["ok"] is False and "unknown movement" in (d["error"] or "") and "pull-ups" in (d.get("known") or "")'
is "  no row added" "$(rows)" "1"
is "  and no model was asked" "$(wc -l <"$TMP/stub-log" | tr -d ' ')" "0"

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/gtg/api/summary?period=today")
is "summary today is 200" "$code" "200"
json_ok "  today mentions the set" "$TMP/body" 'd["ok"] is True and "pull-ups" in d["output"]'

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/mcp" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}')
is "initialize is 200" "$code" "200"
json_ok "  echoes the protocol and names itself gtg" "$TMP/body" \
  'd["result"]["protocolVersion"]=="2025-03-26" and d["result"]["serverInfo"]["name"]=="gtg" and d["result"]["capabilities"]=={"tools":{}}'

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/mcp" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":4,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}')
json_ok "  unknown protocol falls back" "$TMP/body" 'd["result"]["protocolVersion"]=="2025-06-18"'

code=$(curl -s -o "$TMP/nobody" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/mcp" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}')
is "initialized notification is 202" "$code" "202"
is "  and the body is empty" "$(wc -c <"$TMP/nobody" | tr -d ' ')" "0"

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/mcp" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
is "tools/list is 200" "$code" "200"
json_ok "  five tools" "$TMP/body" \
  'sorted(t["name"] for t in d["result"]["tools"])==["get_summary","list_movements","log_sets","pause","resume"]'

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/mcp" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"log_sets","arguments":{"text":"push-ups x20"}}}')
is "tools/call log_sets is 200" "$code" "200"
json_ok "  tool result is the logged set" "$TMP/body" \
  'd["result"]["isError"] is False and "push-ups" in d["result"]["content"][0]["text"]'
is "  and it wrote a row" "$(rows)" "2"
is "  that row is push-ups" "$(cut -f2 "$GTG_STATE_DIR/log.tsv" | tail -1)" "push-ups"

before=$(rows)
code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/api/log" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"text":"sled push x5","new":true}')
is "new=true logs an unknown name" "$code" "200"
is "  one more row" "$(rows)" "$((before + 1))"
is "  named as typed" "$(tail -1 "$GTG_STATE_DIR/log.tsv" | cut -f2)" "sled push"

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/api/off" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{"for":"2h","reason":"sick"}')
is "off is 200" "$code" "200"
code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/summary?period=status")
is "status after off is 200" "$code" "200"
json_ok "  status shows paused" "$TMP/body" '"paused:" in d["output"]'

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/api/on" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d '{}')
is "on is 200" "$code" "200"
json_ok "  on says they are back" "$TMP/body" '"back on" in d["output"]'
code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/summary?period=status")
json_ok "  status no longer paused" "$TMP/body" '"paused:" not in d["output"]'

code=$(curl -s -o "$TMP/page" -w '%{http_code}' --max-time 20 "$BASE/")
is "dashboard is 200" "$code" "200"
if grep -qi '<!doctype html>' "$TMP/page"; then ok "  dashboard is html"; else
  bad "  dashboard is html" "$(head -c 80 "$TMP/page")" "<!doctype html>"
fi

code=$(curl -s -o "$TMP/agent" -w '%{http_code}' --max-time 15 "$BASE/agent.md")
is "agent.md is 200 without a token" "$code" "200"
if grep -qF '<hub>.<tailnet>.ts.net/gtg' "$TMP/agent"; then
  ok "  agent.md names the hub"
else
  bad "  agent.md names the hub" "$(head -c 120 "$TMP/agent")" "the tailnet base url"
fi

if grep -qF '/api/energy' "$TMP/agent" && grep -qi 'Energy' "$TMP/agent"; then
  ok "  agent.md mentions energy"
else
  bad "  agent.md mentions energy" "$(grep -n energy "$TMP/agent" | head -3)" "/api/energy"
fi

# --- Oura energy (stubbed; never hits api.ouraring.com) ---------------------

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/oura/status")
is "oura status without client is 200" "$code" "200"
json_ok "  reports not configured" "$TMP/body" \
  'd["ok"] is True and d["configured"] is False and d["connected"] is False and "oura-client.json" in (d["error"] or "")'

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/energy")
is "energy without client is 200" "$code" "200"
json_ok "  disconnected, no invented scores" "$TMP/body" \
  'd["ok"] is False and d["connected"] is False and d["readiness"]["score"] is None and d["coaching"]["band"]=="unknown" and "oura-client.json" in (d["error"] or "")'


/usr/bin/python3 -c '
import json, os, sys
path = os.path.join(os.environ["GTG_CONF_DIR"], "oura-client.json")
payload = {
  "client_id": "test-client",
  "client_secret": "test-secret",
  "redirect_uri": sys.argv[1] + "/oura/callback",
}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, json.dumps(payload).encode())
os.close(fd)
' "$BASE"

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/oura/status")
is "oura status with client, no tokens is 200" "$code" "200"
json_ok "  configured but not connected" "$TMP/body" \
  'd["ok"] is True and d["configured"] is True and d["connected"] is False and "authorize" in (d["error"] or "")'

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/energy")
is "energy not connected is 200" "$code" "200"
json_ok "  asks Ben to connect, scores null" "$TMP/body" \
  'd["ok"] is False and d["connected"] is False and d["readiness"]["score"] is None and "authorize" in (d["error"] or "")'

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/oura/authorize")
is "authorize is 200" "$code" "200"
json_ok "  authorize_url has client and daily scope" "$TMP/body" \
  'd["ok"] is True and "client_id=test-client" in d["authorize_url"] and "scope=daily" in d["authorize_url"] and "code_challenge=" in d["authorize_url"]'
AUTH_URL=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["authorize_url"])' "$TMP/body")
STATE=$(/usr/bin/python3 -c 'from urllib.parse import urlparse, parse_qs; import sys; print(parse_qs(urlparse(sys.argv[1]).query)["state"][0])' "$AUTH_URL")

code=$(curl -s -o "$TMP/cb" -w '%{http_code}' --max-time 15 \
  "$BASE/oura/callback?code=good-code&state=$STATE&scope=daily")
is "callback without bearer is 200" "$code" "200"
if grep -q 'Oura connected' "$TMP/cb"; then ok "  callback html says connected"; else
  bad "  callback html says connected" "$(head -c 200 "$TMP/cb")" "Oura connected"
fi
if grep -Eiq 'access-1|refresh-1|test-secret' "$TMP/cb"; then
  bad "  callback leaked secrets" "$(cat "$TMP/cb")" "no tokens"
else
  ok "  callback did not leak tokens"
fi
is "  tokens file mode 600" "$(stat -f '%Lp' "$GTG_CONF_DIR/oura-tokens.json")" "600"

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/oura/status")
json_ok "status connected after callback" "$TMP/body" \
  'd["ok"] is True and d["connected"] is True and "daily" in d["scopes"]'

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/energy")
is "energy connected is 200" "$code" "200"
json_ok "  high band from readiness 88" "$TMP/body" \
  'd["ok"] is True and d["connected"] is True and d["readiness"]["score"]==88 and d["sleep"]["score"]==82 and d["sleep"]["total_sleep_hours"]==7.0 and d["activity"]["score"]==75 and d["coaching"]["band"]=="high" and d["error"] is None'
is "  energy cache written" "$(test -f "$GTG_STATE_DIR/oura-energy.json" && echo yes || echo no)" "yes"

code=$(curl -s -o "$TMP/body2" -w '%{http_code}' --max-time 15 \
  "${AUTH[@]}" "$BASE/api/energy")
is "energy cache hit is 200" "$code" "200"
json_ok "  cache still high" "$TMP/body2" 'd["ok"] is True and d["coaching"]["band"]=="high"'

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "${AUTH[@]}" "$BASE/api/oura/refresh" -H 'Content-Type: application/json' -d '{}')
is "oura refresh is 200" "$code" "200"
json_ok "  refresh still returns energy" "$TMP/body" 'd["ok"] is True and d["connected"] is True'

code=$(curl -s -o "$TMP/cb" -w '%{http_code}' --max-time 15 \
  "$BASE/oura/callback?code=good-code&state=nope")
is "callback bad state is 400" "$code" "400"

unset GTG_OURA_API GTG_OURA_AUTH GTG_OURA_STUB_PORT GTG_OURA_STUB_DAY

before=$(rows)
code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/api/log" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -d 'not json')
is "bad json is 400" "$code" "400"
is "  and it logged nothing" "$(rows)" "$before"

/usr/bin/python3 -c 'import sys; sys.stdout.write("x" * 70000)' >"$TMP/big"
code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 15 \
  -X POST "$BASE/api/log" "${AUTH[@]}" -H 'Content-Type: application/json' \
  -H 'Expect:' --data-binary @"$TMP/big" || true)
is "body over 64KB is 413" "$code" "413"
is "  and it logged nothing" "$(rows)" "$before"

if [ "$fail" -ne 0 ]; then
  echo "-- server stderr --" >&2
  cat "$TMP/server.err" >&2
fi

mutated=0
while IFS="$(printf '\t')" read -r f want; do
  now=$(md5 -q "$f" 2>/dev/null || echo ABSENT)
  [ "$now" = "$want" ] || { mutated=$((mutated + 1)); echo "         MUTATED: $f"; }
done <"$LIVE"
is "live log, page, plan, token, key, oura and cache unchanged" "$mutated" "0"

printf '\nserver: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
