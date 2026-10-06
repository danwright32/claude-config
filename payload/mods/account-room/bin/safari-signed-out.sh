#!/bin/sh
# The account room's signed out check for Safari (#808): prints exactly "signed out" once Safari's
# cookie store holds no live claude.ai session cookie (sessionKey). safari-cookies.py reads the store
# and prints only a count, never a name or value.
#
# Safari may, as Chrome does, write a cookie's removal to its store some time after the page that
# removed it, so it looks again once a second, 50 times, inside the 60 seconds the mod allows the check. How
# long Safari takes is not measured yet (the tries copy Chrome's): the live proof with Dan present
# is on #808.
# Exit 0 signed out, 1 still signed in, 2 could not tell (printing why).
# Seams for the tests: ACCOUNT_ROOM_SAFARI_COOKIES, ACCOUNT_ROOM_NOW, ACCOUNT_ROOM_CHECK_TRIES,
# ACCOUNT_ROOM_CHECK_SECONDS and ACCOUNT_ROOM_PAUSE.
HERE=$(cd "$(dirname "$0")" && pwd)
TRIES="${ACCOUNT_ROOM_CHECK_TRIES:-50}"
PAUSE="${ACCOUNT_ROOM_PAUSE:-/bin/sleep 1}"
# Bounded by elapsed time as well as tries, so the verdict is its own inside the mod's 60 s
# however slow a look is (one look at a 532,410 byte store took 0.03 s, 2026-10-05).
BUDGET="${ACCOUNT_ROOM_CHECK_SECONDS:-50}"
start=$SECONDS
command -v python3 >/dev/null 2>&1 || { echo "could not read Safari's cookies: python3 is not installed"; exit 2; }
i=0
while :; do
  i=$((i + 1))
  if ! n=$(python3 "$HERE/safari-cookies.py"); then
    [ -n "$n" ] || n="could not read Safari's cookies: the reader stopped without saying why"
    # A store that does not parse may be one Safari is rewriting, so it is looked at again; one that
    # cannot be opened will not open on the next look, and a parse failure on the last is the answer.
    case "$n" in
      "could not parse "*) { [ "$i" -ge "$TRIES" ] || [ $((SECONDS - start)) -ge "$BUDGET" ]; } && { echo "$n"; exit 2; } ;;
      *) echo "$n"; exit 2 ;;
    esac
    eval "$PAUSE"
    continue
  fi
  if [ "$n" = 0 ]; then echo "signed out"; exit 0; fi
  if [ "$i" -ge "$TRIES" ] || [ $((SECONDS - start)) -ge "$BUDGET" ]; then echo "still signed in to claude.ai in Safari"; exit 1; fi
  eval "$PAUSE"
done
