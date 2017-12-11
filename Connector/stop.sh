#!/usr/bin/env bash

echo "Stopping Fazool Connector..."

CHECK=`ps auxwwww | grep connector.rb | grep -v grep | grep -v ack | awk '{print $2}'`

if [ "x${CHECK}" = "x" ];then
  echo "There is no Fazool Connector process running."
  exit 1
fi

kill ${CHECK}
sleep 1

CHECK_TWO=`ps auxwwww | grep "${CHECK}" | grep rb | grep connector`
if [ "x${CHECK_TWO}" != "x" ];then
  echo "Process ${CHECK} failed to terminate."
  exit 1
else
  exit 0
fi
