#!/usr/bin/env bash
# Tests that an agent working in an isolated worktree can record a finding with the documented
# `issue-spool.sh note` call, and that the finding reaches the review of the session that
# dispatched it (claude-config#1342).
#
# What happened. On 2026-10-19 a builder dispatched with isolation "worktree" ran the call
# CLAUDE.md taught every agent, `bash ~/.claude/hooks/lib/issue-spool.sh note "$PWD" ...`, and
# Claude Code refused it before it ran: "This agent is isolated in the worktree ..., but this
# command runs bash inside a construct too complex to verify; what it reads or is handed as shell
# text cannot be shown not to run git." The refusal is Claude Code's own worktree isolation, not a
# hook here, and it fires on the RUNTIME VALUE `$PWD` handed to a script: the same script with a
# literal argument runs. Reproduced from a worktree subagent the same day: `hello.sh "$PWD"` was
# refused, `hello.sh "/abs/path"` and `hello.sh .` ran. So the documented form could never work
# for exactly the agents it was written for.
#
# The #1342 fix has two halves and this suite holds both:
#   1. The documented call passes `.` instead of `$PWD`, and `note` turns whatever directory it is
#      handed into an absolute path before recording it. Without that, the record's `cwd` would be
#      the literal ".", which every later reader resolves against ITS OWN directory, attributing
#      the finding to whichever project the reader happens to stand in.
#   2. No instruction an agent follows may hand `note` a shell expansion again: a scan of every
#      place the call is documented, seen to fail on planted copies of the old form (L1, L30).
#
# And the wider class it belongs to (claude-config#1347): the same refusal fires on any shell
# variable or loop in a worktree agent's command, so the last check asserts CLAUDE.md's dispatch
# guidance tells every brief to hand such an agent plain, separate commands with literal paths.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cd "$DIR/.." && pwd)"
REPO_ROOT="$(cd "$PAYLOAD/.." && pwd)"
SPOOL_LIB="$DIR/lib/issue-spool.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

TMPROOT="$(mktemp -d)"
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-spool-note-worktree: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT
# This suite's own spool, transcripts and temp directory, never the live ones (L2).
export CLAUDE_ISSUE_SPOOL_DIR="$TMPROOT/spool"
export CLAUDE_TRANSCRIPT_ROOT="$TMPROOT/transcripts"
export TMPDIR="$TMPROOT/tmp"
mkdir -p "$TMPDIR"
unset CLAUDE_CODE_SESSION_ID

# The layout Claude Code makes: the main checkout, with the agent's worktree NESTED inside it under
# .claude/worktrees, and the session's transcript under the projects root named after the session.
MAIN="$TMPROOT/project"
WT="$MAIN/.claude/worktrees/agent-1342"
mkdir -p "$MAIN"
git -C "$MAIN" init -q 2>/dev/null
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
mkdir -p "$MAIN/.claude/worktrees"
git -C "$MAIN" worktree add -q -b agent-1342 "$WT" 2>/dev/null
SESSION="session-1342"
TRANSCRIPT="$CLAUDE_TRANSCRIPT_ROOT/-encoded-project/$SESSION.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")"
printf '%s\n' '{"type":"user","message":{"content":"dispatch a builder"}}' > "$TRANSCRIPT"

if [ ! -d "$WT" ]; then
  check "the worktree fixture was created" "git worktree add failed"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi
WT_ABS="$(cd "$WT" && pwd)"

records() { cat "$CLAUDE_ISSUE_SPOOL_DIR"/*.jsonl 2>/dev/null; }
cwd_of() { # cwd_of <marker> -> the cwd recorded on the record carrying that finding
  records | python3 -c '
import json, sys
for line in sys.stdin:
    try:
        rec = json.loads(line)
    except ValueError:
        continue
    if any(sys.argv[1] in f for f in rec.get("findings", [])):
        print(rec.get("cwd", "<no cwd>"))
        break' "$1"
}

# ---------------------------------------------------------------------------------------------
# 1. The documented form, run exactly as an agent runs it: from inside the worktree, with `.`.
# ---------------------------------------------------------------------------------------------
rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"
( cd "$WT" && CLAUDE_CODE_SESSION_ID="$SESSION" \
    bash "$SPOOL_LIB" note . "r1342 dot finding from a worktree" "builder-1342" >/dev/null 2>&1 )
rc=$?
[ "$rc" -eq 0 ] && check "note . from a worktree exits 0" ok || check "note . from a worktree exits 0" "exit $rc"

got="$(cwd_of "r1342 dot finding")"
[ "$got" = "$WT_ABS" ] \
  && check "note . records the worktree as an absolute path, never a bare dot" ok \
  || check "note . records the worktree as an absolute path, never a bare dot" "cwd=${got:-<no record>} expected $WT_ABS"

# The dispatching session's review reads with its own transcript, from the MAIN checkout. That is
# the reader that has to see the finding, not one standing in the worktree.
pending="$(bash "$SPOOL_LIB" pending "$MAIN" "$TRANSCRIPT" 2>/dev/null)"
case "$pending" in
  *"r1342 dot finding"*) check "the main session's review sees a note made in its agent's worktree" ok ;;
  *) check "the main session's review sees a note made in its agent's worktree" "pending=${pending:0:200}" ;;
esac

# And with no session to resolve (an agent whose environment carries none), the git common dir
# still takes the worktree to the main checkout's key, which the review also reads.
rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"
( cd "$WT" && bash "$SPOOL_LIB" note . "r1342 sessionless finding" "builder-1342" >/dev/null 2>&1 )
pending="$(bash "$SPOOL_LIB" pending "$MAIN" "$TRANSCRIPT" 2>/dev/null)"
case "$pending" in
  *"r1342 sessionless finding"*) check "a sessionless note from a worktree reaches the main checkout's review" ok ;;
  *) check "a sessionless note from a worktree reaches the main checkout's review" "pending=${pending:0:200}" ;;
esac

# A relative path other than the dot is made absolute the same way, against the caller's directory.
rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"
mkdir -p "$WT/sub"
( cd "$WT" && bash "$SPOOL_LIB" note sub "r1342 relative finding" "builder-1342" >/dev/null 2>&1 )
got="$(cwd_of "r1342 relative finding")"
[ "$got" = "$WT_ABS/sub" ] \
  && check "a relative directory is recorded as the absolute path it names" ok \
  || check "a relative directory is recorded as the absolute path it names" "cwd=${got:-<no record>} expected $WT_ABS/sub"

# The old form keeps working for a caller that is allowed to use it (the main session), and an
# absolute path is recorded unchanged.
rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"
( cd "$WT" && bash "$SPOOL_LIB" note "$WT_ABS" "r1342 absolute finding" "builder-1342" >/dev/null 2>&1 )
got="$(cwd_of "r1342 absolute finding")"
[ "$got" = "$WT_ABS" ] \
  && check "an absolute directory is recorded unchanged" ok \
  || check "an absolute directory is recorded unchanged" "cwd=${got:-<no record>}"

# A directory that does not exist cannot be resolved, and the finding still matters more than its
# attribution: it is kept, under the path exactly as given, rather than refused (L98).
rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"
( cd "$WT" && bash "$SPOOL_LIB" note "$TMPROOT/gone" "r1342 missing dir finding" "builder-1342" >/dev/null 2>&1 )
got="$(cwd_of "r1342 missing dir finding")"
[ "$got" = "$TMPROOT/gone" ] \
  && check "a directory that is not there is kept as given, not dropped" ok \
  || check "a directory that is not there is kept as given, not dropped" "cwd=${got:-<no record>}"

# ---------------------------------------------------------------------------------------------
# 2. No instruction an agent follows may hand `note` a shell expansion.
#
# Claude Code refuses a worktree agent's command that passes a runtime value to a script, so a
# documented `note "$PWD"` (or `$(pwd)`, or any other expansion) is a call that cannot run for the agents
# it is meant for. Scanned in every place that instructs an agent, by the state reached (an
# expansion as any argument of a documented note call), not one spelling of it (L247).
# ---------------------------------------------------------------------------------------------
# Up to the end of the call: the closing backtick of a code span in prose, or the end of the line.
# Reaching past it reads the rest of a paragraph as arguments, and the very sentence explaining why
# `"$PWD"` is refused would then count as passing it.
NOTE_EXPANSION_PAT='issue-spool\.sh"? +note [^`]*[$]'
planted="$TMPROOT/planted.txt"
printf '%s\n' \
  'bash ~/.claude/hooks/lib/issue-spool.sh note "$PWD" "<the finding>" "<who>"' \
  'bash ~/.claude/hooks/lib/issue-spool.sh note $PWD "<the finding>"' \
  'bash ~/.claude/hooks/lib/issue-spool.sh note "$(pwd)" "<the finding>"' \
  'bash ~/.claude/hooks/lib/issue-spool.sh note . "<the finding>" "$AGENT"' > "$planted"
clean="$TMPROOT/clean.txt"
printf '%s\n' \
  'bash ~/.claude/hooks/lib/issue-spool.sh note . "<the finding>" "<who is reporting>"' \
  'issue-spool.sh note <dir> <text> [who]' \
  'with `bash ~/.claude/hooks/lib/issue-spool.sh note . "<the finding>"` (a literal dot, never `"$PWD"`)' > "$clean"
hits="$(grep -cE "$NOTE_EXPANSION_PAT" "$planted" 2>/dev/null || true)"
misses="$(grep -cE "$NOTE_EXPANSION_PAT" "$clean" 2>/dev/null || true)"
[ "$hits" = 4 ] && [ "$misses" = 0 ] \
  && check "the expansion pattern matches every planted old form and none of the safe ones" ok \
  || check "the expansion pattern matches every planted old form and none of the safe ones" "matched $hits of 4 planted and $misses of 3 safe"

# Every file that instructs an agent: CLAUDE.md, the review docs, README, DESIGN and the spool script
# by name, then skills, agents and commands scanned whole so a new brief is covered the day it lands (L96).
scan_files=()
for f in "$PAYLOAD/CLAUDE.md" "$PAYLOAD/hooks/review/"*.md "$REPO_ROOT/README.md" "$REPO_ROOT/DESIGN.md" "$SPOOL_LIB"; do
  [ -f "$f" ] && scan_files+=("$f")
done
for d in "$PAYLOAD/skills" "$PAYLOAD/agents" "$PAYLOAD/commands"; do
  [ -d "$d" ] || continue
  while IFS= read -r f; do scan_files+=("$f"); done < <(find "$d" -type f \( -name '*.md' -o -name '*.sh' \) 2>/dev/null)
done
bad="$(grep -nE "$NOTE_EXPANSION_PAT" "${scan_files[@]}" 2>/dev/null | cut -c1-200)"
[ -z "$bad" ] \
  && check "no documented note call hands the script a shell expansion" ok \
  || check "no documented note call hands the script a shell expansion" "$bad"

# The positive control: the scan above passes vacuously if the call stopped being documented or
# changed its spelling, so the file every agent is told to follow must still carry the dot form.
documented="$(grep -cE 'issue-spool\.sh"? +note +\. ' "$PAYLOAD/CLAUDE.md" 2>/dev/null || true)"
[ "${documented:-0}" -ge 1 ] \
  && check "CLAUDE.md documents the note call in the form a worktree agent can run" ok \
  || check "CLAUDE.md documents the note call in the form a worktree agent can run" "found ${documented:-0} documented note calls using '.'"

# The dot form is one case of a wider refusal: Claude Code refuses a worktree agent's Bash command
# when it holds a shell variable or a loop, so the dispatch guidance must say so for every brief (#1347).
plain="$(grep -E '^- \*\*A worktree agent runs plain, separate commands with literal paths' "$PAYLOAD/CLAUDE.md" 2>/dev/null | grep -E 'shell variable' | grep -cE 'a loop' || true)"
[ "${plain:-0}" -ge 1 ] \
  && check "CLAUDE.md tells briefs a worktree agent runs plain commands with literal paths" ok \
  || check "CLAUDE.md tells briefs a worktree agent runs plain commands with literal paths" "no dispatch rule naming the shell variable and loop cases"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
