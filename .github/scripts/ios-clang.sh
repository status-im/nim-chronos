#!/usr/bin/env bash

set -euo pipefail

: "${IOS_SDK_PATH:?IOS_SDK_PATH must point to the iPhone simulator SDK}"

exec xcrun --sdk iphonesimulator clang \
  -target arm64-apple-ios13.0-simulator \
  -isysroot "$IOS_SDK_PATH" \
  -mios-simulator-version-min=13.0 \
  "$@"
