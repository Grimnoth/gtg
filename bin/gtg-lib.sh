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
    | awk '!seen[$0]++'
}

# Just the first option, for logging and for one-line summaries.
primary_option() {
  local first
  first=$(today_options "$1" | head -1)
  printf '%s' "${first:-do a quick set}"
}

# The rep count in a line, if there is one. Two shapes, because the plan writes
# one way ("pull-ups x5") and people type the other ("5 ring dips").
reps_from_line() {
  local s="$1" n
  n=$(printf '%s' "$s" | sed -n 's/.*[[:space:]]x\([0-9]\{1,\}\).*/\1/p')
  [ -n "$n" ] || n=$(printf '%s' "$s" | sed -n 's/^\([0-9]\{1,\}\)[[:space:]].*/\1/p')
  printf '%s' "$n"
}

# One row: iso8601 <TAB> exercise <TAB> reps <TAB> home|away
record() {
  printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1" "$2" "$3" >>"$LOG"
}

# Escape for embedding in an AppleScript double-quoted string.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
