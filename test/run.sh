#!/bin/bash
# gtg test suite. Runs entirely against a scratch state dir -- it must never be
# able to touch the real log, which is the whole reason GTG_STATE_DIR exists.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export GTG_STATE_DIR="$TMP/state" GTG_CONF_DIR="$TMP/conf"
mkdir -p "$GTG_STATE_DIR" "$GTG_CONF_DIR"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n         got  [%s]\n         want [%s]\n' "$1" "$2" "$3"; }
is()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

reset_plan() {
  cat >"$GTG_CONF_DIR/plan.txt" <<'P'
WAKE_START=9
WAKE_END=20
STYLE=picker
every: ring dips x5 | pull-ups x5 | push-ups x20 | kettlebell swings x10
away: stairs, 2 flights | air squats x20
wed: farmer walk 1 min
P
  : >"$GTG_STATE_DIR/log.tsv"
}
reset_plan
. ./bin/gtg-lib.sh

echo "== parser =="
p() { parse_piece "$1" | paste -sd'|' -; }
is "farmer walk, full sentence" "$(p 'Farmer Walk 1 minute - 100 lbs total')" "Farmer Walk||100lb|60"
is "weight suffix"              "$(p 'kettlebell swings x10 @ 50 lb')"        "kettlebell swings|10|50lb|"
is "weight prefix"              "$(p '50 lb kettlebell swings x10')"          "kettlebell swings|10|50lb|"
is "kg"                         "$(p '24kg swings x15')"                      "swings|15|24kg|"
is "seconds"                    "$(p 'dead hang 30s')"                        "dead hang|||30"
is "hyphen kept"                "$(p 'pull-ups x5')"                          "pull-ups|5||"
is "leading count"              "$(p '10 air squats')"                        "air squats|10||"
is "minutes"                    "$(p '2 min walk')"                           "walk|||120"
is "mixed case units"           "$(p 'Farmer Walk 1 Minute - 100 LBS Total')" "Farmer Walk||100lb|60"
is "metres are not minutes"     "$(p '400m sprint')"                          "400m sprint|||"

echo "== movement identity (key) =="
k() { printf '%s\n' "$1" | awk "$AWK_KEY"'{print key($0)}'; }
is "decorated option == logged name" "$(k 'kettlebell swings x10 @ 50 lb')" "$(k 'kettlebell swings')"
is "duration does not fork"          "$(k 'farmer walk 1 min')"             "$(k 'farmer walk 2 min')"
is "spelling does not fork"          "$(k 'Push-Ups x20')"                  "$(k 'pushups')"

echo "== bash/python key parity =="
for n in 'Farmer Walk 1 minute - 100 lbs total' 'pull-ups x5' '10 Air Squats' \
         'kettlebell swings x10 @ 50 lb' 'dead hang 30s' '400m sprint'; do
  b=$(k "$n")
  y=$(python3 -c "import sys,importlib.util as u;s=u.spec_from_loader('m',None);m=u.module_from_spec(s);exec(open('bin/gtg-page').read().split('def load')[0],m.__dict__);print(m.norm_ex(sys.argv[1]))" "$n")
  is "parity: $n" "$b" "$y"
done

echo "== resolution: known set, no guessing =="
is "exact"                "$(resolve_movement 'kettlebell swings')" "kettlebell swings"
is "unambiguous prefix"   "$(resolve_movement 'kett')"              "kettlebell swings"
is "unknown stays unknown" "$(resolve_movement 'sled push')"        ""
is "no edit-distance snap" "$(resolve_movement 'puships')"          ""

echo "== no splitting on separators =="
reset_plan
out=$(record_typed 'stairs, 2 flights' away); is "shipped away option stays one set" "$out" "stairs, 2 flights"
is "  and it is one row" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "1"

echo "== weight memory =="
reset_plan
record_typed 'kettlebell swings x10 @ 50 lb' home >/dev/null
is "inherits"      "$(record_typed 'kettlebell swings x10' home)" "kettlebell swings x10 @ 50 lb"
record_typed 'kettlebell swings x10 @ 70 lb' home >/dev/null
is "override sticks" "$(record_typed 'kettlebell swings x10' home)" "kettlebell swings x10 @ 70 lb"
is "no cross-movement leak" "$(record_typed 'pull-ups x5' home)" "pull-ups x5"

echo "== duration is NOT inherited =="
reset_plan
record_typed 'farmer walk 1 min' home >/dev/null
is "2 min stays 2 min" "$(record_typed 'farmer walk 2 min' home)" "farmer walk 2 min"

echo "== unknown movement is refused, not guessed =="
reset_plan
record_typed 'sled push x5' home >/dev/null 2>&1; is "returns 3" "$?" "3"
is "  and wrote nothing" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "0"

echo "== extending the pool =="
reset_plan
plan_add 'sled push x5 @ 90 lb' every; is "plan_add ok" "$?" "0"
is "now resolves"  "$(resolve_movement 'sled push')" "sled push"
plan_add 'sled push x5 @ 90 lb' every; is "duplicate refused (rc 2)" "$?" "2"
is "and logs"      "$(record_typed 'sled push x5' home)" "sled push x5 @ 90 lb"

echo "== backfill is safe =="
reset_plan
printf '2026-08-01T10:00:00\tFarmer Walk 1 minute - 100 lbs total\t\thome\n' >"$GTG_STATE_DIR/log.tsv"
printf '2026-08-01T11:00:00\t10 air squats\t\thome\n' >>"$GTG_STATE_DIR/log.tsv"
./bin/gtg backfill >/dev/null 2>&1
is "rows preserved" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "2"
is "weight extracted" "$(awk -F'\t' 'NR==1{print $5}' "$GTG_STATE_DIR/log.tsv")" "100lb"
is "duration extracted" "$(awk -F'\t' 'NR==1{print $6}' "$GTG_STATE_DIR/log.tsv")" "60"
# the failure that destroyed a 27-row log and reported success
cp "$GTG_STATE_DIR/log.tsv" "$TMP/before"
: >"$GTG_STATE_DIR/log.tsv.bak"; chmod 444 "$GTG_STATE_DIR/log.tsv.bak"
./bin/gtg backfill >/dev/null 2>&1; rc=$?
chmod 644 "$GTG_STATE_DIR/log.tsv.bak"
is "unwritable backup => nonzero exit" "$([ $rc -ne 0 ] && echo yes)" "yes"
is "unwritable backup => log intact"   "$(cmp -s "$TMP/before" "$GTG_STATE_DIR/log.tsv" && echo yes)" "yes"

echo "== readers run clean =="
reset_plan
record_typed 'pull-ups x5' home >/dev/null
for c in today week stats options plan; do
  ./bin/gtg "$c" >/dev/null 2>&1 && ok "gtg $c" || bad "gtg $c" "nonzero" "0"
done
./bin/gtg history 30 >/dev/null 2>&1 && ok "gtg history 30" || bad "gtg history 30" "nonzero" "0"
./bin/gtg-page --no-open >/dev/null 2>&1 && ok "gtg-page" || bad "gtg-page" "nonzero" "0"

echo "== isolation: the real log was never touched =="
is "no writes outside the scratch dir" "$(find "$HOME/.local/state/gtg" -newer "$TMP" -name 'log.tsv' 2>/dev/null | wc -l | tr -d ' ')" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
