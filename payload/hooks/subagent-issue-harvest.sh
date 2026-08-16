#!/usr/bin/env bash
#
# subagent-issue-harvest.sh — SubagentStop hook. Reads the transcript of a
# subagent that just finished and spools anything it noticed that is worth
# filing but was not the job it was sent to do.
#
# The point is that it does not ask the agent for anything. An instruction to
# "report what you found" is a rule living only in a prompt, which is a hope
# (LESSONS.md L27), and it reaches nothing at all in the batches where it
# matters most: SubagentStop was unlistened to, so an agent's observations died
# with it, and the main session's issue review can only ever see an agent's
# final report. This reads the agent's own transcript instead.
#
# Runs async (see settings.json), so it never holds a subagent's completion up.
#
# Seams, both for the tests and for driving it by hand:
#   CLAUDE_ISSUE_HARVEST_CMD   the model runner (default: headless claude, haiku)
#   CLAUDE_ISSUE_SPOOL_DIR     where the spool lives
#   CLAUDE_ISSUE_HARVEST_OFF   set to anything to disable the harvest entirely
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPOOL="$DIR/lib/issue-spool.sh"

input=$(cat)

# The harvest runs a headless Claude of its own. Its subagents must not harvest
# in turn, or one agent finishing starts a chain of them.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0
[ -n "${CLAUDE_ISSUE_HARVEST_OFF:-}" ] && exit 0
[ -f "$SPOOL" ] || exit 0

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
agent=$(printf '%s' "$input" | jq -r '.agent_type // .subagent_type // "subagent"' 2>/dev/null)
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty' 2>/dev/null)
session=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"
[ -n "$agent" ] || agent="subagent"

# THE TRANSCRIPT TO READ IS `agent_transcript_path`, NOT `transcript_path`.
# A SubagentStop payload carries both, and `transcript_path` is the transcript
# of the SESSION THAT SPAWNED the agent. Reading that one does not fail: it
# harvests the wrong conversation and spools findings that look entirely real
# (measured 2026-08-16, three records, every one of them about the parent).
# So there is no fallback to it here, ever, in any of the three ways it could
# arrive wrong. A payload change has to surface as a loud error rather than as
# a harvest quietly reporting on the wrong thing.
transcript=$(printf '%s' "$input" | jq -r '.agent_transcript_path // empty' 2>/dev/null)
parent=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

spool_error() { # spool_error <reason>
  local rec
  rec=$(python3 -c '
import json, sys
print(json.dumps({"ts": sys.argv[1], "status": "error", "agent": sys.argv[2],
                  "agent_id": sys.argv[3], "session": sys.argv[4], "cwd": sys.argv[5],
                  "transcript": sys.argv[6], "error": sys.argv[7]}))
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$agent" "$agent_id" "$session" "$cwd" "$transcript" "$1")
  bash "$SPOOL" append "$cwd" "$rec"
  exit 0
}

if [ -z "$transcript" ]; then
  spool_error "the payload named no agent_transcript_path, so there was nothing safe to read"
fi
if [ -n "$parent" ] && [ "$transcript" = "$parent" ]; then
  spool_error "the agent transcript and the parent session transcript were the same file"
fi
if [ ! -f "$transcript" ]; then
  spool_error "the named agent transcript does not exist"
fi

# The digest's EXIT CODE is what tells an unreadable transcript from an agent
# that said nothing, because both print nothing. Consulting only its output
# files a corrupt file, a permissions failure or a payload schema change as a
# reassuring "found nothing", which is the same defect as reading the parent
# transcript, one function along.
digest=$(python3 "$DIR/subagent-digest.py" "$transcript" 2>/dev/null)
digest_status=$?
if [ "$digest_status" -ge 99 ]; then
  spool_error "the agent transcript could not be read (digest exited $digest_status)"
fi
if [ -z "$digest" ]; then
  # The agent said nothing at all. Recorded rather than skipped, so the spool
  # still shows a harvest ran for it.
  rec=$(python3 -c '
import json, sys
print(json.dumps({"ts": sys.argv[1], "status": "none", "agent": sys.argv[2],
                  "agent_id": sys.argv[3], "session": sys.argv[4], "cwd": sys.argv[5],
                  "transcript": sys.argv[6], "findings": [],
                  "note": "the agent transcript held nothing the agent said"}))
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$agent" "$agent_id" "$session" "$cwd" "$transcript")
  bash "$SPOOL" append "$cwd" "$rec"
  exit 0
fi

read -r -d '' PROMPT <<'PROMPT_END' || true
You are reading the transcript of a coding subagent that has just finished a task.

Report the problems the agent IDENTIFIED and did not resolve: a defect it saw
and left alone, a gap it flagged, an assumption it made that could be wrong, a
missing test, work it explicitly deferred.

Report those whether or not finding them was the agent's job. An agent sent to
review, audit or investigate has problems as its OUTPUT, and those are exactly
what is worth filing; excluding them as "the task it was sent to do" throws away
the richest transcripts there are. Measured 2026-08-16: an agent that reported
seventeen concrete defects was harvested as having found nothing, for that
reason.

What to leave out is narration of work that is finished: changes the agent made
and verified, its restating of its own assignment, and its progress commentary.

Apply a real bar. Report only things a maintainer would genuinely act on. A
transcript with nothing of that kind in it is the normal case, not a failure.

If there is nothing that meets the bar, print exactly:
NONE

Otherwise print one line per item, each beginning with "FINDING: ", each a
single sentence, naming a file path where the transcript gives one. Print
nothing else: no preamble, no summary, no closing line.

The transcript follows.
PROMPT_END

runner="${CLAUDE_ISSUE_HARVEST_CMD:-}"
if [ -n "$runner" ]; then
  # The recursion guard belongs on BOTH paths. A custom runner that reaches
  # `claude` re-enters this hook when its own agents finish, and the guard at
  # the top of the file is the only thing standing between one agent finishing
  # and a chain of them.
  out=$(printf '%s\n\n%s\n' "$PROMPT" "$digest" | CLAUDE_DETACHED_RUN=1 "$runner" 2>/dev/null)
else
  out=$(printf '%s\n\n%s\n' "$PROMPT" "$digest" \
    | CLAUDE_DETACHED_RUN=1 claude -p --model haiku 2>/dev/null)
fi
status=$?

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# A harvest that could not run is recorded as an ERROR, never as an empty
# answer. The two are indistinguishable downstream otherwise, and "no findings"
# is the reassuring reading of the pair (LESSONS.md L11, L98).
if [ "$status" -ne 0 ] || [ -z "${out//[[:space:]]/}" ]; then
  reason="the harvest model exited $status"
  [ -z "${out//[[:space:]]/}" ] && [ "$status" -eq 0 ] && reason="the harvest model returned nothing"
  spool_error "$reason"
fi

record=$(printf '%s' "$out" | python3 -c '
import json, sys
findings = [ln.split("FINDING:", 1)[1].strip()
            for ln in sys.stdin.read().splitlines()
            if ln.strip().startswith("FINDING:") and ln.split("FINDING:", 1)[1].strip()]
print(json.dumps({"ts": sys.argv[1],
                  "status": "found" if findings else "none",
                  "agent": sys.argv[2], "agent_id": sys.argv[3], "session": sys.argv[4],
                  "cwd": sys.argv[5], "transcript": sys.argv[6],
                  "findings": findings}))
' "$ts" "$agent" "$agent_id" "$session" "$cwd" "$transcript")

bash "$SPOOL" append "$cwd" "$record"
exit 0
