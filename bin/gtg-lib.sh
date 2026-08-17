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
#   1. what you last actually lifted -- rows are appended in order, so the last
#      match wins, and changing weight once changes it from then on;
#   2. failing that, the weight written into the plan entry.
#
# The plan fallback is what makes a movement usable the moment you add it:
# `gtg add "sled push x5 @ 90 lb"` should mean 90 lb straight away, not only
# after you have logged it once with the weight spelled out.
last_weight_for() {
  local w=""
  if [ -s "$LOG" ]; then
    w=$(awk -F'\t' -v target="$1" "$AWK_KEY"'
      BEGIN { want = key(target) }
      $3 != "skip" && $5 != "" && key($2) == want { w = $5 }
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
record() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "$3" "${4:-}" "${5:-}" >>"$LOG"
  # Refresh the history page so an already-open tab only needs a reload.
  "$(dirname "$0")/gtg-page" --no-open >/dev/null 2>&1 || true
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
# Exact key first, then an unambiguous prefix, so "kett" finds "kettlebell
# swings" but a prefix matching two movements finds neither. Both rules are
# decidable and explainable when they are wrong.
#
# This replaced an edit-distance guess that silently rewrote what you typed.
# "Incline Press" and "Decline Press" are distance 2 -- exactly the threshold
# it auto-corrected at -- so two real movements quietly became one, and the
# log said nothing. A closed set you extend on purpose beats a guess.
resolve_movement() {
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$1" | awk "$AWK_KEY"'{print key($0)}' | {
    read -r want
    [ -n "$want" ] || exit 0
    known_movements | awk -F'\t' -v want="$want" '
      $1 == want { exact = $2 }
      index($1, want) == 1 { pfx[$2]; n++ }
      END {
        if (exact != "") { print exact; exit }
        if (n == 1) for (p in pfx) print p
      }'
  }
}

# Add a movement to a pool in plan.txt, so the set of known movements is
# something you extend rather than something the parser invents.
# plan_add "kettlebell swings x10 @ 50 lb" [every|away|mon|...]
plan_add() {
  local entry="$1" pool="${2:-every}" cur
  entry=$(printf '%s' "$entry" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$entry" ] || return 1
  [ -w "$PLAN" ] || { echo "cannot write $PLAN" >&2; return 1; }
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
      $0 ~ "^" pool ":" { print $0 " | " entry; next } { print }' "$PLAN" >"$PLAN.tmp"
  elif grep -q "^$pool:" "$PLAN"; then
    awk -v pool="$pool" -v entry="$entry" '
      $0 ~ "^" pool ":" { print pool ": " entry; next } { print }' "$PLAN" >"$PLAN.tmp"
  else
    cp "$PLAN" "$PLAN.tmp" && printf '%s: %s\n' "$pool" "$entry" >>"$PLAN.tmp"
  fi
  [ -s "$PLAN.tmp" ] || { rm -f "$PLAN.tmp"; echo "refusing to write an empty plan" >&2; return 1; }
  mv "$PLAN.tmp" "$PLAN"
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

# Log a typed report for a movement you have just agreed to add.
record_new() {
  local text="$1" where="$2" pool="${3:-every}" wt
  read_piece "$text"
  [ -n "$P_NAME" ] || return 1
  plan_add "$(fmt_piece "$P_NAME" "$P_REPS" "$P_WT" "$P_DUR")" "$pool" || true
  wt="$P_WT"
  record "$P_NAME" "$P_REPS" "$where" "$wt" "$P_DUR"
  fmt_piece "$P_NAME" "$P_REPS" "$wt" "$P_DUR"; printf '\n'
}


# Escape for embedding in an AppleScript double-quoted string.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
