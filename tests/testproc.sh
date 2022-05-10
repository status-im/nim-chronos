#!/bin/sh

if [ "$1" == "stdin" ]; then
  read -r inputdata
  echo "STDIN DATA: $inputdata"
elif [ "$1" == "timeout2" ]; then
  sleep 2
  exit 2
elif [ "$1" == "timeout10" ]; then
  sleep 10
else
  echo "arguments missing"
fi
