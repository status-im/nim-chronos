#!/bin/bash

mkdir wrksrc
cd wrksrc
if [ ! -f 4.1.0.tar.gz ]; then
  wget -nc https://github.com/wg/wrk/archive/4.1.0.tar.gz | tar xz --strip-components=1
  make > /dev/null
  cp wrk ..
fi

cd ..
nim c -d:release -r bot
