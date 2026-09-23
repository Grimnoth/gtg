#!/bin/bash
# Idempotent. Safe to re-run after editing anything in bin/.
set -eu

REPO=$(cd "$(dirname "$0")" && pwd -P)
CONF_DIR="$HOME/.config/gtg"
STATE_DIR="$HOME/.local/state/gtg"
SHIM="$HOME/.local/bin/gtg"
LABEL="com.grimnoth.gtg"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$CONF_DIR" "$STATE_DIR" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
chmod +x "$REPO/bin/gtg" "$REPO/bin/gtg-nudge" "$REPO/bin/gtg-page" "$REPO/bin/gtg-interpret"

# --- gtg say (optional) -----------------------------------------------------
# On-device speech, through the framework macOS 26 ships. It is compiled here
# rather than shipped as a binary so there is nothing to trust and nothing to
# sign, and the whole feature is skipped when there is no compiler: `gtg say`
# is a convenience, and an install that fails over a convenience is worse than
# one without it.
if command -v swiftc >/dev/null 2>&1; then
  if [ ! -x "$REPO/bin/gtg-listen" ] \
     || [ "$REPO/bin/gtg-listen.swift" -nt "$REPO/bin/gtg-listen" ]; then
    if swiftc -O -parse-as-library -o "$REPO/bin/gtg-listen" "$REPO/bin/gtg-listen.swift" \
         2>"$STATE_DIR/build.log"; then
      echo "built    bin/gtg-listen  (gtg say)"
    else
      echo "WARN     bin/gtg-listen did not build; gtg say is off."
      echo "         See $STATE_DIR/build.log"
    fi
  else
    echo "current  bin/gtg-listen"
  fi
else
  echo "skipped  gtg say (no swiftc; install Xcode or its command line tools)"
fi

# --- plan.txt: seeded once, then it is yours. Never overwritten. -------------
if [ ! -f "$CONF_DIR/plan.txt" ]; then
  cp "$REPO/plan.example.txt" "$CONF_DIR/plan.txt"
  echo "seeded   $CONF_DIR/plan.txt"
else
  echo "kept     $CONF_DIR/plan.txt (already yours)"
fi

# --- home gateway MAC -------------------------------------------------------
# Run this while at home. Re-run it if the router is moved or replaced.
gw=$(/sbin/route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}' || true)
mac=""
if [ -n "$gw" ]; then
  mac=$(/usr/sbin/arp -n "$gw" 2>/dev/null | awk '{print $4; exit}' || true)
fi
case "${mac:-}" in
  *:*:*:*:*:*)
    # One MAC per line; `gtg home` appends others. Never clobber existing ones.
    if ! grep -qxF "$mac" "$CONF_DIR/home-gateway-mac" 2>/dev/null; then
      printf '%s\n' "$mac" >>"$CONF_DIR/home-gateway-mac"
    fi
    echo "home     gateway $gw -> $mac"
    ;;
  *)
    echo "WARN     no gateway MAC readable; every nudge will read as 'away'."
    echo "         Re-run this on your home network to fix it."
    ;;
esac

# --- launcher shim ----------------------------------------------------------
# A shim rather than a symlink, so that $0 inside gtg is always the real path
# and it finds gtg-lib.sh beside it without any symlink resolution.
printf '#!/bin/sh\nexec "%s/bin/gtg" "$@"\n' "$REPO" >"$SHIM"
chmod +x "$SHIM"
echo "linked   $SHIM"

# --- launchd ----------------------------------------------------------------
sed "s|__HOME__|$HOME|g" "$REPO/launchd/$LABEL.plist" >"$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns at once, but a job with a live process (an open nudge
# dialog) stays registered until launchd has killed it, up to its 20s exit
# timeout. A bootstrap inside that window fails with "5: Input/output error",
# and the job is simply gone: no nudges, nothing in the log. That is how a
# ./ship at 11:20 on 2026-09-22 silenced every nudge after it. Measured with a
# throwaway job before trusting this: registered for 5s of a 5s timeout, then
# the bootstrap went through.
for _ in $(seq 1 30); do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 1
done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "loaded   $LABEL (fires at :20 and :50)"

# --- menu bar (optional) ----------------------------------------------------
# Hammerspoon rather than a menu bar app of its own, because it was already
# installed and running here. Skipped entirely when it is not.
HS_DIR="$HOME/.hammerspoon"
if [ -d "/Applications/Hammerspoon.app" ]; then
  mkdir -p "$HS_DIR"
  cp "$REPO/hammerspoon/gtg.lua" "$HS_DIR/gtg.lua"
  echo "copied   $HS_DIR/gtg.lua"
  # One guarded line in init.lua, appended only when it is not already there.
  # init.lua is yours and has broken itself before, so it is backed up first
  # and nothing already in it is ever rewritten.
  if [ -f "$HS_DIR/init.lua" ] && grep -q 'gtg\.lua' "$HS_DIR/init.lua"; then
    echo "kept     $HS_DIR/init.lua (already loads it)"
  else
    [ -f "$HS_DIR/init.lua" ] && cp "$HS_DIR/init.lua" "$HS_DIR/init.lua.bak-gtg"
    cat >>"$HS_DIR/init.lua" <<'LUA'

-- GTG menu bar (grease-the-groove). Kept in its own file and loaded inside a
-- pcall so a fault in it cannot take the rest of this config down with it.
local gtgOk, gtgErr = pcall(dofile, os.getenv("HOME") .. "/.hammerspoon/gtg.lua")
if not gtgOk then hs.printf("gtg.lua failed to load: %s", tostring(gtgErr)) end
LUA
    echo "added    load line to $HS_DIR/init.lua"
  fi
  # </dev/null: when stdin is a pipe, hs runs -c and then keeps reading stdin
  # for more commands until the pipe closes. Under anything that pipes
  # ./ship (an agent, a script) that is never, and install.sh hung for ten
  # minutes on 2026-09-23. Even `hs -c 'return 1'` does it. Scheduling the
  # reload lets the command return before the port it talks to goes away,
  # so it exits 0 rather than 69.
  command -v hs >/dev/null 2>&1 && hs -c 'hs.timer.doAfter(0.2, hs.reload)' </dev/null >/dev/null 2>&1 || true
else
  echo "skipped  menu bar (Hammerspoon not installed)"
fi

# --- dependency -------------------------------------------------------------
if ! command -v icalBuddy >/dev/null 2>&1; then
  echo
  echo "NOTE     icalBuddy is not installed, so meeting detection is off and"
  echo "         nudges will fire during meetings. Fix: brew install ical-buddy"
fi

# --- reading a sentence -----------------------------------------------------
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  echo
  echo "NOTE     neither claude nor codex is on PATH, so a line the parser"
  echo "         cannot read is refused rather than interpreted. That is the"
  echo "         old behaviour, not a fault. See INTERPRET= in plan.txt."
fi

echo
if [ -x "$REPO/bin/gtg-listen" ]; then
  echo "Done. Try:  gtg mic   |   gtg say   |   gtg week"
  echo
  echo "Run 'gtg mic' FIRST. The system default input is often the wrong one:"
  echo "an interface with nothing plugged in records silence, and one with"
  echo "loopback records whatever is playing on the Mac."
else
  echo "Done. Try:  gtg plan   |   gtg   |   gtg week"
fi
