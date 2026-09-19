#!/usr/bin/env bash
# Tests for the gate that refuses an unscoped `git add` in a shared checkout (claude-config#366).
#
# CLAUDE.md already said to scope every `git add` to named paths, never `-A` or `.`, because a
# checkout is routinely shared by concurrent sessions. Nothing enforced it. On 2026-09-10 a session
# working on claude-config#362 committed with an unscoped add and carried another session's half
# finished generator change and its six tests into commits 580842f and after, under a message that
# does not describe them, and pushed them. The work was correct so nothing broke, but it was judged
# by a test gate that was not asked about it and it is recorded as somebody else's change. A rule
# that lives only in a prompt is a hope (L27).
#
# The transcript is a REAL jsonl file in the shape Claude Code writes, because what the gate reads
# out of it is the whole question, and a stub would only confirm this suite's own assumption about
# that shape (L52).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-add-scope.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "test-check-add-scope: there is no check-add-scope.sh beside this suite at $DIR." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs check-add-scope.sh beside it"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/check-add-scope.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

REPO="$FIX/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email t@e
git -C "$REPO" config user.name t
printf 'seed\n' > "$REPO/seed.txt"
git -C "$REPO" add seed.txt
git -C "$REPO" -c commit.gpgsign=false commit -q -m seed

STATE="$FIX/state"; mkdir -p "$STATE"
TR="$FIX/transcript.jsonl"

# One transcript line in the shape Claude Code writes: a tool_use block inside an assistant message.
mention_edit(){ # mention_edit <file path>
  python3 -c '
import json, sys
print(json.dumps({"type": "assistant", "message": {"content": [
    {"type": "tool_use", "name": "Edit", "input": {"file_path": sys.argv[1]}}]}}))
' "$1" >> "$TR"
}
mention_bash(){ # mention_bash <command>
  python3 -c '
import json, sys
print(json.dumps({"type": "assistant", "message": {"content": [
    {"type": "tool_use", "name": "Bash", "input": {"command": sys.argv[1]}}]}}))
' "$1" >> "$TR"
}
fresh_cache(){ rm -f "$STATE"/claude-add-scope-* 2>/dev/null; }

RC=0; OUT=""
run(){ # run <command> [transcript]
  local tr="${2-$TR}"
  OUT="$(python3 -c '
import json, sys
d = {"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}
if sys.argv[3]:
    d["transcript_path"] = sys.argv[3]
print(json.dumps(d))
' "$1" "$REPO" "$tr" | env CLAUDE_ADD_SCOPE_STATE_DIR="$STATE" bash "$HOOK" 2>&1)"; RC=$?
}
refused(){ if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, said: ${OUT:0:200}"; fi; }
allowed(){ if [ "$RC" -eq 0 ] && [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then check "$1" ok
           else check "$1" "exit $RC, said: ${OUT:0:200}"; fi; }
says(){ case "$OUT" in *"$2"*) check "$1" ok ;; *) check "$1" "did not say '$2'" ;; esac; }
silentabout(){ case "$OUT" in *"$2"*) check "$1" "it named '$2'" ;; *) check "$1" ok ;; esac; }

echo "check add scope: a checkout this session is alone in"

# The control FIRST, and it matters more than the refusal: an unscoped add is fine when a session
# is alone, and a gate that fires on the ordinary case is one nobody reads (L36, L104).
printf 'mine\n' > "$REPO/mine.txt"
mention_edit "$REPO/mine.txt"
fresh_cache
run "git add -A"
allowed "an unscoped add is allowed when every change is this session's"
run "git add ."
allowed "and so is a bare dot"

# A file this session wrote through a Bash heredoc rather than an Edit. A great deal of this
# repo's own editing happens that way, and a gate that could only see Edit calls would call all of
# it foreign and be turned off within the hour.
printf 'via bash\n' > "$REPO/viabash.txt"
mention_bash "cat > $REPO/viabash.txt <<'EOF'
via bash
EOF"
fresh_cache
run "git add -A"
allowed "a file this session wrote through a Bash command is this session's too"

echo "check add scope: a checkout somebody else is working in"

# The incident: another session's file, which this one has never mentioned anywhere.
printf 'theirs\n' > "$REPO/theirs.txt"
fresh_cache
run "git add -A"
refused "an unscoped add is refused when the tree holds a change this session never made"
says "and it names the foreign path" "theirs.txt"
silentabout "and does not accuse this session's own file" "mine.txt is not this session"
says "and hands back the scoped command to run instead" "git -C $REPO add"
says "and that command names this session's own file" "mine.txt"
says "and names the override for the case it has got wrong" "SKIP_ADD_SCOPE_CHECK=1"

run "git add ."
refused "a bare dot is refused the same way"
run "git add --all"
refused "and so is --all"
run "git add -u"
refused "and so is -u, which stages every tracked change"
# The shapes the shared parser has to keep reading once this hook asks it rather than its own
# detector (claude-config#457 item 6): a heredoc commit whose body carries an apostrophe, and an
# add inside a subshell.
run "git add -A && git commit -q -F - <<'MSG'
it isn't balanced
MSG"
refused "an unscoped add before a heredoc with an apostrophe is still refused"
run "(cd $REPO && git add .)"
refused "an unscoped add inside a subshell is refused"
run "git add :/"
refused "and so is :/, which is the whole tree from anywhere"

# The scoped form is the whole point: it must go through even with a foreign change present.
run "git add mine.txt"
allowed "a scoped add is allowed even with another session's work in the tree"
run "git add -- mine.txt viabash.txt"
allowed "and so is an explicit path list"

# The documented override, good for one command.
run "SKIP_ADD_SCOPE_CHECK=1 git add -A"
allowed "the documented override lets one command through"

echo "check add scope: it only fires on a command that really stages"

run "echo 'remember to git add -A next time'"
allowed "a command that merely mentions an unscoped add is not one"
run "git commit -m 'git add -A was wrong here'"
allowed "and neither is a commit message that quotes one"
run "git status"
allowed "an unrelated git command is not one"
run "git add --help"
allowed "asking for help stages nothing"

echo "check add scope: it never goes quiet on its own failure"

# Without the transcript there is no way to tell this session's work from another session's, and
# "everything is yours" is the assumption that produced the incident. Refusing costs one override;
# the other direction costs somebody else's work being committed under a message that does not
# describe it (L42, L98).
run "git add -A" ""
refused "with no transcript to read, it refuses rather than assuming the tree is all this session's"
says "and says that is why" "could not read the session transcript"
run "git add -A" "$FIX/no-such-transcript.jsonl"
refused "a transcript path that is not there is the same failure"

# A transcript that SHRANK is a different file under the same name (a compaction, a fresh session
# reusing the path). Reading on from the old offset would read the middle of a line and the cache
# would hold whatever that produced.
fresh_cache
run "git add mine.txt"
: > "$TR"
mention_edit "$REPO/theirs.txt"
mention_edit "$REPO/mine.txt"
mention_bash "cat > $REPO/viabash.txt <<'EOF'
via bash
EOF"
run "git add -A"
allowed "a transcript rewritten shorter is re-read from the start, not resumed mid line"

echo "check add scope: the reader that says what an add takes (claude-config#480)"

# ps__read_adds in lib/push-scope.sh reads what a `git add` takes with python3, and ps_add_takes_all
# compared its answer against the literal "yes". With no python3 there was no answer at all, which
# compared as NO, so this gate exited 0 on every unscoped add on such a machine with nothing said:
# an absent reader is the one failure indistinguishable from a clean run (L490, L42, L98). The
# transcript this gate tells the session's work from a stranger's by is read with python3 too, so
# nothing is left that could judge the add.
NOPY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/check-add-scope-nopy.XXXXXXXX")"
NOPY="$NOPY_ROOT/bin"; mkdir -p "$NOPY"
for tool in bash sh git grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm shasum wc tail; do
  toolpath="$(command -v "$tool" 2>/dev/null)"
  [ -n "$toolpath" ] && ln -s "$toolpath" "$NOPY/$tool" 2>/dev/null
done
# The fixture's own premise, asserted rather than assumed: a bare directory that still reaches a
# python3 would make every case below pass for the wrong reason (L159).
if PATH="$NOPY" "$NOPY/bash" -c 'command -v python3 >/dev/null 2>&1'; then
  check "the bare directory really reaches no python3" "it found one, so nothing below measures its absence"
else check "the bare directory really reaches no python3" ok; fi

# The SAME directory with jq linked in beside it. jq reads the payload, so the command is legible
# and only the add's own reader is gone, which is the machine this issue is actually about. Its
# twin above, with jq missing too, is the harder case where nothing read the payload either.
WITHJQ="$NOPY_ROOT/withjq"; mkdir -p "$WITHJQ"
for tool in bash sh git grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm shasum wc tail jq; do
  toolpath="$(command -v "$tool" 2>/dev/null)"
  [ -n "$toolpath" ] && ln -s "$toolpath" "$WITHJQ/$tool" 2>/dev/null
done
if PATH="$WITHJQ" "$WITHJQ/bash" -c 'command -v python3 >/dev/null 2>&1'; then
  check "the jq only directory reaches no python3" "it found one, so nothing below measures its absence"
else check "the jq only directory reaches no python3" ok; fi
if PATH="$WITHJQ" "$WITHJQ/bash" -c 'command -v jq >/dev/null 2>&1'; then
  check "the jq only directory really does reach jq" ok
else check "the jq only directory really does reach jq" "there is no jq in it, so it is the same case as the other one"; fi

# RUN FROM the repository, not merely naming it in the payload. Where nothing can read the payload
# at all the gate cannot read its cwd either, and the session's own working directory is what
# Claude Code starts a hook in, so that is what it has left to ask about. A run from anywhere else
# would be judging whichever checkout this suite happens to sit in, and would pass or fail with
# that checkout's state rather than with the fixture's (L2, L411).
run_nopy(){ # run_nopy <command> [bin dir, default the one with no python3 and no jq]
  OUT="$(python3 -c '
import json, sys
d = {"tool_name": "Bash", "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]},
     "transcript_path": sys.argv[3]}
print(json.dumps(d))
' "$1" "$REPO" "$TR" | ( cd "$REPO" && env CLAUDE_ADD_SCOPE_STATE_DIR="$STATE" PATH="${2:-$NOPY}" "${2:-$NOPY}/bash" "$HOOK" 2>&1 ))"; RC=$?
}

fresh_cache
run_nopy "git add -A" "$WITHJQ"
refused "with jq but no python3 an unscoped add is refused rather than allowed in silence"
says "and that refusal names the reader that is missing" "python3"
fresh_cache
run_nopy "git add mine.txt" "$WITHJQ"
refused "and an add nobody can read the scope of is refused whatever it names"

fresh_cache
run_nopy "git add -A"
refused "with no reader at all the add is refused too, rather than passing unseen"
says "and the refusal names the reader that is missing" "python3"

# A command with no `git add` in it takes nothing from the missing reader, so there is nothing to
# refuse over. Without this the gate would be refusing commands it was never about (L54, L324).
fresh_cache
run_nopy "git status"
allowed "a command with no add is not refused over a reader it never needed"

# The documented override still clears it, or the refusal is a dead end nothing in the session can
# answer (L109).
fresh_cache
run_nopy "SKIP_ADD_SCOPE_CHECK=1 git add -A"
allowed "the visible override still clears the missing reader refusal"

# The control, the same command on the same tree with python3 on PATH: allowed, because by now the
# transcript mentions every change in it. So the refusal above is the reader's absence rather than
# a fixture that refuses everything (L159).
fresh_cache
run "git add -A"
allowed "the control still allows the same unscoped add with python3 present"

rm -rf "$NOPY_ROOT"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
