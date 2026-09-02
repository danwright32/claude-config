#!/usr/bin/env bash
#
# subagent-issue-harvest.sh: SubagentStop hook. Reads the transcript of a
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

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
[ -n "$DIR" ] || DIR="$HOME/.claude/hooks"
SPOOL="${CLAUDE_ISSUE_SPOOL_LIB:-$DIR/lib/issue-spool.sh}"
SPOOL_ROOT="${CLAUDE_ISSUE_SPOOL_DIR:-$HOME/.claude-issue-spool}"

# Where a record goes when the ordinary path cannot take it. Both of these exist
# because the alternative is dropping a finding and reporting success: the spool
# library going missing (a partial config sync is plausible) and a spool the
# process cannot write to (a full or read-only disk) are both silent otherwise.
unrecorded_log="$SPOOL_ROOT/harvest-unrecorded.log"
lost_records="${TMPDIR:-/tmp}/claude-issue-spool-lost.jsonl"

note_unrecorded() { # note_unrecorded <what>
  mkdir -p "$SPOOL_ROOT" 2>/dev/null
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$unrecorded_log" 2>/dev/null
}

input=$(cat)

# The harvest runs a headless Claude of its own. Its subagents must not harvest
# in turn, or one agent finishing starts a chain of them.
[ -n "${CLAUDE_DETACHED_RUN:-}" ] && exit 0
[ -n "${CLAUDE_ISSUE_HARVEST_OFF:-}" ] && exit 0
if [ ! -f "$SPOOL" ]; then
  note_unrecorded "the spool library is missing at $SPOOL, so this agent's harvest was dropped"
  exit 0
fi

# Appending is the last step of every path through this file, and it can fail.
# Reporting success over a record that was never written is the same defect this
# whole mechanism exists to stop, one layer down.
# The record is keyed on the PARENT SESSION, not on `cwd`. `cwd` is the AGENT's
# directory, and an agent routinely works in a git repo nested inside the folder
# its session was started in, which files its findings under a key that session's
# review never opens (see issue_spool_key). `cwd` is still RECORDED on the
# record: it is how that split was found, and it is worth keeping.
spool_append() { # spool_append <record>
  if bash "$SPOOL" append "$cwd" "$1" "${parent:-}" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$1" >> "$lost_records" 2>/dev/null
  note_unrecorded "a record could not be appended to the spool; it is in $lost_records"
  return 1
}

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
' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$agent" "$agent_id" "$session" "$cwd" "$transcript" "$1" 2>/dev/null)
  # If python3 itself is unavailable this would otherwise append an empty line,
  # which every reader skips: the error would vanish at the exact moment the
  # machine is least healthy. A hand-built record with no interpolation at all
  # is worth more than a blank one.
  # `case` rather than stripping every space out of the record: that substitution's cost is
  # superlinear in the number of matches under the bash macOS ships (claude-config#117).
  case "$rec" in *[![:space:]]*) ;; *)
    rec='{"status":"error","agent":"subagent","error":"a harvest failed and could not encode its own reason"}' ;;
  esac
  spool_append "$rec"
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
if [ "$digest_status" -ge 2 ]; then
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
  spool_append "$rec"
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

# The model call gets a DEADLINE. The hook itself is killed at 180 seconds (a limit Claude Code
# sets, not measured) by
# Claude Code, and a kill leaves no record at all: absence of a record is the one
# state this design cannot represent, so a hang would be indistinguishable from
# an agent that never ran. The default sits below the hook's own limit so the
# error is written while there is still a process alive to write it. macOS has
# no `timeout`, hence perl's alarm.
harvest_timeout="${CLAUDE_ISSUE_HARVEST_TIMEOUT:-150}"
# The child is FORKED rather than exec'd. An `exec` replaces the process image
# and takes the alarm with it, so the deadline silently never fires: measured,
# a two second limit let a thirty second sleep run to completion.
with_deadline() { # with_deadline <seconds> <command...>
  perl -e '
    my $secs = shift;
    my $pid = fork();
    if (!defined $pid) { exit 125; }
    # The child leads its own process GROUP, and the deadline kills the group.
    # Killing only the child leaves its own children holding the output pipe
    # open, so the caller keeps waiting for a command that is already dead:
    # measured, a two second limit still took the full thirty seconds.
    if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127; }
    $SIG{ALRM} = sub { kill("KILL", -$pid) || kill("KILL", $pid); waitpid($pid, 0); exit 124; };
    alarm $secs;
    waitpid($pid, 0);
    alarm 0;
    exit($? >> 8);
  ' "$@" 2>/dev/null
}

# The runner is documented as a command, so it has to be able to carry
# arguments. Expanded as a single word it fails with "command not found" on the
# obvious form, and no test covered it because every stub was one bare script.
runner="${CLAUDE_ISSUE_HARVEST_CMD:-}"
if [ -n "$runner" ]; then
  # The recursion guard belongs on BOTH paths. A custom runner that reaches
  # `claude` re-enters this hook when its own agents finish, and the guard at
  # the top of the file is the only thing standing between one agent finishing
  # and a chain of them.
  out=$(printf '%s\n\n%s\n' "$PROMPT" "$digest" \
    | CLAUDE_DETACHED_RUN=1 with_deadline "$harvest_timeout" bash -c "$runner")
else
  out=$(printf '%s\n\n%s\n' "$PROMPT" "$digest" \
    | CLAUDE_DETACHED_RUN=1 with_deadline "$harvest_timeout" claude -p --model haiku)
fi
status=$?

# A runaway reply must not become a multi-megabyte record that is then injected
# into every review prompt until it is filed.
if [ "${#out}" -gt 20000 ]; then
  out="${out:0:20000}"
fi

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# A harvest that could not run is recorded as an ERROR, never as an empty
# answer. The two are indistinguishable downstream otherwise, and "no findings"
# is the reassuring reading of the pair (LESSONS.md L11, L98).
# Asked ONCE and kept, because $out is model output with no bounded length and the substitution
# this replaces is superlinear in the number of matches it makes (claude-config#117). Holding the
# answer also stops the two readings below drifting apart.
out_blank=1
case "$out" in *[![:space:]]*) out_blank=0 ;; esac
if [ "$status" -ne 0 ] || [ "$out_blank" -eq 1 ]; then
  reason="the harvest model exited $status"
  [ "$out_blank" -eq 1 ] && [ "$status" -eq 0 ] && reason="the harvest model returned nothing"
  spool_error "$reason"
fi

record=$(printf '%s' "$out" | python3 -c '
import json, sys

MAX_FINDINGS = 50
MAX_FINDING_CHARS = 500

raw = sys.stdin.read()
findings = [ln.split("FINDING:", 1)[1].strip()[:MAX_FINDING_CHARS]
            for ln in raw.splitlines()
            if ln.strip().startswith("FINDING:") and ln.split("FINDING:", 1)[1].strip()]
findings = findings[:MAX_FINDINGS]

# A reply that is neither NONE nor FINDING lines is its OWN outcome. Treating it
# as "found nothing" throws away whatever the model actually said and looks
# exactly like a clean answer, so the raw text is kept and the reader is told.
# This is the one place the code trusts a format the prompt asks for, and a
# prompt-level contract with no fallback is a hope.
status = "found" if findings else ("none" if raw.strip().upper().startswith("NONE") else "unparsed")

rec = {"ts": sys.argv[1], "status": status,
       "agent": sys.argv[2], "agent_id": sys.argv[3], "session": sys.argv[4],
       "cwd": sys.argv[5], "transcript": sys.argv[6],
       "findings": findings}
if status == "unparsed":
    rec["raw"] = raw.strip()[:2000]
print(json.dumps(rec))
' "$ts" "$agent" "$agent_id" "$session" "$cwd" "$transcript")

spool_append "$record"
exit 0
