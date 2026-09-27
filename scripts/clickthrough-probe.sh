#!/usr/bin/env bash
# D-04 regression check (RESEARCH.md Pitfall 1).
#
# Probes the PRODUCTION panel sets — arms MyIslandClickProbe on the real installed app, confirms
# one clickProbe line per connected display, and surfaces any outsideClick line
# (NotchPanel.sendEvent's swallowed-click detector, the real D-04 evidence under the toggle
# click-through mechanism 07-01 chose). Re-runnable after any macOS point release.
#
# 07-13: the `spike [black|glass|glassContainer]` mode (07-01's measurement harness) is retired
# along with `FluidSpikeController` itself — this script now checks production surfaces only.
set -euo pipefail

BUNDLE_ID="com.maksim101.myisland"
APP_NAME="my-island"

if [[ $# -gt 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi

quit_app() {
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
  sleep 1
}

echo "==> Arming production click-through probe"
quit_app
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
defaults write "$BUNDLE_ID" MyIslandVerboseLogging -bool YES
defaults write "$BUNDLE_ID" MyIslandClickProbe -bool YES
open "/Applications/${APP_NAME}.app"

DISPLAY_COUNT="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c Resolution || true)"
[ "${DISPLAY_COUNT:-0}" -ge 1 ] || DISPLAY_COUNT=1

# 07-08 Task 3: three lines per display now — the collapsed "skipped" line, then
# `surface=band` and `surface=droplet` from `NotchPanelController.runOpenSurfaceProbe`, which
# opens the band (per-point ignoresMouseEvents + a 20ms settle before each windowNumber(at:)
# query, since 07-01 measured that assignment taking up to ~9ms/p99 to actually apply), shows
# the droplet, probes, then closes. Budget generously: ~48 points × 20ms × 2 surfaces per
# display, plus the open/settle waits.
PROD_WAIT_SECONDS=45
PROD_POLL_INTERVAL=2
MAX_ITER=$((PROD_WAIT_SECONDS / PROD_POLL_INTERVAL))
n=0
while [ "$n" -lt "$MAX_ITER" ]; do
  LOG_SO_FAR="$(/usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"NotchPanelController\"" --start "$START_TS" --style compact 2>/dev/null | grep "clickProbe" || true)"
  READY=1
  for display in $(echo "$LOG_SO_FAR" | grep -oE 'display=[^ ]+' | sort -u); do
    key="${display#display=}"
    echo "$LOG_SO_FAR" | grep -q "skipped mode=toggle display=${key}\$" || READY=0
    echo "$LOG_SO_FAR" | grep -q "surface=band .*display=${key} " || READY=0
    echo "$LOG_SO_FAR" | grep -q "surface=droplet .*display=${key} " || READY=0
  done
  SEEN_DISPLAYS="$( { echo "$LOG_SO_FAR" | grep -oE 'display=[^ ]+' | sort -u | wc -l | tr -d ' '; } || true)"
  if [ "$READY" -eq 1 ] && [ "${SEEN_DISPLAYS:-0}" -ge "$DISPLAY_COUNT" ]; then
    break
  fi
  sleep "$PROD_POLL_INTERVAL"
  n=$((n + 1))
done

PROBE_LINES="$(/usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"NotchPanelController\"" --start "$START_TS" --style compact 2>/dev/null | grep "clickProbe" || true)"
OUTSIDE_LINES="$(/usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"NotchPanelController\"" --start "$START_TS" --style compact 2>/dev/null | grep "outsideClick" || true)"

echo "$PROBE_LINES"
if [ -n "$OUTSIDE_LINES" ]; then
  echo "$OUTSIDE_LINES"
fi

# Debug defaults are ALWAYS cleared before this script exits, success or failure — never leave
# the installed app logging verbosely or click-probing on a normal relaunch.
defaults delete "$BUNDLE_ID" MyIslandClickProbe >/dev/null 2>&1 || true
defaults delete "$BUNDLE_ID" MyIslandVerboseLogging >/dev/null 2>&1 || true
quit_app
open "/Applications/${APP_NAME}.app"

SEEN_DISPLAYS="$( { echo "$PROBE_LINES" | grep -oE 'display=[^ ]+' | sort -u | wc -l | tr -d ' '; } || true)"
if [ "${SEEN_DISPLAYS:-0}" -lt "$DISPLAY_COUNT" ]; then
  echo "==> Only ${SEEN_DISPLAYS:-0}/${DISPLAY_COUNT} connected displays reported a clickProbe line" >&2
  exit 2
fi
if ! echo "$PROBE_LINES" | grep -q "surface=band "; then
  echo "==> No surface=band line — the band probe did not run or did not complete" >&2
  exit 2
fi
if ! echo "$PROBE_LINES" | grep -q "surface=droplet "; then
  echo "==> No surface=droplet line — the droplet probe did not run or did not complete" >&2
  exit 2
fi

if [ -n "$OUTSIDE_LINES" ]; then
  echo "==> outsideClick lines present — a panel caught a click outside its own outline (D-04 regression)" >&2
  exit 1
fi

# Validate every surface=* line's insideHit/outsidePass — the bare "skipped mode=toggle
# display=..." collapsed line carries no insideHit and is correctly left unvalidated.
FAILING=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  INSIDE="$( { echo "$line" | grep -oE 'insideHit=[0-9]+/[0-9]+' | cut -d= -f2; } || true)"
  OUTSIDE="$( { echo "$line" | grep -oE 'outsidePass=[0-9]+/[0-9]+' | cut -d= -f2; } || true)"
  [ -z "$INSIDE" ] && continue
  IN_HIT="${INSIDE%%/*}"; IN_TOTAL="${INSIDE##*/}"
  OUT_PASS="${OUTSIDE%%/*}"; OUT_TOTAL="${OUTSIDE##*/}"
  if [ "$IN_HIT" != "$IN_TOTAL" ] || [ "$OUT_PASS" != "$OUT_TOTAL" ]; then
    FAILING=1
  fi
done <<< "$PROBE_LINES"

if [ "$FAILING" -eq 1 ]; then
  echo "==> One or more surfaces did not reach full insideHit/outsidePass" >&2
  exit 1
fi

exit 0
