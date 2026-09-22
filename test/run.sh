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
