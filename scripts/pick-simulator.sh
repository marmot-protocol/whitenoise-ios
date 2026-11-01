#!/usr/bin/env bash
# Print an xcodebuild `-destination` string for the newest available iPhone
# simulator on this machine. CI uses this instead of hardcoding a device/runtime
# that may not be installed on the runner image. Set WN_TEST_DEVICE_NAME to pick
# that device on the newest runtime that has it.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Error: jq not found. Install with 'brew install jq'." >&2; exit 1; }

device="${WN_TEST_DEVICE_NAME:-}"

udid=$(
  xcrun simctl list devices available --json \
  | jq -r --arg device "$device" '
      [ .devices
        | to_entries[]
        | select(.key | test("SimRuntime\\.iOS-[0-9]+-[0-9]+$"))
        | (.key | capture("iOS-(?<maj>[0-9]+)-(?<min>[0-9]+)")) as $v
        | .value[]
        | select(.isAvailable and (if $device == "" then .name | test("iPhone") else .name == $device end))
        | [ ($v.maj | tonumber), ($v.min | tonumber), .udid ]
      ]
      | sort_by(.[0], .[1])
      | last
      | .[2] // empty
    '
)

if [ -z "$udid" ]; then
  echo "No available ${device:-iPhone} simulator found" >&2
  xcrun simctl list devices available >&2
  exit 1
fi

printf 'platform=iOS Simulator,id=%s\n' "$udid"
