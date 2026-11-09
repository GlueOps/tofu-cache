#!/bin/sh
set -eu
rm -f /tmp/fcgiwrap.sock
su -s /bin/sh nginx -c 'exec fcgiwrap -s unix:/tmp/fcgiwrap.sock' &
sleep 1
exec nginx -g 'daemon off;'
