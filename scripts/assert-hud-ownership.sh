#!/usr/bin/env bash
# HUD ownership guard (HUD-03, HUD-04, HUD-05, HUD-06) — re-runnable after any change.
#
# Static checks for the invariants that keep the brightness tap opt-in and narrow: one
# Accessibility prompt call site, one event tap, a type-14-only production mask, a built-in-only
# brightness setter, debug flags never written by code, and dev-reset still clearing the grant.
# Swift lines whose content starts with `//` (doc comments included) are ignored, so a comment
# that names an API never trips a check.
#
# Exit: 0 all passed, 1 a check failed, 2 usage.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -gt 0 ]]; then
  echo "usage: $0" >&2
  exit 2
fi

passed=0
failed=0

pass() { echo "PASS $1"; passed=$((passed + 1)); }
fail() { echo "FAIL $1: $2"; failed=$((failed + 1)); }

# Non-comment Swift matches for a fixed string, as "file:line:content" lines.
code_hits() {
  local pattern="$1"; shift
  { grep -rn --include='*.swift' -F -- "$pattern" "$@" || true; } | { grep -v -E ':[0-9]+:[[:space:]]*//' || true; }
}

count_lines() {
  if [[ -z "$1" ]]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi
}

# exactly N hits of a pattern in Sources, all in the one given file
check_only_in() {
  local name="$1" pattern="$2" expected="$3" file="$4"
  local hits count outside
  hits=$(code_hits "$pattern" Sources)
  count=$(count_lines "$hits")
  outside=$({ printf '%s\n' "$hits" | grep -v "^$file:" || true; } | sed '/^$/d')
  if [[ "$count" -ne "$expected" ]]; then
    fail "$name" "expected $expected occurrence(s) of '$pattern', found $count"
  elif [[ -n "$outside" ]]; then
    fail "$name" "'$pattern' outside $file: $outside"
  else
    pass "$name"
  fi
}

check_prompt_call_site() { check_only_in prompt-call-site "AXIsProcessTrustedWithOptions" 1 Sources/App/SettingsView.swift; }
check_prompt_option()    { check_only_in prompt-option "AXTrustedCheckOptionPrompt" 1 Sources/App/SettingsView.swift; }
check_prompt_entry()     { check_only_in prompt-entry "requestAccessibility(" 2 Sources/App/SettingsView.swift; }
check_single_tap()       { check_only_in single-tap "tapCreate" 1 Sources/App/BrightnessKeyTap.swift; }

check_production_mask() {
  local def probe_hits outside
  def=$(code_hits "static let productionMask" Sources | head -1)
  if [[ -z "$def" ]]; then fail production-mask "no productionMask definition found"; return; fi
  if [[ "$def" != *"1 << 14"* || "$def" == *"1 << 10"* ]]; then
    fail production-mask "productionMask must be 1 << 14 only: $def"; return
  fi
  probe_hits=$(code_hits "1 << 10" Sources)
  outside=$({ printf '%s\n' "$probe_hits" | grep -v "probeMask" || true; } | sed '/^$/d')
  if [[ -n "$outside" ]]; then
    fail production-mask "1 << 10 outside the probeMask line: $outside"
  else
    pass production-mask
  fi
}

check_built_in_only() {
  local file=Sources/App/Providers/BrightnessProvider.swift main smooth setter
  main=$(code_hits "CGMainDisplayID" "$file")
  smooth=$(code_hits "DisplayServicesSetBrightnessSmooth" "$file")
  setter=$(count_lines "$(code_hits '"DisplayServicesSetBrightness"' "$file")")
  if [[ -n "$main" ]]; then fail built-in-only "main-display lookup in BrightnessProvider: $main"
  elif [[ -n "$smooth" ]]; then fail built-in-only "smoothing setter in BrightnessProvider: $smooth"
  elif [[ "$setter" -ne 1 ]]; then fail built-in-only "expected one \"DisplayServicesSetBrightness\" lookup, found $setter"
  else pass built-in-only
  fi
}

check_debug_flags_read_only() {
  local bad
  bad=$({ grep -rn --include='*.swift' -E 'MyIslandKeyProbe|MyIslandTapTimeoutSelfTest|probeKey|timeoutSelfTestKey' Sources || true; } \
    | { grep -v -E ':[0-9]+:[[:space:]]*//' || true; } | { grep -E 'set\(' || true; })
  if [[ -n "$bad" ]]; then fail debug-flags-read-only "a debug flag is written by code: $bad"; else pass debug-flags-read-only; fi
}

check_dev_reset_accessibility() {
  if grep -q "tccutil reset Accessibility" scripts/dev-reset.sh; then pass dev-reset-accessibility
  else fail dev-reset-accessibility "scripts/dev-reset.sh no longer resets Accessibility"; fi
}

check_volume_gate() {
  local hits
  hits=$(count_lines "$(code_hits 'VolumeHUDPolicy.shouldShow(' Sources/App/NotchPanelController.swift)")
  if [[ "$hits" -eq 1 ]]; then pass volume-gate
  else fail volume-gate "expected one VolumeHUDPolicy.shouldShow( in NotchPanelController.swift, found $hits"; fi
}

check_finetune_read_only() {
  local file=Sources/App/FineTuneMonitor.swift hits="" p
  for p in forceTerminate '.terminate(' '.hide(' '.activate(' openApplication; do
    hits+=$(code_hits "$p" "$file")
  done
  if [[ -z "$hits" ]]; then pass finetune-read-only
  else fail finetune-read-only "FineTuneMonitor acts on FineTune: $hits"; fi
}

check_prompt_call_site
check_prompt_option
check_prompt_entry
check_single_tap
check_production_mask
check_built_in_only
check_debug_flags_read_only
check_dev_reset_accessibility
check_volume_gate
check_finetune_read_only

echo "assert-hud-ownership: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
