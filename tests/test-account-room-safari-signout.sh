#!/bin/bash
# Tests for the account room's Safari sign out route and the per Mac choice of browser (#808):
# bin/safari-logout.sh, bin/safari-signed-out.sh with its reader bin/safari-cookies.py, and
# bin/browser.sh, which runs Safari's pair on Daniels-MacBook-Pro-2 and Chrome's on Dans-MacBook-Pro.
#
# Every seam is set: ACCOUNT_ROOM_SAFARI_COOKIES (a fixture store this suite writes in Safari's
# binarycookies format, never the real one), ACCOUNT_ROOM_OPEN (a stub, so no test opens a page, L2),
# ACCOUNT_ROOM_PAUSE (so no test waits in real time, L524), ACCOUNT_ROOM_NOW (the clock the expiry is
# judged against, L130) and ACCOUNT_ROOM_HOST (the Mac's name).
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
BIN="$MOD/bin"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
if ! command -v python3 >/dev/null 2>&1; then
  echo "UNMEASURED: the Safari check reads its store with python3, which this machine lacks"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
fi
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-account-room-safari.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
NOW=1791245000            # the clock every check below is judged at
LATER=$((NOW + 86400))    # a cookie expiring tomorrow is live
EARLIER=$((NOW - 86400))  # one that expired yesterday is not

# store <file> <domain:name:expiry>...: a Cookies.binarycookies in Safari's format, two cookies a page.
store(){
  python3 - "$@" <<'PY'
import struct, sys
out, specs = sys.argv[1], sys.argv[2:]
MAC_EPOCH = 978307200
def cookie(domain, name, expiry):
    strings = b""
    offs = []
    base = 56
    for s in (domain, name, "/", "VALUE-NEVER-PRINTED"):
        offs.append(base + len(strings))
        strings += s.encode() + b"\0"
    head = struct.pack("<iiii", 56 + len(strings), 0, 0, 0) + struct.pack("<iiii", *offs) + b"\0" * 8
    # "session" writes an expiry of 0, as a cookie with no expiry date of its own is stored.
    when = 0.0 if expiry == "session" else float(expiry) - MAC_EPOCH
    return head + struct.pack("<dd", when, 0.0) + strings
def page(cookies):
    n = len(cookies)
    at = 4 + 4 + 4 * n + 4
    offs = []
    for c in cookies:
        offs.append(at)
        at += len(c)
    return b"\0\0\x01\0" + struct.pack("<i", n) + struct.pack("<%di" % n, *offs) + b"\0" * 4 + b"".join(cookies)
cs = [cookie(*(s.rsplit(":", 2))) for s in specs]
pages = [page(cs[i:i + 2]) for i in range(0, len(cs), 2)] or [page([])]
body = b"cook" + struct.pack(">i", len(pages)) + b"".join(struct.pack(">i", len(p)) for p in pages) + b"".join(pages)
open(out, "wb").write(body + b"\0\0\0\0" + bytes.fromhex("071720050000004b"))
PY
}
signed_out(){   # $1 = store; sets out and code
  out=$(ACCOUNT_ROOM_SAFARI_COOKIES="$1" ACCOUNT_ROOM_NOW="$NOW" ACCOUNT_ROOM_CHECK_TRIES="${TRIES:-3}" ACCOUNT_ROOM_PAUSE="${PAUSE:-true}" /bin/sh "$BIN/safari-signed-out.sh" 2>&1); code=$?
}

# 1. A live claude.ai session cookie, among others: still signed in, after every try.
S="$TMPROOT/s1"; store "$S" ".claude.ai:sessionKey:$LATER" "claude.ai:lastActiveOrg:$LATER" ".example.com:sid:$LATER"
: > "$TMPROOT/pauses"
PAUSE="echo x >> '$TMPROOT/pauses'" signed_out "$S"
[ "$code" = 1 ] && [ "$out" = "still signed in to claude.ai in Safari" ] \
  && check "a store still holding claude.ai's session cookie is reported as still signed in" ok \
  || check "a store still holding claude.ai's session cookie is reported as still signed in" "code=$code out=$out"
n=$(wc -l < "$TMPROOT/pauses" | tr -d ' ')
[ "$n" = 2 ] && check "it looks three times, pausing between looks and not after the last" ok \
  || check "it looks three times, pausing between looks and not after the last" "pauses=$n"
case "$out" in *VALUE-NEVER-PRINTED*) check "and no cookie value is ever printed" "$out" ;; *) check "and no cookie value is ever printed" ok ;; esac

# 2. No session cookie left: exactly "signed out", with claude.ai's other cookies and another site's
# sessionKey still there, and across more than one page.
S="$TMPROOT/s2"; store "$S" "claude.ai:anthropic-device-id:$LATER" ".example.com:sessionKey:$LATER" "claude.ai:lastActiveOrg:$LATER"
signed_out "$S"
[ "$code" = 0 ] && [ "$out" = "signed out" ] && check "with no claude.ai session cookie it prints exactly signed out" ok \
  || check "with no claude.ai session cookie it prints exactly signed out" "code=$code out=$out"

# 3. A session cookie left behind with an expiry in the past is no session.
S="$TMPROOT/s3"; store "$S" ".claude.ai:sessionKey:$EARLIER"
signed_out "$S"
[ "$code" = 0 ] && [ "$out" = "signed out" ] && check "an expired claude.ai session cookie counts as signed out" ok \
  || check "an expired claude.ai session cookie counts as signed out" "code=$code out=$out"
# The control for 3: the same cookie judged at a clock before its expiry is live (L159).
out=$(ACCOUNT_ROOM_SAFARI_COOKIES="$S" ACCOUNT_ROOM_NOW="$((EARLIER - 60))" ACCOUNT_ROOM_CHECK_TRIES=1 /bin/sh "$BIN/safari-signed-out.sh" 2>&1); code=$?
[ "$code" = 1 ] && check "while the same cookie before its expiry is still a session" ok \
  || check "while the same cookie before its expiry is still a session" "code=$code out=$out"

# 3b. A session cookie with no expiry of its own (stored as 0) lasts as long as Safari does, so it
# is a live session, never read as expired (lessons review of #808).
S="$TMPROOT/s3b"; store "$S" ".claude.ai:sessionKey:session"
TRIES=1 signed_out "$S"
[ "$code" = 1 ] && check "a claude.ai session cookie with no expiry is still a session" ok \
  || check "a claude.ai session cookie with no expiry is still a session" "code=$code out=$out"

# 3c. The looks are bounded by elapsed time too, so the check gives its own verdict inside the
# limit the mod sets however slow each look is (lessons review of #808): with no time left after the first
# look it answers then, never waiting out its tries.
S="$TMPROOT/s3c"; store "$S" ".claude.ai:sessionKey:$LATER"
: > "$TMPROOT/pauses"
out=$(ACCOUNT_ROOM_SAFARI_COOKIES="$S" ACCOUNT_ROOM_NOW="$NOW" ACCOUNT_ROOM_CHECK_TRIES=5 ACCOUNT_ROOM_CHECK_SECONDS=0 ACCOUNT_ROOM_PAUSE="echo x >> '$TMPROOT/pauses'" /bin/sh "$BIN/safari-signed-out.sh" 2>&1); code=$?
n=$(wc -l < "$TMPROOT/pauses" | tr -d ' ')
[ "$code" = 1 ] && [ "$n" = 0 ] && [ "$out" = "still signed in to claude.ai in Safari" ] \
  && check "with its time spent it answers still signed in at once, with its own verdict" ok \
  || check "with its time spent it answers still signed in at once, with its own verdict" "code=$code pauses=$n out=$out"

# 4. Safari writes the removal late, so a cookie gone by a later look is a sign out.
S="$TMPROOT/s4"; store "$S" ".claude.ai:sessionKey:$LATER"
store "$TMPROOT/s4-after" "claude.ai:lastActiveOrg:$LATER"
PAUSE="cp '$TMPROOT/s4-after' '$S'" TRIES=5 signed_out "$S"
[ "$code" = 0 ] && [ "$out" = "signed out" ] && check "a cookie removed between looks is confirmed as signed out" ok \
  || check "a cookie removed between looks is confirmed as signed out" "code=$code out=$out"

# 5 to 7. What it cannot read is said as such, exit 2 with a reason, never as signed out (L11, #773).
signed_out "$TMPROOT/no-such-store"
[ "$code" = 2 ] && case "$out" in "could not read Safari's cookies: "?*) true ;; *) false ;; esac \
  && check "no store: could not read Safari's cookies, exit 2, with why" ok \
  || check "no store: could not read Safari's cookies, exit 2, with why" "code=$code out=$out"
S="$TMPROOT/s6"; printf 'not a cookie store at all\n' > "$S"
signed_out "$S"
[ "$code" = 2 ] && [ "$out" = "could not parse Safari's cookies: not a Safari cookie store" ] \
  && check "a file that is not a cookie store: could not parse, exit 2" ok \
  || check "a file that is not a cookie store: could not parse, exit 2" "code=$code out=$out"
S="$TMPROOT/s7"; store "$S" ".claude.ai:sessionKey:$LATER"; head -c 40 "$S" > "$S.cut"
signed_out "$S.cut"
[ "$code" = 2 ] && case "$out" in "could not parse Safari's cookies: "?*) true ;; *) false ;; esac \
  && check "a store cut short: could not parse, exit 2" ok \
  || check "a store cut short: could not parse, exit 2" "code=$code out=$out"
S="$TMPROOT/s8"; store "$S" ".claude.ai:sessionKey:$LATER"; chmod 000 "$S"
if [ -r "$S" ]; then
  echo "UNMEASURED: running as a user who can read a mode 000 file, so the permission refusal cannot be made"
else
  signed_out "$S"
  [ "$code" = 2 ] && case "$out" in *"permission refused"*"Full Disk Access"*) true ;; *) false ;; esac \
    && check "a store the system refuses names Full Disk Access as the likely cause" ok \
    || check "a store the system refuses names Full Disk Access as the likely cause" "code=$code out=$out"
fi
chmod 600 "$S"

# 8b. Safari rewrites its store in place, so one look can catch it half written. A store that does
# not parse on one look is looked at again; only one that never parses is exit 2 (lessons review).
S="$TMPROOT/s9"; store "$TMPROOT/s9-good" "claude.ai:lastActiveOrg:$LATER"; head -c 40 "$TMPROOT/s9-good" > "$S"
PAUSE="cp '$TMPROOT/s9-good' '$S'" TRIES=3 signed_out "$S"
[ "$code" = 0 ] && [ "$out" = "signed out" ] && check "a store caught half written is looked at again, not taken as unreadable" ok \
  || check "a store caught half written is looked at again, not taken as unreadable" "code=$code out=$out"
: > "$TMPROOT/pauses"
PAUSE="echo x >> '$TMPROOT/pauses'" TRIES=3 signed_out "$TMPROOT/s6"
n=$(wc -l < "$TMPROOT/pauses" | tr -d ' ')
[ "$code" = 2 ] && [ "$n" = 2 ] && check "a store that never parses is exit 2 after every try" ok \
  || check "a store that never parses is exit 2 after every try" "code=$code pauses=$n out=$out"
: > "$TMPROOT/pauses"
PAUSE="echo x >> '$TMPROOT/pauses'" TRIES=3 signed_out "$TMPROOT/no-such-store"
n=$(wc -l < "$TMPROOT/pauses" | tr -d ' ')
[ "$code" = 2 ] && [ "$n" = 0 ] && check "while a store that cannot be opened is exit 2 at once" ok \
  || check "while a store that cannot be opened is exit 2 at once" "code=$code pauses=$n out=$out"

# 8c. A store whose shape is wrong anywhere is not read as one with no cookies, which would say
# signed out while Safari is signed in: a page whose header is zeroed, a cookie offset outside its
# page, and a store missing its closing footer (lessons review of #808).
S="$TMPROOT/s10"; store "$S" ".claude.ai:sessionKey:$LATER"
python3 - "$S" <<'PY'
import struct, sys
p = sys.argv[1]
d = bytearray(open(p, "rb").read())
n = struct.unpack(">i", d[4:8])[0]
first = 8 + 4 * n
d[first:first + 4] = b"\0\0\0\0"
open(p + ".zeroed", "wb").write(d)
d = bytearray(open(p, "rb").read())
d[first + 8:first + 12] = struct.pack("<i", 100000)
open(p + ".wild", "wb").write(d)
open(p + ".nofooter", "wb").write(open(p, "rb").read()[:-8])
PY
for kind in zeroed wild nofooter; do
  TRIES=1 signed_out "$S.$kind"
  [ "$code" = 2 ] && case "$out" in "could not parse Safari's cookies: "?*) true ;; *) false ;; esac \
    && check "a store with a $kind part is could not parse, never signed out" ok \
    || check "a store with a $kind part is could not parse, never signed out" "code=$code out=$out"
done

# 9. The logout loads claude.ai's logout page in Safari.
STUB="$TMPROOT/open"; printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "%s/open.args"\nexit "${OPEN_EXIT:-0}"\n' "$TMPROOT" > "$STUB"; chmod +x "$STUB"
out=$(ACCOUNT_ROOM_OPEN="$STUB" /bin/sh "$BIN/safari-logout.sh" 2>&1); code=$?
args=$(tr '\n' '|' < "$TMPROOT/open.args" 2>/dev/null)
[ "$code" = 0 ] && [ "$args" = "-a|Safari|https://claude.ai/logout|" ] && check "the Safari logout opens claude.ai/logout in Safari" ok \
  || check "the Safari logout opens claude.ai/logout in Safari" "code=$code args=$args out=$out"
rm -f "$TMPROOT/open.args"
out=$(OPEN_EXIT=1 ACCOUNT_ROOM_OPEN="$STUB" /bin/sh "$BIN/safari-logout.sh" 2>&1); code=$?
[ "$code" = 1 ] && check "an open that fails fails the Safari logout" ok || check "an open that fails fails the Safari logout" "code=$code out=$out"
rm -f "$TMPROOT/open.args"

# 10. The browser is chosen per Mac, by its name: Safari on Daniels-MacBook-Pro-2, Chrome on
# Dans-MacBook-Pro, and a Mac in neither is refused by name rather than given one (L75).
C="$TMPROOT/chrome"; mkdir -p "$C/Profile 3"
printf '{"profile":{"last_used":"Profile 3","info_cache":{}}}\n' > "$C/Local State"
route(){   # $1 = host  $2 = step; sets out and code
  out=$(ACCOUNT_ROOM_HOST="$1" ACCOUNT_ROOM_OPEN="$STUB" ACCOUNT_ROOM_CHROME_DIR="$C" /bin/sh "$BIN/browser.sh" "$2" 2>&1); code=$?
}
route Daniels-MacBook-Pro-2 logout
args=$(tr '\n' '|' < "$TMPROOT/open.args" 2>/dev/null); rm -f "$TMPROOT/open.args"
[ "$code" = 0 ] && [ "$args" = "-a|Safari|https://claude.ai/logout|" ] && check "on Daniels-MacBook-Pro-2 the logout opens in Safari" ok \
  || check "on Daniels-MacBook-Pro-2 the logout opens in Safari" "code=$code args=$args out=$out"
if [ -x /usr/bin/plutil ]; then
  route Dans-MacBook-Pro logout
  args=$(tr '\n' '|' < "$TMPROOT/open.args" 2>/dev/null); rm -f "$TMPROOT/open.args"
  [ "$code" = 0 ] && [ "$args" = "-na|Google Chrome|--args|--profile-directory=Profile 3|https://claude.ai/logout|" ] \
    && check "on Dans-MacBook-Pro it keeps the proven Chrome route" ok \
    || check "on Dans-MacBook-Pro it keeps the proven Chrome route" "code=$code args=$args out=$out"
else
  echo "UNMEASURED: the Chrome route reads Chrome's profile with macOS's plutil, which this machine lacks"
fi
route Someone-Elses-Mac logout
[ "$code" = 2 ] && [ ! -f "$TMPROOT/open.args" ] && [ "$out" = "no browser is set for this Mac (Someone-Elses-Mac) to sign out in" ] \
  && check "a Mac with no browser set is refused by name and nothing is opened" ok \
  || check "a Mac with no browser set is refused by name and nothing is opened" "code=$code out=$out"
out=$(ACCOUNT_ROOM_HOST=Daniels-MacBook-Pro-2 ACCOUNT_ROOM_SAFARI_COOKIES="$TMPROOT/s2" ACCOUNT_ROOM_NOW="$NOW" ACCOUNT_ROOM_CHECK_TRIES=1 /bin/sh "$BIN/browser.sh" signed-out 2>&1); code=$?
[ "$code" = 0 ] && [ "$out" = "signed out" ] && check "on Daniels-MacBook-Pro-2 the check reads Safari's store" ok \
  || check "on Daniels-MacBook-Pro-2 the check reads Safari's store" "code=$code out=$out"
out=$(ACCOUNT_ROOM_HOST=Daniels-MacBook-Pro-2 ACCOUNT_ROOM_SAFARI_COOKIES="$TMPROOT/s1" ACCOUNT_ROOM_NOW="$NOW" ACCOUNT_ROOM_CHECK_TRIES=1 /bin/sh "$BIN/browser.sh" signed-out 2>&1); code=$?
[ "$code" = 1 ] && check "and passes on its still signed in" ok || check "and passes on its still signed in" "code=$code out=$out"
# A browser script the sync has not delivered is named, never a bare exit 127.
LONE="$TMPROOT/lone"; mkdir -p "$LONE"; cp "$BIN/browser.sh" "$LONE/"
out=$(ACCOUNT_ROOM_HOST=Daniels-MacBook-Pro-2 /bin/sh "$LONE/browser.sh" signed-out 2>&1); code=$?
[ "$code" = 2 ] && case "$out" in "the safari signed-out script is missing ("*"/lone/safari-signed-out.sh)") true ;; *) false ;; esac \
  && check "a missing browser script is named, exit 2" ok || check "a missing browser script is named, exit 2" "code=$code out=$out"
out=$(ACCOUNT_ROOM_HOST=Daniels-MacBook-Pro-2 /bin/sh "$BIN/browser.sh" sideways 2>&1); code=$?
[ "$code" = 2 ] && check "a step that is neither logout nor signed-out is refused" ok || check "a step that is neither logout nor signed-out is refused" "code=$code out=$out"

# 11. The manifest's defaults run browser.sh the way the mod runs them (/bin/sh -c) from where the
# mod is installed, ~/.claude/mods/account-room, here a home whose .claude is the payload.
H="$TMPROOT/home"; mkdir -p "$H"; ln -s "$ROOT/payload" "$H/.claude"
default(){ python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["userConfig"][sys.argv[2]]["default"])' "$MOD/.claude-plugin/plugin.json" "$1"; }
out=$(HOME="$H" ACCOUNT_ROOM_HOST=Daniels-MacBook-Pro-2 ACCOUNT_ROOM_SAFARI_COOKIES="$TMPROOT/s2" ACCOUNT_ROOM_NOW="$NOW" ACCOUNT_ROOM_CHECK_TRIES=1 /bin/sh -c "$(default signedOutCheck)" 2>&1); code=$?
[ "$code" = 0 ] && [ "$out" = "signed out" ] && check "the signedOutCheck default runs the per Mac check" ok \
  || check "the signedOutCheck default runs the per Mac check" "code=$code out=$out default=$(default signedOutCheck)"
out=$(HOME="$H" ACCOUNT_ROOM_HOST=Daniels-MacBook-Pro-2 ACCOUNT_ROOM_OPEN="$STUB" /bin/sh -c "$(default logoutCommand)" 2>&1); code=$?
args=$(tr '\n' '|' < "$TMPROOT/open.args" 2>/dev/null); rm -f "$TMPROOT/open.args"
[ "$code" = 0 ] && [ "$args" = "-a|Safari|https://claude.ai/logout|" ] && check "the logoutCommand default runs the per Mac logout" ok \
  || check "the logoutCommand default runs the per Mac logout" "code=$code args=$args out=$out default=$(default logoutCommand)"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
