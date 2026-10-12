#!/bin/sh
# Reports what a container image expects from its runtime, then echoes stdin.
echo "probe: fd0=$(readlink /proc/self/fd/0)"
[ -e /dev/fd/0 ] && [ -e /dev/stdin ] && echo "probe: devfd-ok"
echo "probe: stdout-path-ok" > /dev/stdout
echo "probe: stderr-path-ok" > /dev/stderr
while read -r l; do echo "probe: got: $l"; done
echo "probe: stdin closed"
exec sleep 600
