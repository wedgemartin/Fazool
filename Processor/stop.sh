#!/usr/bin/env bash

echo "Stopping Fazool Processor..."

CHECK=`ps auxwwww | grep processor.rb | grep -v grep | grep -v ack | awk '{print $2}'`

if [ "x${CHECK}" = "x" ];then
  echo "There is no Fazool Processor process running."
  exit 1
fi

kill ${CHECK}
sleep 1

CHECK_TWO=`ps auxwwww | grep "${CHECK}" | grep rb | grep processor`
if [ "x${CHECK_TWO}" != "x" ];then
  echo "Process ${CHECK_TWO} failed to terminate."
  exit 1
else
  exit 0
fi
