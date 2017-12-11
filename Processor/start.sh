#!/usr/bin/env bash

echo "Starting Fazool Processor..."

CHECK=`ps auxwwww | grep processor.rb | grep -v grep | grep -v ack | awk '{print $2}'`

if [ "x${CHECK}" != "x" ];then
  echo "There is already a Fazool Processor running with PID ${CHECK}"
  exit 1
fi

PROCESSOR_PATH=`dirname $0`

( cd ${PROCESSOR_PATH} && nohup ${PROCESSOR_PATH}/processor.rb > /tmp/processor.out 2>&1 & )

if [ $? -eq 0 ]; then
  echo "Started successfully." 
  exit 0
else
  echo "ERROR Failed to start Fazool Processor."
  exit 1
fi

