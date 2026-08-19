#!/bin/bash
# gtg test suite. Runs entirely against a scratch state dir -- it must never be
# able to touch the real log, which is the whole reason GTG_STATE_DIR exists.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Fingerprint every live file BEFORE anything runs, and re-check at the end.
# The overrides below are the primary defence, but a defence you never verify
# is not a defence -- an earlier "dry run" of backfill rewrote the real log
# precisely because the override it relied on was silently ignored.
REAL_HOME=$HOME
LIVE="$TMP/live-before"
for f in "$REAL_HOME/.local/state/gtg/log.tsv" \
         "$REAL_HOME/.local/state/gtg/history.html" \
         "$REAL_HOME/.local/state/gtg/last-nudge" \
         "$REAL_HOME/.config/gtg/plan.txt"; do
  printf '%s\t%s\n' "$f" "$(md5 -q "$f" 2>/dev/null || echo ABSENT)" >>"$LIVE"
done

export GTG_STATE_DIR="$TMP/state" GTG_CONF_DIR="$TMP/conf"
mkdir -p "$GTG_STATE_DIR" "$GTG_CONF_DIR"
# Belt and braces: with HOME redirected, a regression in either override lands
# in a scratch path instead of the real account.
export HOME="$TMP/home"
mkdir -p "$HOME"

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
is "no edit-distance snap" "$(resolve_movement 'puships')"        ""
# You name a movement by its distinctive part, and the words you leave off are
# often at the FRONT -- "kettlebell back stretch" gets typed as "back stretch".
# A prefix rule cannot see that, which is why there is a substring tier.
is "unambiguous substring" "$(resolve_movement 'bell swings')"      "kettlebell swings"
is "  with a count on it"  "$(resolve_movement 'swings')"           "kettlebell swings"
# The property that makes the substring tier safe: two candidates resolve to
# neither, so you are asked rather than told.
is "ambiguous substring resolves to nothing" "$(resolve_movement 'ups')" ""
is "exact wins over substring" "$(resolve_movement 'pull-ups')"     "pull-ups"

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

echo "== backfill never writes the live log =="
reset_plan
printf '2026-08-01T10:00:00\tFarmer Walk 1 minute - 100 lbs total\t\thome\n'  >"$GTG_STATE_DIR/log.tsv"
printf '2026-08-01T11:00:00\t10 air squats\t\thome\n'                       >>"$GTG_STATE_DIR/log.tsv"
printf '2026-08-01T12:00:00\tZone 2\t\thome\n'                              >>"$GTG_STATE_DIR/log.tsv"
cp "$GTG_STATE_DIR/log.tsv" "$TMP/before"
./bin/gtg backfill >/dev/null 2>&1
is "log itself untouched"   "$(cmp -s "$TMP/before" "$GTG_STATE_DIR/log.tsv" && echo yes)" "yes"
is "candidate written"      "$([ -f "$GTG_STATE_DIR/log.tsv.migrated" ] && echo yes)" "yes"
is "candidate keeps rows"   "$(wc -l <"$GTG_STATE_DIR/log.tsv.migrated" | tr -d ' ')" "3"
is "weight extracted"       "$(awk -F'\t' 'NR==1{print $5}' "$GTG_STATE_DIR/log.tsv.migrated")" "100lb"
is "duration extracted"     "$(awk -F'\t' 'NR==1{print $6}' "$GTG_STATE_DIR/log.tsv.migrated")" "60"
is "leading count is reps"  "$(awk -F'\t' 'NR==2{print $3}' "$GTG_STATE_DIR/log.tsv.migrated")" "10"
# "Zone 2" must keep its name: a trailing bare number is part of the name at
# least as often as it is a count.
is "Zone 2 name preserved"  "$(awk -F'\t' 'NR==3{print $2}' "$GTG_STATE_DIR/log.tsv.migrated")" "Zone 2"
is "Zone 2 reps left empty" "$(awk -F'\t' 'NR==3{print $3}' "$GTG_STATE_DIR/log.tsv.migrated")" ""

# Applying it is your move, and then there is nothing left to do.
mv "$GTG_STATE_DIR/log.tsv.migrated" "$GTG_STATE_DIR/log.tsv"
out=$(./bin/gtg backfill 2>&1)
is "second run is a no-op"  "$(printf '%s' "$out" | grep -c 'nothing to migrate')" "1"
is "no stale candidate"     "$([ -f "$GTG_STATE_DIR/log.tsv.migrated" ] && echo yes || echo no)" "no"

echo "== CLI WRITE paths =="
# These exist because they were missing. record_option() was deleted in a
# refactor and four callers kept calling it; every reader test still passed,
# because none of them logged anything. Bash printed "command not found", the
# surrounding echo exited 0, and a nudge would have stamped the slot as used
# while writing no row. Exercising library functions is not the same as
# exercising the commands.
rows() { wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' '; }
reset_plan
n0=$(rows); out=$(./bin/gtg 2>&1)
is "bare gtg wrote a row"    "$(( $(rows) - n0 ))" "1"
is "bare gtg named it"       "$(printf '%s' "$out" | grep -c 'logged: [a-zA-Z]')" "1"
is "bare gtg: no not-found"  "$(printf '%s' "$out" | grep -c 'not found')" "0"

n0=$(rows); out=$(./bin/gtg 12 2>&1)
is "gtg 12 wrote a row"      "$(( $(rows) - n0 ))" "1"
is "gtg 12 used 12 reps"     "$(awk -F'\t' 'END{print $3}' "$GTG_STATE_DIR/log.tsv")" "12"
is "gtg 12: no not-found"    "$(printf '%s' "$out" | grep -c 'not found')" "0"

n0=$(rows); out=$(./bin/gtg skip 2>&1)
is "gtg skip wrote a row"    "$(( $(rows) - n0 ))" "1"
is "gtg skip marked skip"    "$(awk -F'\t' 'END{print $3}' "$GTG_STATE_DIR/log.tsv")" "skip"
is "gtg skip: no not-found"  "$(printf '%s' "$out" | grep -c 'not found')" "0"

n0=$(rows); out=$(./bin/gtg "pull-ups x5" 2>&1)
is "gtg <text> wrote a row"  "$(( $(rows) - n0 ))" "1"
is "gtg <text>: no not-found" "$(printf '%s' "$out" | grep -c 'not found')" "0"

# Every function the shipped commands reference must actually exist.
missing=0
for fn in record record_option record_typed record_new resolve_movement \
          known_movements plan_add last_weight_for read_piece parse_piece \
          fmt_piece fmt_dur fmt_wt decorate_weights today_options; do
  declare -f "$fn" >/dev/null 2>&1 || { missing=$((missing+1)); echo "         missing: $fn"; }
done
is "no called function is undefined" "$missing" "0"

echo "== time parser =="
# Anchored on yesterday and on offsets from now, never on a bare hour today:
# "8am" means this morning at 10am and yesterday morning at 7am, so asserting
# an absolute value for it would make the suite pass or fail by wall clock.
today=$(date '+%Y-%m-%d'); yest=$(date -v-1d '+%Y-%m-%d')
is "yesterday + hour"      "$(when_to_iso 'yesterday 7am')"      "${yest}T07:00:00"
is "leading zero is not octal" "$(when_to_iso 'yesterday 08:00')" "${yest}T08:00:00"
is "4-digit military"      "$(when_to_iso 'yesterday 0730')"     "${yest}T07:30:00"
is "12am is midnight"      "$(when_to_iso 'yesterday 12am')"     "${yest}T00:00:00"
is "12pm is noon"          "$(when_to_iso 'yesterday 12pm')"     "${yest}T12:00:00"
is "pm adds twelve"        "$(when_to_iso 'yesterday 2:15pm')"   "${yest}T14:15:00"
is "explicit date"         "$(when_to_iso "$yest 6:30")"         "${yest}T06:30:00"
is "minutes back from now" "$(when_to_iso '-90m')"    "$(date -v-90M '+%Y-%m-%dT%H:%M:00')"
is "hours back from now"   "$(when_to_iso '2h ago')"  "$(date -v-2H '+%Y-%m-%dT%H:%M:00')"
# The one property that must hold for every input: you cannot have already done
# a set you have not done yet.
is "23:59 never lands in the future" \
  "$([ "$(date -j -f '%Y-%m-%dT%H:%M:%S' "$(when_to_iso '23:59')" '+%s')" -le "$(date '+%s')" ] && echo past)" "past"
is "a bare day is not a time"  "$(when_to_iso "$yest" || echo REJECTED)"  "REJECTED"
is "impossible hour rejected"  "$(when_to_iso '25:00' || echo REJECTED)"  "REJECTED"
is "nonsense rejected"         "$(when_to_iso 'banana' || echo REJECTED)" "REJECTED"
is "empty rejected"            "$(when_to_iso '' || echo REJECTED)"       "REJECTED"

echo "== pulling @time off one line of text =="
# A dialog has one text field and no quoting, so the time has to be able to
# span words -- and must not get greedy about it.
sa() { split_at "$1"; printf '%s|%s' "$AT_ISO" "$AT_REST"; }
is "one-word time"        "$(sa '@yesterday 7am pull-ups x5')" "${yest}T07:00:00|pull-ups x5"
is "two-word time"        "$(sa "@$yest 6:30 ring dips x5")"   "${yest}T06:30:00|ring dips x5"
is "time with no text"    "$(sa '@yesterday 7am')"             "${yest}T07:00:00|"
is "a round survives it"  "$(sa '@yesterday 7am a; b; c')"     "${yest}T07:00:00|a; b; c"
# The greedy trap: "7am 10" is not a time, so the count must stay with the
# movement rather than being swallowed as part of the time.
is "count is not eaten"   "$(sa '@yesterday 7am 10 ring crunches')" \
                          "${yest}T07:00:00|10 ring crunches"
is "no @ means no time"   "$(sa '10 ring crunches')"           "|10 ring crunches"
is "unreadable time left whole" "$(sa '@banana pull-ups x5')"  "|@banana pull-ups x5"
is "a bare @ is left whole"     "$(sa '@')"                    "|@"

echo "== backdating =="
reset_plan
export GTG_AT="${yest}T07:00:00"
record_option 'pull-ups x5' home >/dev/null
unset GTG_AT
is "the row carries the time given" "$(cut -f1 <"$GTG_STATE_DIR/log.tsv")" "${yest}T07:00:00"

reset_plan
record_typed 'kettlebell swings x10 @ 50 lb' home >/dev/null
export GTG_AT="${yest}T07:00:00"
record_typed 'kettlebell swings x10 @ 20 lb' home >/dev/null
unset GTG_AT
is "a backdated set cannot redefine the current weight" \
  "$(last_weight_for 'kettlebell swings')" "50lb"

echo "== a round typed in one go =="
reset_plan
export GTG_AT="${yest}T07:00:00"
record_batch '10 air squats; pull-ups x5; push-ups x20' home >/dev/null
unset GTG_AT
is "three movements, three rows" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "3"
is "  a second apart, so they read back in order" \
  "$(cut -f1 <"$GTG_STATE_DIR/log.tsv" | paste -sd, -)" \
  "${yest}T07:00:00,${yest}T07:00:01,${yest}T07:00:02"

reset_plan
is "pipe separates too" \
  "$(record_batch 'pull-ups x5 | push-ups x20' home >/dev/null; wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "2"

# The same rule record_typed has, and for the same reason: the shipped option
# `stairs, 2 flights` is one movement whose name contains a comma.
reset_plan
record_batch 'stairs, 2 flights' away >/dev/null
is "a comma still does not separate" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "1"

# A round typed in one breath must not half-land, leaving you to work out
# which half made it.
reset_plan
record_batch 'pull-ups x5; sled push x5; push-ups x20' home >/dev/null 2>&1
is "an unknown movement rejects the whole round" "$?" "3"
is "  and writes nothing at all" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "0"

echo "== a fire that decides to stay quiet still says so =="
# The two checks that exit without nudging used to exit silently, so an absent
# log line meant either "suppressed on purpose" or "the job never ran" and
# there was no way to tell which. Neither may go quiet again.
reset_plan
printf '%s' "$(date +%s)" >"$GTG_STATE_DIR/last-nudge"
is "a debounced fire is logged" \
  "$(./bin/gtg-nudge 2>&1 | grep -c 'skip: debounced')" "1"

# A one-hour waking window on the NEXT hour, so the current one is always
# outside it whatever time the suite runs, midnight included.
rm -f "$GTG_STATE_DIR/last-nudge"
w=$(( ($(date +%-H) + 1) % 24 ))
sed -i '' "s/^WAKE_START=.*/WAKE_START=$w/; s/^WAKE_END=.*/WAKE_END=$w/" "$GTG_CONF_DIR/plan.txt"
is "an out-of-hours fire is logged" \
  "$(./bin/gtg-nudge 2>&1 | grep -c 'outside waking hours')" "1"
is "  and it wrote no set" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "0"

echo "== readers run clean =="
reset_plan
record_typed 'pull-ups x5' home >/dev/null
# `nudges` must survive an empty nudge log rather than erroring on it.
for c in today week stats options plan nudges; do
  ./bin/gtg "$c" >/dev/null 2>&1 && ok "gtg $c" || bad "gtg $c" "nonzero" "0"
done
./bin/gtg when 8am >/dev/null 2>&1 && ok "gtg when 8am" || bad "gtg when 8am" "nonzero" "0"
./bin/gtg history 30 >/dev/null 2>&1 && ok "gtg history 30" || bad "gtg history 30" "nonzero" "0"
./bin/gtg-page --no-open >/dev/null 2>&1 && ok "gtg-page" || bad "gtg-page" "nonzero" "0"

echo "== isolation: nothing live was touched =="
# Content comparison, not mtime: an mtime threshold moves whenever the suite
# creates a file, which can hide a write that happened before it.
mutated=0
while IFS=$'\t' read -r f want; do
  now=$(md5 -q "$f" 2>/dev/null || echo ABSENT)
  [ "$now" = "$want" ] || { mutated=$((mutated+1)); echo "         MUTATED: $f"; }
done <"$LIVE"
is "live log, page, stamp and plan all unchanged" "$mutated" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
