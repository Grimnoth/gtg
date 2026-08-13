#!/bin/bash
# Shared by gtg-nudge and gtg. Not executable on its own.

CONF_DIR="$HOME/.config/gtg"
STATE_DIR="$HOME/.local/state/gtg"
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
where_am_i() {
  local home_mac cur_mac
  home_mac=$(cat "$HOME_MAC_FILE" 2>/dev/null || true)
  cur_mac=$(current_gateway_mac || true)
  if [ -n "$home_mac" ] && [ -n "$cur_mac" ] && [ "$cur_mac" = "$home_mac" ]; then
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
    | rotate_options
}

# Reorder the pool so the movement you have neglected longest comes first.
#
# Rotation is derived from the log, not from a fixed schedule: fewest sets
# TODAY wins, ties broken by whichever went longest since it was last done,
# and anything never done at all sorts to the front. The effect is that the
# preselected item is nearly always the right answer, so a nudge stays one
# click rather than a menu to deliberate over.
#
# Matching is on the movement name with the count stripped, so "ring dips x5"
# in the plan still matches "5 ring dips" typed into Other..., and editing a
# rep count does not make a movement look untouched.
rotate_options() {
  if [ ! -s "$LOG" ]; then cat; return; fi
  awk -F'\t' -v today="$(date '+%Y-%m-%d')" '
    function key(s) {
      s = tolower(s)
      sub(/[ \t]*x[0-9]+[ \t]*$/, "", s)
      sub(/^[0-9]+[ \t]+/, "", s)
      gsub(/[ \t]+/, " ", s)
      sub(/^ /, "", s); sub(/ $/, "", s)
      return s
    }
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

# One row: iso8601 <TAB> exercise <TAB> reps <TAB> home|away
#
# The timestamp is the moment you answer, not the moment the nudge fired, so
# the log reflects when the set actually happened.
record() {
  printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "$3" >>"$LOG"
  # Refresh the history page so an already-open tab only needs a reload.
  "$(dirname "$0")/gtg-page" --no-open >/dev/null 2>&1 || true
}

# Escape for embedding in an AppleScript double-quoted string.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
