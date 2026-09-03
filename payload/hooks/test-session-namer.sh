#!/usr/bin/env bash
# Tests for session-namer.sh, which names a session from its working directory on the first prompt
# (claude-config#124).
#
# It runs on EVERY prompt in every session and had no test. It also builds a filesystem path by
# pasting a value straight out of the hook payload onto a fixed prefix, which is the shape L50
# warns about: a value from input must never feed a path or a comparison directly. The sibling hook
# doing the same thing (teammate-challenge-gate.sh) strips everything but a safe alphabet first.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/session-namer.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.namer.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-session-namer: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The markers go in a throwaway of this run's own, never in the real temp root. A test that leaves
# markers behind makes the NEXT run of itself pass for the wrong reason, and one that writes where
# the live hook writes could silence a real session (L2).
export SESSION_MARKER_DIR="$TMPROOT/markers"
mkdir -p "$SESSION_MARKER_DIR"

newid() { printf '%s' "ns-$$-$1"; }
payload() { python3 -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"cwd":sys.argv[2]}))' "$1" "$2"; }

# ---------------------------------------------------------------------------
# The name it produces, and the fact that it produces one only once.
# ---------------------------------------------------------------------------
id1="$(newid one)"
out1="$(payload "$id1" "$TMPROOT/My Project" | bash "$H" 2>/dev/null)"
grep -q '"sessionTitle"' <<< "$out1" \
  && check "the first prompt of a session gets a title" ok \
  || check "the first prompt of a session gets a title" "out=$out1"
printf '%s' "$out1" | grep -q "my-project-$(date +%m%d)" \
  && check "the title is the folder name, lowercased, spaces to dashes, plus the date" ok \
  || check "the title is the folder name, lowercased, spaces to dashes, plus the date" "out=$out1"
printf '%s' "$out1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && check "and it is valid JSON, which is the only reason it is read at all" ok \
  || check "and it is valid JSON, which is the only reason it is read at all" "out=$out1"

out2="$(payload "$id1" "$TMPROOT/My Project" | bash "$H" 2>/dev/null)"
[ -z "$out2" ] \
  && check "the second prompt of the same session says nothing" ok \
  || check "the second prompt of the same session says nothing" "out=$out2"

# A DIFFERENT session still gets named, or the check above is satisfied by a hook that names
# nothing after the first session on the machine (L159).
id2="$(newid two)"
out3="$(payload "$id2" "$TMPROOT/Other" | bash "$H" 2>/dev/null)"
grep -q 'other-' <<< "$out3" \
  && check "a different session still gets its own name" ok \
  || check "a different session still gets its own name" "out=$out3"

# ---------------------------------------------------------------------------
# Payloads it must not act on.
# ---------------------------------------------------------------------------
out_nosession="$(printf '{"cwd":"/tmp/x"}' | bash "$H" 2>/dev/null)"; code_nosession=$?
[ -z "$out_nosession" ] && [ "$code_nosession" -eq 0 ] \
  && check "a payload with no session id names nothing and exits cleanly" ok \
  || check "a payload with no session id names nothing and exits cleanly" "out=$out_nosession exit=$code_nosession"
out_junk="$(printf 'not json at all' | bash "$H" 2>/dev/null)"; code_junk=$?
[ -z "$out_junk" ] && [ "$code_junk" -eq 0 ] \
  && check "a payload that does not parse names nothing and exits cleanly" ok \
  || check "a payload that does not parse names nothing and exits cleanly" "out=$out_junk exit=$code_junk"

# ---------------------------------------------------------------------------
# The marker path is built from a value that arrives in the payload. A session id carrying path
# separators must not be able to steer that write anywhere, and the hook must still refuse to do
# its work rather than writing to a mangled name and carrying on.
# ---------------------------------------------------------------------------
ESCAPE="$TMPROOT/escaped-marker"
trav_id="../../..$ESCAPE"
out_trav="$(payload "$trav_id" "$TMPROOT/Trav" | bash "$H" 2>/dev/null)"
[ ! -e "$ESCAPE" ] \
  && check "a session id carrying path separators cannot steer the marker write" ok \
  || check "a session id carrying path separators cannot steer the marker write" "it wrote $ESCAPE"
# It cannot escape, because the prefix ends in a character rather than a separator, so the first
# path component is a directory that does not exist and the write simply fails. But it fails
# SILENTLY, and the only thing the marker does is stop the session being renamed, so the real
# consequence is a session that gets renamed on every single prompt for the rest of its life. The
# hook has to sanitise the id the way its sibling teammate-challenge-gate.sh already does (L50).
out_trav2="$(payload "$trav_id" "$TMPROOT/Trav" | bash "$H" 2>/dev/null)"
[ -z "$out_trav2" ] \
  && check "and such a session is still only named once" ok \
  || check "and such a session is still only named once" "it named it again, so the marker never stuck"
# The control: the same payload shape with an ordinary id DOES write a marker, so the check above
# is not satisfied by a hook that stopped writing markers at all (L159).
id3="$(newid three)"
payload "$id3" "$TMPROOT/Ctl" | bash "$H" >/dev/null 2>&1
[ -e "$SESSION_MARKER_DIR/.claude-session-named-$id3" ] \
  && check "the control: an ordinary session id does write one" ok \
  || check "the control: an ordinary session id does write one" "no marker was written, so the traversal check proves nothing"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
