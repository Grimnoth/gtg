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
chmod +x "$REPO/bin/gtg" "$REPO/bin/gtg-nudge"

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
    printf '%s' "$mac" >"$CONF_DIR/home-gateway-mac"
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

# --- dependency -------------------------------------------------------------
if ! command -v icalBuddy >/dev/null 2>&1; then
  echo
  echo "NOTE     icalBuddy is not installed, so meeting detection is off and"
  echo "         nudges will fire during meetings. Fix: brew install ical-buddy"
fi

echo
echo "Done. Try:  gtg plan   |   gtg   |   gtg week"
