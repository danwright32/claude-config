#!/usr/bin/env bash
# Tests for the route a failed SessionEnd hook takes to the person (claude-config#1949).
#
# issue-spool-session-end.sh said its failures on stderr with exit 2, which the hooks documentation
# says is shown to the user at the end of a session. On 2026-10-30 Dan made ~/.claude-issue-spool
# read only and ran /clear in a real session, and no issue-spool-session-end line appeared. So the
# failure reached nobody. It now leaves a marker file, in the spool or, when the spool is what
# cannot be written, in TMPDIR, and the next prompt in any session says it once through
# sync-stuck-notice.sh's systemMessage, which Dan saw reach him the same day.
#
# What has to be proven is the whole route, written by the real SessionEnd hook and read by the real
# prompt hook, so a marker path the two stop agreeing on fails here (L3), and the quiet after it:
# a notice repeated on every prompt is the one a person learns to skip (L36).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
END_HOOK="$DIR/issue-spool-session-end.sh"
PROMPT_HOOK="$DIR/sync-stuck-notice.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
. "$DIR/lib/hook-notice.sh"
said() { # said <description> <stdout> <ERE>: one JSON object whose systemMessage says it
  local why; why="$(hook_notice_verdict "$2" "$3")"
  if [ -z "$why" ]; then check "$1" ok; else check "$1" "$why"; fi
}
silent() { # silent <description> <stdout>
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then check "$1" ok; else check "$1" "it said: ${2:0:300}"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.sessionend.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
# A read only folder left behind would stop the cleanup, so every one is made writable first.
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# Everything either hook could read from the real machine is pointed into the fixture: the home
# directory, the spool, TMPDIR (where the fallback marker lives), the launch agents, and the prompt
# hook's per session record (L2).
FHOME="$WORK/home"; SPOOL="$WORK/spool"; FTMP="$WORK/tmp"
mkdir -p "$FHOME/.claude" "$SPOOL" "$FTMP" "$WORK/agents" "$WORK/state"
fixture_env=(HOME="$FHOME" CLAUDE_HOME="$FHOME/.claude" CLAUDE_ISSUE_SPOOL_DIR="$SPOOL" TMPDIR="$FTMP"
             SYNC_LAUNCHAGENTS="$WORK/agents" CLAUDE_SYNC_STUCK_STATE_DIR="$WORK/state" SYNC_NO_NOTIFY=1)

end_session() { # end_session <payload> -> the SessionEnd hook's exit code; its stderr in $WORK/end.err
  printf '%s' "$1" | env "${fixture_env[@]}" bash "$END_HOOK" >/dev/null 2>"$WORK/end.err"
}
prompt() { # prompt <session id> -> the prompt hook's stdout
  printf '{"session_id":"%s","transcript_path":"/x/%s.jsonl","cwd":".","prompt":"carry on"}' "$1" "$1" \
    | env "${fixture_env[@]}" bash "$PROMPT_HOOK" 2>/dev/null
}
markers() { # every marker either place holds, by name
  find "$SPOOL" "$FTMP" -maxdepth 1 -name '*session-end-failed*' 2>/dev/null | sort
}

[ -f "$END_HOOK" ] && [ -f "$PROMPT_HOOK" ] && check "both hooks are there" ok \
  || check "both hooks are there" "end=$END_HOOK prompt=$PROMPT_HOOK"

echo "session end notice: a session that ends cleanly leaves nothing to say"
end_session '{"session_id":"clean-1","hook_event_name":"SessionEnd"}'; rc=$?
[ "$rc" -eq 0 ] && [ -f "$SPOOL/ended/clean-1" ] && check "a clean end stamps the session in the spool and exits 0" ok \
  || check "a clean end stamps the session in the spool and exits 0" "rc=$rc err=$(cat "$WORK/end.err")"
[ -z "$(markers)" ] && check "a clean end leaves no marker" ok || check "a clean end leaves no marker" "found: $(markers)"
silent "the prompt after a clean end says nothing" "$(prompt after-clean)"

echo "session end notice: a failure in a writable spool is said once, at the next prompt"
end_session '{"hook_event_name":"SessionEnd"}'; rc=$?
[ "$rc" -eq 2 ] && check "a payload with no session still exits 2 with its stderr, for the debug log" ok \
  || check "a payload with no session still exits 2 with its stderr, for the debug log" "rc=$rc"
[ -s "$SPOOL/session-end-failed" ] && check "it leaves its marker in the spool" ok \
  || check "it leaves its marker in the spool" "markers: $(markers) err=$(cat "$WORK/end.err")"
out="$(prompt next-1)"
said "the next prompt says the failure to the person" "$out" "no session_id"
said "and says it came from a session that ended, and when" "$out" "a session that ended earlier.*[0-9]{2}:[0-9]{2} ET"
[ -z "$(markers)" ] && check "the marker is gone once said" ok || check "the marker is gone once said" "left: $(markers)"
silent "a second prompt in that session does not repeat it" "$(prompt next-1)"
silent "nor does a prompt in another session" "$(prompt next-2)"

echo "session end notice: a spool root made read only still takes a stamp in its ended folder"
# What the 2026-10-30 check did: chmod 500 on the spool root alone. The stamp goes into ended/,
# which stays writable, so the hook succeeded and had nothing to say. That check therefore never
# produced the stderr it was looking for, and this pins why.
chmod 555 "$SPOOL"
end_session '{"session_id":"root-ro","hook_event_name":"SessionEnd"}'; rc=$?
chmod 755 "$SPOOL"
[ "$rc" -eq 0 ] && [ -f "$SPOOL/ended/root-ro" ] && check "a read only root with a writable ended folder stamps and exits 0" ok \
  || check "a read only root with a writable ended folder stamps and exits 0" "rc=$rc err=$(cat "$WORK/end.err")"
[ -z "$(markers)" ] && check "and leaves no marker" ok || check "and leaves no marker" "found: $(markers)"

echo "session end notice: a spool that cannot be written falls back to TMPDIR"
chmod 555 "$SPOOL" "$SPOOL/ended"
end_session '{"session_id":"ro-1","hook_event_name":"SessionEnd"}'; rc=$?
chmod 755 "$SPOOL" "$SPOOL/ended"
[ "$rc" -eq 2 ] && check "a read only spool fails the stamp, exit 2" ok || check "a read only spool fails the stamp, exit 2" "rc=$rc"
[ ! -e "$SPOOL/session-end-failed" ] && check "nothing landed in the read only spool" ok \
  || check "nothing landed in the read only spool" "found $SPOOL/session-end-failed"
case "$(markers)" in
  "$FTMP"/*) check "the marker went to TMPDIR instead" ok ;;
  *) check "the marker went to TMPDIR instead" "markers: $(markers) err=$(cat "$WORK/end.err")" ;;
esac
out="$(prompt next-3)"
said "the next prompt says the stamp that could not be written" "$out" "could not mark session ro-1 ended"
[ -z "$(markers)" ] && check "the TMPDIR marker is gone once said" ok || check "the TMPDIR marker is gone once said" "left: $(markers)"
silent "a second prompt does not repeat it" "$(prompt next-3)"

echo "session end notice: two failures before anyone prompts are both said, once"
end_session '{"hook_event_name":"SessionEnd"}'
chmod 555 "$SPOOL" "$SPOOL/ended"
end_session '{"session_id":"ro-2","hook_event_name":"SessionEnd"}'
chmod 755 "$SPOOL" "$SPOOL/ended"
out="$(prompt next-4)"
said "the one notice carries the first failure" "$out" "no session_id"
said "and the second" "$out" "could not mark session ro-2 ended"
silent "and the prompt after says neither" "$(prompt next-4)"

echo "session end notice: a marker that cannot be removed says so rather than repeating unexplained"
end_session '{"hook_event_name":"SessionEnd"}'
chmod 555 "$SPOOL"
out="$(prompt next-5)"
chmod 755 "$SPOOL"
said "a marker it cannot remove is still said" "$out" "no session_id"
said "with why it will be said again" "$out" "could not be removed"
rm -f "$SPOOL/session-end-failed"

echo "session end notice: the default spool, and a test run kept out of the real one"
# With no CLAUDE_ISSUE_SPOOL_DIR the marker goes where lib/issue-spool.sh puts the spool, under HOME.
printf '{"hook_event_name":"SessionEnd"}' \
  | env -u CLAUDE_ISSUE_SPOOL_DIR -u CLAUDE_SUITE_RUN_ID HOME="$FHOME" TMPDIR="$FTMP" bash "$END_HOOK" >/dev/null 2>&1
[ -s "$FHOME/.claude-issue-spool/session-end-failed" ] && check "with no spool named, the marker goes in ~/.claude-issue-spool" ok \
  || check "with no spool named, the marker goes in ~/.claude-issue-spool" "markers: $(find "$FHOME" "$FTMP" -name '*session-end-failed*')"
out="$(printf '{"session_id":"dflt","prompt":"x"}' | env -u CLAUDE_ISSUE_SPOOL_DIR -u CLAUDE_SUITE_RUN_ID HOME="$FHOME" \
  CLAUDE_HOME="$FHOME/.claude" TMPDIR="$FTMP" SYNC_LAUNCHAGENTS="$WORK/agents" CLAUDE_SYNC_STUCK_STATE_DIR="$WORK/state" \
  bash "$PROMPT_HOOK" 2>/dev/null)"
said "and the prompt hook finds it there" "$out" "no session_id"
# Under a test run with the spool left at its real place, neither hook touches the marker there, the
# rule lib/issue-spool.sh keeps for every write into the real spool (claude-config#278).
printf '{"hook_event_name":"SessionEnd"}' \
  | env -u CLAUDE_ISSUE_SPOOL_DIR HOME="$FHOME" TMPDIR="$FTMP" CLAUDE_SUITE_RUN_ID=suite-1949 bash "$END_HOOK" >/dev/null 2>&1
[ -z "$(find "$FHOME" "$FTMP" -name '*session-end-failed*')" ] && check "a test run leaves no marker in the real spool or its fallback" ok \
  || check "a test run leaves no marker in the real spool or its fallback" "found: $(find "$FHOME" "$FTMP" -name '*session-end-failed*')"
mkdir -p "$FHOME/.claude-issue-spool"; printf 'a real one\n' > "$FHOME/.claude-issue-spool/session-end-failed"
out="$(printf '{"session_id":"t1949","prompt":"x"}' | env -u CLAUDE_ISSUE_SPOOL_DIR HOME="$FHOME" CLAUDE_HOME="$FHOME/.claude" \
  TMPDIR="$FTMP" CLAUDE_SUITE_RUN_ID=suite-1949 SYNC_LAUNCHAGENTS="$WORK/agents" CLAUDE_SYNC_STUCK_STATE_DIR="$WORK/state" \
  bash "$PROMPT_HOOK" 2>/dev/null)"
[ -s "$FHOME/.claude-issue-spool/session-end-failed" ] && check "and a test run never takes a real marker" ok \
  || check "and a test run never takes a real marker" "it was taken; said: ${out:0:300}"

echo "session end notice: each hook with a library it needs gone still does its job and says what it lost"
# A copy of the hooks folder with one library taken away (claude-config#1949). Advisory: neither
# hook ever exits with anything SessionEnd or a prompt would treat as a refusal, and neither goes
# quiet about what the missing file cost.
lib_gone() { # lib_gone <library> -> a hooks folder copy without it, printed
  local d="$WORK/without-${1%.sh}"
  rm -rf "$d"; mkdir -p "$d"
  cp "$END_HOOK" "$PROMPT_HOOK" "$d/"
  cp -R "$DIR/lib" "$d/lib"
  rm -f "$d/lib/$1"
  printf '%s' "$d"
}
rm -rf "$SPOOL"; mkdir -p "$SPOOL"; rm -f "$FTMP"/*session-end-failed* 2>/dev/null
for gone in spool-end-marker.sh hook-notice.sh; do
  G="$(lib_gone "$gone")"
  printf '{"session_id":"lib-%s","hook_event_name":"SessionEnd"}' "${gone%.sh}" \
    | env "${fixture_env[@]}" bash "$G/issue-spool-session-end.sh" >/dev/null 2>"$WORK/end.err"; rc=$?
  [ "$rc" -eq 0 ] && [ -f "$SPOOL/ended/lib-${gone%.sh}" ] && check "with lib/$gone gone the SessionEnd hook still stamps and exits 0" ok \
    || check "with lib/$gone gone the SessionEnd hook still stamps and exits 0" "rc=$rc err=$(cat "$WORK/end.err")"
  printf '{"hook_event_name":"SessionEnd"}' | env "${fixture_env[@]}" bash "$G/issue-spool-session-end.sh" >/dev/null 2>"$WORK/end.err"; rc=$?
  case "$rc:$(cat "$WORK/end.err")" in
    2:*"no session_id"*"could not be left for the next prompt"*) check "with lib/$gone gone a failure is still said on stderr, with why it could not be left for later" ok ;;
    *) check "with lib/$gone gone a failure is still said on stderr, with why it could not be left for later" "rc=$rc err=$(cat "$WORK/end.err")" ;;
  esac
  rm -f "$SPOOL/session-end-failed"
done
# The prompt hook without lib/spool-end-marker.sh cannot know where a marker would be, so it says so.
G="$(lib_gone spool-end-marker.sh)"
out="$(printf '{"session_id":"lib1","prompt":"x"}' | env "${fixture_env[@]}" bash "$G/sync-stuck-notice.sh" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && check "with lib/spool-end-marker.sh gone the prompt hook exits 0" ok || check "with lib/spool-end-marker.sh gone the prompt hook exits 0" "rc=$rc"
said "and says it could not check for a failed session end, naming the file" "$out" "could not load lib/spool-end-marker\\.sh"
# Without lib/hook-notice.sh it cannot take a marker, so a marker that is there is named, not dropped.
G="$(lib_gone hook-notice.sh)"
printf 'At some time, issue-spool-session-end: a lost one\n' > "$SPOOL/session-end-failed"
out="$(printf '{"session_id":"lib2","prompt":"x"}' | env "${fixture_env[@]}" bash "$G/sync-stuck-notice.sh" 2>/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && check "with lib/hook-notice.sh gone the prompt hook exits 0" ok || check "with lib/hook-notice.sh gone the prompt hook exits 0" "rc=$rc"
said "and names the marker it could not read out" "$out" "session-end-failed"
silent "while with no marker there it stays quiet" "$(rm -f "$SPOOL/session-end-failed"; printf '{"session_id":"lib3","prompt":"x"}' | env "${fixture_env[@]}" bash "$G/sync-stuck-notice.sh" 2>/dev/null)"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
