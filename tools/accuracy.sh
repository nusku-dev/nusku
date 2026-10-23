#!/usr/bin/env bash
# Runs the test service under nusku and compares nusku's numbers with the service's own.
# Build first: zig build, and go build -o zig-out/bin/nusku-gosvc tools/gosvc.go
set -u
cd "$(dirname "$0")/.."
WORKERS=${WORKERS:-4}
sudo -v || exit 1   # so the background sudo below does not need to ask for a password

"${SERVICE:-./zig-out/bin/nusku-gosvc}" -workers "$WORKERS" -out /tmp/svc-oracle.json > /tmp/svc-stdout.txt 2>&1 &
SVC=$!
sleep 3

# nusku runs for 70 s. The service's own window is the 52 s in the middle of that.
sudo env NUSKU_DUMP=1 ./zig-out/bin/nusku prof --pid "$SVC" --duration 70 > /tmp/svc-nusku.txt 2>&1 &
NUSKU=$!
sleep 8
kill -USR1 "$SVC"
sleep 52
kill -USR2 "$SVC"
wait "$NUSKU"
kill "$SVC" 2>/dev/null

cat /tmp/svc-stdout.txt
python3 tools/accuracy.py /tmp/svc-oracle.json /tmp/svc-nusku.txt
