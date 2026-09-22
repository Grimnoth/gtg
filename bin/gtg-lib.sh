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
PAUSE="$STATE_DIR/paused"

# Where the other scripts are, taken from THIS file rather than from $0.
#
# $0 is whoever sourced us, and that is not always something in bin/: the test
# suite sources this file directly, so `dirname "$0"` is test/ and a sibling
# script is looked for where none exists.
#
# ponytail: record() and refresh_page() still reach for gtg-page through $0,
# so under the suite that call silently finds nothing and is swallowed by the
# `|| true`. Harmless today and wrong in the same way. Moving them here makes
# every recorded row in the suite rebuild the history page, which is a real
# cost on a suite that writes a few hundred, so it wants a GTG_NO_PAGE around
# the suite rather than a one-line change.
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

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
    gsub(/[ \t]+(total|each|per hand|with|of|for)([ \t]|$)/, " ", s)
    # Anywhere, not anchored at the end. Once decorate_weights appends
    # "@ 50 lb", the count is no longer last, and an end-anchored strip left
    # "kettlebellswingsx10" -- which never matched the "kettlebellswing" the
    # same set was logged under, so rotation read the movement as never done.
    gsub(/[ \t]*[xX][0-9]+([ \t]|$)/, " ", s)
    # "20x push ups": count first, then the x. The shape Ben types most.
    gsub(/(^|[ \t])[0-9]+[ \t]*[xX]([ \t]|$)/, " ", s)
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
    gsub(/(^|[ \t])[0-9]+[ \t]*[xX]([ \t]|$)/, " ", s)
    sub(/^[0-9]+[ \t]+/, "", s)
    sub(/[ \t]+[0-9]+[ \t]*$/, "", s)
    # "@" goes, the comma stays: a comma is part of names you actually use,
    # such as the shipped "stairs, 2 flights".
    gsub(/[ \t]+-[ \t]+/, " ", s); gsub(/@/, " ", s)
    gsub(/[ \t]+(total|each|per hand|with|of|for)[ \t]*$/, "", s)
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

# One stamped line, the shape every entry in nudge.log takes. gtg-nudge prints
# these to stdout and launchd appends them; `gtg note` appends one directly.
note() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*"; }

# Sets WAKE_S / WAKE_E from the plan, with the shipped defaults. The one place
# the defaults live: the nudge, `today` and `fires` all read them from here.
waking_bounds() {
  WAKE_S=$(cfg WAKE_START); WAKE_S=${WAKE_S:-9}
  WAKE_E=$(cfg WAKE_END);   WAKE_E=${WAKE_E:-21}
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
  waking_bounds
  [ "$1" -ge "$WAKE_S" ] && [ "$1" -lt "$WAKE_E" ]
}

# --- not today --------------------------------------------------------------
# Some days there is no set coming: sick, wrecked, travelling. Nine dialogs on
# such a day are pure nuisance, and a nuisance with no off switch is how a
# reminder gets muted for good -- the tool survives by being answerable, so it
# has to take "not today" for an answer.
#
# Every pause carries an end time and expires by itself, because the failure to
# avoid is the opposite one: a tool switched off in February and noticed in
# May. Nothing is scheduled and no timer has to survive a reboot. The expiry is
# read, and an expired file is deleted as it is read.

# True while the nudge is off. Sets PAUSE_UNTIL (epoch) and PAUSE_WHY.
pause_active() {
  PAUSE_UNTIL=""; PAUSE_WHY=""
  [ -s "$PAUSE" ] || return 1
  IFS="$(printf '\t')" read -r PAUSE_UNTIL PAUSE_WHY <"$PAUSE" || true
  # A file that is not an epoch is a file nobody can trust to expire, so it
  # goes rather than muting the tool for ever.
  case "$PAUSE_UNTIL" in ''|*[!0-9]*) rm -f "$PAUSE"; PAUSE_UNTIL=""; return 1 ;; esac
  [ "$(date +%s)" -lt "$PAUSE_UNTIL" ] && return 0
  rm -f "$PAUSE"; PAUSE_UNTIL=""; PAUSE_WHY=""
  return 1
}

# When a pause must end, as an epoch. "1d" is the default and means the rest of
# today: the nudges come back at TOMORROW's WAKE_START, since "I am not doing
# these today" is the thing actually being said.
#
#   2h / 90m   a stretch from now
#   3d         today and two more days, back on the fourth morning
pause_ends() {
  local d="${1:-1d}"
  printf '%s' "$d" | grep -qE '^[0-9]+[dhm]$' || return 1
  waking_bounds
  case "$d" in
    *d) date -v+"${d%d}"d -v"${WAKE_S}"H -v0M -v0S '+%s' ;;
    *h) printf '%s' $(( $(date +%s) + ${d%h} * 3600 )) ;;
    *m) printf '%s' $(( $(date +%s) + ${d%m} * 60 )) ;;
  esac
}

# Written by every path that turns the nudges off. The caller writes the nudge
# log line itself: gtg-nudge prints its log to stdout for launchd to append,
# and `gtg` appends directly, so doing it here would double-record one of them.
pause_set() {   # ENDS_EPOCH [REASON]
  printf '%s\t%s\n' "$1" "${2:-}" >"$PAUSE"
}

pause_human() { date -r "$1" '+%a %-d %b %H:%M'; }

# "Nah, stop sending me these" -- typed where a movement would go. The nudge's
# Other... box and the menu bar's one text field are where the nuisance is
# actually felt, so the answer is taken there rather than only in a terminal.
#
# Sets PAUSE_FOR (a duration, or empty for the rest of today) and PAUSE_REASON.
# Returns 1 for every ordinary set, which is nearly every line: the words are
# anchored at the start, must end a word, and none of them names a movement.
parse_pause() {
  PAUSE_FOR=""; PAUSE_REASON=""
  local l first
  l=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]!.,]*$//')
  printf '%s' "$l" \
    | grep -qE '^(off|pause|stop|not today|no more today|done for today|sick)([[:space:],]|$)' \
    || return 1
  # The keyword goes, the reason stays. "sick" is deliberately not stripped:
  # it is the reason as well as the request.
  l=$(printf '%s' "$l" \
      | sed -E 's/^(off|pause|stop|not today|no more today|done for today)[,[:space:]]*//' \
      | sed -E 's/^(for|until|till)[[:space:]]+//; s/^(today|the rest of the day)[,[:space:]]*//' \
      | sed 's/^[[:space:]]*//')
  # A word that STARTS with a digit is a stretch of time or a mistyped one,
  # never a reason. Letting "2x" fall through to the reason would have paused
  # for the rest of the day while the person meant two hours, and said nothing
  # about it. pause_ends rejects it and the caller decides what to say.
  first=${l%%[[:space:]]*}
  case "$first" in
    [0-9]*)
      PAUSE_FOR="$first"
      l=$(printf '%s' "${l#"$first"}" | sed 's/^[[:space:]]*//') ;;
  esac
  PAUSE_REASON="$l"
  return 0
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

# Append the remembered weight, and the remembered count, to any option that
# does not name them, so the picker reads "kettlebell swings x10 @ 50 lb" and
# "Did it" logs both without a word typed. The decorated string round-trips:
# parse_piece takes the "x10" and the "@ 50 lb" back off when the row is
# written.
#
# The count came later than the weight, and for the same reason: a pool
# entry without one ("bulgarian split squats") was offered bare, "Did it"
# logged a set with no reps, and the question was "how does it know how
# many?". It does not; it remembers. A timed movement never gets a count.
#
# ponytail: this is the slow part of the whole tool, and the ceiling is the
# shape, not the size of the log. Each option forks read_piece, last_reps_for
# and last_weight_for, and a movement with no logged weight also forks
# plan_weight_for, which re-reads the plan nine times. Five options measured
# ~470ms on 124 rows. The upgrade is one awk pass over the log that emits the
# last weight and count for every movement at once, read into the loop.
decorate_weights() {
  local opt wt reps
  while IFS= read -r opt; do
    read_piece "$opt"
    if [ -z "$P_REPS" ] && [ -z "$P_DUR" ]; then
      reps=$(last_reps_for "$P_NAME")
      [ -n "$reps" ] && opt="$opt x$reps"
    fi
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
      # A sentence ends in a period; a movement does not. "kettlebell walk."
      # was refused as unknown for the dot alone.
      sub(/[.!]+[ \t]*$/, "", s)
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
      # "20x Push Ups" and "8 x ring dips": the count before the x. Twelve
      # of the first twenty-three refused entries were this shape.
      } else if (match(s, /(^|[ \t])[0-9]+[ \t]*[xX]([ \t]|$)/)) {
        t=substr(s,RSTART,RLENGTH); s=substr(s,1,RSTART-1) " " substr(s,RSTART+RLENGTH)
        gsub(/[^0-9]/,"",t); r=t
      } else if (match(s, /^[ \t]*[0-9]+[ \t]/)) {
        t=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH); gsub(/[^0-9]/,"",t); r=t
      } else if (match(s, /[ \t][0-9]+[ \t]*$/)) {
        t=substr(s,RSTART,RLENGTH); s=substr(s,1,RSTART-1); gsub(/[^0-9]/,"",t); r=t
      }
      gsub(/[ \t]+-[ \t]+/, " ", s); gsub(/@/, " ", s)
      # "for" too: "Running for 20 minutes" logged a movement called
      # "Running for" once the duration was lifted out.
      gsub(/[ \t]+([Tt][Oo][Tt][Aa][Ll]|[Ee][Aa][Cc][Hh]|[Pp]er hand|[Ww][Ii][Tt][Hh]|[Oo][Ff]|[Ff][Oo][Rr])[ \t]*$/, "", s)
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

# The count you last did of a movement, or nothing. Same rule as the weight,
# tie-break included, and read from the log only: a plan entry with a count
# already carries it, so there is nothing to fall back to.
last_reps_for() {
  [ -s "$LOG" ] || return 0
  awk -F'\t' -v target="$1" "$AWK_KEY"'
    BEGIN { want = key(target) }
    $3 ~ /^[0-9]+$/ && key($2) == want && $1 >= seen { seen = $1; r = $3 }
    END { if (r != "") printf "%s", r }
  ' "$LOG"
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
  local ts="${GTG_AT:-$(date '+%Y-%m-%dT%H:%M:%S')}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$1" "$2" "$3" "${4:-}" "${5:-}" >>"$LOG"
  # Backgrounded, with every fd closed: record() runs inside command
  # substitutions, and a child still holding stdout keeps the caller waiting
  # until Calendar answers, which is seven seconds. That is exactly what
  # `[ skip ] || calendar_event ... >/dev/null &` did -- the redirect covered
  # the inner command while the backgrounded LIST kept the pipe. Measured: a
  # menu click took 8s to confirm. The if form redirects the child itself.
  if [ "$2" != skip ]; then
    calendar_event "$(fmt_piece "$1" "$2" "${4:-}" "${5:-}")" "$ts" "$3" </dev/null >/dev/null 2>&1 &
  fi
  [ -n "${GTG_NO_PAGE:-}" ] && return 0
  # Refresh the history page so an already-open tab only needs a reload.
  "$(dirname "$0")/gtg-page" --no-open >/dev/null 2>&1 || true
}

# The AppleScript that puts one set on the calendar as a zero-minute event at
# the set's own time, so a backdated 7:15 set lands at 7:15. Idempotent: an
# event with the same summary at the same minute is not written twice, which
# is what lets `gtg calendar-sync` be re-run and lets record() and the sync
# overlap without a duplicate.
#
# The date is built from parts rather than parsed from a string, because
# `date "..."` in AppleScript reads the string in the user's locale format.
# Day is set to 1 first so that setting month never overflows a short month.
#
# Only %s carries text in, and every one goes through esc(). A literal quote
# in the format is \\" (see the dialog builders above for why).
calendar_script() {
  local cal="$1" summary="$2" iso="$3" where="${4:-}"
  local Y=${iso:0:4} M=${iso:5:2} D=${iso:8:2} h=${iso:11:2} m=${iso:14:2}
  printf 'with timeout of 30 seconds\n  tell application "Calendar"\n    set d to current date\n    set day of d to 1\n    set year of d to %d\n    set month of d to %d\n    set day of d to %d\n    set hours of d to %d\n    set minutes of d to %d\n    set seconds of d to 0\n    tell calendar "%s"\n      if (count of (every event whose start date = d and summary = "%s")) = 0 then\n        make new event with properties {summary:"%s", start date:d, end date:d, description:"%s"}\n      end if\n    end tell\n  end tell\nend timeout\n' \
    "$((10#$Y))" "$((10#$M))" "$((10#$D))" "$((10#$h))" "$((10#$m))" \
    "$(esc "$cal")" "$(esc "$summary")" "$(esc "$summary")" "$(esc "$where")"
}

# Put one set on the calendar named by CALENDAR= in plan.txt. No name, no
# calendar, and no Calendar.app is ever launched. calendar_event SUMMARY ISO WHERE
#
# Calendar.app has to be running for AppleScript to reach it, so it is started
# hidden when it is not. A failed write is written to the nudge log by name,
# never swallowed: a calendar that quietly stops filling is the same shape as
# a reminder that quietly stops reminding.
calendar_event() {
  local cal err
  cal=$(cfg CALENDAR)
  [ -n "$cal" ] || return 0
  pgrep -xq Calendar || { open -gj -a Calendar 2>/dev/null; sleep 3; }
  err=$(mktemp)
  if ! /usr/bin/osascript >/dev/null 2>"$err" <<<"$(calendar_script "$cal" "$1" "$2" "${3:-}")"; then
    note "calendar write failed for \"$1\" at $2: $(head -1 "$err")" >>"$NUDGE_LOG"
    rm -f "$err"; return 1
  fi
  rm -f "$err"
}

# The sets of the last N days, one per line as SUMMARY<TAB>ISO<TAB>WHERE, for
# the calendar sync. Skips excluded.
#
# The log is read by awk and re-emitted with a unit separator (0x1f) between
# columns, because `IFS=$'\t' read` collapses a run of empty fields -- and an
# empty reps column (a timed hang has none) slid "home" into the reps slot,
# which put "dead hang xhome" on the calendar the first time this ran.
sync_rows() {
  local days="${1:-30}" since us ts ex reps wh wt secs
  us=$(printf '\037')
  since=$(date -v-"$(( days - 1 ))"d '+%Y-%m-%d')
  awk -F'\t' -v OFS="$us" -v since="$since" \
    'substr($1, 1, 10) >= since && $3 != "skip" { print $1, $2, $3, $4, $5, $6 }' "$LOG" \
  | while IFS="$us" read -r ts ex reps wh wt secs; do
      printf '%s\t%s\t%s\n' "$(fmt_piece "$ex" "$reps" "$wt" "$secs")" "$ts" "$wh"
    done
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

# How many sets landed today, skips excluded. The menu bar title and a
# friction note both want the number without the listing.
sets_today() {
  [ -s "$LOG" ] || { printf '0'; return 0; }
  awk -F'\t' -v d="$(date '+%Y-%m-%d')" 'index($1, d) == 1 && $3 != "skip" { n++ } END { printf "%d", n }' "$LOG"
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

# What this tool knows about each movement, one line each, for the interpreter
# to read before it rewrites a sentence.
#
# This is the whole difference between a model guessing and a model looking
# something up. Given only the NAMES, sonnet read "32nd backstretch" as 32
# REPS. Given that kettlebell back stretch is a timed movement that has been 30
# seconds every time it was ever done, it reads 30s.
#
# Every word of it comes out of Ben's own log and plan -- the same two sources
# known_movements reads. Nothing is invented and there is no second registry to
# drift out of step with the plan he actually reads.
#
# One awk pass over three tagged streams rather than a fork per movement. The
# decorate_weights ponytail measured five movements at ~470ms done that way,
# and this runs immediately before a model call that already costs seven
# seconds.
movement_profiles() {
  local known plan
  known=$(known_movements)
  [ -n "$known" ] || return 0
  plan=$(for k in every away mon tue wed thu fri sat sun; do plan_line "$k"; done \
         | tr '|' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' \
         | awk "$AWK_KEY"'{ print key($0) "\t" $0 }')
  {
    printf '%s\n' "$known" | sed 's/^/K\t/'
    [ -n "$plan" ] && printf '%s\n' "$plan" | sed 's/^/P\t/'
    [ -s "$LOG" ] && sed 's/^/L\t/' "$LOG"
  } | awk -F'\t' "$AWK_KEY"'
      function dur(d) { return (d >= 60 && d % 60 == 0) ? int(d / 60) " min" : d "s" }
      function wgt(w) { sub(/[0-9.]+/, "& ", w); return w }

      $1 == "K" { name[$2] = $3; next }
      $1 == "P" { if (!($2 in entry)) entry[$2] = $3; next }
      $1 == "L" && $4 != "skip" && $3 != "" {
        k = key($3)
        if (!(k in name)) next
        # Latest by timestamp, file order breaking a tie. The same rule as
        # last_weight_for, and for the same reason: a whole round lands inside
        # one second, so ">" alone lets its first set outrank its last.
        sets[k]++
        # "Usually" means the value seen MOST OFTEN, not the one seen last.
        # Last is what a single mistyped entry leaves behind: one "back stretch
        # 30" typed by hand this morning would otherwise teach the model that
        # the movement is 30 reps. The mode survives a bad row; the last value
        # is the bad row.
        if ($4 ~ /^[0-9]+$/) { nrep[k]++; rc[k SUBSEP $4]++; if (rc[k SUBSEP $4] > rb[k]) { rb[k] = rc[k SUBSEP $4]; rep[k] = $4 } }
        if ($7 != "")        { ndur[k]++; dc[k SUBSEP $7]++; if (dc[k SUBSEP $7] > db[k]) { db[k] = dc[k SUBSEP $7]; dur_[k] = $7 } }
        # The weight is the exception and stays LATEST, because that is what
        # the whole feature means: change the bell once and it is the new one.
        if ($6 != "" && $2 >= ws[k]) { ws[k] = $2; wt[k] = $6 }
      }
      END {
        for (k in name) {
          # Timed or counted is decided by the whole log, not by the newest
          # row, for the same reason the mode beats the last value.
          shape = ""
          if (ndur[k] > nrep[k]) shape = "timed, usually " dur(dur_[k])
          else if (nrep[k] > 0)  shape = "counted, usually x" rep[k]
          else if (k in entry)   shape = "in the plan as: " entry[k]
          else                   shape = "never logged"
          if (k in wt) shape = shape ", at " wgt(wt[k])
          # The set count is here so a one-off can be recognised as one. A
          # movement logged once is either brand new or a mistake -- the log
          # holds "7am Ring Dips" and "Ring Dips Weight +", both of them a
          # parse that went wrong -- and a reader deciding what a sentence
          # means should be able to see that nobody has ever done it twice.
          n = (k in sets) ? sets[k] : 0
          printf "%s - %s (%d %s)\n", name[k], shape, n, (n == 1 ? "set" : "sets")
        }
      }' | sort
}

# Write a KEY=value line into plan.txt, replacing the existing one or adding
# it at the end. Same care as plan_add: a producer that fails halfway still
# leaves a nonempty file, so success is checked before anything is renamed
# over the plan you actually read.
cfg_set() {   # KEY VALUE
  local k="$1" v="$2" tmp
  case "$k" in
    [A-Z_]*) ;;
    *) echo "bad setting name: $k" >&2; return 1 ;;
  esac
  [ -w "$PLAN" ] || { echo "cannot write $PLAN" >&2; return 1; }
  tmp="$PLAN.tmp.$$"
  if grep -q "^$k=" "$PLAN"; then
    awk -v k="$k" -v v="$v" '
      index($0, k "=") == 1 && !done { print k "=" v; done = 1; next } { print }' "$PLAN" >"$tmp"
  else
    cp "$PLAN" "$tmp" && printf '%s=%s\n' "$k" "$v" >>"$tmp"
  fi
  # shellcheck disable=SC2181
  if [ $? -ne 0 ] || [ ! -s "$tmp" ]; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "$PLAN"
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
# One movement is a round of one, and every typed report comes through here.
#
# A round done away from the keyboard is remembered as a round, so making you
# type it one movement per command is the wrong shape -- and the menu bar has
# exactly one text field to offer.
#
# ";", "|", "&" and the word "and" separate; a COMMA does not. That is not
# fussiness: the shipped option `stairs, 2 flights` is one movement with a
# comma in its name.
#
# ponytail: "and" tears a movement NAMED with it ("clean and press") in two.
# No pool here has one, and "and" is how a round gets dictated. If one ever
# arrives, try the whole piece against known_movements before splitting it.
#
# A piece may carry its own "@time": "@7:15 pull-ups x5; @7:40 dead hang 30s"
# is a morning done at two times, typed as one line. A piece without a time
# follows the one before it, a second later.
#
# Checked in FULL before a single row is written. A round typed in one breath
# should not half-land because the third movement was misspelled, leaving you
# to work out which half made it.
#
# An unknown movement returns 3, names it on stderr, and writes nothing: the
# caller asks, rather than guessing. With GTG_NEW set the same movement is
# logged under the name as typed -- the caller has asked, and the log is what
# makes a movement known from then on. GTG_NEW=pool also puts it in the
# every-day pool, before the first row is written.
#
# Deliberately no bash arrays. This is /bin/bash, which on macOS is 3.2, and
# every caller runs under `set -u` -- where ${#arr[@]} on an array that has not
# been assigned yet aborts the script rather than reading as zero. A validated
# "name<TAB>piece" line per movement carries the same information with no such
# edge, since a movement name cannot contain a tab or a newline.
record_batch() {
  local text="$1" where="$2" piece name wt orig base i ts at new us validated=""
  # Unit separator between the fields of a validated line, not a tab: tab is
  # IFS whitespace, and `read` collapses a run of empty tab fields -- an empty
  # time would slide the "new" mark into its slot.
  us=$(printf '\037')
  while IFS= read -r piece; do
    piece=$(printf '%s' "$piece" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$piece" ] || continue
    at=""
    case "$piece" in
      @*) split_at "$piece"
          [ -n "$AT_ISO" ] || { echo "could not read a time out of: $piece" >&2; return 1; }
          at="$AT_ISO"; piece="$AT_REST" ;;
    esac
    read_piece "$piece"
    [ -n "$P_NAME" ] || { echo "could not read that as a movement: $piece" >&2; return 1; }
    name=$(resolve_movement "$P_NAME"); new=""
    if [ -z "$name" ]; then
      if [ -n "${GTG_NEW:-}" ]; then
        name="$P_NAME"; new=new
      else
        echo "unknown movement: $P_NAME" >&2
        echo "new? log it as typed:  gtg --new \"$text\"   (--offer to also see it daily)" >&2
        return 3
      fi
    fi
    validated="$validated$name$us$piece$us$at$us$new
"
  done < <(printf '%s\n' "$text" | tr ';|' '\n\n' \
           | awk '{ gsub(/[ \t]+([Aa][Nn][Dd]|&)[ \t]+/, "\n"); print }')
  [ -n "$validated" ] || return 1

  # The pool first, and all of it before any row: a plan that cannot be
  # written is a reason to log nothing, not half a round.
  if [ "${GTG_NEW:-}" = pool ]; then
    while IFS="$us" read -r name piece at new; do
      [ "$new" = new ] || continue
      read_piece "$piece"
      plan_add "$(fmt_piece "$name" "$P_REPS" "$P_WT" "$P_DUR")" every
      case $? in 0|2) ;; *) return 1 ;; esac
    done <<EOF
$validated
EOF
  fi

  orig="${GTG_AT:-}"; base="$orig"
  GTG_NO_PAGE=1
  i=0
  while IFS="$us" read -r name piece at new; do
    [ -n "$name" ] || continue
    # A piece with its own time restarts the count from there.
    if [ -n "$at" ]; then base="$at"; i=0; fi
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
  GTG_AT="$orig"; unset GTG_NO_PAGE
  refresh_page
}


# record_batch, and if the line is not a set of MOVEMENTS, one attempt at
# reading it as a SENTENCE. The single hook for the whole interpreter, so the
# CLI, the nudge and the menu bar all get it from one place.
#
# The order is the safety. Everything already understood is logged by the
# parser exactly as before and never reaches a model at all: the interpreter
# runs only on the miss, which today means a sentence, a dictation, or a typo.
# And its answer is not trusted either -- it goes back through record_batch,
# which resolves every name against the movements you actually have and still
# refuses what it does not know. The model gets to rephrase the question. It
# never gets to answer it.
#
# "read as:" goes to STDERR on every interpreted line, and that is not a
# detail. It is the same rule the time parser follows: a forgiving reader is
# safe only because it says out loud what it read, in the same breath, rather
# than leaving a misreading to be found weeks later in the history page.
# Stderr rather than a variable because every caller runs this inside a command
# substitution, and a variable set in a subshell reaches nobody.
record_smart() {   # TEXT WHERE
  local text="$1" where="$2" err out rc reading
  err=$(mktemp)
  out=$(record_batch "$text" "$where" 2>"$err"); rc=$?
  if [ "$rc" -ne 3 ]; then
    cat "$err" >&2; rm -f "$err"
    [ -n "$out" ] && printf '%s\n' "$out"
    return "$rc"
  fi

  reading=$(printf '%s\n' "$text" | "$LIB_DIR/gtg-interpret" 2>/dev/null)
  # Nothing to add: no reader configured, a model that failed, or an answer
  # identical to the question. The original refusal stands, word for word.
  if [ -z "$reading" ] || [ "$reading" = "$text" ]; then
    cat "$err" >&2; rm -f "$err"
    return 3
  fi
  rm -f "$err"

  err=$(mktemp)
  out=$(record_batch "$reading" "$where" 2>"$err"); rc=$?
  printf 'read as: %s\n' "$reading" >&2
  cat "$err" >&2; rm -f "$err"
  [ -n "$out" ] && printf '%s\n' "$out"
  return "$rc"
}

# Escape for embedding in an AppleScript double-quoted string.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# The dialogs gtg-nudge shows, as AppleScript source. Each reads $title and
# $DIALOG_TIMEOUT from the caller. They live here rather than in gtg-nudge so
# the test suite can source them and compile every one with osacompile.
#
# That test exists because confirm_new_for never compiled from the day it was
# written until 2026-09-03. Its format string held \" to quote the movement
# name, and printf reads \" in a FORMAT as a bare quote -- so the script that
# reached osascript said `message "Add "Bulgarian Split Squats" to your
# pool?"`, a syntax error. osascript printed nothing, stderr was discarded,
# and the empty answer was recorded as "unknown movement declined". Fifteen
# declines in the log, and not one of them was a person saying no.
#
# Only %s carries text into these, and the text goes through esc() first. A
# literal quote in the format must be written \\" so printf emits \".

# One recommendation and three buttons. Three is the hard limit of `display
# alert`, and unlike `choose from list` it supports `giving up after`.
alert_for() {
  printf 'with timeout of %s seconds\n  tell application "System Events"\n    activate\n    set r to display alert "%s" message "%s" buttons {"Snooze", "Other...", "Did it"} default button "Did it" giving up after %s\n    if gave up of r then\n      return "__TIMEOUT__"\n    else\n      return button returned of r\n    end if\n  end tell\nend timeout\n' \
    "$(( DIALOG_TIMEOUT + 60 ))" "$(esc "$title")" "$(esc "$1")" "$DIALOG_TIMEOUT"
}

# Asked when what you typed names a movement this tool does not know. The
# alternative was guessing, and guessing merged two real movements without
# saying so. The whole line comes back in a text field: a misspelling is
# fixed in place and resolves, a new movement is logged as typed. Answers
# "<button><TAB><text>", or __CANCEL__ / __TIMEOUT__.
#
# A button named "Cancel" does not return from `display dialog`, it raises
# error -128 -- hence the try block. Without it osascript printed nothing,
# and nothing is what a dialog that failed to open prints too.
new_for() {   # UNKNOWN_NAME TYPED_LINE
  printf 'with timeout of 180 seconds\n  tell application "System Events"\n    activate\n    try\n      set r to display dialog "\\"%s\\" is not a movement I know. Fix the spelling, or log it as it is. Add to pool also offers it every day." default answer "%s" with title "New movement" buttons {"Cancel", "Add to pool", "Log it"} default button "Log it" giving up after 120\n    on error number -128\n      return "__CANCEL__"\n    end try\n    if gave up of r then\n      return "__TIMEOUT__"\n    else\n      return (button returned of r) & tab & (text returned of r)\n    end if\n  end tell\nend timeout\n' \
    "$(esc "$1")" "$(esc "$2")"
}

# Prefilled with the suggestion, so "same movement, different count" is one
# edit. `display dialog` also carries its own timeout. Same -128 rule as
# new_for: Cancel is an error, not a button.
other_for() {
  printf 'with timeout of 360 seconds\n  tell application "System Events"\n    activate\n    try\n      set r to display dialog "What did you do? Put and or ; between sets." default answer "%s" with title "%s" buttons {"Cancel", "Log it"} default button "Log it" giving up after 300\n    on error number -128\n      return "__CANCEL__"\n    end try\n    if gave up of r then\n      return "__TIMEOUT__"\n    else\n      return text returned of r\n    end if\n  end tell\nend timeout\n' \
    "$(esc "$1")" "$(esc "$title")"
}
