#!/bin/bash
# Starts JACK, then SuperCollider running netsong.scd. Used by the netsong service.
export JACK_NO_AUDIO_RESERVATION=1
export SC_JACK_DEFAULT_OUTPUTS="system:playback_1,system:playback_2"
export QT_QPA_PLATFORM=offscreen
jackd -d alsa -d hw:Headphones -P -r 44100 -p 512 -n 3 -S &
sleep 3
exec sclang -D "$(dirname "$(readlink -f "$0")")/netsong.scd"
