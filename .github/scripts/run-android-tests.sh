#!/usr/bin/env bash

set -euo pipefail

binary="${1:?usage: run-android-tests.sh <test-binary>}"
remote_dir="/data/local/tmp/nim-chronos"
remote_binary="$remote_dir/$(basename "$binary")"

adb shell "mkdir -p '$remote_dir'"
adb push "$binary" "$remote_binary"
adb shell "chmod 755 '$remote_binary'"
adb shell "cd '$remote_dir' && '$remote_binary'"
