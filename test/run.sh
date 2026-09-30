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
         "$REAL_HOME/.config/gtg/plan.txt" \
         "$REAL_HOME/.config/gtg/gcal-key.json" \
         "$REAL_HOME/.local/state/gtg/gcal-token.json"; do
  printf '%s\t%s\n' "$f" "$(md5 -q "$f" 2>/dev/null || echo ABSENT)" >>"$LIVE"
done

export GTG_STATE_DIR="$TMP/state" GTG_CONF_DIR="$TMP/conf"
mkdir -p "$GTG_STATE_DIR" "$GTG_CONF_DIR"

# NO TEST EVER REACHES A MODEL. /usr/bin/true prints nothing, which is the
# interpreter's fail-open answer, so every pre-existing test keeps the exact
# behaviour it was written against. The tests that do exercise the interpreter
# point this at a stub script instead.
#
# It is set here rather than per test because the cost of forgetting is not a
# flake: `claude -p` under a redirected HOME answers "Not logged in - Please
# run /login" on stdout and exits 0, so a suite that leaked into it tested the
# shape of an error message.
export GTG_INTERPRET_CMD=/usr/bin/true

# A stand-in for the model: prints $STUB_ANSWER, records that it was called.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/stub" <<'STUB'
#!/bin/sh
cat >"$STUB_SAW"
echo "$STUB_CALLS" >>"$STUB_SAW.n"
printf '%s\n' "$STUB_ANSWER"
STUB
chmod +x "$TMP/bin/stub"
stub_calls() { [ -f "$STUB_SAW.n" ] && wc -l <"$STUB_SAW.n" | tr -d ' ' || echo 0; }
stub_reset() { rm -f "$STUB_SAW" "$STUB_SAW.n"; }
export STUB_SAW="$TMP/stub-saw"
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
WAKE_END=21
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
# The shape Ben actually types. Twelve of the first twenty-three refused
# entries in the live nudge log were "20x Push Ups": count first, then x.
is "count-x prefix"             "$(p '20x Push Ups')"                    "Push Ups|20||"
is "count-x with a weight"      "$(p '12x Kettlebell Swings 50lb')"      "Kettlebell Swings|12|50lb|"
is "count-x with a space"       "$(p '8 x ring dips')"                   "ring dips|8||"
is "trailing period dropped"    "$(p 'kettlebell walk.')"                "kettlebell walk|||"
is "no x eaten from a name"     "$(p 'box jumps x5')"                    "box jumps|5||"

k() { printf '%s\n' "$1" | awk "$AWK_KEY"'{print key($0)}'; }
is "count-x does not fork"           "$(k '20x push ups')"               "$(k 'push-ups')"
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
out=$(record_batch 'stairs, 2 flights' away); is "shipped away option stays one set" "$out" "stairs, 2 flights"
is "  and it is one row" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "1"

echo "== weight memory =="
reset_plan
record_batch 'kettlebell swings x10 @ 50 lb' home >/dev/null
is "inherits"      "$(record_batch 'kettlebell swings x10' home)" "kettlebell swings x10 @ 50 lb"
record_batch 'kettlebell swings x10 @ 70 lb' home >/dev/null
is "override sticks" "$(record_batch 'kettlebell swings x10' home)" "kettlebell swings x10 @ 70 lb"
is "no cross-movement leak" "$(record_batch 'pull-ups x5' home)" "pull-ups x5"

echo "== the count is remembered, like the weight =="
reset_plan
plan_add 'bulgarian split squats' every >/dev/null
is "offered bare before any set" "$(today_options home | grep -c '^bulgarian split squats$')" "1"
record_batch 'bulgarian split squats x5' home >/dev/null
is "offered with the count after" "$(today_options home | grep -c '^bulgarian split squats x5$')" "1"
is "  and Did it logs it" "$(record_option 'bulgarian split squats x5' home)" "bulgarian split squats x5"
is "  as reps, not name" "$(tail -1 "$GTG_STATE_DIR/log.tsv" | cut -f2,3)" "$(printf 'bulgarian split squats\t5')"
record_batch 'bulgarian split squats x8' home >/dev/null
is "a new count overrides" "$(last_reps_for 'bulgarian split squats')" "8"
record_batch 'farmer walk 1 min' home >/dev/null
is "a timed movement gets no count" "$(last_reps_for 'farmer walk')" ""
is "  in the picker either" "$(today_options home | grep -c '^farmer walk 1 min x')" "0"

echo "== duration is NOT inherited =="
reset_plan
record_batch 'farmer walk 1 min' home >/dev/null
is "2 min stays 2 min" "$(record_batch 'farmer walk 2 min' home)" "farmer walk 2 min"

echo "== unknown movement is refused, not guessed =="
reset_plan
record_batch 'sled push x5' home >/dev/null 2>&1; is "returns 3" "$?" "3"
is "  and wrote nothing" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "0"

echo "== extending the pool =="
reset_plan
plan_add 'sled push x5 @ 90 lb' every; is "plan_add ok" "$?" "0"
is "now resolves"  "$(resolve_movement 'sled push')" "sled push"
plan_add 'sled push x5 @ 90 lb' every; is "duplicate refused (rc 2)" "$?" "2"
is "and logs"      "$(record_batch 'sled push x5' home)" "sled push x5 @ 90 lb"

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
for fn in record record_option record_batch new_for resolve_movement \
          known_movements plan_add last_weight_for read_piece parse_piece \
          fmt_piece fmt_dur fmt_wt decorate_weights today_options \
          pause_active pause_ends pause_set pause_human parse_pause; do
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
record_batch 'kettlebell swings x10 @ 50 lb' home >/dev/null
export GTG_AT="${yest}T07:00:00"
record_batch 'kettlebell swings x10 @ 20 lb' home >/dev/null
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

# The same rule record_batch has, and for the same reason: the shipped option
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

echo "== \"and\" separates a round =="
# The word a round gets dictated with. "clean and press" would be torn in
# two, and no pool has one -- see the ponytail on record_batch.
reset_plan
record_batch 'pull-ups x5 and push-ups x20 AND 10 air squats' home >/dev/null
is "three rows, any case" "$(rows)" "3"
reset_plan
record_batch 'pull-ups x5 & push-ups x20' home >/dev/null
is "so does &" "$(rows)" "2"
reset_plan
record_batch 'pull-ups x5;push-ups x20 and 10 air squats' home >/dev/null
is "mixed with ;" "$(rows)" "3"

echo "== a trailing \"for\" is not part of the name =="
# "Soccer / Running for 20 minutes" logged a movement called "Running for".
read_piece 'Soccer / Running for 20 minutes'
is "name"     "$P_NAME" "Soccer / Running"
is "duration" "$P_DUR"  "1200"
is "key matches without it" \
  "$(printf 'running for 20 min\n' | awk "$AWK_KEY"'{print key($0)}')" \
  "$(printf 'running\n' | awk "$AWK_KEY"'{print key($0)}')"

echo "== GTG_NEW logs what it does not know, as typed =="
reset_plan
GTG_NEW=log record_batch 'pull-ups x5; sled push x5' home >/dev/null 2>&1; is "accepted" "$?" "0"
is "  both rows"         "$(rows)" "2"
is "  named as typed"    "$(tail -1 "$GTG_STATE_DIR/log.tsv" | cut -f2)" "sled push"
is "  pool untouched"    "$(grep -c 'sled push' "$GTG_CONF_DIR/plan.txt")" "0"
is "  known from now on" "$(resolve_movement 'sled push')" "sled push"
record_batch 'sled push x5' home >/dev/null 2>&1; is "  so the plain form logs it" "$?" "0"
reset_plan
GTG_NEW=pool record_batch 'plank 1 min' home >/dev/null 2>&1; is "GTG_NEW=pool accepted" "$?" "0"
is "  row written" "$(rows)" "1"
is "  and offered" "$(plan_line every | grep -c 'plank 1 min')" "1"
reset_plan
record_batch 'sled push x5' home >"$TMP/o" 2>"$TMP/e"
is "refusal names it on stderr" "$(sed -n 's/^unknown movement: //p' "$TMP/e")" "sled push"
is "  and the fix" "$(grep -c -- '--new' "$TMP/e")" "1"

echo "== a piece carries its own time =="
# A morning done at two times, typed as one line.
reset_plan
y=$(date -v-1d '+%Y-%m-%d')
record_batch '@yesterday 7:15 pull-ups x5; @yesterday 7:40 push-ups x20 and 10 air squats' home >/dev/null 2>&1
is "three rows" "$(rows)" "3"
is "each at its own time" "$(cut -f1 "$GTG_STATE_DIR/log.tsv" | paste -sd, -)" \
   "${y}T07:15:00,${y}T07:40:00,${y}T07:40:01"
record_batch '@nonsense pull-ups x5' home >/dev/null 2>&1; is "an unreadable time is an error (rc 1)" "$?" "1"
is "  that wrote nothing" "$(rows)" "3"
is "GTG_AT is left as it was" "${GTG_AT:-unset}" "unset"

echo "== gtg --new and --offer =="
reset_plan
./bin/gtg 'sled push x5' >/dev/null 2>"$TMP/e"; is "plain gtg refuses (rc 1)" "$?" "1"
is "  naming it" "$(grep -c '^unknown movement: sled push' "$TMP/e")" "1"
out=$(./bin/gtg --new 'sled push x5' 2>&1); is "--new logs it" "$?" "0"
is "  and says so" "$(printf '%s' "$out" | grep -c '^logged: sled push x5')" "1"
out=$(./bin/gtg --offer '@yesterday 6am plank 1 min' 2>&1); is "--offer with a time" "$?" "0"
is "  lands at six"   "$(tail -1 "$GTG_STATE_DIR/log.tsv" | cut -f1)" "${y}T06:00:00"
is "  and is offered" "$(plan_line every | grep -c 'plank 1 min')" "1"

echo "== a fire that decides to stay quiet still says so =="
# The two checks that exit without nudging used to exit silently, so an absent
# log line meant either "suppressed on purpose" or "the job never ran" and
# there was no way to tell which. Neither may go quiet again.
reset_plan
printf '%s' "$(date +%s)" >"$GTG_STATE_DIR/last-nudge"
is "a debounced fire is logged" \
  "$(./bin/gtg-nudge 2>&1 | grep -c 'skip: debounced')" "1"

# A one-hour window on the NEXT hour, so the current one is always outside it
# whatever time the suite runs, midnight included.
rm -f "$GTG_STATE_DIR/last-nudge"
w=$(( ($(date +%-H) + 1) % 24 ))
sed -i '' "s/^WAKE_START=.*/WAKE_START=$w/; s/^WAKE_END=.*/WAKE_END=$(( w + 1 ))/" \
  "$GTG_CONF_DIR/plan.txt"
is "an out-of-hours fire is logged" \
  "$(./bin/gtg-nudge 2>&1 | grep -c 'outside waking hours')" "1"
is "  and it wrote no set" "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "0"

# WAKE_END is exclusive: fires land at :20 and :50, so an inclusive 21 would
# have let 21:50 through, an hour past what the number looks like. Both sides
# of the boundary, tested directly rather than through gtg-nudge, which would
# open a dialog on the inside case.
sed -i '' "s/^WAKE_START=.*/WAKE_START=9/; s/^WAKE_END=.*/WAKE_END=21/" \
  "$GTG_CONF_DIR/plan.txt"
in_waking_window 8  && bad "08:00 is before the window" "allowed" "skipped" || ok "08:00 is before the window"
in_waking_window 9  && ok  "09:00 is the first hour"    || bad "09:00 is the first hour" "skipped" "allowed"
in_waking_window 20 && ok  "20:00 still nudges"         || bad "20:00 still nudges" "skipped" "allowed"
in_waking_window 21 && bad "21:00 is already out"       "allowed" "skipped" || ok "21:00 is already out"
in_waking_window 23 && bad "23:00 is out"               "allowed" "skipped" || ok "23:00 is out"

echo "== not today: the nudges can be turned off =="
# A day with no set coming is a day of nine useless dialogs, and a reminder
# with no off switch is one you learn to ignore, which costs every later day
# too. Every pause carries an end time, so the failure is never the opposite
# one: switched off in February, noticed in May.
reset_plan
rm -f "$GTG_STATE_DIR/paused"
pause_active && bad "off by default" "paused" "on" || ok "off by default"

# The words, wherever they are typed. The menu bar and the nudge have one text
# field and no subcommands, so "not today" arrives as a whole line.
pp() { if parse_pause "$1"; then printf '%s|%s' "$PAUSE_FOR" "$PAUSE_REASON"; else printf 'SET'; fi; }
is "bare off"                 "$(pp 'off')"                  "|"
is "with a reason"            "$(pp 'off sick')"             "|sick"
is "sick on its own"          "$(pp 'sick')"                 "|sick"
is "a comma after it"         "$(pp 'not today, wrecked')"   "|wrecked"
is "for a stretch"            "$(pp 'pause 90m bad back')"   "90m|bad back"
is "any case"                 "$(pp 'OFF 2h')"               "2h|"
# Every ordinary set must fall through, including one that starts with the
# same letters: the word has to END there.
is "a movement is a set"      "$(pp 'pull-ups x5')"          "SET"
is "  even starting with off" "$(pp 'offset rows x5')"       "SET"
is "  even with a comma"      "$(pp 'stairs, 2 flights')"    "SET"
# A word starting with a digit is a stretch of time or a mistyped one, never a
# reason. "2x" read as a reason would pause the whole day in silence.
is "a mistyped stretch stays a stretch" "$(pp 'off 2x')"     "2x|"

# The expiry is READ, never scheduled: nothing has to survive a reboot for the
# nudges to come back, and a stale pause cannot outlive its day.
pause_set "$(( $(date +%s) + 60 ))" "sick"
pause_active; is "a live pause is on" "$?" "0"
is "  and says why"                   "$PAUSE_WHY" "sick"
pause_set "$(( $(date +%s) - 60 ))" "sick"
pause_active && bad "an expired pause is off" "paused" "on" || ok "an expired pause is off"
is "  and the file is gone" "$([ -f "$GTG_STATE_DIR/paused" ] && echo yes || echo no)" "no"
# A file nobody can trust to expire must not be able to mute the tool for ever.
printf 'soon\n' >"$GTG_STATE_DIR/paused"
pause_active && bad "an unreadable pause is off" "paused" "on" || ok "an unreadable pause is off"

# End to end: a paused fire opens nothing, says why, and leaves the slot
# unburned. A window of 0..24 keeps this true at any hour the suite runs.
reset_plan
sed -i '' "s/^WAKE_START=.*/WAKE_START=0/; s/^WAKE_END=.*/WAKE_END=24/" "$GTG_CONF_DIR/plan.txt"
rm -f "$GTG_STATE_DIR/last-nudge" "$GTG_STATE_DIR/paused"
./bin/gtg off sick >/dev/null
is "a paused fire says so"  "$(./bin/gtg-nudge 2>&1 | grep -c 'skip: paused until')" "1"
is "  and logs no set"      "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "0"
is "  and burns no slot"    "$([ -f "$GTG_STATE_DIR/last-nudge" ] && echo yes || echo no)" "no"
is "  and today says it"    "$(./bin/gtg today | grep -c '^nudges are off until')" "1"
is "  and status says it"   "$(./bin/gtg status | grep -c '^paused: ')" "1"
./bin/gtg on >/dev/null
is "gtg on turns them back on" "$(./bin/gtg status | grep -c '^paused: ')" "0"
is "  and a second gtg on is honest" "$(./bin/gtg on)" "nudges are already on"

# Typed into a text field rather than run as a subcommand: the menu bar path.
is "a typed line pauses too" "$(./bin/gtg 'not today' | grep -c '^nudges off until')" "1"
is "  and wrote no set"      "$(wc -l <"$GTG_STATE_DIR/log.tsv" | tr -d ' ')" "0"
./bin/gtg on >/dev/null
./bin/gtg off 2x >/dev/null 2>&1; is "a mistyped stretch is refused (rc 1)" "$?" "1"
is "  and paused nothing" "$([ -f "$GTG_STATE_DIR/paused" ] && echo yes || echo no)" "no"
is "3d reaches a later day" \
  "$(./bin/gtg off 3d >/dev/null; date -r "$(cut -f1 "$GTG_STATE_DIR/paused")" '+%Y-%m-%d')" \
  "$(date -v+3d '+%Y-%m-%d')"
rm -f "$GTG_STATE_DIR/paused"

# A day turned off on purpose is not a day of dialogs ignored, and counting
# the two together would read as a collapse in compliance.
D=$(date '+%Y-%m-%d')
cat >"$GTG_STATE_DIR/nudge.log" <<N
$D 09:20  paused until Thu 17 Sep 09:00 (sick)
$D 09:50  skip: paused until Thu 17 Sep 09:00 (sick)
$D 10:20  skip: paused until Thu 17 Sep 09:00 (sick)
N
is "fires counts a day off apart" "$(./bin/gtg fires | grep -c '2 turned off')" "1"
is "  and shows no nudges at all" "$(./bin/gtg fires | grep -c '^last 14 days: 0 nudges shown')" "1"

echo "== status: one call for the menu bar =="
# The menu used to make three calls on every click and waited about a second
# for them. This is the one call that replaced them, so it has to carry
# everything the menu draws.
reset_plan
record_batch 'pull-ups x5' home >/dev/null
out=$(./bin/gtg status)
is "names where you are" "$(printf '%s' "$out" | grep -c '^where: \(home\|away\)$')" "1"
is "carries the pick"    "$(printf '%s' "$out" | grep -c '^pick: [a-zA-Z]')" "1"
is "and today's sets"    "$(printf '%s' "$out" | grep -c '1 set(s)')" "1"
is "and one row per set" "$(printf '%s' "$out" | grep -cE '^  [0-9][0-9]:[0-9][0-9]  ')" "1"
is "quiet when it is on" "$(printf '%s' "$out" | grep -c '^paused: ')" "0"

echo "== today shows the spread across the day =="
# Grease-the-groove lives on spread, so `today` says how many waking hours
# got a set. A window of 0..24 keeps the test true at any hour of the day.
reset_plan
sed -i '' "s/^WAKE_START=.*/WAKE_START=0/; s/^WAKE_END=.*/WAKE_END=24/" "$GTG_CONF_DIR/plan.txt"
export GTG_AT="$(date '+%Y-%m-%d')T00:05:00"
record_batch 'pull-ups x5' home >/dev/null
unset GTG_AT
is "one set, one hour, of the hours so far" \
  "$(./bin/gtg today | grep -c "in 1 of $(( $(date +%-H) + 1 )) waking hours")" "1"
is "  and the strip marks hour 00" "$(./bin/gtg today | grep -c '^  00 ')" "1"
# A set before WAKE_START is the kind this tool most wants, so the strip
# reaches back to it rather than reading "0 of 0" all morning.
sed -i '' "s/^WAKE_START=.*/WAKE_START=9/" "$GTG_CONF_DIR/plan.txt"
is "a set before the window still counts" \
  "$(./bin/gtg today | grep -c "in 1 of $(( $(date +%-H) + 1 )) waking hours")" "1"
is "  and widens the strip to reach it" "$(./bin/gtg today | grep -c '^  00 ')" "1"

echo "== fires: what happened to every nudge =="
reset_plan
D=$(date '+%Y-%m-%d')
cat >"$GTG_STATE_DIR/nudge.log" <<N
$D 02:20  skip: outside waking hours (9:00 until 21:00)
$D 09:20  logged (typed): Pull-Ups x5
$D 09:20  nudged (home): Pull Ups x5
$D 09:50  skip: debounced, 30 min since the last nudge (needs 40); next due 10:00
$D 10:20  seen: Google Chrome: Meet – abc-defg-hij - Google Chrome
$D 10:20  snoozed
$D 11:05  seen: no meeting window
$D 11:05  no answer (dismissed itself after 900s)
$D 11:26  seen: hs did not answer in 8s
$D 11:26  unknown movement declined: 5x Pull Ups
$D 12:00  catch-up shown (unlocked after 3h)
$D 12:01  catch-up done: 2 logged
N
fires=$(./bin/gtg fires 14)
is "four dialogs shown"      "$(printf '%s\n' "$fires" | grep -c '4 nudges shown')" "1"
is "the stamp line is not a fifth" "$(printf '%s\n' "$fires" | grep -c '5 nudges')" "0"
is "logged share"            "$(printf '%s\n' "$fires" | grep -cE 'logged +1 +25%')" "1"
is "no answer share"         "$(printf '%s\n' "$fires" | grep -cE 'no answer +1 +25%')" "1"
is "refused share"           "$(printf '%s\n' "$fires" | grep -cE 'refused +1 +25%')" "1"
is "skips summarized"        "$(printf '%s\n' "$fires" | grep -c '1 outside hours, 1 debounced, 0 in a meeting')" "1"
is "catch-ups counted"       "$(printf '%s\n' "$fires" | grep -c 'catch-up: 1 shown, 2 sets logged')" "1"
# The observed meeting signal, counted against what happened next. A "seen:"
# that names a window counts; "no meeting window" and an hs failure do not.
is "call window cross-tab"   "$(printf '%s\n' "$fires" | grep -c 'with a call window open: 1 shown, 0 logged')" "1"
is "by hour: 11 shows two"   "$(printf '%s\n' "$fires" | awk '/^  hour/{for(i=2;i<=NF;i++)if($i=="11")c=i} /^  shown/{print $c}')" "2"

# `gtg note` is how the menu bar records a catch-up into the same log the
# nudges use, so `fires` sees both in one place.
./bin/gtg note "catch-up shown (test)" >/dev/null
is "a note lands in the nudge log" "$(./bin/gtg nudges | grep -c 'catch-up shown (test)')" "1"

echo "== friction notes =="
# The feedback loop needs somewhere to land in the moment, not a week later.
reset_plan
./bin/gtg friction "the box hid behind zoom" >/dev/null
is "a friction note is kept"   "$(./bin/gtg friction | grep -c 'hid behind zoom')" "1"
is "  with where you were"     "$(./bin/gtg friction | grep -cE '\[(home|away), [0-9]+ sets today\]')" "1"
is "  in its own file"         "$([ -s "$GTG_STATE_DIR/friction.log" ] && echo yes)" "yes"

echo "== calendar: off unless the plan names one, and the script compiles =="
# The test plan has no CALENDAR line, so nothing here can reach the real
# Calendar.app. That is asserted, not assumed.
is "test plan names no calendar" "$(cfg CALENDAR)" ""
is "calendar_event is a no-op then" "$(calendar_event 'pull-ups x5' '2026-09-03T11:52:00' home; echo "rc=$?")" "rc=0"
for s in 'Pull-Ups x5' 'Bulgarian "split" squats x10 @ 20 lb'; do
  if calendar_script 'GTG' "$s" '2026-09-03T11:52:00' home | osacompile -o "$TMP/cal.scpt" 2>"$TMP/cal.err"; then
    ok "calendar script compiles: $s"
  else
    bad "calendar script compiles: $s" "$(head -1 "$TMP/cal.err")" "clean compile"
  fi
done
# The write outlives the nudge, and launchd kills a job's leftover children
# unless the plist says not to. A set logged from a nudge reached the log and
# never the calendar, with nothing in the nudge log, until this key existed.
is "launchd lets the calendar write outlive the nudge" \
  "$(grep -A1 AbandonProcessGroup launchd/com.grimnoth.gtg.plist | grep -c '<true/>')" "1"
is "the event carries the set's own time" \
  "$(calendar_script GTG 'Pull-Ups x5' '2026-09-03T07:15:00' home | grep -c 'set hours of d to 7$')" "1"
# The rows the sync feeds the calendar. A timed set has an EMPTY reps column,
# and the first sync read "home" into it and wrote "dead hang xhome".
reset_plan
record_batch 'farmer walk 1 min' home >/dev/null
record_batch 'kettlebell swings x10 @ 50 lb' away >/dev/null
record_option 'pull-ups x5' home skip >/dev/null
is "empty reps do not shift the columns" "$(sync_rows 1 | head -1 | cut -f1,3)" "farmer walk 1 min	home"
is "weight rides along"                  "$(sync_rows 1 | sed -n 2p | cut -f1,3)" "kettlebell swings x10 @ 50 lb	away"
is "skips are not synced"                "$(sync_rows 1 | wc -l | tr -d ' ')" "2"

echo "== what each movement usually is =="
reset_plan
# The mode, not the last value: one mistyped row must not redefine a movement.
# This is the exact shape of the 2026-09-22 entry that started all of this --
# a timed back stretch hand-corrected into a row saying 30 reps.
GTG_NEW=log record_batch 'kettlebell back stretch 30s' home >/dev/null 2>&1
for _ in 1 2; do record_batch 'kettlebell back stretch 30s' home >/dev/null; done
record_batch 'kettlebell back stretch x30' home >/dev/null
for _ in 1 2; do record_batch 'ring dips x5' home >/dev/null; done
record_batch 'ring dips x9' home >/dev/null
is "a timed movement reads as timed" \
  "$(movement_profiles | sed -n 's/^kettlebell back stretch - \([a-z]*\),.*/\1/p')" "timed"
is "  at the duration seen most often" \
  "$(movement_profiles | grep -c '^kettlebell back stretch - timed, usually 30s')" "1"
is "a counted movement reads as counted" \
  "$(movement_profiles | grep -c '^ring dips - counted, usually x5')" "1"
is "  and carries its set count" \
  "$(movement_profiles | sed -n 's/^ring dips .*(\([0-9]*\) sets)$/\1/p')" "3"
is "a plan movement never done says so" \
  "$(movement_profiles | grep -c '^push-ups - in the plan as:')" "1"

echo "== reading a sentence, when the parser cannot =="
reset_plan; stub_reset
# The movement has to exist before a sentence can resolve TO it. It is in the
# real plan; the suite's throwaway pool is deliberately smaller.
GTG_NEW=log record_batch 'kettlebell back stretch 30s' home >/dev/null 2>&1

# The line that started this, and the answer sonnet actually gave for it.
STUB_ANSWER='kettlebell back stretch 30s' \
  GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg '30-second back stretch with kettlebell' >"$TMP/o" 2>"$TMP/e"
is "a sentence the parser refuses is logged" "$?" "0"
is "  under the right movement" "$(tail -1 "$GTG_STATE_DIR/log.tsv" | cut -f2)" \
  "kettlebell back stretch"
is "  as a DURATION, not a rep count" "$(tail -1 "$GTG_STATE_DIR/log.tsv" | cut -f6)" "30"
is "  and the reading is said out loud" \
  "$(grep -c '^read as: kettlebell back stretch 30s' "$TMP/e")" "1"
is "  the model was asked once" "$(stub_calls)" "1"
is "  and was told what the movement usually is" \
  "$(grep -c 'kettlebell back stretch - timed' "$STUB_SAW")" "1"

# Twice is once. Speech repeats itself, and the second answer is free.
stub_reset
STUB_ANSWER='kettlebell back stretch 30s' GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg '30-second back stretch with kettlebell' >/dev/null 2>&1
is "the same sentence again asks nobody" "$(stub_calls)" "0"

# A movement it already understands never goes near a model.
reset_plan; stub_reset
STUB_ANSWER='ring dips x99' GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg 'pull-ups x5' >/dev/null 2>&1
is "a line the parser understands is not sent" "$(stub_calls)" "0"
is "  and is logged as typed" "$(tail -1 "$GTG_STATE_DIR/log.tsv" | cut -f3)" "5"

echo "== a fragment is not a report =="
# 2026-09-22, the first real use: the microphone was not open yet, so "I just
# did 5 Bulgarian split squats" reached the reader as "squats" -- and the
# reader picked the commoner of the two squats and supplied a rep count from
# the usual values. A set nobody did was logged. resolve_movement refuses an
# ambiguous match on purpose; a model given the same word does not refuse, it
# picks. So the refusal happens before the model is asked.
reset_plan; stub_reset
GTG_NEW=log record_batch 'air squats x10' home >/dev/null 2>&1
GTG_NEW=log record_batch 'bulgarian split squats x10' home >/dev/null 2>&1
STUB_ANSWER='air squats x10' GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg 'squats' >/dev/null 2>"$TMP/e"
is "one word naming two movements is refused" "$?" "1"
is "  the reader is never even asked" "$(stub_calls)" "0"
is "  and nothing is logged" "$(tail -1 "$GTG_STATE_DIR/log.tsv" | cut -f2)" \
  "bulgarian split squats"
is "  with the reason written down" \
  "$(grep -c 'could be 2 movements' "$GTG_STATE_DIR/nudge.log")" "1"

# One word naming exactly ONE movement is still fine: the rule is about
# ambiguity, not about brevity.
reset_plan; stub_reset
STUB_ANSWER='pull-ups x5' GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg 'pullups' >/dev/null 2>&1
is "one word naming one movement still resolves" \
  "$(tail -1 "$GTG_STATE_DIR/log.tsv" | cut -f2)" "pull-ups"

echo "== the calendar can be held back =="
# The state-dir override is not enough isolation on its own. A scratch run
# started from a COPY of the real plan.txt inherits its CALENDAR= line, so the
# log lands in a throwaway file while the EVENTS land in the real Google
# calendar. Nine test sets reached it on 2026-09-22 and came out by hand.
reset_plan
calendar_event() { printf 'called\n' >>"$TMP/cal-calls"; }
rm -f "$TMP/cal-calls"
printf 'CALENDAR=Pretend\n' >>"$GTG_CONF_DIR/plan.txt"
GTG_NO_PAGE=1 record 'pull-ups' 5 home >/dev/null 2>&1
# record() backgrounds the write. The line is there once the child runs.
i=0
while [ "$i" -lt 40 ] && [ ! -s "$TMP/cal-calls" ]; do sleep 0.05; i=$((i + 1)); done
is "a plain record would write to the calendar" \
  "$(wc -l <"$TMP/cal-calls" 2>/dev/null | tr -d ' ')" "1"
GTG_NO_PAGE=1 GTG_NO_CALENDAR=1 record 'pull-ups' 5 home >/dev/null 2>&1
is "  GTG_NO_CALENDAR holds it back" \
  "$(wc -l <"$TMP/cal-calls" 2>/dev/null | tr -d ' ')" "1"
unset -f calendar_event
. ./bin/gtg-lib.sh

echo "== the reader is found without a PATH =="
# The one thing nobody tested first time, and it broke BOTH callers at once
# while working perfectly from a terminal. launchd gives a job
# PATH=/usr/bin:/bin:/usr/sbin:/sbin, and hs.task gives a Hammerspoon child
# exactly the same four, so `command -v claude` found nothing in the nudge and
# nothing in the menu bar. --which answers this without calling a model.
reset_plan
printf 'INTERPRET=claude\n' >>"$GTG_CONF_DIR/plan.txt"
bare=$(env -u GTG_INTERPRET_CMD PATH=/usr/bin:/bin:/usr/sbin:/sbin \
       HOME="$REAL_HOME" GTG_STATE_DIR="$GTG_STATE_DIR" GTG_CONF_DIR="$GTG_CONF_DIR" \
       ./bin/gtg-interpret --which 2>/dev/null)
is "a reader is resolved with launchd's PATH" \
  "$(printf '%s' "$bare" | grep -c '^/.*claude')" "1"
is "  and it is an absolute path, not a bare name" \
  "$(printf '%s' "${bare%% *}" | cut -c1)" "/"

# A named reader that genuinely is not there says so, rather than going quiet.
reset_plan; rm -f "$GTG_STATE_DIR/nudge.log"
printf 'INTERPRET=nosuchreader\n' >>"$GTG_CONF_DIR/plan.txt"
out=$(env -u GTG_INTERPRET_CMD ./bin/gtg-interpret <<<'sled push x5' 2>&1)
is "an unknown reader name interprets nothing" "$out" ""

echo "== and when the reader is wrong, absent or broken =="
# Every one of these must land on the SAME refusal the tool gave before any of
# this existed. Failing open is the whole safety argument.
reset_plan
./bin/gtg 'sled push x5' >/dev/null 2>"$TMP/e"; is "no reader: refused as before" "$?" "1"
is "  naming the movement" "$(grep -c '^unknown movement: sled push' "$TMP/e")" "1"

reset_plan
STUB_ANSWER='' GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg 'sled push x5' >/dev/null 2>"$TMP/e"; is "an empty answer: refused" "$?" "1"
is "  naming the movement" "$(grep -c '^unknown movement: sled push' "$TMP/e")" "1"

# The one that bit for real: `claude -p` with no credential answers on STDOUT
# and exits 0, so an error message arrived shaped like a movement name.
reset_plan; rm -f "$GTG_STATE_DIR/nudge.log"
STUB_ANSWER='Not logged in - Please run /login' GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg 'sled push x5' >/dev/null 2>"$TMP/e"; is "prose: refused" "$?" "1"
is "  and never offered as a movement" "$(grep -c 'Not logged in' "$TMP/e")" "0"
is "  the original refusal stands" "$(grep -c '^unknown movement: sled push' "$TMP/e")" "1"
is "  and the refusal is written down, not swallowed" \
  "$(grep -c 'interpret: refused' "$GTG_STATE_DIR/nudge.log")" "1"

reset_plan
STUB_ANSWER='x5' GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg 'sled push x5' >/dev/null 2>"$TMP/e"; is "a nameless answer: refused" "$?" "1"

reset_plan
GTG_INTERPRET_TIMEOUT=1 GTG_INTERPRET_CMD='sleep 20' \
  ./bin/gtg 'sled push x5' >/dev/null 2>"$TMP/e"; is "a hang: refused, on time" "$?" "1"
is "  naming the movement" "$(grep -c '^unknown movement: sled push' "$TMP/e")" "1"

# An answer in the right SHAPE naming a movement nobody has: still refused,
# because record_batch validates the model exactly as it validates a person.
reset_plan
STUB_ANSWER='sled push x5' GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg 'shoved the sled five times' >/dev/null 2>"$TMP/e"
is "an invented movement: still refused" "$?" "1"
is "  named as the model read it" "$(grep -c '^unknown movement: sled push' "$TMP/e")" "1"
is "  with the reading shown" "$(grep -c '^read as: sled push x5' "$TMP/e")" "1"
is "  and nothing written" "$(rows)" "0"

# INTERPRET=off means off.
reset_plan; stub_reset
printf 'INTERPRET=off\n' >>"$GTG_CONF_DIR/plan.txt"
unset GTG_INTERPRET_CMD
./bin/gtg 'sled push x5' >/dev/null 2>"$TMP/e"; is "INTERPRET=off: refused" "$?" "1"
is "  and asked nobody" "$(stub_calls)" "0"
export GTG_INTERPRET_CMD=/usr/bin/true

# A spoken round still splits, backdates and takes "not today" for an answer,
# because `gtg say` execs the ordinary path rather than repeating it.
reset_plan
STUB_ANSWER='@7:15 ring dips x5 ; pull-ups x5' GTG_INTERPRET_CMD="$TMP/bin/stub" \
  ./bin/gtg 'at quarter past seven I did five ring dips and five pull ups' \
  >"$TMP/o" 2>"$TMP/e"
is "a spoken round lands as two rows" "$(rows)" "2"
is "  backdated to the time said" \
  "$(head -1 "$GTG_STATE_DIR/log.tsv" | cut -f1)" "$(date '+%Y-%m-%d')T07:15:00"

echo "== every dialog compiles =="
# Compiled, never shown: osacompile checks the syntax and opens nothing. The
# add-a-movement prompt shipped with a syntax error and nobody saw it, because
# osascript's stderr is discarded and its empty answer read as "declined".
# The name carries a double quote so esc() is on the path as well.
title="GTG"; DIALOG_TIMEOUT=900
for d in alert_for other_for new_for; do
  if "$d" 'Bulgarian "split" squats x10' | osacompile -o "$TMP/$d.scpt" 2>"$TMP/$d.err"; then
    ok "$d compiles"
  else
    bad "$d compiles" "$(head -1 "$TMP/$d.err")" "clean compile"
  fi
done
is "the new-movement prompt names it and prefills the line" \
  "$(new_for 'plank' '@7:40 plank 1 min' | grep -c '\\"plank\\" is not a movement I know.*default answer "@7:40 plank 1 min"')" "1"
if new_for 'x' 'a "quoted" line' | osacompile -o "$TMP/new_for2.scpt" 2>"$TMP/new_for2.err"; then
  ok "new_for compiles with a quote in the line"
else
  bad "new_for compiles with a quote in the line" "$(head -1 "$TMP/new_for2.err")" "clean compile"
fi

echo "== readers run clean =="
reset_plan
record_batch 'pull-ups x5' home >/dev/null
# `nudges` must survive an empty nudge log rather than erroring on it.
for c in today week stats options plan nudges status; do
  ./bin/gtg "$c" >/dev/null 2>&1 && ok "gtg $c" || bad "gtg $c" "nonzero" "0"
done
./bin/gtg when 8am >/dev/null 2>&1 && ok "gtg when 8am" || bad "gtg when 8am" "nonzero" "0"
./bin/gtg history 30 >/dev/null 2>&1 && ok "gtg history 30" || bad "gtg history 30" "nonzero" "0"
./bin/gtg-page --no-open >/dev/null 2>&1 && ok "gtg-page" || bad "gtg-page" "nonzero" "0"

echo "== hub ingest =="
# The hub takes rows on stdin and the whole line is the idempotency key.
# A timed set has empty reps and empty weight; IFS=$'\t' read collapses those
# and once slid "home" into the reps column. This must not.
export GTG_NO_CALENDAR=1 GTG_NO_PAGE=1
reset_plan
hang=$'2026-09-01T10:00:00\tdead hang\t\thome\t\t30'
pulls=$'2026-09-01T10:05:00\tpull-ups\t5\thome\t\t'
out=$(printf '%s\n%s\n%s\n' "$hang" "$pulls" "$hang" | ./bin/gtg ingest 2>"$TMP/e")
is "ingest rc" "$?" "0"
is "ingest counts new and duplicate" "$out" "ingested 2, duplicate 1"
is "  two rows kept" "$(rows)" "2"
is "  a timed set keeps its empty fields" \
  "$(awk -F'\t' 'NR==1{printf "%s[%s][%s][%s][%s]", NF, $3, $4, $5, $6}' "$GTG_STATE_DIR/log.tsv")" \
  "6[][home][][30]"
is "  and the bytes are the line we sent" \
  "$(head -1 "$GTG_STATE_DIR/log.tsv")" "$hang"

out=$(printf '%s\n' "$pulls" | ./bin/gtg ingest 2>"$TMP/e")
is "a second send is a duplicate" "$out" "ingested 0, duplicate 1"
is "  and adds no row" "$(rows)" "2"

before=$(cat "$GTG_STATE_DIR/log.tsv")
out=$(printf '%s\n%s\n' 'not-a-row' $'2026-13-01T10:00:00\tpull-ups\t5\thome\t\t' | ./bin/gtg ingest 2>"$TMP/e")
is "malformed lines fail the command" "$?" "1"
is "  and are named" "$(grep -c '^rejected:' "$TMP/e")" "2"
is "  the good rows stay" "$(cat "$GTG_STATE_DIR/log.tsv")" "$before"
is "  summary still prints" "$(printf '%s' "$out" | grep -c 'ingested 0, duplicate 0')" "1"

# One bad line must not throw away a good neighbour.
mixed=$'2026-09-01T11:00:00\tpush-ups\t20\thome\t\t'
out=$(printf '%s\n%s\n' "$mixed" $'only-five\tfields\there\tno\tts' | ./bin/gtg ingest 2>"$TMP/e")
is "a mixed batch fails" "$?" "1"
is "  but keeps the valid row" "$(tail -1 "$GTG_STATE_DIR/log.tsv")" "$mixed"

# Calendar and the page, once per batch, in-process so the overrides are the
# ones that run. Skip rows are not events.
reset_plan
printf 'CALENDAR=Pretend\n' >>"$GTG_CONF_DIR/plan.txt"
: >"$TMP/cal"
page_n=0
calendar_event() { printf '%s\n' "$1" >>"$TMP/cal"; }
refresh_page() { page_n=$((page_n + 1)); }
# Not a pipe: the right-hand side of one runs in a subshell, and the page
# count would stay 0 here no matter what ingest did.
unset GTG_NO_CALENDAR GTG_NO_PAGE
printf '%s\n%s\n' "$pulls" $'2026-09-01T10:06:00\tpull-ups\tskip\thome\t\t' >"$TMP/in"
ingest_rows >/dev/null <"$TMP/in"
i=0
while [ "$i" -lt 40 ] && [ ! -s "$TMP/cal" ]; do sleep 0.05; i=$((i + 1)); done
is "ingest writes the calendar for a real set" "$(wc -l <"$TMP/cal" | tr -d ' ')" "1"
is "  not for a skip" "$(grep -c skip "$TMP/cal")" "0"
is "  and refreshes the page once" "$page_n" "1"
export GTG_NO_CALENDAR=1 GTG_NO_PAGE=1
page_n=0
printf '%s\n' "$hang" >"$TMP/in"
GTG_NO_PAGE=1 ingest_rows >/dev/null <"$TMP/in"
is "GTG_NO_PAGE skips the refresh" "$page_n" "0"
unset -f calendar_event refresh_page
. ./bin/gtg-lib.sh

echo "== hub client =="
# ssh and rsync are stubs. A PATH entry in front of both fails the run if the
# code reaches the real binaries: a test must never open a connection.
GTG_HUB_STATE="$TMP/hub-state"
GTG_HUB_CONF="$TMP/hub-conf"
GTG_SSH_LOG="$TMP/ssh-log"
GTG_SSH_LEAK="$TMP/ssh-leak"
export GTG_HUB_STATE GTG_HUB_CONF GTG_SSH_LOG GTG_SSH_LEAK
export GTG_SSH="$TMP/bin/gtg-ssh" GTG_RSYNC="$TMP/bin/gtg-rsync"
unset GTG_SSH_FAIL GTG_RSYNC_FAIL
cat >"$TMP/bin/gtg-ssh" <<'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift # host
printf '%s\n' "$*" >>"$GTG_SSH_LOG"
[ "${GTG_SSH_FAIL:-}" = 1 ] && exit 1
# A set recorded on the laptop while this send is in flight.
if [ -n "${GTG_SSH_DURING:-}" ]; then
  during=$GTG_SSH_DURING
  (unset GTG_SSH_DURING; bash -c "$during")
fi
export GTG_STATE_DIR="$GTG_HUB_STATE" GTG_CONF_DIR="$GTG_HUB_CONF"
export GTG_NO_CALENDAR=1 GTG_NO_PAGE=1
# If the hub side thinks it is a client, this is the fail-loud ssh, not a network.
export GTG_SSH="$(command -v ssh)"
bash -c "$*"
STUB
cat >"$TMP/bin/gtg-rsync" <<'STUB'
#!/bin/bash
[ "${GTG_RSYNC_FAIL:-}" = 1 ] && { echo "rsync: connection failed" >&2; exit 1; }
prev=""
src=""
dest=""
for a in "$@"; do
  case "$prev" in
    -e) prev=""; continue ;;
  esac
  case "$a" in
    -e) prev=-e; continue ;;
    --timeout=*) continue ;;
    -*) continue ;;
    *) if [ -z "$src" ]; then src=$a; else dest=$a; fi ;;
  esac
done
base=$(basename "${src#*:}")
from="$GTG_HUB_STATE/$base"
if [ ! -f "$from" ]; then
  echo "rsync(1): warning: sender has empty file list: exiting"
  echo "rsync: link_stat \"$base\" failed: No such file or directory (2)" >&2
  exit 23
fi
cp "$from" "$dest"
STUB
cat >"$TMP/bin/ssh" <<'STUB'
#!/bin/bash
echo REALSSH >>"$GTG_SSH_LEAK"
exit 97
STUB
cat >"$TMP/bin/rsync" <<'STUB'
#!/bin/bash
echo REALRSYNC >>"$GTG_SSH_LEAK"
exit 97
STUB
chmod +x "$TMP/bin/gtg-ssh" "$TMP/bin/gtg-rsync" "$TMP/bin/ssh" "$TMP/bin/rsync"
hub_path=$PATH
PATH="$TMP/bin:$PATH"

reset_client() {
  reset_plan
  printf 'HUB=mini\nHUB_GTG=%s\n' "$REPO/bin/gtg" >>"$GTG_CONF_DIR/plan.txt"
  : >"$GTG_STATE_DIR/log.tsv"
  rm -f "$GTG_STATE_DIR/outbox.tsv" "$GTG_STATE_DIR/outbox.sending" "$GTG_STATE_DIR/paused" \
        "$GTG_STATE_DIR/pause.pending" "$GTG_STATE_DIR/nudge.log" "$GTG_SSH_LOG"
  mkdir -p "$GTG_HUB_STATE" "$GTG_HUB_CONF"
  cat >"$GTG_HUB_CONF/plan.txt" <<'P'
WAKE_START=0
WAKE_END=24
every: pull-ups x5 | push-ups x20 | ring dips x5 | farmer walk 1 min
P
  : >"$GTG_HUB_STATE/log.tsv"
  rm -f "$GTG_HUB_STATE/paused"
  unset GTG_SSH_FAIL GTG_RSYNC_FAIL GTG_SSH_DURING
}
queued() { cat "$GTG_STATE_DIR/outbox.tsv" "$GTG_STATE_DIR/outbox.sending" 2>/dev/null; }
# Background flush: the nudge must not wait on ssh, so record() returns before
# the outbox is necessarily empty. Give it a moment, then fail loud.
outbox_clear() {
  local i=0
  while [ "$i" -lt 80 ]; do
    [ -z "$(queued)" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}
noted() {
  local i=0
  while [ "$i" -lt 80 ]; do
    grep -q "$1" "$GTG_STATE_DIR/nudge.log" 2>/dev/null && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# No HUB= line: the mirror outbox does not exist, same as before this feature.
reset_plan
rm -f "$GTG_STATE_DIR/outbox.tsv"
GTG_NO_PAGE=1 record 'pull-ups' 5 home
is "no hub: nothing queued" "$([ -e "$GTG_STATE_DIR/outbox.tsv" ] && echo yes || echo no)" "no"

reset_client
./bin/gtg 'pull-ups x5' >/dev/null
outbox_clear
is "a client set reaches the hub" \
  "$(awk -F'\t' 'NR==1{print $2,$3,$4}' "$GTG_HUB_STATE/log.tsv")" "pull-ups 5 away"
is "  the local mirror has the same row" \
  "$(cat "$GTG_STATE_DIR/log.tsv")" "$(cat "$GTG_HUB_STATE/log.tsv")"
is "  and the outbox is empty" \
  "$([ -s "$GTG_STATE_DIR/outbox.tsv" ] && echo full || echo empty)" "empty"

reset_client
./bin/gtg 'farmer walk 1 min' >/dev/null
outbox_clear
is "a timed set keeps empty fields on the hub" \
  "$(awk -F'\t' '{printf "%s[%s][%s][%s]", NF,$3,$5,$6}' "$GTG_HUB_STATE/log.tsv")" \
  "6[][][60]"

reset_client
export GTG_SSH_FAIL=1
./bin/gtg 'pull-ups x5' >/dev/null
noted 'hub flush failed'
is "a failed flush keeps the row" \
  "$(queued | awk -F'\t' '{print $2}')" "pull-ups"
is "  in the mirror too" "$(awk -F'\t' '{print $2}' "$GTG_STATE_DIR/log.tsv")" "pull-ups"
is "  and not on the hub yet" "$(wc -l <"$GTG_HUB_STATE/log.tsv" | tr -d ' ')" "0"
is "  and says so in the nudge log" \
  "$(grep -c 'hub flush failed' "$GTG_STATE_DIR/nudge.log")" "1"
unset GTG_SSH_FAIL
./bin/gtg flush >/dev/null
is "a later flush delivers it" \
  "$(awk -F'\t' '{print $2}' "$GTG_HUB_STATE/log.tsv")" "pull-ups"
is "  exactly once" "$(wc -l <"$GTG_HUB_STATE/log.tsv" | tr -d ' ')" "1"
is "  and clears the outbox" "$(queued)" ""

# A set recorded while a flush is on the wire must survive that flush.
reset_client
printf '2026-09-30T08:00:00\tpull-ups\t5\thome\t\t\n' >"$GTG_STATE_DIR/outbox.tsv"
export GTG_SSH_DURING="cd '$REPO' && . bin/gtg-lib.sh && GTG_NO_PAGE=1 GTG_AT=2026-09-30T08:05:00 record ring-dips 5 home"
./bin/gtg flush >/dev/null
unset GTG_SSH_DURING
is "a set recorded mid-flush is still queued" "$(queued | awk -F'\t' '{print $2}')" "ring-dips"
./bin/gtg flush >/dev/null
is "  and the next flush delivers both, once each" \
  "$(awk -F'\t' '{print $2}' "$GTG_HUB_STATE/log.tsv" | paste -sd, -)" "pull-ups,ring-dips"

# Pull must not replace the mirror while an unsent row would be thrown away.
reset_client
printf 'local-only\n' >"$GTG_STATE_DIR/log.tsv"
printf 'not yet sent\n' >"$GTG_STATE_DIR/outbox.tsv"
printf 'hub-copy\n' >"$GTG_HUB_STATE/log.tsv"
out=$(./bin/gtg pull 2>"$TMP/e")
is "pull with a full outbox keeps the mirror" "$(cat "$GTG_STATE_DIR/log.tsv")" "local-only"
is "  and says why" "$(printf '%s' "$out" | grep -c 'outbox')" "1"
rm -f "$GTG_STATE_DIR/outbox.tsv" "$GTG_STATE_DIR/outbox.sending"
./bin/gtg pull >/dev/null
is "pull with an empty outbox takes the hub log" "$(cat "$GTG_STATE_DIR/log.tsv")" "hub-copy"

reset_client
is "a client status still starts with where:, not rsync noise" \
  "$(./bin/gtg status 2>/dev/null | head -1 | cut -d: -f1)" "where"

reset_client
printf 'keep-me\n' >"$GTG_STATE_DIR/log.tsv"
printf 'hub-copy\n' >"$GTG_HUB_STATE/log.tsv"
export GTG_RSYNC_FAIL=1
./bin/gtg pull >/dev/null 2>&1
is "a failed pull keeps the stale mirror" "$(cat "$GTG_STATE_DIR/log.tsv")" "keep-me"
is "  and is noted" "$(grep -c 'hub pull failed' "$GTG_STATE_DIR/nudge.log")" "1"
unset GTG_RSYNC_FAIL

reset_client
./bin/gtg off 2h sick >/dev/null
is "pause is forwarded" "$(grep -c 'off 2h sick' "$GTG_SSH_LOG")" "1"
is "  locally" "$([ -s "$GTG_STATE_DIR/paused" ] && echo yes || echo no)" "yes"
is "  and on the hub" "$([ -s "$GTG_HUB_STATE/paused" ] && echo yes || echo no)" "yes"
./bin/gtg on >/dev/null
is "resume is forwarded" "$(grep -c ' on$' "$GTG_SSH_LOG")" "1"
is "  hub pause cleared" "$([ -f "$GTG_HUB_STATE/paused" ] && echo yes || echo no)" "no"
# The local file can already be gone while the hub is still paused. `gtg on`
# still has to say so, or the next pull puts the pause back.
./bin/gtg on >/dev/null
is "a second gtg on still tells the hub" "$(grep -c ' on$' "$GTG_SSH_LOG")" "2"

reset_client
export GTG_SSH_FAIL=1
./bin/gtg off sick >/dev/null
is "a failed forward keeps the local pause" \
  "$([ -s "$GTG_STATE_DIR/paused" ] && echo yes || echo no)" "yes"
is "  and is noted" "$(grep -c 'hub command failed' "$GTG_STATE_DIR/nudge.log")" "1"
is "  hub was not paused" "$([ -f "$GTG_HUB_STATE/paused" ] && echo yes || echo no)" "no"
unset GTG_SSH_FAIL

# The nudge has to see a pause made on the hub before it decides to speak.
# Running gtg-nudge to prove the order is not safe: a miss opens a real
# dialog, and killing osascript leaves the window up. The order is the
# contract; pull itself is asserted above.
order=$(awk '
  /hub_pull/ && !h { h = NR }
  /^if pause_active/ && !a { a = NR }
  END { print (h && a && h < a) ? "before" : "after" }
' bin/gtg-nudge)
is "a nudge pulls before it checks the pause" "$order" "before"

reset_client
# CALENDAR= and a real row, so the refusal is the hub check and not the
# empty-log or missing-calendar exits this command already had.
printf 'CALENDAR=Pretend\n' >>"$GTG_CONF_DIR/plan.txt"
printf '2026-09-01T08:00:00\tpull-ups\t5\taway\t\t\n' >>"$GTG_STATE_DIR/log.tsv"
./bin/gtg calendar-sync >/dev/null 2>"$TMP/e"
is "calendar-sync refuses on a client" "$?" "1"
is "  and says the hub owns it" "$(grep -c 'hub' "$TMP/e")" "1"
./bin/gtg backfill >/dev/null 2>"$TMP/e"
is "backfill refuses on a client" "$?" "1"

# status is what the menu bar parses. The pull is quiet; the first line stays
# `where:`.
reset_client
printf '2026-09-01T08:00:00\tpull-ups\t5\taway\t\t\n' >"$GTG_HUB_STATE/log.tsv"
out=$(./bin/gtg status 2>"$TMP/e")
is "status still leads with where" "$(printf '%s\n' "$out" | head -1 | cut -d: -f1)" "where"
is "  and pulled first" "$(cat "$GTG_STATE_DIR/log.tsv")" "$(cat "$GTG_HUB_STATE/log.tsv")"

is "the suite never called ssh or rsync" \
  "$([ -s "$GTG_SSH_LEAK" ] && cat "$GTG_SSH_LEAK" || echo clean)" "clean"
PATH=$hub_path
reset_plan
rm -f "$GTG_STATE_DIR/outbox.tsv"

echo "== direct to Google Calendar =="
# The ingest block exports this so a scratch plan cannot reach a real
# calendar. Here the calendar is a stub on 127.0.0.1, and the flag would
# turn every write into a silent success.
unset GTG_NO_CALENDAR
# Calendar.app answered "already there?" from its own cache, which lagged
# and duplicated sets. These calls must hit the stub and nothing else.
stub_pid=""
cleanup_suite() {
  if [ -n "${stub_pid:-}" ]; then
    kill "$stub_pid" 2>/dev/null || true
    wait "$stub_pid" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup_suite EXIT

had_tz=0
old_tz=""
if [ -n "${TZ+x}" ]; then had_tz=1; old_tz=$TZ; fi
export TZ=America/New_York
mkdir -p "$TMP/keytmp"
export TMPDIR="$TMP/keytmp"
export GTG_GCAL_LOG="$TMP/gcal-requests.jsonl"
export GTG_GCAL_CONTROL="$TMP/gcal-control.json"
export GTG_GCAL_PORT="$TMP/gcal-port"
export GTG_GCAL_PUB="$TMP/gcal.pub"
export GTG_GCAL_ISS="gtg-test@example.iam.gserviceaccount.com"
: >"$GTG_GCAL_LOG"
gcal_control() {
  /usr/bin/python3 -c '
import json, sys
json.dump({
    "insert_status": int(sys.argv[1]),
    "events": json.loads(sys.argv[2]),
    "ids": json.loads(sys.argv[3]),
}, open(sys.argv[4], "w"))
' "$1" "$2" "$3" "$GTG_GCAL_CONTROL"
}
gcal_n() {
  /usr/bin/python3 -c '
import json, sys
op, path, summary = sys.argv[1], sys.argv[2], sys.argv[3]
n = 0
for line in open(path):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    if row.get("op") != op:
        continue
    if summary and (row.get("body") or {}).get("summary") != summary:
        continue
    n += 1
print(n)
' "$1" "$GTG_GCAL_LOG" "${2:-}"
}
gcal_ops() {
  /usr/bin/python3 -c '
import json, sys
ops = []
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    ops.append(json.loads(line).get("op", ""))
print(" ".join(ops))
' "$GTG_GCAL_LOG"
}
gcal_field() {
  /usr/bin/python3 -c '
import json, sys
summary, field, path = sys.argv[1], sys.argv[2], sys.argv[3]
for line in open(path):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    if row.get("op") != "insert":
        continue
    body = row.get("body") or {}
    if body.get("summary") != summary:
        continue
    if field == "status":
        print(row.get("status", ""))
        sys.exit(0)
    cur = body
    for part in field.split("."):
        if not isinstance(cur, dict):
            cur = ""
            break
        cur = cur.get(part, "")
    print(cur if cur is not None else "")
    sys.exit(0)
' "$1" "$2" "$GTG_GCAL_LOG"
}
gcal_listq() {
  /usr/bin/python3 -c '
import json, sys
key, path, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
seen = 0
for line in open(path):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    if row.get("op") != "list":
        continue
    if seen == n:
        print((row.get("query") or {}).get(key, ""))
        sys.exit(0)
    seen += 1
' "$1" "$GTG_GCAL_LOG" "$2"
}
gcal_id() {
  /usr/bin/python3 -c '
import hashlib, sys
raw = "%s\t%s\t%s" % (sys.argv[1], sys.argv[2], sys.argv[3])
print("gtg" + hashlib.sha1(raw.encode("utf-8")).hexdigest())
' "$1" "$2" "$3"
}
gcal_window() {
  /usr/bin/python3 -c '
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
import sys
iso, which = sys.argv[1], sys.argv[2]
start = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%S").replace(second=0, microsecond=0)
start = start.replace(tzinfo=ZoneInfo("America/New_York"))
# Same exclusive-bound adjustment as minute_bounds in bin/gtg-gcal.
begin = start - timedelta(seconds=1)
end = start + timedelta(seconds=60)
print(begin.isoformat() if which == "min" else end.isoformat())
' "$1" "$2"
}
gcal_call() {
  ./bin/gtg-gcal "$1" "$2" "$3" >"$TMP/gcal.out" 2>"$TMP/gcal.err"
  gcal_rc=$?
  gcal_out=$(cat "$TMP/gcal.out")
}
sys_zone() {
  /usr/bin/python3 -c '
import os
p = os.path.realpath("/etc/localtime")
mark = "zoneinfo/"
i = p.find(mark)
print(p[i + len(mark):] if i >= 0 else "")
'
}

cat >"$TMP/gcal-stub.py" <<'GCALSTUB'
#!/usr/bin/python3
import base64
import json
import os
import subprocess
import tempfile
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, unquote, urlparse
from zoneinfo import ZoneInfo

STORED = {}


def aware(text, tzname):
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None and tzname:
        dt = dt.replace(tzinfo=ZoneInfo(tzname))
    return dt


def listed(ev, time_min, time_max):
    start = ev.get("start") if isinstance(ev, dict) else None
    end = ev.get("end") if isinstance(ev, dict) else None
    if not isinstance(start, dict):
        return False
    s = start.get("dateTime") or ""
    e = (end or {}).get("dateTime") if isinstance(end, dict) else ""
    e = e or s
    if not s or not e:
        return False
    tzname = start.get("timeZone") or (end.get("timeZone") if isinstance(end, dict) else "") or ""
    try:
        start_dt = aware(s, tzname)
        end_dt = aware(e, tzname)
        if time_min and not (end_dt > aware(time_min, "")):
            return False
        if time_max and not (start_dt < aware(time_max, "")):
            return False
    except (ValueError, TypeError):
        return False
    return True


def log(obj):
    with open(os.environ["GTG_GCAL_LOG"], "a", encoding="utf-8") as fh:
        fh.write(json.dumps(obj) + "\n")


def control():
    try:
        with open(os.environ["GTG_GCAL_CONTROL"], "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
    return data if isinstance(data, dict) else {}


def b64decode(seg):
    pad = "=" * ((4 - len(seg) % 4) % 4)
    return base64.urlsafe_b64decode(seg + pad)


def verify_jwt(token, aud):
    parts = token.split(".")
    if len(parts) != 3:
        return "not three parts"
    try:
        header = json.loads(b64decode(parts[0]).decode("utf-8"))
        payload = json.loads(b64decode(parts[1]).decode("utf-8"))
        sig = b64decode(parts[2])
    except (ValueError, TypeError):
        return "undecodable"
    if not isinstance(header, dict) or header.get("alg") != "RS256":
        return "alg"
    signed = (parts[0] + "." + parts[1]).encode("ascii")
    fd, sigpath = tempfile.mkstemp(prefix="gtg-stub-sig-")
    try:
        os.write(fd, sig)
        os.close(fd)
        fd = -1
        proc = subprocess.run(
            ["/usr/bin/openssl", "dgst", "-sha256", "-verify",
             os.environ["GTG_GCAL_PUB"], "-signature", sigpath],
            input=signed, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.remove(sigpath)
        except OSError:
            pass
    if proc.returncode != 0:
        return "bad signature"
    if not isinstance(payload, dict):
        return "payload"
    if payload.get("iss") != os.environ["GTG_GCAL_ISS"]:
        return "iss"
    if payload.get("scope") != "https://www.googleapis.com/auth/calendar.events":
        return "scope"
    if payload.get("aud") != aud:
        return "aud"
    iat, exp = payload.get("iat"), payload.get("exp")
    if iat.__class__ is not int or exp.__class__ is not int:
        return "iat type"
    if exp != iat + 3600:
        return "exp"
    return ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def body_bytes(self):
        n = int(self.headers.get("Content-Length") or "0")
        if n <= 0:
            return b""
        return self.rfile.read(n)

    def send_json(self, code, obj):
        raw = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def route(self, method):
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        raw = self.body_bytes()
        if path == "/token" and method == "POST":
            self.token(raw)
            return
        prefix = "/calendar/v3/calendars/"
        if path.startswith(prefix) and path.endswith("/events"):
            if method == "GET":
                self.events_list(parsed)
            elif method == "POST":
                self.events_insert(raw)
            else:
                self.send_json(405, {"error": {"message": "method"}})
            return
        log({"op": "unknown", "method": method, "path": path})
        self.send_json(404, {"error": {"message": "not found"}})

    def token(self, raw):
        form = parse_qs(raw.decode("utf-8"))
        assertion = (form.get("assertion") or [""])[0]
        grant = (form.get("grant_type") or [""])[0]
        host, port = self.server.server_address
        aud = "http://%s:%s/token" % (host, port)
        if grant != "urn:ietf:params:oauth:grant-type:jwt-bearer":
            log({"op": "token", "ok": False, "why": "grant"})
            self.send_json(400, {"error": "unsupported_grant_type"})
            return
        why = verify_jwt(assertion, aud)
        if why:
            log({"op": "token", "ok": False, "why": why})
            self.send_json(401, {"error": "invalid_grant", "error_description": why})
            return
        log({"op": "token", "ok": True})
        self.send_json(200, {
            "access_token": "ya29.gtg-stub-token",
            "expires_in": 3600,
            "token_type": "Bearer",
        })

    def events_list(self, parsed):
        flat = {}
        for key, vals in parse_qs(parsed.query).items():
            flat[key] = vals[0] if vals else ""
        log({"op": "list", "query": flat})
        cfg = control()
        items = list(cfg.get("events") or [])
        items.extend(STORED.values())
        # Google's timeMin is exclusive on the event end, timeMax exclusive
        # on the event start. A zero-minute event is invisible if timeMin
        # sits on its start.
        items = [ev for ev in items if listed(ev, flat.get("timeMin", ""), flat.get("timeMax", ""))]
        self.send_json(200, {"items": items})

    def events_insert(self, raw):
        try:
            body = json.loads(raw.decode("utf-8"))
        except ValueError:
            body = {}
        if not isinstance(body, dict):
            body = {}
        cfg = control()
        try:
            status = int(cfg.get("insert_status") or 200)
        except (TypeError, ValueError):
            status = 200
        eid = body.get("id") or ""
        known = set(cfg.get("ids") or [])
        known.update(STORED.keys())
        if status >= 400 and status != 409:
            log({"op": "insert", "status": status, "body": body})
            self.send_json(status, {"error": {"code": status, "message": "stub broke"}})
            return
        if eid in known:
            log({"op": "insert", "status": 409, "body": body})
            self.send_json(409, {"error": {
                "code": 409,
                "message": "The requested identifier already exists.",
            }})
            return
        STORED[eid] = body
        log({"op": "insert", "status": 200, "body": body})
        self.send_json(200, body)


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(os.environ["GTG_GCAL_PORT"], "w", encoding="utf-8") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
GCALSTUB

gcal_control 200 '[]' '[]'
openssl genrsa -out "$TMP/gcal.pkcs1" 2048 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "$TMP/gcal.pkcs1" -out "$TMP/gcal.key"
openssl rsa -in "$TMP/gcal.key" -pubout -out "$TMP/gcal.pub" 2>/dev/null
/usr/bin/python3 "$TMP/gcal-stub.py" >"$TMP/gcal-stub.out" 2>"$TMP/gcal-stub.err" &
stub_pid=$!
i=0
while [ ! -s "$TMP/gcal-port" ]; do
  if ! kill -0 "$stub_pid" 2>/dev/null; then
    break
  fi
  i=$((i + 1))
  [ "$i" -gt 50 ] && break
  sleep 0.05
done
port=$(cat "$TMP/gcal-port" 2>/dev/null || true)
if [ -z "$port" ]; then
  bad "gcal stub started" "$(head -1 "$TMP/gcal-stub.err" 2>/dev/null)" "a port"
else
  ok "gcal stub started"
  export GTG_GCAL_API="http://127.0.0.1:$port/calendar/v3"
  export GTG_GCAL_ID=gtg-test
  /usr/bin/python3 -c '
import json, sys
pem = open(sys.argv[1], encoding="utf-8").read()
json.dump({
    "type": "service_account",
    "client_email": "gtg-test@example.iam.gserviceaccount.com",
    "private_key": pem,
    "token_uri": sys.argv[2],
}, open(sys.argv[3], "w", encoding="utf-8"))
' "$TMP/gcal.key" "http://127.0.0.1:$port/token" "$GTG_CONF_DIR/gcal-key.json"
  chmod 600 "$GTG_CONF_DIR/gcal-key.json"
  reset_plan
  printf 'GCAL_ID=gtg-test\n' >>"$GTG_CONF_DIR/plan.txt"

  summary="pull-ups x5"
  iso="2026-09-03T11:52:00"
  where="home"
  eid=$(gcal_id "$summary" "$iso" "$where")
  old_umask=$(umask)
  umask 000
  gcal_call "$summary" "$iso" "$where"
  umask "$old_umask"
  is "a set is written" "$gcal_rc" "0"
  is "  and says so" "$gcal_out" "written"
  is "  success stays off stderr" "$(cat "$TMP/gcal.err")" ""
  is "  under the deterministic id" "$(gcal_field "$summary" id)" "$eid"
  is "  with the summary" "$(gcal_field "$summary" summary)" "$summary"
  is "  at the set's own time" "$(gcal_field "$summary" start.dateTime)" "$iso"
  is "  and the end is the same instant" "$(gcal_field "$summary" end.dateTime)" "$iso"
  is "  in the zone TZ names" "$(gcal_field "$summary" start.timeZone)" "America/New_York"
  is "  on both ends" "$(gcal_field "$summary" end.timeZone)" "America/New_York"
  is "  location is where it happened" "$(gcal_field "$summary" location)" "$where"
  is "  description matches the AppleScript event" "$(gcal_field "$summary" description)" "$where"
  is "list covers that minute" "$(gcal_listq timeMin 0)" "$(gcal_window "$iso" min)"
  is "  and the next 60 seconds" "$(gcal_listq timeMax 0)" "$(gcal_window "$iso" max)"
  is "  as single events" "$(gcal_listq singleEvents 0)" "true"
  is "the private key is not left on disk" "$(ls -A "$TMP/keytmp" | wc -l | tr -d ' ')" "0"
  is "the token cache is mode 0600" "$(stat -f %Lp "$GTG_STATE_DIR/gcal-token.json" 2>/dev/null || echo missing)" "600"
  is "stderr never contains the token" "$(grep -c 'ya29' "$TMP/gcal.err" || true)" "0"
  is "  or the private key" "$(grep -c 'PRIVATE KEY' "$TMP/gcal.err" || true)" "0"

  gcal_call "$summary" "$iso" "$where"
  is "the same set again exits 0" "$gcal_rc" "0"
  is "  says it already exists" "$gcal_out" "exists"
  is "  and does not insert again" "$(gcal_n insert "$summary")" "1"
  is "  reusing the cached token" "$(gcal_ops)" "token list insert list"

  exp_soon=$(/usr/bin/python3 -c 'import time; print(int(time.time()) + 30)')
  printf '{"access_token":"ya29.stale","expiry":%s}\n' "$exp_soon" \
    >"$GTG_STATE_DIR/gcal-token.json"
  chmod 600 "$GTG_STATE_DIR/gcal-token.json"
  gcal_call "$summary" "$iso" "$where"
  is "a token inside 60s of expiry is refreshed" "$(gcal_n token)" "2"

  gcal_control 200 '[{"id":"randomappleid","summary":"dead hang 30s","start":{"dateTime":"2026-09-03T08:15:00","timeZone":"America/New_York"},"end":{"dateTime":"2026-09-03T08:15:00","timeZone":"America/New_York"}}]' '[]'
  gcal_call "dead hang 30s" "2026-09-03T08:15:00" "away"
  is "a random-id event with the same summary is a skip" "$gcal_rc" "0"
  is "  reported as already there" "$gcal_out" "exists"
  is "  and nothing is inserted for it" "$(gcal_n insert "dead hang 30s")" "0"

  summary3="push-ups x20"
  iso3="2026-09-03T09:00:00"
  where3="home"
  eid3=$(gcal_id "$summary3" "$iso3" "$where3")
  gcal_control 200 '[]' "[\"$eid3\"]"
  : >"$GTG_STATE_DIR/nudge.log"
  gcal_call "$summary3" "$iso3" "$where3"
  is "an insert conflict is success" "$gcal_rc" "0"
  is "  and says exists" "$gcal_out" "exists"
  is "  after the insert came back 409" "$(gcal_field "$summary3" status)" "409"
  calendar_event "$summary3" "$iso3" "$where3"
  is "  calendar_event treats 409 as written" "$?" "0"
  is "  with no failure note" "$(grep -c 'calendar write failed' "$GTG_STATE_DIR/nudge.log" || true)" "0"

  unset TZ
  zone=$(sys_zone)
  gcal_control 200 '[]' '[]'
  gcal_call "stairs, 2 flights" "2026-09-04T06:00:00" "away"
  is "with TZ unset the zone is /etc/localtime" \
    "$(gcal_field "stairs, 2 flights" start.timeZone)" "$zone"
  export TZ=America/New_York

  summary4="farmer walk 1 min"
  iso4="2026-09-03T10:00:00"
  where4="home"
  gcal_control 500 '[]' '[]'
  gcal_call "$summary4" "$iso4" "$where4"
  is "a 500 is a failure" "$gcal_rc" "1"
  is "  named by status and Google's message" "$(cat "$TMP/gcal.err")" "500 stub broke"
  is "  on one line" "$(wc -l <"$TMP/gcal.err" | tr -d ' ')" "1"
  is "  and the token is not in it" "$(grep -c 'ya29' "$TMP/gcal.err" || true)" "0"
  is "  nor the key" "$(grep -c 'PRIVATE KEY' "$TMP/gcal.err" || true)" "0"
  : >"$GTG_STATE_DIR/nudge.log"
  calendar_event "$summary4" "$iso4" "$where4"
  is "calendar_event records the failed write" "$?" "1"
  is "  in the nudge log" "$(grep -c 'calendar write failed' "$GTG_STATE_DIR/nudge.log")" "1"
  is "  with the status" "$(grep -c '500 stub broke' "$GTG_STATE_DIR/nudge.log")" "1"
  is "  and still no token" "$(grep -c 'ya29' "$GTG_STATE_DIR/nudge.log" || true)" "0"
  is "the key file was not copied into the private-key dir" \
    "$(ls -A "$TMP/keytmp" | wc -l | tr -d ' ')" "0"

  gcal_control 200 '[]' '[]'
  reset_plan
  printf 'GCAL_ID=gtg-test\n' >>"$GTG_CONF_DIR/plan.txt"
  day=$(TZ=America/New_York date '+%Y-%m-%dT12:34:56')
  printf '%s\tring dips\t5\thome\t\t\n' "$day" >>"$GTG_STATE_DIR/log.tsv"
  out=$(./bin/gtg calendar-sync 2>"$TMP/e")
  rc=$?
  is "calendar-sync runs with GCAL_ID and no CALENDAR" "$rc" "0"
  is "  and prints the calendar id" \
    "$(printf '%s\n' "$out" | grep -c '1 set(s) on calendar "gtg-test"')" "1"
  is "  by inserting that set" "$(gcal_n insert "ring dips x5")" "1"
  out=$(./bin/gtg calendar-sync 2>"$TMP/e")
  rc=$?
  is "a second calendar-sync is idempotent" "$rc" "0"
  is "  and still counts the set" \
    "$(printf '%s\n' "$out" | grep -c '1 set(s) on calendar "gtg-test"')" "1"
  is "  without inserting it again" "$(gcal_n insert "ring dips x5")" "1"
fi

if [ -n "${stub_pid:-}" ]; then
  kill "$stub_pid" 2>/dev/null || true
  wait "$stub_pid" 2>/dev/null || true
  stub_pid=""
fi
unset GTG_GCAL_API GTG_GCAL_ID GTG_GCAL_LOG GTG_GCAL_CONTROL GTG_GCAL_PORT GTG_GCAL_PUB GTG_GCAL_ISS TMPDIR
if [ "$had_tz" -eq 1 ]; then export TZ="$old_tz"; else unset TZ; fi
reset_plan

echo "== isolation: nothing live was touched =="
# Content comparison, not mtime: an mtime threshold moves whenever the suite
# creates a file, which can hide a write that happened before it.
mutated=0
while IFS=$'\t' read -r f want; do
  now=$(md5 -q "$f" 2>/dev/null || echo ABSENT)
  [ "$now" = "$want" ] || { mutated=$((mutated+1)); echo "         MUTATED: $f"; }
done <"$LIVE"
is "live log, page, stamp, plan, key and token all unchanged" "$mutated" "0"

# 03:00 on the spring-forward morning: one second earlier does not exist in
# local time, and a window built there came out backwards.
dst_ok() {
  /usr/bin/python3 - "$REPO/bin/gtg-gcal" "$1" <<'PY'
import sys, importlib.machinery, importlib.util
from datetime import datetime
loader = importlib.machinery.SourceFileLoader("gcal", sys.argv[1])
spec = importlib.util.spec_from_loader("gcal", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
b, e = m.minute_bounds(sys.argv[2], "America/New_York")
print("ordered" if datetime.fromisoformat(b) < datetime.fromisoformat(e) else "backwards")
PY
}
is "the list window is ordered at spring-forward 03:00" "$(dst_ok 2026-03-08T03:00:00)" "ordered"
is "  and at fall-back 01:30" "$(dst_ok 2026-11-01T01:30:00)" "ordered"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
bash test/server.sh && [ "$fail" -eq 0 ]
