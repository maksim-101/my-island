#!/usr/bin/env bash
# Reset all TCC grants my-island will ever request, scoped to its bundle id.
# Ad-hoc signing churns the code signature on every rebuild, so TCC forgets
# prior grants (PITFALLS.md Pitfall 2) — run this after a rebuild, then re-grant.
set -euo pipefail

BUNDLE_ID="com.maksim101.myisland"

echo "==> Resetting TCC grants for $BUNDLE_ID"

# AppleEvents is macOS's internal tccutil name for the user-facing "Automation" privacy category.
tccutil reset AppleEvents "$BUNDLE_ID"
echo "    Reset: AppleEvents (Automation)"

tccutil reset Accessibility "$BUNDLE_ID"
echo "    Reset: Accessibility"

tccutil reset Calendar "$BUNDLE_ID"
echo "    Reset: Calendar"

tccutil reset SystemPolicyAllFiles "$BUNDLE_ID"
echo "    Reset: SystemPolicyAllFiles (Full Disk Access)"

tccutil reset ListenEvent "$BUNDLE_ID"
echo "    Reset: ListenEvent (Input Monitoring)"

echo "==> Done. All grants for $BUNDLE_ID cleared — re-grant on next use."
