#!/usr/bin/env bash
# D-04 regression check (RESEARCH.md Pitfall 1): run the D-03 spike harness in `cycle` hold mode
# for a given material and confirm every clickProbe line reads insideHit n/n and outsidePass n/n.
# Re-runnable after any macOS point release to catch a silent alpha-hit-testing regression.
set -euo pipefail

MODE="${1:-}"
MATERIAL="${2:-black}"
BUNDLE_ID="com.maksim101.myisland"
APP_NAME="my-island"
LOG_WAIT_SECONDS=45
LOG_POLL_INTERVAL=2

if [[ "$MODE" != "spike" ]]; then
  echo "usage: $0 spike [black|glass|glassContainer]" >&2
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

echo "==> Arming spike harness (material=${MATERIAL}, hold=cycle)"
quit_app
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
    if /usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"FluidSpike\"" --last 2m --style compact 2>/dev/null \
      | grep -q "clickProbe state=${state} "; then
      FOUND=$((FOUND + 1))
    fi
  done
  if [ "$FOUND" -eq "${#STATES[@]}" ]; then
    break
  fi
  sleep "$LOG_POLL_INTERVAL"
  n=$((n + 1))
done

LINES="$(/usr/bin/log show --predicate "subsystem == \"${BUNDLE_ID}\" AND category == \"FluidSpike\"" --last 2m --style compact 2>/dev/null | grep "clickProbe" || true)"
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
