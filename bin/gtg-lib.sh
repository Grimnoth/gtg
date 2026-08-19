#!/bin/bash
# Shared by gtg-nudge and gtg. Not executable on its own.

# Overridable so the tool can be exercised against a scratch log instead of
# your real one. Without this a test run of anything that WRITES -- `backfill`
# above all -- has no choice but to touch the live log.
CONF_DIR="${GTG_CONF_DIR:-$HOME/.config/gtg}"
STATE_DIR="${GTG_STATE_DIR:-$HOME/.local/state/gtg}"
PLAN="$CONF_DIR/plan.txt"
HOME_MAC_FILE="$CONF_DIR/home-gateway-mac"
STAMP="$STATE_DIR/last-nudge"
LOG="$STATE_DIR/log.tsv"
NUDGE_LOG="$STATE_DIR/nudge.log"

# 40 min, against fires 30 min apart -- so answering one nudge suppresses the
# next slot and the felt cadence is about an hour, which is the point of the
# whole tool. It also absorbs the burst launchd emits when it replays every
# slot missed while the Mac slept.
#
# Shared rather than living in gtg-nudge, because `gtg nudges` reports when the
# next nudge becomes possible and must use the same number.
DEBOUNCE_SECS=2400

mkdir -p "$STATE_DIR" "$CONF_DIR"

# Read a KEY=value line from plan.txt. Trims the ends but keeps inner spaces,
# because calendar names contain them.
cfg() {
  [ -r "$PLAN" ] || return 0
  sed -n "s/^$1=//p" "$PLAN" | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# The movement key, as an awk fragment shared by every bash reader.
#
# A movement is a NAME. Reps, weight and duration are separate columns, so they
# are stripped here: "farmer walk 1 min" and "farmer walk 2 min @ 100 lb" are
# the same movement at different settings, not two exercises. New rows arrive
# already clean, so the stripping is really a shim for rows written before the
# weight/duration columns existed.
#
# ponytail: this is now single-sourced across the bash readers (rotate_options,
# canon_piece, `gtg stats`). Only norm_ex() in bin/gtg-page, which is Python,
# is still a hand-synced twin -- keep the two in step.
AWK_KEY='
  function key(s) {
    s = tolower(s)
    gsub(/[0-9]+(\.[0-9]+)?[ \t]*(lbs?|kgs?|#)/, " ", s)
    gsub(/[0-9]+(\.[0-9]+)?[ \t]*(minutes?|mins?|seconds?|secs?)/, " ", s)
    gsub(/[0-9]+[ \t]*s([^a-z]|$)/, " ", s)
    gsub(/[ \t]+(total|each|per hand|with|of)([ \t]|$)/, " ", s)
    # Anywhere, not anchored at the end. Once decorate_weights appends
    # "@ 50 lb", the count is no longer last, and an end-anchored strip left
    # "kettlebellswingsx10" -- which never matched the "kettlebellswing" the
    # same set was logged under, so rotation read the movement as never done.
    gsub(/[ \t]*[xX][0-9]+([ \t]|$)/, " ", s)
    gsub(/@/, " ", s)
    sub(/[ \t]+[0-9]+[ \t]*$/, "", s)
    sub(/^[0-9]+[ \t]+/, "", s)
    gsub(/[^a-z0-9]/, "", s)
    sub(/s$/, "", s)
    return s
  }
'

# Render reps/weight/duration back onto a name for display, the same shape they
# are typed in, so the log and the screen cannot drift apart.
AWK_HUMAN='
  function human(reps, wt, dur,   o, w) {
    o = ""
    if (reps != "" && reps != "skip") o = o " x" reps
    if (dur != "") o = o " " ((dur >= 60 && dur % 60 == 0) ? int(dur / 60) " min" : dur "s")
    if (wt != "") { w = wt; sub(/[0-9.]+/, "& ", w); o = o " @ " w }
    return o
  }
'

# The spelling to SHOW for a movement: same strippings, case and spacing kept.
AWK_CLEAN='
  function clean(s) {
    gsub(/[0-9]+(\.[0-9]+)?[ \t]*([Ll][Bb][Ss]?|[Kk][Gg][Ss]?|#)/, " ", s)
    gsub(/[0-9]+(\.[0-9]+)?[ \t]*([Mm][Ii][Nn][A-Za-z]*|[Ss][Ee][Cc][A-Za-z]*)/, " ", s)
    gsub(/[ \t]+([Tt][Oo][Tt][Aa][Ll]|[Ee][Aa][Cc][Hh])([ \t]|$)/, " ", s)
    gsub(/[0-9]+[ \t]*[sS]([^A-Za-z]|$)/, " ", s)
    # Anywhere, not end-anchored -- same reason as in key(). Left anchored,
    # the plan entry "sled push x5 @ 90 lb" cleaned to "sled push x5", which
    # then rendered as "sled push x5 x5".
    gsub(/[ \t]*[xX][0-9]+([ \t]|$)/, " ", s)
    sub(/^[0-9]+[ \t]+/, "", s)
    sub(/[ \t]+[0-9]+[ \t]*$/, "", s)
    # "@" goes, the comma stays: a comma is part of names you actually use,
    # such as the shipped "stairs, 2 flights".
    gsub(/[ \t]+-[ \t]+/, " ", s); gsub(/@/, " ", s)
    gsub(/[ \t]+(total|each|per hand|with|of)[ \t]*$/, "", s)
    gsub(/^[ \t]+|[ \t]+$/, "", s); gsub(/[ \t]+/, " ", s)
    return s
  }
'

# MAC address of the default gateway, or nothing.
#
# This is the home/away test. Deliberately NOT the wifi SSID: reading the SSID
# needs a Location Services grant on macOS 14+, and it returns nothing at all
# when on ethernet, which is how this machine is usually docked. The gateway MAC
# is unique per router, needs no permission, and behaves the same on both.
current_gateway_mac() {
  local gw mac
  gw=$(/sbin/route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
  [ -n "$gw" ] || return 1
  mac=$(/usr/sbin/arp -n "$gw" 2>/dev/null | awk '{print $4; exit}')
  # An unresolved ARP entry prints "(incomplete)" -- only accept a real MAC.
  case "$mac" in
    *:*:*:*:*:*) printf '%s' "$mac" ;;
    *) return 1 ;;
  esac
}

# Echoes "home" or "away".
#
# The file holds one gateway MAC per line, not just one, so a second house, an
# office, or a replaced router can all count as "home". `gtg home` appends the
# network you are on now.
where_am_i() {
  local cur
  cur=$(current_gateway_mac || true)
  if [ -n "$cur" ] && [ -s "$HOME_MAC_FILE" ] && grep -qxF "$cur" "$HOME_MAC_FILE" 2>/dev/null; then
    printf 'home'
  else
    printf 'away'
  fi
}

# True when a nudge may fire in the given hour. Sets WAKE_S / WAKE_E to the
# bounds it used, so a caller can name them in its log line.
#
# WAKE_END is EXCLUSIVE, and that is the whole point. "Nothing at or after 9pm"
# is written WAKE_END=21, and the last fire lands at 20:50. Read inclusively,
# 21 would have let 21:20 and 21:50 through -- an hour past what the number
# looks like. WAKE_START stays inclusive, so 9 permits the 9:20 fire.
#
# Split out of gtg-nudge so both sides of the boundary can be tested without
# reaching the part of that script that opens a dialog.
in_waking_window() {
  WAKE_S=$(cfg WAKE_START); WAKE_S=${WAKE_S:-9}
  WAKE_E=$(cfg WAKE_END);   WAKE_E=${WAKE_E:-21}
  [ "$1" -ge "$WAKE_S" ] && [ "$1" -lt "$WAKE_E" ]
}

# One plan line by key, options still "|" separated.
plan_line() { sed -n "s/^$1:[[:space:]]*//p" "$PLAN" 2>/dev/null | head -1; }

# The options on offer right now, one per line.
#
# "every:" is the core pool and is offered every single day. A weekday line only
# ADDS to it. Grease-the-groove is one or two movements hit often, not a weekly
# split, so gating a movement behind its assigned day is exactly backwards --
# it hides the thing you are trying to accumulate volume in.
today_options() {
  local where="$1" dow
  dow=$(date +%a | tr '[:upper:]' '[:lower:]')
  {
    if [ "$where" = home ]; then
      plan_line every
      plan_line "$dow"
    else
      plan_line away
    fi
  } \
    | tr '|' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' \
    | awk '!seen[$0]++' \
    | rotate_options \
    | decorate_weights
}

# Append the remembered weight to any option that does not name one, so the
# picker reads "kettlebell swings x10 @ 50 lb" and "Did it" logs the weight
# without a word typed. The decorated string round-trips: parse_piece takes
# the "@ 50 lb" back off when the row is written.
decorate_weights() {
  local opt wt
  while IFS= read -r opt; do
    read_piece "$opt"
    if [ -z "$P_WT" ]; then
      wt=$(last_weight_for "$P_NAME")
      [ -n "$wt" ] && opt="$opt @ $(fmt_wt "$wt")"
    fi
    printf '%s\n' "$opt"
  done
}

# Reorder the pool so the movement you have neglected longest comes first.
#
# Rotation is derived from the log, not from a fixed schedule: fewest sets
# TODAY wins, ties broken by whichever went longest since it was last done,
# and anything never done at all sorts to the front. The effect is that the
# preselected item is nearly always the right answer, so a nudge stays one
# click rather than a menu to deliberate over.
#
# Matching is on the movement name with the count stripped and the spelling
# squeezed, so "ring dips x5" in the plan still matches "5 ring dips" typed
# into Other..., and "Pushups", "push-ups" and "push ups" are one movement.
rotate_options() {
  if [ ! -s "$LOG" ]; then cat; return; fi
  awk -F'\t' -v today="$(date '+%Y-%m-%d')" "$AWK_KEY"'
    FNR == NR {
      if ($3 != "skip" && $2 != "") {
        k = key($2)
        if ($1 > last[k]) last[k] = $1
        if (substr($1, 1, 10) == today) n[k]++
      }
      next
    }
    {
      k = key($0)
      printf "%d\t%s\t%03d\t%s\n", (k in n ? n[k] : 0), (k in last ? last[k] : "0"), FNR, $0
    }
  ' "$LOG" - \
    | sort -t"$(printf '\t')" -k1,1n -k2,2 -k3,3n \
    | cut -f4
}

# Just the first option, for logging and for one-line summaries.
primary_option() {
  local first
  first=$(today_options "$1" | head -1)
  printf '%s' "${first:-do a quick set}"
}

# The rep count in a line, wherever it sits. Free text arrives in every shape:
# "pull-ups x5", "5 ring dips", "ring dips 5".
reps_from_line() {
  local s="$1" n
  # 1. An explicit "xN" is unambiguous, so it wins outright.
  n=$(printf '%s' "$s" | sed -n 's/.*[[:space:]]x\([0-9]\{1,\}\).*/\1/p')
  # 2. A bare number at the end: "ring dips 12".
  [ -n "$n" ] || n=$(printf '%s' "$s" | sed -n 's/.*[^0-9]\([0-9]\{1,\}\)[[:space:]]*$/\1/p')
  # 3. A leading number: "12 ring dips" -- but not when it introduces a
  #    duration ("2 min walk", "30 sec hang"), which is a time, not a count.
  if [ -z "$n" ] \
     && ! printf '%s' "$s" | grep -qiE '^[0-9]+[[:space:]]*(m|s|min|sec|minute|second)'; then
    n=$(printf '%s' "$s" | sed -n 's/^\([0-9]\{1,\}\)[[:space:]].*/\1/p')
  fi
  printf '%s' "$n"
}

# Pull the four separable facts out of one free-text movement report, printed
# as four LINES: name, reps, weight, duration_seconds.
#
# Four lines rather than one tab-separated line on purpose. Tab is an IFS
# whitespace character, so `IFS=$'\t' read a b c d` silently collapses a run of
# empty fields into one -- and an empty reps (a timed carry has none) would
# slide the weight into the reps slot and the duration into the weight slot.
# Line-per-field has no such rule; an empty line stays an empty field.
#
# Everything Ben types arrives in a different shape -- "pull-ups x5", "5 ring
# dips", "Farmer Walk 1 minute - 100 lbs total", "50 lb kettlebell swings x10"
# -- and burying any of it in the NAME forks a new exercise every time a number
# changes. So each fact gets lifted out and the name is whatever is left.
#
# Weight normalizes to <number><unit> (100lb, 24kg); duration to seconds, so
# "1 minute", "1 min" and "60s" are one value. A bare "@ 50" assumes pounds.
#
# Two traps, both live in the tidy-up at the end: only a SPACED hyphen is a
# separator, because "pull-ups" must keep its own, and "@" has to go or
# "swings x10 @ 50 lb" leaves a dangling "@" in the name.
# The parser itself, as an awk fragment, so the row rewriter in `gtg backfill`
# can reuse it instead of splitting the TSV in bash -- which would hit the very
# tab-collapse trap described above. Sets PN/PR/PW/PD.
AWK_PARSE='
    function parse(s,   w, d, r, t, u) {
      w = ""; d = ""; r = ""
      if (match(s, /[0-9]+(\.[0-9]+)?[ \t]*([Ll][Bb][Ss]?|[Kk][Gg][Ss]?|#)/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s,1,RSTART-1) " " substr(s,RSTART+RLENGTH)
        u = (tolower(t) ~ /kg/) ? "kg" : "lb"; gsub(/[^0-9.]/, "", t); w = t u
      } else if (match(s, /@[ \t]*[0-9]+(\.[0-9]+)?/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s,1,RSTART-1) " " substr(s,RSTART+RLENGTH)
        gsub(/[^0-9.]/, "", t); w = t "lb"
      }
      # "min" spelled out, never a bare "m": in exercise text "400m" is metres
      # far more often than minutes, and reading it as minutes silently logged a
      # 6.7 hour sprint. A bare "s" stays -- "30s" has no such rival.
      if (match(s, /[0-9]+(\.[0-9]+)?[ \t]*([Mm][Ii][Nn][Uu][Tt][Ee][Ss]?|[Mm][Ii][Nn][Ss]?)([^a-zA-Z]|$)/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s,1,RSTART-1) " " substr(s,RSTART+RLENGTH)
        gsub(/[^0-9.]/, "", t); d = int(t * 60)
      } else if (match(s, /[0-9]+(\.[0-9]+)?[ \t]*([Ss][Ee][Cc][Oo][Nn][Dd][Ss]?|[Ss][Ee][Cc][Ss]?|[Ss])([^a-zA-Z]|$)/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s,1,RSTART-1) " " substr(s,RSTART+RLENGTH)
        gsub(/[^0-9.]/, "", t); d = int(t)
      }
      if (match(s, /[xX][0-9]+/)) {
        t=substr(s,RSTART,RLENGTH); s=substr(s,1,RSTART-1) " " substr(s,RSTART+RLENGTH)
        gsub(/[^0-9]/,"",t); r=t
      } else if (match(s, /^[ \t]*[0-9]+[ \t]/)) {
        t=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH); gsub(/[^0-9]/,"",t); r=t
      } else if (match(s, /[ \t][0-9]+[ \t]*$/)) {
        t=substr(s,RSTART,RLENGTH); s=substr(s,1,RSTART-1); gsub(/[^0-9]/,"",t); r=t
      }
      gsub(/[ \t]+-[ \t]+/, " ", s); gsub(/@/, " ", s)
      gsub(/[ \t]+([Tt][Oo][Tt][Aa][Ll]|[Ee][Aa][Cc][Hh]|[Pp]er hand|[Ww][Ii][Tt][Hh]|[Oo][Ff])[ \t]*$/, "", s)
      gsub(/[ \t]+[xX][ \t]*$/, "", s)   # a count taken away can leave its "x"
      gsub(/^[ \t]+|[ \t]+$/, "", s); gsub(/[ \t]+/, " ", s)
      PN = s; PR = r; PW = w; PD = d
    }
'

parse_piece() {
  printf '%s\n' "$1" | awk "$AWK_PARSE"'
    { parse($0); printf "%s\n%s\n%s\n%s\n", PN, PR, PW, PD }'
}

# Read parse_piece's four lines into four named variables.
read_piece() {
  { IFS= read -r P_NAME; IFS= read -r P_REPS; IFS= read -r P_WT; IFS= read -r P_DUR; } \
    < <(parse_piece "$1") || true
}

# The weight to assume for a movement, or nothing.
#
# This is what makes "kettlebell swings x10" mean the 50 lb bell without saying
# so. Two sources, in order:
#
#   1. what you last actually lifted, so changing weight once changes it from
#      then on;
#   2. failing that, the weight written into the plan entry.
#
# The plan fallback is what makes a movement usable the moment you add it:
# `gtg add "sled push x5 @ 90 lb"` should mean 90 lb straight away, not only
# after you have logged it once with the weight spelled out.
#
# "Last" means latest by TIMESTAMP, then last in the file to break a tie. Those
# were one and the same until backdating arrived: the log is append-only, so
# `gtg @8am "swings x10 @ 35 lb"` typed this afternoon lands last in the file
# while describing this morning. Reading it as "what you last lifted" would let
# a correction to an old set silently redefine the current weight.
#
# The tie-break is not a detail: whole rounds land inside one second, so
# comparing timestamps alone made the FIRST set of a round outrank a heavier
# one logged moments later. The test suite caught exactly that.
last_weight_for() {
  local w=""
  if [ -s "$LOG" ]; then
    w=$(awk -F'\t' -v target="$1" "$AWK_KEY"'
      BEGIN { want = key(target) }
      $3 != "skip" && $5 != "" && key($2) == want && $1 >= seen { seen = $1; w = $5 }
      END { if (w != "") print w }
    ' "$LOG")
  fi
  [ -n "$w" ] || w=$(plan_weight_for "$1")
  printf '%s' "$w"
}

# The weight declared in a plan entry for a movement, or nothing.
plan_weight_for() {
  local target="$1"
  for k in every away mon tue wed thu fri sat sun; do plan_line "$k"; done \
    | tr '|' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' \
    | while IFS= read -r opt; do
        read_piece "$opt"
        [ -n "$P_WT" ] || continue
        [ "$(printf '%s\n' "$P_NAME" | awk "$AWK_KEY"'{print key($0)}')" \
          = "$(printf '%s\n' "$target" | awk "$AWK_KEY"'{print key($0)}')" ] || continue
        printf '%s' "$P_WT"; break
      done
}

# 90 -> "90s", 120 -> "2 min". Whole minutes read as minutes, nothing else does.
fmt_dur() {
  [ -n "${1:-}" ] || return 0
  if [ "$1" -ge 60 ] && [ $(( $1 % 60 )) -eq 0 ]; then printf '%d min' "$(( $1 / 60 ))"
  else printf '%ds' "$1"; fi
}

# 100lb -> "100 lb".
fmt_wt() { [ -n "${1:-}" ] || return 0; printf '%s' "$1" | sed 's/\([0-9.]*\)\(.*\)/\1 \2/'; }

# The four columns rendered back into one human line, the same shape they are
# typed in, so what the log holds and what the dialog shows cannot drift.
fmt_piece() {
  local out="$1"
  [ -n "${2:-}" ] && [ "${2:-}" != skip ] && out="$out x$2"
  [ -n "${4:-}" ] && out="$out $(fmt_dur "$4")"
  [ -n "${3:-}" ] && out="$out @ $(fmt_wt "$3")"
  printf '%s' "$out"
}

# One row: iso8601 <TAB> exercise <TAB> reps <TAB> home|away <TAB> weight <TAB> secs
#
# The last two are optional and were added after the fact, so a 3-argument call
# still writes a valid row and every reader tolerates the short legacy shape.
#
# The timestamp is the moment you answer, not the moment the nudge fired, so
# the log reflects when the set actually happened.
#
# GTG_AT overrides the timestamp, which is how backdating works: every writer
# goes through here, so setting it once covers the picker, typed text and
# batches alike without a new argument on any of them.
#
# The log stays APPEND-ONLY even when backdating. Inserting a row in sorted
# position means rewriting the only copy of your history to serve a
# convenience, which is the exact shape of the bug `gtg backfill` exists to
# avoid. Readers that care about order sort at read time instead.
#
# GTG_NO_PAGE suppresses the page rebuild so a batch renders once at the end
# rather than once per movement.
record() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${GTG_AT:-$(date '+%Y-%m-%dT%H:%M:%S')}" "$1" "$2" "$3" "${4:-}" "${5:-}" >>"$LOG"
  [ -n "${GTG_NO_PAGE:-}" ] && return 0
  # Refresh the history page so an already-open tab only needs a reload.
  "$(dirname "$0")/gtg-page" --no-open >/dev/null 2>&1 || true
}

# Rebuild the history page. Same call record() makes, named so a batch can make
# it once itself.
refresh_page() { "$(dirname "$0")/gtg-page" --no-open >/dev/null 2>&1 || true; }

# Turn how a human says a time into a log timestamp. Prints iso8601, or fails.
#
# This exists because the sets you most want to record are the ones you did
# before sitting down: the nudge only ever timestamps the moment you answer it,
# so a 7am round in the kitchen had nowhere to go.
#
#   8  8am  8:00  08:00  0800  8:00am  2pm  14:30      a time today
#   yesterday 7am    2026-08-18 6:30                   another day
#   -90m  -2h  45m ago                                 counted back from now
#
# A bare 1-12 with no am/pm is read as the most recent one that has already
# happened, so at 2pm "8" is this morning and "1" is an hour ago. Anything that
# still lands in the future drops back a day, because a set you have not done
# yet cannot be logged. Every caller prints the resolved time back, which is
# what makes a forgiving parser safe: a wrong reading is visible immediately.
when_to_iso() {
  local raw n unit day_off=0 datepart="" ampm="" h m base ts
  raw=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | sed 's/^ *//; s/ *$//; s/  */ /g')
  [ -n "$raw" ] || return 1

  # Counted back from now: -90m, 2h ago.
  if printf '%s' "$raw" \
     | grep -qE '^-?[0-9]+ ?(m|min|mins|minute|minutes|h|hr|hrs|hour|hours)( ago)?$'; then
    n=$(printf '%s' "$raw" | sed 's/[^0-9]//g')
    unit=$(printf '%s' "$raw" | sed 's/ago//; s/[0-9 -]//g')
    case "$unit" in
      h*) date -v-"${n}"H '+%Y-%m-%dT%H:%M:00' ;;
      *)  date -v-"${n}"M '+%Y-%m-%dT%H:%M:00' ;;
    esac
    return 0
  fi

  case "$raw" in
    yesterday*) day_off=1; raw=${raw#yesterday} ;;
    yest*)      day_off=1; raw=${raw#yest} ;;
  esac
  raw=$(printf '%s' "$raw" | sed 's/^ *//')

  # An explicit day in front of the time.
  if printf '%s' "$raw" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
    datepart=${raw%% *}
    if [ "$datepart" = "$raw" ]; then raw=""; else raw=${raw#* }; fi
  fi
  # A day on its own means that day's midnight, which is never what is meant.
  [ -n "$raw" ] || return 1

  case "$raw" in
    *am) ampm=am; raw=${raw%am} ;;
    *a)  ampm=am; raw=${raw%a} ;;
    *pm) ampm=pm; raw=${raw%pm} ;;
    *p)  ampm=pm; raw=${raw%p} ;;
  esac
  raw=$(printf '%s' "$raw" | sed 's/ *$//')

  case "$raw" in
    *:*)  h=${raw%%:*}; m=${raw#*:} ;;
    [0-9][0-9][0-9][0-9]) h=${raw%??}; m=${raw#??} ;;
    *)    h=$raw; m=0 ;;
  esac
  printf '%s' "$h" | grep -qE '^[0-9]{1,2}$' || return 1
  printf '%s' "$m" | grep -qE '^[0-9]{1,2}$' || return 1
  # 10# so a leading zero is not read as octal: "08" is eight o'clock, and
  # without this it is a syntax error.
  h=$((10#$h)); m=$((10#$m))
  [ "$m" -le 59 ] || return 1

  case "$ampm" in
    am) [ "$h" -ge 1 ] && [ "$h" -le 12 ] || return 1; [ "$h" -eq 12 ] && h=0 ;;
    pm) [ "$h" -ge 1 ] && [ "$h" -le 12 ] || return 1
        [ "$h" -lt 12 ] && h=$((h + 12)) ;;
    *)  [ "$h" -le 23 ] || return 1
        # Ambiguous bare hour, and only when no day was named: prefer the
        # afternoon reading when it has already happened. 12 is left alone --
        # it is already noon, and 24 is not an hour.
        if [ "$day_off" -eq 0 ] && [ -z "$datepart" ] \
           && [ "$h" -ge 1 ] && [ "$h" -le 11 ]; then
          ts=$(printf '%sT%02d:%02d:00' "$(date '+%Y-%m-%d')" "$((h + 12))" "$m")
          if [ "$(date -j -f '%Y-%m-%dT%H:%M:%S' "$ts" '+%s' 2>/dev/null || echo 0)" \
               -le "$(date '+%s')" ]; then
            h=$((h + 12))
          fi
        fi ;;
  esac

  if [ -n "$datepart" ]; then base="$datepart"
  else base=$(date -v-"${day_off}"d '+%Y-%m-%d'); fi
  ts=$(printf '%sT%02d:%02d:00' "$base" "$h" "$m")
  date -j -f '%Y-%m-%dT%H:%M:%S' "$ts" '+%s' >/dev/null 2>&1 || return 1
  # Still ahead of now: it must have been yesterday.
  if [ "$(date -j -f '%Y-%m-%dT%H:%M:%S' "$ts" '+%s')" -gt "$(date '+%s')" ]; then
    ts=$(date -j -f '%Y-%m-%dT%H:%M:%S' -v-1d "$ts" '+%Y-%m-%dT%H:%M:00')
  fi
  printf '%s' "$ts"
}

# Every movement this tool knows, as "key<TAB>name", newest spelling last.
#
# Two sources, and both are yours: the pools in plan.txt, and anything already
# in the log. That is the whole registry -- there is no separate database to
# drift out of step with the plan you actually read.
known_movements() {
  {
    for k in every away mon tue wed thu fri sat sun; do plan_line "$k"; done \
      | tr '|' '\n'
    awk -F'\t' '$2 != "" { print $2 }' "$LOG" 2>/dev/null
  } \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' \
    | awk "$AWK_KEY$AWK_CLEAN"'
        { k = key($0); if (k != "") name[k] = clean($0) }
        END { for (k in name) printf "%s\t%s\n", k, name[k] }'
}

# Resolve typed text to a movement this tool already knows. Prints the
# canonical name, or nothing when it is not a movement we have seen.
#
# Three tiers, each tried only when the one above found nothing, and each
# requiring exactly ONE candidate:
#
#   1. the exact key
#   2. an unambiguous prefix    -- "kett" finds "kettlebell swings"
#   3. an unambiguous substring -- "back stretch" finds "kettlebell back
#                                  stretch"
#
# Tier 3 exists because you name a movement by its distinctive part, not by
# its full registered name. "kettlebell back stretch" got typed back as
# "30s back stretch" the same day it was added, and prefix matching cannot
# see it: the words you left off were at the FRONT.
#
# Ambiguity still resolves to nothing, which is the property that matters. If
# "hamstring stretch" is ever added, "stretch" matches two and therefore
# matches neither -- and you are asked, rather than told.
#
# All three rules are decidable and explainable when they are wrong. This
# replaced an edit-distance guess that silently rewrote what you typed:
# "Incline Press" and "Decline Press" are distance 2, exactly the threshold it
# auto-corrected at, so two real movements quietly became one and the log said
# nothing. A closed set you extend on purpose beats a guess.
resolve_movement() {
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$1" | awk "$AWK_KEY"'{print key($0)}' | {
    read -r want
    [ -n "$want" ] || exit 0
    # Counted by distinct NAME, not by row: two plan entries for one movement
    # must not read as an ambiguous pair and cancel each other out.
    known_movements | awk -F'\t' -v want="$want" '
      $1 == want         { exact = $2 }
      index($1, want) == 1 { if (!($2 in pre)) { pre[$2]; npre++ } }
      index($1, want) > 0  { if (!($2 in any)) { any[$2]; nany++ } }
      END {
        if (exact != "") { print exact; exit }
        if (npre == 1) { for (p in pre) print p; exit }
        if (nany == 1) for (p in any) print p
      }'
  }
}

# Add a movement to a pool in plan.txt, so the set of known movements is
# something you extend rather than something the parser invents.
# plan_add "kettlebell swings x10 @ 50 lb" [every|away|mon|...]
plan_add() {
  local entry="$1" pool="${2:-every}" cur tmp
  # A pool name reaches sed, grep and awk patterns, so it is an allowlist, not
  # free text. "gtg add x .*" would otherwise match and rewrite every pool line.
  case "$pool" in
    every|away|mon|tue|wed|thu|fri|sat|sun) ;;
    *) echo "unknown pool: $pool (every|away|mon..sun)" >&2; return 1 ;;
  esac
  entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$entry" ] || return 1
  [ -w "$PLAN" ] || { echo "cannot write $PLAN" >&2; return 1; }
  tmp="$PLAN.tmp.$$"
  cur=$(plan_line "$pool")
  if [ -n "$cur" ]; then
    # Already there? Compare on the movement key, not the spelling.
    if printf '%s\n' "$cur" | tr '|' '\n' \
         | awk -v e="$entry" "$AWK_KEY"'
             BEGIN { want = key(e) } key($0) == want { found = 1 }
             END { exit !found }'; then
      return 2
    fi
    # A pool line already exists: extend it in place.
    awk -v pool="$pool" -v entry="$entry" '
      index($0, pool ":") == 1 { print $0 " | " entry; next } { print }' "$PLAN" >"$tmp"
  elif grep -q "^$pool:" "$PLAN"; then
    awk -v pool="$pool" -v entry="$entry" '
      index($0, pool ":") == 1 { print pool ": " entry; next } { print }' "$PLAN" >"$tmp"
  else
    cp "$PLAN" "$tmp" && printf '%s: %s\n' "$pool" "$entry" >>"$tmp"
  fi
  # The producer must have SUCCEEDED, not merely produced bytes: a write that
  # fails halfway still leaves a nonempty file, and -s alone would rename that
  # truncated plan over the real one.
  # shellcheck disable=SC2181
  if [ $? -ne 0 ] || [ ! -s "$tmp" ] \
     || [ "$(wc -l <"$tmp")" -lt "$(wc -l <"$PLAN")" ]; then
    rm -f "$tmp"; echo "plan write failed; plan.txt untouched" >&2; return 1
  fi
  mv "$tmp" "$PLAN"
}

# Log an option the picker already chose, rather than free text you typed.
#
# The option line may carry an "@ 50 lb" that decorate_weights put there, so it
# still has to be taken apart -- otherwise "Did it", the most-used path of all,
# would write the weight back into the movement NAME.
#
# reps_override wins when given (`gtg 12`), and the literal "skip" passes
# straight through as the reps field. The name is resolved like any other, but
# falls back to what was parsed: options come from the plan, so they are known
# by construction, and a nudge must never fail to log because of a lookup.
record_option() {
  local line="$1" where="$2" reps="${3:-}" name wt
  read_piece "$line"
  [ -n "$P_NAME" ] || return 1
  name=$(resolve_movement "$P_NAME"); [ -n "$name" ] || name="$P_NAME"
  wt="$P_WT"; [ -n "$wt" ] || wt=$(last_weight_for "$name")
  [ -n "$reps" ] && P_REPS="$reps"
  record "$name" "$P_REPS" "$where" "$wt" "$P_DUR"
  fmt_piece "$name" "$P_REPS" "$wt" "$P_DUR"
}

# Log one typed report as ONE set.
#
# Deliberately no splitting on commas or the word "and". Splitting every
# separator tore real movement names apart -- "clean and press x5" became two
# entries, and the shipped `stairs, 2 flights` option became "stairs" plus
# "2 flights". One dialog, one set, is both simpler and correct.
#
# Prints the recorded line. Returns 3, printing nothing, when the movement is
# not one we know: the caller decides whether to add it, which is a question
# worth asking rather than a guess worth making.
record_typed() {
  local text="$1" where="$2" name wt
  read_piece "$text"
  [ -n "$P_NAME" ] || return 1
  name=$(resolve_movement "$P_NAME")
  [ -n "$name" ] || return 3
  wt="$P_WT"; [ -n "$wt" ] || wt=$(last_weight_for "$name")
  record "$name" "$P_REPS" "$where" "$wt" "$P_DUR"
  fmt_piece "$name" "$P_REPS" "$wt" "$P_DUR"; printf '\n'
}

# Pull a leading "@<time>" off one line of text. Sets AT_ISO and AT_REST.
#
# A dialog has ONE text field and no quoting, so the time has to be allowed to
# span words -- "yesterday 7am", "2026-08-18 6:30", "2h ago". The longest
# leading run of words that parses as a time wins.
#
# Longest-first is what keeps it safe rather than greedy: for
# "@8am 10 ring crunches" the two-word candidate is "8am 10", which is not a
# time and does not parse, so it falls back to "8am" and the count stays with
# the movement. A parser that guessed instead of failing would silently log
# ten o'clock.
#
# Text that merely starts with "@" is left whole, with AT_ISO empty -- the
# caller decides whether that is an error or just text.
split_at() {
  local s="$1" n try rest w
  AT_ISO=""; AT_REST="$s"
  case "$s" in @*) ;; *) return 0 ;; esac
  s=${s#@}
  for n in 3 2 1; do
    try=$(printf '%s' "$s" | awk -v n="$n" '
      { if (NF < n) exit 1
        out = $1; for (i = 2; i <= n; i++) out = out " " $i
        print out }') || continue
    if w=$(when_to_iso "$try"); then
      rest=$(printf '%s' "$s" | awk -v n="$n" '
        { out = ""; for (i = n + 1; i <= NF; i++) out = (out == "" ? $i : out " " $i)
          print out }')
      AT_ISO="$w"; AT_REST="$rest"
      return 0
    fi
  done
  return 0
}

# Log a whole round typed in one go: "10 ring crunches; pull-ups x5; hang 30s".
#
# A round done away from the keyboard is remembered as a round, so making you
# type it one movement per command is the wrong shape -- and the menu bar has
# exactly one text field to offer.
#
# ";" and "|" separate; a COMMA does not. That is not fussiness: the shipped
# option `stairs, 2 flights` is one movement with a comma in its name, and
# `clean and press` is why "and" is not a separator either.
#
# Checked in FULL before a single row is written. A round typed in one breath
# should not half-land because the third movement was misspelled, leaving you
# to work out which half made it.
#
# Deliberately no bash arrays. This is /bin/bash, which on macOS is 3.2, and
# every caller runs under `set -u` -- where ${#arr[@]} on an array that has not
# been assigned yet aborts the script rather than reading as zero. A validated
# "name<TAB>piece" line per movement carries the same information with no such
# edge, since a movement name cannot contain a tab or a newline.
record_batch() {
  local text="$1" where="$2" piece name wt base i ts validated=""
  while IFS= read -r piece; do
    piece=$(printf '%s' "$piece" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$piece" ] || continue
    read_piece "$piece"
    [ -n "$P_NAME" ] || { echo "could not read that as a movement: $piece" >&2; return 1; }
    name=$(resolve_movement "$P_NAME")
    if [ -z "$name" ]; then
      echo "unknown movement: $P_NAME" >&2
      echo "add it first:  gtg add \"$(fmt_piece "$P_NAME" "$P_REPS" "$P_WT" "$P_DUR")\"" >&2
      return 3
    fi
    validated="$validated$name	$piece
"
  done < <(printf '%s\n' "$text" | tr ';|' '\n\n')
  [ -n "$validated" ] || return 1

  base="${GTG_AT:-}"
  GTG_NO_PAGE=1
  i=0
  while IFS="$(printf '\t')" read -r name piece; do
    [ -n "$name" ] || continue
    # One second apart, so a round reads back in the order you did it rather
    # than in whatever order identical timestamps happen to sort.
    if [ -n "$base" ]; then
      ts=$(date -j -f '%Y-%m-%dT%H:%M:%S' -v+"${i}"S "$base" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null)
      GTG_AT="${ts:-$base}"
    fi
    read_piece "$piece"
    wt="$P_WT"; [ -n "$wt" ] || wt=$(last_weight_for "$name")
    record "$name" "$P_REPS" "$where" "$wt" "$P_DUR"
    fmt_piece "$name" "$P_REPS" "$wt" "$P_DUR"; printf '\n'
    i=$((i + 1))
  done <<EOF
$validated
EOF
  GTG_AT="$base"; unset GTG_NO_PAGE
  refresh_page
}

# Log a typed report for a movement you have just agreed to add.
record_new() {
  local text="$1" where="$2" pool="${3:-every}" wt
  read_piece "$text"
  [ -n "$P_NAME" ] || return 1
  # 0 added, 2 already there -- both mean the movement is in a pool. Anything
  # else failed, and recording it after telling you it was added would be a
  # lie: the set would never be offered again.
  plan_add "$(fmt_piece "$P_NAME" "$P_REPS" "$P_WT" "$P_DUR")" "$pool"
  case $? in 0|2) ;; *) return 1 ;; esac
  read_piece "$text"
  wt="$P_WT"
  record "$P_NAME" "$P_REPS" "$where" "$wt" "$P_DUR"
  fmt_piece "$P_NAME" "$P_REPS" "$wt" "$P_DUR"; printf '\n'
}


# Escape for embedding in an AppleScript double-quoted string.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
