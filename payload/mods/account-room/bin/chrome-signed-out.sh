#!/bin/sh
# The account room's signed out check (#659): prints exactly "signed out" once Google Chrome's last
# used profile holds no claude.ai session cookie (sessionKey). It reads a copy of the cookie file,
# since Chrome holds the live one open, and asks for names only, never values.
#
# Chrome writes a cookie's removal to disk late (31 seconds after the logout in the 2026-10-05
# proof; it saves cookie changes about every 30), so it looks again once a second, 50 times, inside
# the 60 seconds the mod allows the check. Exit 0 signed out, 1 still signed in, 2 could not tell.
# Seams for the tests: ACCOUNT_ROOM_CHROME_DIR, ACCOUNT_ROOM_CHECK_TRIES and ACCOUNT_ROOM_PAUSE.
CHROME_DIR="${ACCOUNT_ROOM_CHROME_DIR:-$HOME/Library/Application Support/Google/Chrome}"
TRIES="${ACCOUNT_ROOM_CHECK_TRIES:-50}"
PAUSE="${ACCOUNT_ROOM_PAUSE:-/bin/sleep 1}"
profile=$(/usr/bin/plutil -extract profile.last_used raw -o - "$CHROME_DIR/Local State" 2>/dev/null) || {
  echo "could not read Chrome's last used profile"
  exit 2
}
db="$CHROME_DIR/$profile/Cookies"
tmp=$(/usr/bin/mktemp -d) || { echo "could not make a folder to copy the cookies into"; exit 2; }
trap '/bin/rm -rf "$tmp"' EXIT
i=0
while :; do
  /bin/cp "$db" "$tmp/Cookies" 2>/dev/null || { echo "could not read the cookies of profile $profile"; exit 2; }
  # A change Chrome has not yet folded into the file sits in its write ahead log, so copy that too.
  /bin/rm -f "$tmp/Cookies-wal"
  if [ -f "$db-wal" ]; then /bin/cp "$db-wal" "$tmp/Cookies-wal" 2>/dev/null || { echo "could not read the cookies of profile $profile"; exit 2; }; fi
  n=$(/usr/bin/sqlite3 "$tmp/Cookies" "select count(*) from cookies where host_key in ('claude.ai', '.claude.ai') and name = 'sessionKey'" 2>/dev/null) || {
    echo "could not query the cookies of profile $profile"
    exit 2
  }
  if [ "$n" = 0 ]; then echo "signed out"; exit 0; fi
  i=$((i + 1))
  if [ "$i" -ge "$TRIES" ]; then echo "still signed in to claude.ai in profile $profile"; exit 1; fi
  eval "$PAUSE"
done
