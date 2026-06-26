#!/usr/bin/env bash
# Print an xcodebuild `-destination` string for the newest available iPhone
# simulator on this machine. CI uses this instead of hardcoding a device/runtime
# that may not be installed on the runner image.
set -euo pipefail

udid=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
data = json.load(sys.stdin)
best = None
for runtime in sorted(data["devices"].keys()):
    if "iOS" not in runtime:
        continue
    for d in data["devices"][runtime]:
        if d.get("isAvailable") and "iPhone" in d.get("name", ""):
            best = d["udid"]  # sorted runtimes -> last match is newest iOS
print(best or "")
')

if [ -z "$udid" ]; then
  echo "No available iPhone simulator found" >&2
  xcrun simctl list devices available >&2
  exit 1
fi

printf 'platform=iOS Simulator,id=%s\n' "$udid"
