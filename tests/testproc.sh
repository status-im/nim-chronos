#!/bin/sh

if [ "$1" == "stdin" ]; then
  read -r inputdata
  echo "STDIN DATA: $inputdata"
elif [ "$1" == "timeout2" ]; then
  sleep 2s
elif [ "$1" == "timeout10" ]; then
  sleep 10s
else
  echo "arguments missing"
fi
