#!/bin/sh
# The account room's signed out check for Safari (#808): prints exactly "signed out" once Safari's
# cookie store holds no live claude.ai session cookie (sessionKey). safari-cookies.py reads the store
# and prints only a count, never a name or value.
#
# Safari, like Chrome, writes a cookie's removal to its store some time after the page that removed
# it, so it looks again once a second, 50 times, inside the 60 seconds the mod allows the check. How
# long Safari takes has not been measured yet: the live proof with Dan present is on #808.
# Exit 0 signed out, 1 still signed in, 2 could not tell (printing why).
# Seams for the tests: ACCOUNT_ROOM_SAFARI_COOKIES, ACCOUNT_ROOM_NOW, ACCOUNT_ROOM_CHECK_TRIES and
# ACCOUNT_ROOM_PAUSE.
HERE=$(cd "$(dirname "$0")" && pwd)
TRIES="${ACCOUNT_ROOM_CHECK_TRIES:-50}"
PAUSE="${ACCOUNT_ROOM_PAUSE:-/bin/sleep 1}"
command -v python3 >/dev/null 2>&1 || { echo "could not read Safari's cookies: python3 is not installed"; exit 2; }
i=0
while :; do
  n=$(python3 "$HERE/safari-cookies.py") || { echo "$n"; exit 2; }
  if [ "$n" = 0 ]; then echo "signed out"; exit 0; fi
  i=$((i + 1))
  if [ "$i" -ge "$TRIES" ]; then echo "still signed in to claude.ai in Safari"; exit 1; fi
  eval "$PAUSE"
done
