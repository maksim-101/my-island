#!/usr/bin/env bash
# Thin capture harness for the vendored mediaremote-adapter (Vendor/MediaRemoteAdapter/).
#
# Resolves the vendored perl script + dylib by glob (never hardcoded file names),
# spawns /usr/bin/perl against them, and tees raw stdout byte-for-byte to an
# output file for later inspection. Never re-executes, evals, or path-expands
# captured adapter output — adapter stdout is untrusted third-party app metadata
# (T-05-01) and is captured verbatim to a file only.
#
# Usage:
#   scripts/capture-nowplaying.sh get  <output-file>
#   scripts/capture-nowplaying.sh loop <output-file> [duration-seconds]
#
# `get` performs exactly one discrete, human-initiated read — D-13 forbids
# polling `get` on a timer, and this harness contains no loop over `get`.
# `loop` runs the adapter's own persistent, event-driven subprocess for a
# bounded wall-clock duration (default 10s) and then terminates it; this is
# not polling — `loop` itself is notification-driven, and the harness only
# bounds how long a single evidence-capture session keeps it running.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$ROOT/Vendor/MediaRemoteAdapter"

MODE="${1:?Usage: $0 <get|loop> <output-file> [duration-seconds]}"
OUTPUT="${2:?Usage: $0 <get|loop> <output-file> [duration-seconds]}"
DURATION="${3:-10}"

case "$MODE" in
  get|loop) ;;
  *)
    echo "Unknown mode: $MODE (expected 'get' or 'loop')" >&2
    exit 1
    ;;
esac

SCRIPT_PATH="$(ls "$VENDOR_DIR"/*.pl 2>/dev/null | head -n1)"
DYLIB_PATH="$(ls "$VENDOR_DIR"/*.dylib 2>/dev/null | head -n1)"

if [[ -z "$SCRIPT_PATH" || -z "$DYLIB_PATH" ]]; then
  echo "Could not resolve vendored adapter script/dylib under $VENDOR_DIR" >&2
  exit 1
fi

echo "Resolved invocation: /usr/bin/perl $SCRIPT_PATH $DYLIB_PATH $MODE"

: > "$OUTPUT"

if [[ "$MODE" == "get" ]]; then
  /usr/bin/perl "$SCRIPT_PATH" "$DYLIB_PATH" get 2>/dev/null | tee "$OUTPUT" >/dev/null
else
  /usr/bin/perl "$SCRIPT_PATH" "$DYLIB_PATH" loop 2>/dev/null | tee "$OUTPUT" >/dev/null &
  TEE_PID=$!
  sleep "$DURATION"
  # Stop the adapter subprocess by matching our own known script path (a fixed,
  # locally-constructed string) — never anything derived from adapter stdout.
  pkill -f "$SCRIPT_PATH" >/dev/null 2>&1 || true
  wait "$TEE_PID" 2>/dev/null || true
fi

BYTES=$(wc -c < "$OUTPUT" | tr -d ' ')
echo "Observed byte count: $BYTES"
