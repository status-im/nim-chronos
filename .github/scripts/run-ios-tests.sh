#!/usr/bin/env bash

set -euo pipefail

binary="${1:?usage: run-ios-tests.sh <test-binary>}"
device_udid="${IOS_SIMULATOR_UDID:-}"

if [[ -z "$device_udid" ]]; then
  device_udid="$(
    xcrun simctl list devices available --json | /usr/bin/python3 -c '
import json
import re
import sys

def runtime_version(runtime):
    match = re.search(r"iOS-(\d+(?:[-.]\d+)*)", runtime)
    if not match:
        return ()
    return tuple(int(part) for part in re.split(r"[-.]", match.group(1)))

candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if ".iOS-" not in runtime:
        continue
    for device in devices:
        if not device.get("isAvailable", True):
            continue
        if not device.get("name", "").startswith("iPhone"):
            continue
        candidates.append((runtime_version(runtime), device["udid"]))

if not candidates:
    raise SystemExit("no available iPhone simulator device")
print(max(candidates)[1])
'
  )"
fi

xcrun simctl boot "$device_udid" 2>/dev/null || true
xcrun simctl bootstatus "$device_udid" -b
codesign --force --sign - "$binary"
xcrun simctl spawn "$device_udid" "$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"
