#!/bin/sh
# The account room's sign out route, chosen per Mac (#808): runs this Mac's browser's script for the
# step named, `logout` or `signed-out`, and passes on its output and exit code.
#
# Dan signs in to claude.ai with Safari on Daniels-MacBook-Pro-2 and with Chrome on Dans-MacBook-Pro.
# The payload is shared by both Macs, so the choice is keyed here on the Mac's LocalHostName rather
# than set as one synced default. A Mac named in neither line is refused by name, never given a
# browser it may not use (L75).
# Seams for the tests: ACCOUNT_ROOM_HOST (the Mac's name) and every seam of the scripts it runs.
HERE=$(cd "$(dirname "$0")" && pwd)
step="$1"
case "$step" in
  logout|signed-out) ;;
  *) echo "browser.sh: no such step '$step' (logout or signed-out)"; exit 2 ;;
esac
host="${ACCOUNT_ROOM_HOST:-$(/usr/sbin/scutil --get LocalHostName 2>/dev/null)}"
case "$host" in
  Daniels-MacBook-Pro-2) browser=safari ;;
  Dans-MacBook-Pro) browser=chrome ;;
  "") echo "could not read this Mac's name, so no browser was chosen to sign out in"; exit 2 ;;
  *) echo "no browser is set for this Mac ($host) to sign out in"; exit 2 ;;
esac
exec /bin/sh "$HERE/$browser-$step.sh"
