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
chmod +x "$REPO/bin/gtg" "$REPO/bin/gtg-nudge" "$REPO/bin/gtg-page"

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
  command -v hs >/dev/null 2>&1 && hs -c 'hs.reload()' >/dev/null 2>&1 || true
else
  echo "skipped  menu bar (Hammerspoon not installed)"
fi

# --- dependency -------------------------------------------------------------
if ! command -v icalBuddy >/dev/null 2>&1; then
  echo
  echo "NOTE     icalBuddy is not installed, so meeting detection is off and"
  echo "         nudges will fire during meetings. Fix: brew install ical-buddy"
fi

echo
echo "Done. Try:  gtg plan   |   gtg   |   gtg week"
