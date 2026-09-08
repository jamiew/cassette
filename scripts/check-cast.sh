#!/bin/bash
# Lists the Google Cast receivers visible from this machine.
#
# Deliberately not part of `make test`: an empty result means there is no Chromecast
# on this network, which is a fact about the room rather than a defect in the code.
# Run it when casting "doesn't work" to establish whether there is anything to cast
# to before looking at the app at all.
set -uo pipefail

DURATION="${1:-6}"
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

echo "Browsing for Cast receivers for ${DURATION}s..."
dns-sd -B _googlecast._tcp local. > "$OUT" 2>&1 &
PID=$!
sleep "$DURATION"
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

# Column 7 onwards is the instance name; the Add/Rmv column tells us it appeared.
FOUND=$(awk '$2 == "Add" { $1=""; $2=""; $3=""; $4=""; $5=""; $6=""; sub(/^ +/, ""); print }' "$OUT" | sort -u)

if [ -z "$FOUND" ]; then
  echo "No Cast receivers found."
  echo
  echo "That is the answer to 'why is the cast button doing nothing' more often than not."
  echo "Check that this machine is on the same network as the speaker, and that the"
  echo "network does not isolate clients from each other (guest Wi-Fi usually does)."
  exit 1
fi

echo "$FOUND" | sed 's/^/  /'
COUNT=$(echo "$FOUND" | wc -l | tr -d ' ')
echo
echo "$COUNT receiver(s) reachable. Discovery should work in the app."
