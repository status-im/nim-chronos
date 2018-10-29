#!/bin/bash

if [ ! -f server ]; then
  echo "building mofuw..."
  nimble install -y mofuw packedjson > /dev/null
  nim c -d:release --threads:on -d:bufSize:512 --verbosity:0 --hints:off server.nim
fi
