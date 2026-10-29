#!/bin/bash
# Follows the Listen switch in the visualiser: starts or stops netsong-stream.
# The Pi only makes outgoing requests; nothing listens on the Pi for this.
SERVER_IP=192.168.1.10   # change to your server's address
URL=http://$SERVER_IP:8095/api/stream
while true; do
  now=$(systemctl is-active netsong-stream)
  want=$(curl -fsS -m 4 "$URL?is=$now" 2>/dev/null | grep -c '"want": true')
  case "$now" in active|activating) running=1 ;; *) running=0 ;; esac
  if [ "$want" = 1 ] && [ $running = 0 ]; then systemctl start netsong-stream
  elif [ "$want" != 1 ] && [ $running = 1 ]; then systemctl stop netsong-stream
  fi
  sleep 3
done
