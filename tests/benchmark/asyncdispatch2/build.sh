#!/bin/bash

if [ ! -f server ]; then
  echo "building asyncdispatch2..."
  nimble install -y https://github.com/status-im/nim-asyncdispatch2 > /dev/null
  nim c -d:release --verbosity:0 --hints:off --threads:on server.nim
fi
