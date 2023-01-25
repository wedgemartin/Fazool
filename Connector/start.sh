#!/usr/bin/env bash

echo "Starting Fazool Connector..."

if [ "x${FAZ_PASS}" = "x" ];then
  echo "Must supply a value for FAZ_PASS in your environment!"
  exit 1
fi

if [ "x${FAZ_MUD_HOST}" = "x" ];then
  echo "Must supply a value for FAZ_MUD_HOST in your environment!"
  exit 1
fi

if [ "x${FAZ_MUD_PORT}" = "x" ];then
  echo "Must supply a value for FAZ_MUD_PORT in your environment!"
  exit 1
fi

CHECK=`ps auxwwww | grep connector.rb | grep -v grep | grep -v ack | awk '{print $2}'`

if [ "x${CHECK}" != "x" ];then
  echo "There is already a Fazool Connector running with PID ${CHECK}"
  # exit 1
fi

CONNECTOR_PATH=`dirname $0`

( cd ${CONNECTOR_PATH} && nohup ${CONNECTOR_PATH}/connector.rb > /tmp/connector.$$.${FAZ_QUEUE_NAME}.out 2>&1 & )

if [ $? -eq 0 ]; then
  echo "Started successfully." 
  exit 0
else
  echo "ERROR Failed to start Fazool Connector."
  exit 1
fi

