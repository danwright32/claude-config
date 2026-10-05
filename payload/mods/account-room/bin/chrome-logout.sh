#!/bin/sh
# The account room's browser logout (#659): loads claude.ai's logout page in Google Chrome's last
# used profile, the one `claude auth login` opens its sign in page in. Proven on a real Chrome on
# 2026-10-05; tests/test-account-room-chrome-signout.sh holds it to that.
# Seams for the tests: ACCOUNT_ROOM_CHROME_DIR and ACCOUNT_ROOM_OPEN.
CHROME_DIR="${ACCOUNT_ROOM_CHROME_DIR:-$HOME/Library/Application Support/Google/Chrome}"
OPEN="${ACCOUNT_ROOM_OPEN:-/usr/bin/open}"
profile=$(/usr/bin/plutil -extract profile.last_used raw -o - "$CHROME_DIR/Local State" 2>/dev/null) || {
  echo "could not read Chrome's last used profile from $CHROME_DIR/Local State" >&2
  exit 1
}
# -n starts a fresh launcher that hands the page to the running Chrome and returns, which is what
# makes Chrome honour the profile flag; a plain open drops the arguments when Chrome is running.
exec "$OPEN" -na "Google Chrome" --args --profile-directory="$profile" https://claude.ai/logout
