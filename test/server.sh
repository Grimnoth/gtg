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
         "$REAL_HOME/.local/state/gtg/gcal-token.json"; do
  printf '%s\t%s\n' "$f" "$(md5 -q "$f" 2>/dev/null || echo ABSENT)" >>"$LIVE"
done
cleanup() {
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
  local pid=$!
  sleep 0.3
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
is "live log, page, plan, token, key and cache unchanged" "$mutated" "0"

printf '\nserver: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
