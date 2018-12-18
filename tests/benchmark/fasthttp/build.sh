#!/bin/bash
echo $PWD
INSDIR=$PWD/install
GOPATH=$PWD
GOROOT=$INSDIR/go

if [ ! -f server ]; then
  echo "building fasthttp..."
  mkdir $INSDIR
  if [ ! -f go1.11.linux-amd64.tar.gz ]; then
    wget -q https://dl.google.com/go/go1.11.linux-amd64.tar.gz  
  fi
  tar -C $INSDIR -xzf go1.11.linux-amd64.tar.gz
  export PATH=$PATH:$GOROOT/bin
  export GOPATH=$GOPATH
  export GOROOT=$GOROOT
  echo $GOROOT
  go get -d -u github.com/valyala/fasthttp/...
  go build -gcflags='-l=4' server
fi
