#!/bin/bash
# Tests for the account room's browser sign out route (#659): bin/chrome-logout.sh, which loads
# claude.ai's logout page in Chrome's last used profile, and bin/chrome-signed-out.sh, which prints
# exactly "signed out" once that profile holds no claude.ai session cookie. The route was proven on
# a real Chrome on 2026-10-05; these hold the scripts to it without a browser.
#
# Every seam is set: ACCOUNT_ROOM_CHROME_DIR (a fixture Chrome folder, never the real one),
# ACCOUNT_ROOM_OPEN (a stub, so no test ever opens a page, L2), ACCOUNT_ROOM_PAUSE (a stub, so no
# test waits in real time, L524) and ACCOUNT_ROOM_CHECK_TRIES. sqlite3 and plutil stay real: they
# are what reads the fixture, and macOS ships both.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
MOD="$ROOT/payload/mods/account-room"
LOGOUT="$MOD/bin/chrome-logout.sh"
SIGNED_OUT="$MOD/bin/chrome-signed-out.sh"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
if [ "$(uname)" != Darwin ] || [ ! -x /usr/bin/plutil ] || [ ! -x /usr/bin/sqlite3 ]; then
  echo "UNMEASURED: the sign out scripts read Chrome's files with macOS's plutil and sqlite3, which this machine lacks"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
fi
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-account-room-signout.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

# A Chrome folder whose last used profile is $2, with a cookie table in each profile named after it.
chrome(){   # $1 = folder  $2 = last used profile  $3... = profiles
  local dir="$1" last="$2"; shift 2; mkdir -p "$dir"
  printf '{"profile":{"last_used":"%s","info_cache":{}}}\n' "$last" > "$dir/Local State"
  for p in "$@"; do
    mkdir -p "$dir/$p"
    /usr/bin/sqlite3 "$dir/$p/Cookies" "create table cookies (host_key text, name text, value text, encrypted_value blob);"
  done
}
cookie(){ /usr/bin/sqlite3 "$1/$2/Cookies" "insert into cookies (host_key, name) values ('$3', '$4');"; }
signed_out(){   # $1 = Chrome folder; sets out and code
  out=$(ACCOUNT_ROOM_CHROME_DIR="$1" ACCOUNT_ROOM_CHECK_TRIES="${TRIES:-3}" ACCOUNT_ROOM_PAUSE="${PAUSE:-true}" /bin/sh "$SIGNED_OUT" 2>&1); code=$?
}

# 1. The last used profile still holds claude.ai's session cookie: not signed out, after every try.
C="$TMPROOT/c1"; chrome "$C" "Profile 3" "Profile 3"
cookie "$C" "Profile 3" .claude.ai sessionKey; cookie "$C" "Profile 3" claude.ai lastActiveOrg
: > "$TMPROOT/pauses"
PAUSE="echo x >> '$TMPROOT/pauses'" signed_out "$C"
[ "$code" = 1 ] && [ "$out" = "still signed in to claude.ai in profile Profile 3" ] \
  && check "a profile still holding claude.ai's session cookie is reported as still signed in" ok \
  || check "a profile still holding claude.ai's session cookie is reported as still signed in" "code=$code out=$out"
n=$(wc -l < "$TMPROOT/pauses" | tr -d ' ')
[ "$n" = 2 ] && check "it looks three times, pausing between looks and not after the last" ok \
  || check "it looks three times, pausing between looks and not after the last" "pauses=$n"

# 2. No session cookie left: exactly "signed out", even with claude.ai's other cookies still there
# and a sessionKey for some other site.
C="$TMPROOT/c2"; chrome "$C" "Profile 3" "Profile 3"
cookie "$C" "Profile 3" claude.ai anthropic-device-id; cookie "$C" "Profile 3" .example.com sessionKey
signed_out "$C"
[ "$code" = 0 ] && [ "$out" = "signed out" ] && check "with no claude.ai session cookie it prints exactly signed out" ok \
  || check "with no claude.ai session cookie it prints exactly signed out" "code=$code out=$out"

# 3. It reads the LAST USED profile, the one claude auth login opens its page in, not another.
C="$TMPROOT/c3"; chrome "$C" "Profile 3" "Default" "Profile 3"
cookie "$C" "Profile 3" .claude.ai sessionKey
TRIES=1 signed_out "$C"
[ "$code" = 1 ] && check "it judges the last used profile, not the Default one that is signed out" ok \
  || check "it judges the last used profile, not the Default one that is signed out" "code=$code out=$out"

# 4. Chrome writes a cookie's removal to disk late (31 seconds in the 2026-10-05 proof), so a cookie
# gone by a later look is a sign out.
C="$TMPROOT/c4"; chrome "$C" "Profile 3" "Profile 3"
cookie "$C" "Profile 3" .claude.ai sessionKey
PAUSE="/usr/bin/sqlite3 '$C/Profile 3/Cookies' \"delete from cookies where name = 'sessionKey'\"" TRIES=5 signed_out "$C"
[ "$code" = 0 ] && [ "$out" = "signed out" ] && check "a cookie removed between looks is confirmed as signed out" ok \
  || check "a cookie removed between looks is confirmed as signed out" "code=$code out=$out"

# 5 to 7. What it cannot read is said as such, with its own exit code, never as signed out (L11).
C="$TMPROOT/c5"; mkdir -p "$C"
signed_out "$C"
[ "$code" = 2 ] && [ "$out" = "could not read Chrome's last used profile" ] && check "no Local State: could not read the profile, exit 2" ok \
  || check "no Local State: could not read the profile, exit 2" "code=$code out=$out"
C="$TMPROOT/c6"; chrome "$C" "Profile 9"
signed_out "$C"
[ "$code" = 2 ] && [ "$out" = "could not read the cookies of profile Profile 9" ] && check "no cookie file: could not read the cookies, exit 2" ok \
  || check "no cookie file: could not read the cookies, exit 2" "code=$code out=$out"
C="$TMPROOT/c7"; chrome "$C" "Profile 3"; mkdir -p "$C/Profile 3"; echo "not a database" > "$C/Profile 3/Cookies"
signed_out "$C"
[ "$code" = 2 ] && [ "$out" = "could not query the cookies of profile Profile 3" ] && check "a cookie file that is not a database: could not query, exit 2" ok \
  || check "a cookie file that is not a database: could not query, exit 2" "code=$code out=$out"

# 8. The logout loads claude.ai's logout page in the last used profile, through a fresh open -n
# that hands it to the running Chrome.
C="$TMPROOT/c8"; chrome "$C" "Profile 3" "Profile 3"
STUB="$TMPROOT/open"; printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s/open.args"\nexit "${OPEN_EXIT:-0}"\n' "$TMPROOT" > "$STUB"; chmod +x "$STUB"
out=$(ACCOUNT_ROOM_CHROME_DIR="$C" ACCOUNT_ROOM_OPEN="$STUB" /bin/sh "$LOGOUT" 2>&1); code=$?
args=$(tr '\n' '|' < "$TMPROOT/open.args" 2>/dev/null)
[ "$code" = 0 ] && [ "$args" = "-na|Google Chrome|--args|--profile-directory=Profile 3|https://claude.ai/logout|" ] \
  && check "the logout opens claude.ai/logout in the last used profile" ok \
  || check "the logout opens claude.ai/logout in the last used profile" "code=$code args=$args out=$out"
rm -f "$TMPROOT/open.args"
out=$(OPEN_EXIT=1 ACCOUNT_ROOM_CHROME_DIR="$C" ACCOUNT_ROOM_OPEN="$STUB" /bin/sh "$LOGOUT" 2>&1); code=$?
[ "$code" = 1 ] && check "an open that fails fails the logout" ok || check "an open that fails fails the logout" "code=$code out=$out"
rm -f "$TMPROOT/open.args"
out=$(ACCOUNT_ROOM_CHROME_DIR="$TMPROOT/c5" ACCOUNT_ROOM_OPEN="$STUB" /bin/sh "$LOGOUT" 2>&1); code=$?
[ "$code" = 1 ] && [ ! -f "$TMPROOT/open.args" ] && check "with no last used profile the logout refuses and opens nothing" ok \
  || check "with no last used profile the logout refuses and opens nothing" "code=$code out=$out"

# 9. The manifest's defaults are these scripts, run the way the mod runs them (/bin/sh -c) from
# where the mod is installed, ~/.claude/mods/account-room, here a home whose .claude is the payload.
H="$TMPROOT/home"; mkdir -p "$H"; ln -s "$ROOT/payload" "$H/.claude"
default(){ /usr/bin/plutil -extract "userConfig.$1.default" raw -o - "$MOD/.claude-plugin/plugin.json"; }
C="$TMPROOT/c2"
out=$(HOME="$H" ACCOUNT_ROOM_CHROME_DIR="$C" ACCOUNT_ROOM_CHECK_TRIES=1 ACCOUNT_ROOM_PAUSE=true /bin/sh -c "$(default signedOutCheck)" 2>&1); code=$?
[ "$code" = 0 ] && [ "$out" = "signed out" ] && check "the signedOutCheck default runs the shipped check" ok \
  || check "the signedOutCheck default runs the shipped check" "code=$code out=$out default=$(default signedOutCheck)"
out=$(HOME="$H" ACCOUNT_ROOM_CHROME_DIR="$C" ACCOUNT_ROOM_OPEN="$STUB" /bin/sh -c "$(default logoutCommand)" 2>&1); code=$?
[ "$code" = 0 ] && [ -f "$TMPROOT/open.args" ] && check "the logoutCommand default runs the shipped logout" ok \
  || check "the logoutCommand default runs the shipped logout" "code=$code out=$out default=$(default logoutCommand)"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
