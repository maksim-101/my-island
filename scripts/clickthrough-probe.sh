#!/usr/bin/env bash
# D-04 regression check (RESEARCH.md Pitfall 1).
#
# No argument (default, 07-02 Task 2): probes the PRODUCTION panel sets — arms
# MyIslandClickProbe on the real installed app, confirms one clickProbe line per connected display,
# and surfaces any outsideClick line (NotchPanel.sendEvent's swallowed-click detector, the real
# D-04 evidence under the toggle click-through mechanism 07-01 chose). Re-runnable after any macOS
# point release.
#
# `spike [black|glass|glassContainer]` (07-01): the measurement harness in `cycle` hold mode,
# confirming every clickProbe line reads insideHit n/n and outsidePass n/n.
set -euo pipefail

MODE="${1:-}"
MATERIAL="${2:-black}"
BUNDLE_ID="com.maksim101.myisland"
APP_NAME="my-island"
LOG_WAIT_SECONDS=45
LOG_POLL_INTERVAL=2

if [[ -n "$MODE" && "$MODE" != "spike" ]]; then
  echo "usage: $0 [spike [black|glass|glassContainer]]" >&2
  exit 2
fi

quit_app() {
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
  sleep 1
}

cleanup_defaults() {
  defaults delete "$BUNDLE_ID" MyIslandFluidSpike >/dev/null 2>&1 || true
  defaults delete "$BUNDLE_ID" MyIslandFluidSpikeHold >/dev/null 2>&1 || true
  defaults delete "$BUNDLE_ID" MyIslandFluidSpikeMaterial >/dev/null 2>&1 || true
}

restore_normal_app() {
  quit_app
  cleanup_defaults
  open "/Applications/${APP_NAME}.app"
}

if [[ -z "$MODE" ]]; then
  # ---- production mode (default, no argument): probes the real, installed panel sets ----
  echo "==> Arming production click-through probe"
  quit_app
  START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
  defaults write "$BUNDLE_ID" MyIslandVerboseLogging -bool YES
  defaults write "$BUNDLE_ID" MyIslandClickProbe -bool YES
  open "/Applications/${APP_NAME}.app"

  DISPLAY_COUNT="$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c Resolution || true)"
  [ "${DISPLAY_COUNT:-0}" -ge 1 ] || DISPLAY_COUNT=1

  PROD_WAIT_SECONDS=30
  PROD_POLL_INTERVAL=2
  MAX_ITER=$((PROD_WAIT_SECONDS / PROD_POLL_INTERVAL))
  n=0
  while [ "$n" -lt "$MAX_ITER" ]; do
    SEEN="$( { /usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"NotchPanelController\"" --start "$START_TS" --style compact 2>/dev/null \
      | grep -oE 'clickProbe.*display=[^ ]+' | grep -oE 'display=[^ ]+' | sort -u | wc -l | tr -d ' '; } || true)"
    if [ "${SEEN:-0}" -ge "$DISPLAY_COUNT" ]; then
      break
    fi
    sleep "$PROD_POLL_INTERVAL"
    n=$((n + 1))
  done

  PROBE_LINES="$(/usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"NotchPanelController\"" --start "$START_TS" --style compact 2>/dev/null | grep "clickProbe" || true)"
  OUTSIDE_LINES="$(/usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"NotchPanelController\"" --start "$START_TS" --style compact 2>/dev/null | grep "outsideClick" || true)"

  echo "$PROBE_LINES"
  if echo "$PROBE_LINES" | grep -q "mode=toggle"; then
    echo "toggle mode: outsideClick lines in the log are the D-04 evidence"
  fi
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

  if [ -n "$OUTSIDE_LINES" ]; then
    echo "==> outsideClick lines present — a collapsed panel caught a click outside its own outline (D-04 regression)" >&2
    exit 1
  fi

  FAILING=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -q "mode=toggle"; then
      continue
    fi
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
    echo "==> One or more alpha-mode states did not reach full insideHit/outsidePass" >&2
    exit 1
  fi

  exit 0
fi

echo "==> Arming spike harness (material=${MATERIAL}, hold=cycle)"
quit_app
# Timestamp captured AFTER quiescing the previous run and BEFORE relaunch, so log queries below
# use --start instead of a rolling --last window — a prior run's material=X lines must never
# satisfy this run's material=Y completeness/pass check (they cannot, once time-scoped this way).
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
defaults write "$BUNDLE_ID" MyIslandVerboseLogging -bool YES
defaults write "$BUNDLE_ID" MyIslandFluidSpike -bool YES
defaults write "$BUNDLE_ID" MyIslandFluidSpikeHold -string cycle
defaults write "$BUNDLE_ID" MyIslandFluidSpikeMaterial -string "$MATERIAL"
open "/Applications/${APP_NAME}.app"

echo "==> Polling FluidSpike log for pill, band, dropEdge, dropMiddle, alert (up to ${LOG_WAIT_SECONDS}s)"
STATES=(pill band dropEdge dropMiddle alert)
n=0
MAX_ITER=$((LOG_WAIT_SECONDS / LOG_POLL_INTERVAL))
while [ "$n" -lt "$MAX_ITER" ]; do
  FOUND=0
  for state in "${STATES[@]}"; do
    if /usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"FluidSpike\"" --start "$START_TS" --style compact 2>/dev/null \
      | grep "material=${MATERIAL} " | grep -q "clickProbe state=${state} "; then
      FOUND=$((FOUND + 1))
    fi
  done
  if [ "$FOUND" -eq "${#STATES[@]}" ]; then
    break
  fi
  sleep "$LOG_POLL_INTERVAL"
  n=$((n + 1))
done

LINES="$(/usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"FluidSpike\"" --start "$START_TS" --style compact 2>/dev/null | grep "clickProbe" | grep "material=${MATERIAL} " || true)"
echo "$LINES"

PROBED_COUNT=0
for state in "${STATES[@]}"; do
  if echo "$LINES" | grep -q "clickProbe state=${state} "; then
    PROBED_COUNT=$((PROBED_COUNT + 1))
  fi
done

restore_normal_app

if [ "$PROBED_COUNT" -lt 5 ]; then
  echo "==> Only ${PROBED_COUNT}/5 states probed — harness did not complete a full cycle" >&2
  exit 2
fi

FAILING=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  if echo "$line" | grep -q "mode=toggle"; then
    continue
  fi
  INSIDE="$(echo "$line" | grep -oE 'insideHit=[0-9]+/[0-9]+' | cut -d= -f2)"
  OUTSIDE="$(echo "$line" | grep -oE 'outsidePass=[0-9]+/[0-9]+' | cut -d= -f2)"
  IN_HIT="${INSIDE%%/*}"; IN_TOTAL="${INSIDE##*/}"
  OUT_PASS="${OUTSIDE%%/*}"; OUT_TOTAL="${OUTSIDE##*/}"
  if [ "$IN_HIT" != "$IN_TOTAL" ] || [ "$OUT_PASS" != "$OUT_TOTAL" ]; then
    FAILING=1
  fi
done <<< "$LINES"

if [ "$FAILING" -eq 1 ]; then
  echo "==> One or more states did not reach full insideHit/outsidePass" >&2
  exit 1
fi

exit 0
