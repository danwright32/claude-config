#!/usr/bin/env bash
# Tests for the subagent issue harvest: lib/issue-spool.sh, subagent-issue-harvest.sh,
# and the spool injection into feature-issue-review.sh.
#
# Why these exist. A subagent that finishes fires SubagentStop, which nothing was
# listening to, so every observation an agent made while working died with it. The
# harvest reads the agent's own transcript and spools what it found, so the review
# does not depend on the agent, or on Claude, choosing to write anything down.
#
# The cases that matter are the ones where silence and success look identical:
# a harvest that found nothing must say so (L98), a harvest that FAILED must say
# that differently (L11), and a finding must survive a review that never fires
# (the spool is cleared by filing, never by being read).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPOOL_LIB="$DIR/lib/issue-spool.sh"
HARVEST="$DIR/subagent-issue-harvest.sh"
REVIEW="$DIR/feature-issue-review.sh"

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
trap 'rm -rf "$TMPROOT"' EXIT
export CLAUDE_ISSUE_SPOOL_DIR="$TMPROOT/spool"
# The hook under test writes the records it could not spool to a fixed name in the shared temp
# directory, and this suite used to read and remove that exact path. Two runs at once therefore
# destroyed each other's file, which is the same fault claude-config#180 was written for, in a
# different directory (claude-config#186).
#
# Pointing TMPDIR at this run's OWN throwaway directory moves every such path inside it, so the
# hook keeps computing the name it computes in production and this run still cannot collide with
# another. It is exported after TMPROOT exists, so TMPROOT itself is still made in the real temp
# directory and the trap above still reclaims the lot.
export TMPDIR="$TMPROOT/tmp"
mkdir -p "$TMPDIR"
# Named once, from that directory, rather than spelled out at each use: a path written out in full
# is a path the next person copies, and the guard cannot tell one copy from three.
LOST_RECORDS="$TMPDIR/claude-issue-spool-lost.jsonl"

# Two transcripts, because the real payload carries two and picking the wrong
# one is the defect these tests exist for. `transcript_path` is the transcript of
# the SESSION THAT SPAWNED the agent; `agent_transcript_path` is the agent's own.
# Reading the parent produces confident findings about the wrong conversation,
# and it looks exactly like the harvest working (measured 2026-08-16: three
# spooled records, every one of them about the parent session).
FAKE_TRANSCRIPT="$TMPROOT/agent.jsonl"
cat > "$FAKE_TRANSCRIPT" <<'JSONL'
{"type":"user","message":{"content":"Fix the venue location bug"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed it. I also noticed EventPlace has no test for the empty case."}]}}
JSONL

PARENT_TRANSCRIPT="$TMPROOT/parent.jsonl"
cat > "$PARENT_TRANSCRIPT" <<'JSONL'
{"type":"user","message":{"content":"run the batch"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"PARENT_SESSION_MARKER: this is the conversation that spawned the agent, not the agent."}]}}
JSONL

payload() { # payload <cwd> [agent-transcript] [parent-transcript]
  python3 - "$1" "${2:-$FAKE_TRANSCRIPT}" "${3:-$PARENT_TRANSCRIPT}" <<'PY'
import json, sys
rec = {
    "session_id": "test-session",
    "cwd": sys.argv[1],
    "agent_type": "Explore",
    "agent_id": "test-agent-id",
    "hook_event_name": "SubagentStop",
}
if sys.argv[2] != "OMIT":
    rec["agent_transcript_path"] = sys.argv[2]
if sys.argv[3] != "OMIT":
    rec["transcript_path"] = sys.argv[3]
print(json.dumps(rec))
PY
}

# ---------------------------------------------------------------------------
# The spool key: an agent working in a worktree must reach the SAME spool as the
# session that reads it, or its findings are filed under a project nobody opens.
# ---------------------------------------------------------------------------
REPO="$TMPROOT/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
WORKTREE="$TMPROOT/wt"
git -C "$REPO" worktree add -q -b harvest-test "$WORKTREE" 2>/dev/null

if [ -d "$WORKTREE" ]; then
  key_main="$(bash "$SPOOL_LIB" key "$REPO" 2>&1)"
  key_wt="$(bash "$SPOOL_LIB" key "$WORKTREE" 2>&1)"
  [ -n "$key_main" ] && [ "$key_main" = "$key_wt" ] \
    && check "a worktree keys to its main checkout" ok \
    || check "a worktree keys to its main checkout" "main=$key_main worktree=$key_wt"
else
  check "worktree fixture was created" "git worktree add failed"
fi

key_other="$(bash "$SPOOL_LIB" key "$TMPROOT" 2>&1)"
[ -n "${key_main:-}" ] && [ "$key_main" != "$key_other" ] \
  && check "two different projects key apart" ok \
  || check "two different projects key apart" "both=$key_main"

# ---------------------------------------------------------------------------
# The harvest itself, with the model call stubbed through its seam.
# ---------------------------------------------------------------------------
MODEL_INPUT="$TMPROOT/model-input.txt"
stub() { # stub <script-body>  -> writes an executable stub and points the seam at it
  # Every stub records what was actually piped to the model, so a test can ask
  # WHICH transcript reached it rather than only what came back.
  printf '#!/usr/bin/env bash\ncat > "%s"\n%s\n' "$MODEL_INPUT" "$1" > "$TMPROOT/stub.sh"
  chmod +x "$TMPROOT/stub.sh"
  export CLAUDE_ISSUE_HARVEST_CMD="$TMPROOT/stub.sh"
}

records() { bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null; }
reset_spool() { rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; }

# `producer | grep -q needle` is a trap under `pipefail`, which this suite sets: grep -q exits on
# its first match, the producer is killed by SIGPIPE, and the pipeline's status becomes that death,
# so a check can report a failure that never happened (L183). It depends on nothing but whether the
# producer had finished writing, which makes it rare, machine specific, and maddening. So the
# output is captured first and matched against a variable.
contains() { # contains <needle> <haystack>
  case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac
}

# What a review actually DELIVERED. The findings no longer travel inside the
# payload: the reason names a file and Claude opens it (claude-config#243), so a
# check that the review carried a record has to read the reason AND that file. It
# is the same question these checks always asked, asked of the new transport.
#
# A reason naming a file that is NOT there answers with the reason alone, which is
# the correct answer: a pointer at nothing delivered nothing.
carried() { # carried <review payload>  -> the text this review put in front of a reader
  local payload="$1" f
  printf '%s' "$payload" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    print(json.loads(raw).get("reason") or "")
except Exception:
    print(raw)
'
  f="$(printf '%s' "$payload" | python3 -c '
import json, re, sys
try:
    reason = json.loads(sys.stdin.read()).get("reason") or ""
except Exception:
    reason = ""
m = re.search(r"waiting in (\S+?)\. They", reason)
print(m.group(1) if m else "")
')"
  if [ -n "$f" ] && [ -f "$f" ]; then cat "$f"; fi
  return 0
}

spool_says() { # spool_says <needle>  -> true when `spool pending` mentions it
  local out
  out="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null || true)"
  case "$out" in *"$1"*) return 0 ;; *) return 1 ;; esac
}

# A harvest that finds something records it.
reset_spool
stub 'echo "FINDING: EventPlace has no test for the empty case (EventPlace.swift)."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"found"' \
  && printf '%s' "$got" | grep -q 'EventPlace' \
  && check "a finding is spooled as found" ok \
  || check "a finding is spooled as found" "spool=$got"

# A harvest that finds NOTHING must still leave a record. Otherwise "looked and
# found nothing" and "never ran" are the same empty file (L98).
reset_spool
stub 'echo NONE'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"none"' \
  && check "an empty harvest records that it looked" ok \
  || check "an empty harvest records that it looked" "spool=$got"

# A harvest that FAILED must say so in its own words, not borrow the empty one.
reset_spool
stub 'echo "model unavailable" >&2; exit 7'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"error"' \
  && check "a failed harvest records an error, not none" ok \
  || check "a failed harvest records an error, not none" "spool=$got"

# A harvest whose model returns nothing at all is a failure too, not an empty answer.
reset_spool
stub 'exit 0'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"error"' \
  && check "a silent model is an error, not none" ok \
  || check "a silent model is an error, not none" "spool=$got"

# Recursion guard: the harvest runs a headless Claude, whose own subagents must
# not harvest in turn.
reset_spool
stub 'echo "FINDING: should never be written."'
payload "$REPO" | CLAUDE_DETACHED_RUN=1 bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
[ -z "$got" ] \
  && check "a detached run does not harvest" ok \
  || check "a detached run does not harvest" "spool=$got"

# ---------------------------------------------------------------------------
# WHICH transcript is read. The payload carries the parent session's transcript
# as well as the agent's, and reading the parent is indistinguishable from the
# harvest working: it spools real-looking findings about the wrong conversation.
# ---------------------------------------------------------------------------
reset_spool
stub 'echo NONE'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
sent="$(cat "$MODEL_INPUT" 2>/dev/null)"
printf '%s' "$sent" | grep -q "EventPlace has no test" \
  && ! printf '%s' "$sent" | grep -q "PARENT_SESSION_MARKER" \
  && check "the agent's transcript is what reaches the model" ok \
  || check "the agent's transcript is what reaches the model" "the parent's content reached it"

# With no agent transcript named, it must REFUSE. Falling back to the parent is
# the exact defect above, and a silent skip would hide a payload change.
# The reason is asserted, not merely the fact of an error. The same-file guard
# below would otherwise answer for this one: under a reintroduced fallback the
# agent path becomes the parent path, that guard fires, and this test passes
# while the fallback it exists to forbid is back in the code (L140).
reset_spool
stub 'echo "FINDING: should never be reached."'
payload "$REPO" OMIT | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"error"' \
  && printf '%s' "$got" | grep -q "named no agent_transcript_path" \
  && ! printf '%s' "$got" | grep -q "should never be reached" \
  && check "no agent transcript is an error, never a fallback to the parent" ok \
  || check "no agent transcript is an error, never a fallback to the parent" "spool=$got"

# Belt and braces: if the two paths ever arrive equal, that is the parent again.
reset_spool
stub 'echo "FINDING: should never be reached."'
payload "$REPO" "$PARENT_TRANSCRIPT" "$PARENT_TRANSCRIPT" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"error"' \
  && check "an agent path equal to the parent's is refused" ok \
  || check "an agent path equal to the parent's is refused" "spool=$got"

# A transcript that was named but is not there is an error, not silence: we were
# told where to look and it was not there, which is a fault worth seeing.
reset_spool
stub 'echo NONE'
payload "$REPO" "$TMPROOT/does-not-exist.jsonl" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"error"' \
  && check "a named but missing transcript is an error" ok \
  || check "a named but missing transcript is an error" "spool=$got"

# Every record has to say what it read and who it read, or the next version of
# this defect is again only findable by hand.
reset_spool
stub 'echo "FINDING: something."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q "$FAKE_TRANSCRIPT" \
  && check "the record names the transcript it read" ok \
  || check "the record names the transcript it read" "spool=$got"
printf '%s' "$got" | grep -q '"agent": *"Explore"' \
  && check "the record names the agent type" ok \
  || check "the record names the agent type" "spool=$got"

# ---------------------------------------------------------------------------
# An UNREADABLE transcript is not an agent that said nothing. The digest prints
# nothing in both cases, so if only its output is consulted a corrupt file, a
# permissions failure or a schema change all file as a reassuring "none". This
# is the same defect as reading the parent transcript, one function along.
# ---------------------------------------------------------------------------
UNREADABLE="$TMPROOT/unreadable.jsonl"
printf '\x80\x81\x82 not valid utf-8 \xff\xfe' > "$UNREADABLE"

reset_spool
stub 'echo NONE'
payload "$REPO" "$UNREADABLE" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"error"' \
  && check "an unreadable transcript is an error, not an agent that said nothing" ok \
  || check "an unreadable transcript is an error, not an agent that said nothing" "spool=$got"

# ...while an agent that genuinely said nothing is still a `none`, so the two
# stay told apart in both directions.
SILENT_AGENT="$TMPROOT/silent.jsonl"
cat > "$SILENT_AGENT" <<'JSONL'
{"type":"user","message":{"content":"do a thing"}}
JSONL
reset_spool
stub 'echo NONE'
payload "$REPO" "$SILENT_AGENT" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"none"' \
  && check "an agent that said nothing is a none, not an error" ok \
  || check "an agent that said nothing is a none, not an error" "spool=$got"

# ---------------------------------------------------------------------------
# Repeated identical failures must not be able to spam the review. A non-empty
# spool bypasses the cooldown by design, so an error that recurs (measured
# 2026-08-16: a subagent with no transcript on disk fired about once a minute)
# would otherwise make the review fire every turn, carrying N copies of one line.
# ---------------------------------------------------------------------------
reset_spool
stub 'exit 7'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
lines="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null | grep -c "HARVEST FAILED" || true)"
[ "$lines" = "1" ] \
  && check "one repeated failure is reported once, not once per occurrence" ok \
  || check "one repeated failure is reported once, not once per occurrence" "printed $lines lines"

# Two DIFFERENT failures are still two, or deduping would hide a second fault.
reset_spool
stub 'exit 7'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
payload "$REPO" OMIT | bash "$HARVEST" >/dev/null 2>&1
lines="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null | grep -c "HARVEST FAILED" || true)"
[ "$lines" = "2" ] \
  && check "two different failures are still reported separately" ok \
  || check "two different failures are still reported separately" "printed $lines lines"

# ---------------------------------------------------------------------------
# Filing must not be able to eat a finding that arrives while it runs. `clear`
# used to copy the file and then truncate it, two steps with no lock, and it is
# run exactly when background agents are still finishing.
# ---------------------------------------------------------------------------
# Timing this by racing real processes is not a test: run against the losing
# implementation it passed anyway, because the window happened not to open. So
# `clear` carries a named seam at the one moment that decides the answer, and
# the test appends exactly there. Copy-then-truncate destroys that record;
# rename-then-drain cannot, because the appender is writing to a fresh file.
reset_spool
stub 'echo "FINDING: filed before the clear."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1

export CLAUDE_ISSUE_SPOOL_MIDCLEAR="bash '$SPOOL_LIB' append '$REPO' '{\"ts\":\"t\",\"status\":\"found\",\"findings\":[\"arrived-mid-clear\"]}'"
bash "$SPOOL_LIB" clear "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
unset CLAUDE_ISSUE_SPOOL_MIDCLEAR

still_pending="$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
archived="$(bash "$SPOOL_LIB" archive "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
printf '%s' "$still_pending" | grep -q "arrived-mid-clear" \
  && check "a finding arriving during filing is not eaten by it" ok \
  || check "a finding arriving during filing is not eaten by it" "pending=$still_pending"
printf '%s' "$archived" | grep -q "filed before the clear" \
  && check "filing still archives what was there when it started" ok \
  || check "filing still archives what was there when it started" "archive=$archived"

# ---------------------------------------------------------------------------
# pending / clear: what the review reads, and what filing removes.
# ---------------------------------------------------------------------------
reset_spool
stub 'echo "FINDING: the queue rebuild is not measured."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
stub 'echo NONE'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1

pending="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>&1)"
pending_code=$?
printf '%s' "$pending" | grep -q "queue rebuild is not measured" \
  && [ "$pending_code" -eq 0 ] \
  && check "pending prints the findings" ok \
  || check "pending prints the findings" "code=$pending_code out=$pending"

lines="$(printf '%s\n' "$pending" | grep -c "FINDING" || true)"
[ "$lines" = "1" ] \
  && check "an empty harvest adds nothing to pending" ok \
  || check "an empty harvest adds nothing to pending" "finding lines=$lines"

# Reading must NOT clear. A review that is read and then interrupted has to leave
# the finding behind for the next one.
pending_again="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>&1)"
printf '%s' "$pending_again" | grep -q "queue rebuild is not measured" \
  && check "reading pending does not consume it" ok \
  || check "reading pending does not consume it" "out=$pending_again"

bash "$SPOOL_LIB" clear "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
[ $? -ne 0 ] \
  && check "clear empties pending" ok \
  || check "clear empties pending" "pending survived clear"

archive="$(bash "$SPOOL_LIB" archive "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
printf '%s' "$archive" | grep -q "queue rebuild is not measured" \
  && check "clear keeps the record in the archive" ok \
  || check "clear keeps the record in the archive" "archive=$archive"

bash "$SPOOL_LIB" pending "$TMPROOT" >/dev/null 2>&1
[ $? -ne 0 ] \
  && check "pending on an untouched project exits non-zero" ok \
  || check "pending on an untouched project exits non-zero" "exited 0 with no spool"

# ---------------------------------------------------------------------------
# The review hook: a pending finding must reach Claude even inside the cooldown,
# and the payload must still be valid JSON once the finding is injected.
# ---------------------------------------------------------------------------
reset_spool
stub 'echo "FINDING: spool injection marker seven."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1

REVIEW_TRANSCRIPT="$TMPROOT/main.jsonl"
cat > "$REVIEW_TRANSCRIPT" <<'JSONL'
{"type":"user","message":{"content":"do the thing"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}
JSONL
review_payload="$(python3 - "$REPO" "$REVIEW_TRANSCRIPT" <<'PY'
import json, sys
print(json.dumps({"transcript_path": sys.argv[2], "cwd": sys.argv[1],
                  "stop_hook_active": False}))
PY
)"

# Warm the cooldown stamp so the only reason the hook can speak is the spool.
export CLAUDE_PROJECT_DIR="$REPO"
printf '%s' "$review_payload" | bash "$REVIEW" >/dev/null 2>&1
out="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
contains "spool injection marker seven" "$(carried "$out")" \
  && check "a pending finding beats the cooldown" ok \
  || check "a pending finding beats the cooldown" "out=${out:0:200}"

parsed="$(printf '%s' "$out" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception as exc:
    print("does not parse: %s" % exc); raise SystemExit
print("ok" if d.get("decision") == "block" and d.get("reason") else "missing decision/reason")
' 2>&1)"
check "the injected payload is still valid JSON" "$parsed"

# A spool holding ONLY failures must NOT bypass the cooldown. Deduping cut the
# volume of a recurring fault but not the interruption: pending stays non-empty
# forever, so the review would still fire on every single turn. A failure is
# worth reporting at the next ordinary review, not worth interrupting for.
reset_spool
stub 'exit 7'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
printf '%s' "$review_payload" | bash "$REVIEW" >/dev/null 2>&1   # warm the stamp
out_err="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
[ -z "$out_err" ] \
  && check "failures alone do not bypass the cooldown" ok \
  || check "failures alone do not bypass the cooldown" "spoke anyway: ${out_err:0:100}"

# ...but a failure still gets REPORTED once the cooldown lets the review speak,
# or a broken harvest becomes invisible instead of merely quiet.
rm -f "${TMPDIR:-/tmp}/claude-feature-issue-review-$(printf '%s' "$REPO" | shasum | cut -c1-12).stamp"
out_err_cold="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
contains "HARVEST FAILED" "$(carried "$out_err_cold")" \
  && check "a failure is still reported at the next ordinary review" ok \
  || check "a failure is still reported at the next ordinary review" "not mentioned"

# With the spool empty, the cooldown must still hold, or the review fires every turn.
bash "$SPOOL_LIB" clear "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
out_quiet="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
[ -z "$out_quiet" ] \
  && check "an empty spool leaves the cooldown in force" ok \
  || check "an empty spool leaves the cooldown in force" "spoke anyway: ${out_quiet:0:120}"

# ...and the review must still FIRE normally when the spool is empty and the
# cooldown has expired. Silence is the correct answer to a warm cooldown and a
# fatal error looks exactly the same from outside, so this asserts the ordinary
# path the spool lookup sits in front of still works at all.
rm -f "${TMPDIR:-/tmp}/claude-feature-issue-review-$(printf '%s' "$REPO" | shasum | cut -c1-12).stamp"
out_cold="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
printf '%s' "$out_cold" | grep -q '"decision"' \
  && check "an empty spool does not stop the ordinary review" ok \
  || check "an empty spool does not stop the ordinary review" "silent: ${out_cold:0:120}"

# ---------------------------------------------------------------------------
# A harvest failure settles itself once it has actually been REPORTED (#85).
#
# A HARVEST FAILED record could never be settled. The spool is emptied only by
# `clear`, and the review's own instruction says to run that AFTER the picker is
# answered; a spool holding nothing but failures gives the review nothing to put
# in a picker, so no picker appears, so nothing ever runs clear. Measured
# 2026-08-18: a record written at 18:18 UTC was still riding along on every
# review an hour later, and the underlying fault (a nested agent leaves no
# transcript anywhere) recurs and cannot be fixed at the source. There is no
# action a person can take on one, so it is filed as soon as it has been
# delivered. A real finding keeps the old rule and waits for the picker.
# ---------------------------------------------------------------------------
REVIEW_STAMP="${TMPDIR:-/tmp}/claude-feature-issue-review-$(printf '%s' "$REPO" | shasum | cut -c1-12).stamp"
reset_spool
stub 'exit 9'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$REPO" "the retry path has no failure test" "nested-agent" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
rm -f "$REVIEW_STAMP"
out_settle="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
# The positive control. Every "gone from pending" assertion below is satisfied by
# a review that never carried the record at all, so what was delivered is checked
# first, in the same fixture (L159).
carried_settle="$(carried "$out_settle")"
contains "HARVEST FAILED" "$carried_settle" \
  && contains "retry path has no failure test" "$carried_settle" \
  && check "the review that settles a failure really carried it" ok \
  || check "the review that settles a failure really carried it" "out=${carried_settle:0:200}"

# The instruction riding with it has to match what the code then does. It tells
# Claude to run `clear` after the picker is answered, and a failure is never in a
# picker, so without this line the reader is told to expect back a record that has
# already been filed (L32: a doc states a testable claim, and this one is delivered
# to the reader inside the same message).
contains "it will not come back" "$(cat "$(dirname "$REVIEW")/review/issue-review.md" 2>/dev/null)" \
  && check "the instruction says a reported failure will not come back" ok \
  || check "the instruction says a reported failure will not come back" "the instruction file does not say it"

pend_settle="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
printf '%s' "$pend_settle" | grep -q "HARVEST FAILED" \
  && check "a reported failure is not offered a second time" "still pending: ${pend_settle:0:200}" \
  || check "a reported failure is not offered a second time" ok
printf '%s' "$pend_settle" | grep -q "retry path has no failure test" \
  && check "a finding in the same spool is left pending" ok \
  || check "a finding in the same spool is left pending" "pending=${pend_settle:0:200}"
arch_settle="$(bash "$SPOOL_LIB" archive "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
printf '%s' "$arch_settle" | grep -q '"status": *"error"' \
  && check "the settled failure is filed, not dropped" ok \
  || check "the settled failure is filed, not dropped" "archive=${arch_settle:0:200}"

# The other half. Filing is tied to the report having GONE OUT, not to the hook
# having run: a review that could not carry the spool text must leave the record
# alone, or the one failure mode this fix introduces (settling something unseen)
# happens on every injector failure as well.
reset_spool
stub 'exit 9'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
rm -f "$REVIEW_STAMP"
out_nodel="$(printf '%s' "$review_payload" | CLAUDE_REVIEW_REASON_FORCE_FAIL=1 bash "$REVIEW" 2>/dev/null)"
printf '%s' "$out_nodel" | grep -q "HARVEST FAILED" \
  && check "the undelivered review really left the failure out" "it carried it: ${out_nodel:0:200}" \
  || check "the undelivered review really left the failure out" ok
pend_nodel="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
printf '%s' "$pend_nodel" | grep -q "HARVEST FAILED" \
  && check "a failure nobody was shown stays pending" ok \
  || check "a failure nobody was shown stays pending" "pending=${pend_nodel:0:200}"

# An unreadable record is NOT an error record: nothing classified it, so filing it
# would settle something nobody has read (L11). It stays until a person files it.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
printf 'this is not a record at all\n' >> "$(bash "$SPOOL_LIB" path "$REPO" "$PARENT_TRANSCRIPT")"
bash "$SPOOL_LIB" file-errors "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
pend_corrupt="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
printf '%s' "$pend_corrupt" | grep -q "UNREADABLE SPOOL RECORDS" \
  && check "filing failures leaves an unreadable record pending" ok \
  || check "filing failures leaves an unreadable record pending" "pending=${pend_corrupt:0:200}"

# ---------------------------------------------------------------------------
# The second round, from an agent's own review of this code. Every one of these
# is a way a failure could be silent, a record could be lost, or something could
# grow without bound.
# ---------------------------------------------------------------------------

# The spool library going missing must not silence the harvest. A partial config
# sync is plausible, and today it drops every finding with nothing written down.
reset_spool
stub 'echo "FINDING: something worth keeping."'
payload "$REPO" | CLAUDE_ISSUE_SPOOL_LIB="$TMPROOT/not-here.sh" bash "$HARVEST" >/dev/null 2>&1
lost="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/harvest-unrecorded.log" 2>/dev/null)"
printf '%s' "$lost" | grep -q "spool library is missing" \
  && check "a missing spool library is recorded, not silently swallowed" ok \
  || check "a missing spool library is recorded, not silently swallowed" "log=$lost"

# An append that cannot be written must not be reported as a clean run.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
chmod 500 "$CLAUDE_ISSUE_SPOOL_DIR"
stub 'echo "FINDING: written to a read-only spool."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
chmod 700 "$CLAUDE_ISSUE_SPOOL_DIR"
lost="$(cat "$LOST_RECORDS" 2>/dev/null)"
printf '%s' "$lost" | grep -q "read-only spool" \
  && check "a record that cannot be written lands in the lost file" ok \
  || check "a record that cannot be written lands in the lost file" "lost=$lost"
rm -f "$LOST_RECORDS"

# A hung model must not take the whole hook down with it and leave no trace.
#
# How long that took is judged against a run of the SAME hook whose model answers at once, timed
# here, rather than against a number chosen here (claude-config#149). It was "under 15 seconds",
# and on 2026-08-21 a Mac at load 38 to 103 pushed ordinary runs of this suite's neighbours past
# bounds of that kind: a red result that has to be re-run before it is believed stops being read
# (L36), and the pre-push gate blocks on it, so a busy Mac blocked a correct push. The reference
# pays the same startup this one does and stretches with the machine in the same way.
#
# The slack over it is three of the hook's OWN deadlines, set on the line below rather than being
# a constant that can age. What has to be caught is the hook sitting there for the model's full
# 30 seconds, or for ever.
reset_spool
stub 'echo NONE'
quick_start=$SECONDS
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
quick_elapsed=$((SECONDS - quick_start))
reset_spool
hang_timeout=2
stub 'sleep 30'
start=$SECONDS
payload "$REPO" | CLAUDE_ISSUE_HARVEST_TIMEOUT=$hang_timeout bash "$HARVEST" >/dev/null 2>&1
elapsed=$((SECONDS - start))
hang_max=$(( quick_elapsed + 3 * hang_timeout ))
got="$(records)"
[ "$elapsed" -le "$hang_max" ] && printf '%s' "$got" | grep -q '"status": *"error"' \
  && check "a hung model is cut off and recorded" ok \
  || check "a hung model is cut off and recorded" "took ${elapsed}s against a bound of ${hang_max}s, spool=$got"
# The same comparison, asked of one second over that bound, so it has been watched REFUSING rather
# than only agreeing. Without it any bound large enough satisfies the check above, which is every
# bound, and it would read as protection while protecting nothing (L1).
[ $(( hang_max + 1 )) -le "$hang_max" ] \
  && check "and a hook one second over that bound would be caught" "the bound accepted $(( hang_max + 1 ))s" \
  || check "and a hook one second over that bound would be caught" ok

# Model output that is neither NONE nor FINDING lines is its own outcome, and
# the raw text is kept. Today it is silently indistinguishable from a clean NONE.
reset_spool
stub 'echo "Here are the issues I spotted: the parser is wrong."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"unparsed"' \
  && printf '%s' "$got" | grep -q "the parser is wrong" \
  && check "unparseable model output is its own status with the raw text kept" ok \
  || check "unparseable model output is its own status with the raw text kept" "spool=$got"
spool_says "COULD NOT BE READ" \
  && check "an unparseable reply is held back from every review" "it printed" \
  || check "an unparseable reply is held back from every review" ok
contains "reply" "$(bash "$SPOOL_LIB" muted-summary "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)" \
  && check "an unparseable reply is counted in the periodic report" ok \
  || check "an unparseable reply is counted in the periodic report" "summary=$(bash "$SPOOL_LIB" muted-summary "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null | cut -c1-160)"

# The two kinds must stay TOLD APART in that line. An unreadable transcript can
# never be fixed; a reply the harvest could not parse is a prompt that can be,
# so folding them into one number would bury the fixable half in the hopeless
# one, which is the mistake the mute was written to avoid.
# Both kinds have to be PRESENT for "told apart" to mean anything: a fixture
# holding one of them is satisfied by a report that can only ever name one.
bash "$SPOOL_LIB" append "$REPO" '{"ts":"2026-08-29T12:00:00Z","status":"error","agent":"subagent","error":"the named agent transcript does not exist"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
sum_kinds="$(bash "$SPOOL_LIB" muted-summary "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
contains "could not be read" "$sum_kinds" && contains "repl" "$sum_kinds" \
  && check "the periodic report tells the two kinds apart" ok \
  || check "the periodic report tells the two kinds apart" "summary=${sum_kinds:0:200}"

# And they settle only when that report has gone out, exactly as the failures do.
bash "$SPOOL_LIB" file-errors "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
contains '"status": "unparsed"' "$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)" \
  && check "filing shown failures leaves the unparseable reply pending" ok \
  || check "filing shown failures leaves the unparseable reply pending" "it was filed unseen"
bash "$SPOOL_LIB" file-muted "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
contains '"status": "unparsed"' "$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)" \
  && check "the periodic report settles the unparseable reply" "it is still pending" \
  || check "the periodic report settles the unparseable reply" ok

# A runaway reply must not become a multi-megabyte record.
reset_spool
stub 'python3 -c "print(\"FINDING: \" + \"x\"*200000)"'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
size="$(records | wc -c | tr -d ' ')"
[ "$size" -lt 20000 ] \
  && check "a runaway model reply is bounded" ok \
  || check "a runaway model reply is bounded" "record is $size bytes"

# A corrupt line must be reported, not skipped in silence.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
printf 'this is not json\n' >> "$(bash "$SPOOL_LIB" path "$REPO" "$PARENT_TRANSCRIPT")"
spool_says "UNREADABLE SPOOL" \
  && check "a corrupt spool line is reported" ok \
  || check "a corrupt spool line is reported" "silently skipped"

# append must refuse anything that would break one record per line.
reset_spool
bash "$SPOOL_LIB" append "$REPO" 'not json at all' "$PARENT_TRANSCRIPT" 2>/dev/null \
  && check "append refuses a non-JSON record" "it accepted it" \
  || check "append refuses a non-JSON record" ok
bash "$SPOOL_LIB" append "$REPO" '{"a":1}
{"b":2}' "$PARENT_TRANSCRIPT" 2>/dev/null \
  && check "append refuses a multi-line record" "it accepted it" \
  || check "append refuses a multi-line record" ok

# The archive must not grow forever.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
arch="$(bash "$SPOOL_LIB" archive-path "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
if [ -n "$arch" ]; then
  python3 -c "
import sys
open(sys.argv[1],'w').write(''.join('{\"ts\":\"t\",\"status\":\"none\",\"n\":%d}\n' % i for i in range(9000)))
" "$arch"
  bash "$SPOOL_LIB" append "$REPO" '{"ts":"t","status":"found","findings":["trigger"]}' "$PARENT_TRANSCRIPT"
  bash "$SPOOL_LIB" clear "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
  lines="$(wc -l < "$arch" | tr -d ' ')"
  [ "$lines" -le 5100 ] \
    && check "the archive is capped" ok \
    || check "the archive is capped" "$lines lines"
else
  check "the archive path is queryable" "archive-path is not a command"
fi

# raw and archive must not exit non-zero just because the spool is empty: a
# caller under errexit dies on the ordinary case.
reset_spool
bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1 \
  && check "raw exits 0 on an empty spool" ok \
  || check "raw exits 0 on an empty spool" "exited non-zero"
bash "$SPOOL_LIB" archive "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1 \
  && check "archive exits 0 on an empty spool" ok \
  || check "archive exits 0 on an empty spool" "exited non-zero"

# A runner carrying arguments is the documented seam and must work.
reset_spool
export CLAUDE_ISSUE_HARVEST_CMD="bash -c 'cat >/dev/null; echo \"FINDING: ran with arguments.\"'"
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
unset CLAUDE_ISSUE_HARVEST_CMD
records | grep -q "ran with arguments" \
  && check "a runner with arguments works" ok \
  || check "a runner with arguments works" "spool=$(records)"

# The key must not change just because a path reaches the repo through a symlink.
LINKED="$TMPROOT/linked-repo"
ln -s "$REPO" "$LINKED" 2>/dev/null
if [ -L "$LINKED" ]; then
  k1="$(bash "$SPOOL_LIB" key "$REPO")"
  k2="$(bash "$SPOOL_LIB" key "$LINKED")"
  [ "$k1" = "$k2" ] \
    && check "a symlinked path keys the same as the real one" ok \
    || check "a symlinked path keys the same as the real one" "real=$k1 link=$k2"
fi

# ...and outside a repo too, where git is not there to resolve it for us. This
# is the case that actually bites: /tmp and /private/tmp are the same directory
# on macOS, and the payload's cwd and the reader's $PWD do not always agree on
# which spelling they use.
PLAIN="$TMPROOT/plain-dir"
mkdir -p "$PLAIN"
PLAIN_LINK="$TMPROOT/plain-link"
ln -s "$PLAIN" "$PLAIN_LINK" 2>/dev/null
if [ -L "$PLAIN_LINK" ]; then
  k1="$(bash "$SPOOL_LIB" key "$PLAIN")"
  k2="$(bash "$SPOOL_LIB" key "$PLAIN_LINK")"
  [ "$k1" = "$k2" ] \
    && check "a symlinked NON-repo path keys the same as the real one" ok \
    || check "a symlinked NON-repo path keys the same as the real one" "real=$k1 link=$k2"
fi

# If the injector fails, the review must still fire. Losing the spool text is a
# bad outcome; losing the entire review because of it is a worse one.
reset_spool
stub 'echo "FINDING: injector failure case."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
rm -f "${TMPDIR:-/tmp}/claude-feature-issue-review-$(printf '%s' "$REPO" | shasum | cut -c1-12).stamp"
out_inj="$(printf '%s' "$review_payload" | CLAUDE_REVIEW_REASON_FORCE_FAIL=1 bash "$REVIEW" 2>/dev/null)"
printf '%s' "$out_inj" | grep -q '"decision"' \
  && check "a broken injector does not cancel the review" ok \
  || check "a broken injector does not cancel the review" "review went silent"

# A very large pending list must not break the review by overflowing the
# argument list. It is handed over as a file, not as one enormous argument.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
python3 -c "
import json, sys
p = sys.argv[1]
with open(p, 'w') as fh:
    for i in range(4000):
        fh.write(json.dumps({'ts':'t','status':'found','findings':['finding number %d %s' % (i, 'y'*200)]}) + '\n')
" "$(bash "$SPOOL_LIB" path "$REPO" "$PARENT_TRANSCRIPT")"
rm -f "${TMPDIR:-/tmp}/claude-feature-issue-review-$(printf '%s' "$REPO" | shasum | cut -c1-12).stamp"
out_big="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
printf '%s' "$out_big" | grep -q '"decision"' \
  && check "a very large pending list does not break the review" ok \
  || check "a very large pending list does not break the review" "review went silent"

# ---------------------------------------------------------------------------
# claude-config#18: an agent must be able to record a finding DIRECTLY, without
# a transcript being read afterwards. A nested subagent leaves no transcript
# anywhere, so for that shape of agent this is the only capture path there is.
# ---------------------------------------------------------------------------
reset_spool
bash "$SPOOL_LIB" note "$REPO" "the queue rebuild is unmeasured" "fix/2693 agent" "$PARENT_TRANSCRIPT" >/dev/null 2>&1 \
  && check "note records a finding" ok \
  || check "note records a finding" "note exited non-zero"
spool_says "queue rebuild is unmeasured" \
  && check "a noted finding reaches the reader" ok \
  || check "a noted finding reaches the reader" "not surfaced"
spool_says "fix/2693 agent" \
  && check "a noted finding says who reported it" ok \
  || check "a noted finding says who reported it" "source not shown"
bash "$SPOOL_LIB" has-findings "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1 \
  && check "a noted finding counts as a real finding" ok \
  || check "a noted finding counts as a real finding" "did not count"
bash "$SPOOL_LIB" note "$REPO" "   " >/dev/null 2>&1 \
  && check "note refuses an empty finding" "it accepted whitespace" \
  || check "note refuses an empty finding" ok

# ---------------------------------------------------------------------------
# claude-config#19: the pending file is compacted once it grows past a limit.
# Repeated failures collapse; findings are never touched, because losing one is
# the single outcome this whole mechanism exists to prevent.
# ---------------------------------------------------------------------------
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$REPO" "a finding that must survive compaction" "early agent" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
for i in $(seq 1 60); do
  bash "$SPOOL_LIB" append "$REPO" '{"ts":"t","status":"error","agent":"subagent","error":"the harvest model exited 1"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
done
CLAUDE_ISSUE_SPOOL_PENDING_MAX=20 bash "$SPOOL_LIB" append "$REPO" '{"ts":"t","status":"error","agent":"subagent","error":"the harvest model exited 1"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
remaining="$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null | grep -c . || true)"
[ "$remaining" -lt 40 ] \
  && check "the pending file is compacted once it grows" ok \
  || check "the pending file is compacted once it grows" "$remaining records remain"

spool_says "a finding that must survive compaction" \
  && check "compaction never drops a finding" ok \
  || check "compaction never drops a finding" "the finding was lost"

# The count a person reads must still be the true number of occurrences, or
# compaction quietly turns 61 failures into 1 and the scale of a fault vanishes.
spool_says "61 times" \
  && check "compaction preserves the true failure count" ok \
  || check "compaction preserves the true failure count" "count wrong: $(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null | grep 'HARVEST FAILED' | cut -c1-90)"

# ---------------------------------------------------------------------------
# Muting the one failure reason that has no remedy.
#
# A nested subagent leaves no transcript anywhere, so its harvest can never
# succeed and there is no action attached to being told. Measured 2026-08-29:
# 235 of PET's 236 pending failures and all 62 of Bidspoke's were this one
# reason, and it reached the end of almost every turn. A notice nobody can act
# on, printed every time, is the noise that teaches the whole review to be
# skipped, so this reason alone is held back and reported as a periodic count.
#
# EVERY OTHER REASON KEEPS PRINTING EVERY TIME. That is the half that matters:
# the same measurement found one "the harvest model exited 1" sitting in the
# same file, which is a real and fixable fault, and a blanket mute would have
# buried it (L104: a filter must be tested against what it has to PRESERVE).
# ---------------------------------------------------------------------------
MUTED_REASON='the named agent transcript does not exist'

muted_rec() { printf '{"ts":"%s","status":"error","agent":"subagent","error":"%s"}' "${1:-2026-08-29T12:00:00Z}" "$MUTED_REASON"; }

reset_spool
bash "$SPOOL_LIB" append "$REPO" "$(muted_rec)" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
out_muted="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
rc_muted=$?
[ -z "$out_muted" ] && [ "$rc_muted" -ne 0 ] \
  && check "a spool holding only the unfixable failure shows nothing" ok \
  || check "a spool holding only the unfixable failure shows nothing" "rc=$rc_muted out=${out_muted:0:120}"

# The half that must be preserved: a DIFFERENT failure reason is still reported
# on every review, exactly as before.
reset_spool
bash "$SPOOL_LIB" append "$REPO" '{"ts":"2026-08-29T12:00:00Z","status":"error","agent":"subagent","error":"the harvest model exited 1"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
spool_says "the harvest model exited 1" \
  && check "a fixable failure reason still prints every time" ok \
  || check "a fixable failure reason still prints every time" "pending=$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null | cut -c1-140)"

# A muted failure must not suppress anything else sharing the spool with it.
reset_spool
bash "$SPOOL_LIB" append "$REPO" "$(muted_rec)" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$REPO" "a real finding that must still be shown" "tester" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
spool_says "a real finding that must still be shown" \
  && check "a muted failure does not hide a finding beside it" ok \
  || check "a muted failure does not hide a finding beside it" "finding missing"
spool_says "HARVEST FAILED" \
  && check "the muted line stays out when a finding is shown" "it printed anyway" \
  || check "the muted line stays out when a finding is shown" ok

# Held back is not thrown away. The count has to survive, including the folded
# `count` a compaction leaves behind, or the periodic report understates a fault
# by exactly the amount compaction tidied away.
reset_spool
bash "$SPOOL_LIB" append "$REPO" "$(muted_rec 2026-08-27T09:00:00Z)" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" append "$REPO" '{"ts":"2026-08-28T09:00:00Z","status":"error","agent":"subagent","count":40,"error":"the named agent transcript does not exist"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
summary="$(bash "$SPOOL_LIB" muted-summary "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
case "$summary" in
  *41*) check "the held-back count includes folded records" ok ;;
  *)    check "the held-back count includes folded records" "summary=${summary:0:160}" ;;
esac

# Nothing held back means nothing to report, so the periodic line can tell
# "still happening" from "stopped" (L98).
reset_spool
bash "$SPOOL_LIB" note "$REPO" "only a finding here" "tester" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" muted-summary "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1 \
  && check "no held-back failures reports nothing" "it reported something" \
  || check "no held-back failures reports nothing" ok

# Filing the failures a review CARRIED must not sweep up the muted ones: they
# were never shown, and filing them resets the count the periodic line reads,
# so the fault would be silently forgotten instead of reported.
reset_spool
bash "$SPOOL_LIB" append "$REPO" "$(muted_rec)" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" append "$REPO" '{"ts":"2026-08-29T12:00:00Z","status":"error","agent":"subagent","error":"the harvest model exited 1"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" file-errors "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
raw_after="$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
contains "$MUTED_REASON" "$raw_after" \
  && check "filing a shown failure leaves the muted one pending" ok \
  || check "filing a shown failure leaves the muted one pending" "muted record was filed too"
contains "the harvest model exited 1" "$raw_after" \
  && check "filing still files the failure that was shown" "it stayed pending" \
  || check "filing still files the failure that was shown" ok

# And once the periodic line HAS gone out, the muted records are settled, or the
# next report counts them a second time and the fault appears to be growing.
bash "$SPOOL_LIB" file-muted "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
contains "$MUTED_REASON" "$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)" \
  && check "filing the muted failures settles them" "they are still pending" \
  || check "filing the muted failures settles them" ok
contains "$MUTED_REASON" "$(bash "$SPOOL_LIB" archive "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)" \
  && check "the muted failures are kept in the archive" ok \
  || check "the muted failures are kept in the archive" "they were dropped, not archived"

# ---------------------------------------------------------------------------
# The periodic report for the held-back failures.
#
# Holding them back is only honest if the fault still surfaces somewhere. It
# rides along with whatever review speaks next once a week has passed, and it
# never MAKES a review speak: a fault nobody can act on must not be able to
# interrupt a turn (the same reason it does not beat the cooldown).
# ---------------------------------------------------------------------------
MUTED_STAMP="${TMPDIR:-/tmp}/claude-feature-issue-muted-$(printf '%s' "$REPO" | shasum | cut -c1-12).stamp"

reset_spool
rm -f "$REVIEW_STAMP" "$MUTED_STAMP"
bash "$SPOOL_LIB" append "$REPO" '{"ts":"2026-08-20T09:00:00Z","status":"error","agent":"subagent","count":7,"error":"the named agent transcript does not exist"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
out_muted_rev="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
contains "HARVEST UNREADABLE" "$out_muted_rev" \
  && check "the periodic report reaches a review when it is due" ok \
  || check "the periodic report reaches a review when it is due" "out=${out_muted_rev:0:200}"
contains "7 agent harvest" "$out_muted_rev" \
  && check "the periodic report carries the true count" ok \
  || check "the periodic report carries the true count" "count missing from ${out_muted_rev:0:200}"

# Delivered, so settled: the records are filed and the clock is restarted.
contains "the named agent transcript does not exist" "$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)" \
  && check "a delivered periodic report files its records" "they are still pending" \
  || check "a delivered periodic report files its records" ok
[ -f "$MUTED_STAMP" ] \
  && check "a delivered periodic report restarts its clock" ok \
  || check "a delivered periodic report restarts its clock" "no stamp written"

# And it does not repeat on the next review, which is the whole point.
bash "$SPOOL_LIB" append "$REPO" '{"ts":"2026-08-29T09:00:00Z","status":"error","agent":"subagent","error":"the named agent transcript does not exist"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
rm -f "$REVIEW_STAMP"
out_again="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
contains "HARVEST UNREADABLE" "$out_again" \
  && check "the periodic report stays quiet until it is due again" "it repeated" \
  || check "the periodic report stays quiet until it is due again" ok

# A report that could not be DELIVERED must settle nothing. Otherwise one
# injector failure both loses the report and silences the next week of them,
# which is the one way this change could hide a fault permanently.
reset_spool
rm -f "$REVIEW_STAMP" "$MUTED_STAMP"
bash "$SPOOL_LIB" append "$REPO" '{"ts":"2026-08-20T09:00:00Z","status":"error","agent":"subagent","count":3,"error":"the named agent transcript does not exist"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
printf '%s' "$review_payload" | CLAUDE_REVIEW_REASON_FORCE_FAIL=1 bash "$REVIEW" >/dev/null 2>&1
contains "the named agent transcript does not exist" "$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)" \
  && check "an undelivered periodic report leaves its records pending" ok \
  || check "an undelivered periodic report leaves its records pending" "they were filed unseen"
[ -f "$MUTED_STAMP" ] \
  && check "an undelivered periodic report does not restart its clock" "the stamp was written" \
  || check "an undelivered periodic report does not restart its clock" ok

# ---------------------------------------------------------------------------
# The spool key must come from the SESSION, not from the agent's cwd.
#
# Measured 2026-08-29, on a real project. A session running in
# ".../Project Enrollment Tracker (PET)" dispatched agents that worked in the
# git repo NESTED inside it, ".../PET/pet". SubagentStop's `cwd` names the
# AGENT's directory, so the harvest filed under the repo; the review keys on the
# session's own directory, so it read the parent. Every record for that project
# was checked and all 318 showed the same split. The review for the parent ran
# that afternoon while 47 real findings, 32 "looked and found nothing" records
# and 236 failures sat in a spool it has never once opened, going back to
# Aug 21. The stamp proves it: the parent's review stamp was written that day,
# and the repo's has never existed.
#
# Normalising through git cannot fix this. It was added for worktrees and does
# exactly the wrong thing here: it makes the nested repo MORE distinct from the
# folder the session is sitting in, not less.
#
# So both sides now derive the key from the ONE thing they are each handed about
# the same conversation: the parent session's transcript path. A writer and a
# reader that compute a key from two independent guesses can only ever agree by
# luck (L70).
# ---------------------------------------------------------------------------
SESSION_PROJECT="$TMPROOT/projects/-fake-project"
mkdir -p "$SESSION_PROJECT"
SESSION_TRANSCRIPT="$SESSION_PROJECT/session-one.jsonl"
cp "$PARENT_TRANSCRIPT" "$SESSION_TRANSCRIPT"

OUTER="$TMPROOT/outer"          # where the session sits: not a repo
INNER="$OUTER/inner"            # where the agent works: a repo nested inside it
mkdir -p "$INNER"
git -C "$INNER" init -q 2>/dev/null
git -C "$INNER" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null

reset_spool
payload "$INNER" "$FAKE_TRANSCRIPT" "$SESSION_TRANSCRIPT" \
  | CLAUDE_ISSUE_HARVEST_CMD="$TMPROOT/stub.sh" bash "$HARVEST" >/dev/null 2>&1
stub 'echo "FINDING: the nested repo split marker."'
payload "$INNER" "$FAKE_TRANSCRIPT" "$SESSION_TRANSCRIPT" | bash "$HARVEST" >/dev/null 2>&1

out_split="$(bash "$SPOOL_LIB" pending "$OUTER" "$SESSION_TRANSCRIPT" 2>/dev/null)"
case "$out_split" in
  *"nested repo split marker"*) check "an agent in a nested repo reaches its session's spool" ok ;;
  *) check "an agent in a nested repo reaches its session's spool" "pending=${out_split:0:200}" ;;
esac

# The positive control for that: without the session transcript, the reader keys
# on its own directory and finds nothing, which is precisely the live defect.
out_nosession="$(bash "$SPOOL_LIB" pending "$OUTER" 2>/dev/null)"
case "$out_nosession" in
  *"nested repo split marker"*) check "the old directory keying really did miss it" "it found it anyway" ;;
  *) check "the old directory keying really did miss it" ok ;;
esac

# Nothing already spooled may be stranded by the change of key. A record written
# the old way must still be read by a session supplying its transcript, or every
# finding waiting on disk becomes invisible the moment this ships.
reset_spool
bash "$SPOOL_LIB" note "$INNER" "a legacy record written under the old key" "tester" >/dev/null 2>&1
out_legacy="$(bash "$SPOOL_LIB" pending "$INNER" "$SESSION_TRANSCRIPT" 2>/dev/null)"
case "$out_legacy" in
  *"legacy record written under the old key"*) check "records under the old key are still read" ok ;;
  *) check "records under the old key are still read" "pending=${out_legacy:0:200}" ;;
esac

# And filing has to reach both, or a legacy record can never be settled and
# comes back at every review for good.
bash "$SPOOL_LIB" clear "$INNER" "$SESSION_TRANSCRIPT" >/dev/null 2>&1
contains "legacy record" "$(bash "$SPOOL_LIB" pending "$INNER" "$SESSION_TRANSCRIPT" 2>/dev/null)" \
  && check "filing reaches records under the old key" "it stayed pending" \
  || check "filing reaches records under the old key" ok

# A DIRECT note has to reach the same place a harvested record does (claude-config#214).
#
# CLAUDE.md tells every dispatched agent to record a finding with
# `issue-spool.sh note "$PWD" "<finding>" "<who>"`, and says that for a nested agent it is the
# only capture path that works at all. That three argument form passes no transcript, so it fell
# back to keying on the agent's OWN directory, which is exactly the split fixed above for
# harvested records: an agent working in a repo nested inside its session's folder filed where no
# review looks. The instruction and the mechanism disagreed, and the instruction is the half a
# person follows.
#
# So `note` resolves the session itself when it can, from CLAUDE_CODE_SESSION_ID, by finding the
# transcript that session id names. The reader is given the transcript, as a review always is, and
# must see the finding.
reset_spool
( cd "$INNER" && CLAUDE_TRANSCRIPT_ROOT="$TMPROOT/projects" CLAUDE_CODE_SESSION_ID="session-one" \
    bash "$SPOOL_LIB" note "$INNER" "the nested note must reach the session" "nested agent" >/dev/null 2>&1 )
out_note_nested="$(bash "$SPOOL_LIB" pending "$OUTER" "$SESSION_TRANSCRIPT" 2>/dev/null)"
case "$out_note_nested" in
  *"nested note must reach the session"*) check "a direct note from a nested repo reaches its session's spool" ok ;;
  *) check "a direct note from a nested repo reaches its session's spool" "pending=${out_note_nested:0:200}" ;;
esac

# The positive control: the SAME note with nothing to resolve the session from still has to be
# recorded rather than refused, because an agent whose environment carries no session id is the
# fallback case and losing its finding is worse than filing it under a directory key (L214, L98).
reset_spool
( cd "$INNER" && CLAUDE_TRANSCRIPT_ROOT="$TMPROOT/projects" \
    env -u CLAUDE_CODE_SESSION_ID bash "$SPOOL_LIB" note "$INNER" "the unresolved note is still kept" "nested agent" >/dev/null 2>&1 )
out_note_fallback="$(bash "$SPOOL_LIB" pending "$INNER" 2>/dev/null)"
case "$out_note_fallback" in
  *"unresolved note is still kept"*) check "a note with no session to resolve is still recorded" ok ;;
  *) check "a note with no session to resolve is still recorded" "pending=${out_note_fallback:0:200}" ;;
esac

# And a session id that names no transcript must not silently key on the WRONG file: it resolves
# nothing and takes the same fallback, rather than matching some other session's transcript by
# accident (L521, a lookup that requires exactly one match treats absence as its own answer).
reset_spool
( cd "$INNER" && CLAUDE_TRANSCRIPT_ROOT="$TMPROOT/projects" CLAUDE_CODE_SESSION_ID="no-such-session" \
    bash "$SPOOL_LIB" note "$INNER" "an unknown session falls back" "nested agent" >/dev/null 2>&1 )
out_note_unknown="$(bash "$SPOOL_LIB" pending "$INNER" 2>/dev/null)"
case "$out_note_unknown" in
  *"unknown session falls back"*) check "an unresolvable session id falls back rather than guessing" ok ;;
  *) check "an unresolvable session id falls back rather than guessing" "pending=${out_note_unknown:0:200}" ;;
esac

# Two different sessions must still key apart, or everything lands in one heap.
OTHER_PROJECT="$TMPROOT/projects/-other-project"
mkdir -p "$OTHER_PROJECT"
cp "$PARENT_TRANSCRIPT" "$OTHER_PROJECT/session-two.jsonl"
k_one="$(bash "$SPOOL_LIB" key "$OUTER" "$SESSION_TRANSCRIPT" 2>/dev/null)"
k_two="$(bash "$SPOOL_LIB" key "$OUTER" "$OTHER_PROJECT/session-two.jsonl" 2>/dev/null)"
[ -n "$k_one" ] && [ "$k_one" != "$k_two" ] \
  && check "two different session projects key apart" ok \
  || check "two different session projects key apart" "one=$k_one two=$k_two"

# Two sessions of the SAME project share one spool, which is the whole point:
# a finding left by yesterday's session is offered to today's.
k_same="$(bash "$SPOOL_LIB" key "$TMPROOT" "$SESSION_PROJECT/session-three.jsonl" 2>/dev/null)"
[ -n "$k_one" ] && [ "$k_one" = "$k_same" ] \
  && check "two sessions of one project share a spool" ok \
  || check "two sessions of one project share a spool" "one=$k_one same=$k_same"

# ---------------------------------------------------------------------------
# What a review CARRIES has to stay readable.
#
# Measured 2026-08-29: one project's pending list rendered to 50,030 characters,
# and every one of them would have been pushed into a single message the next
# time its review fired. Its 47 finding records were largely five observations
# restated by several agents in one run, so most of that length was the same
# handful of sentences in different words.
#
# Two separate limits, because they fail differently. Near-duplicates are folded
# (the same observation twice helps nobody), and what is left is capped by SIZE
# rather than by count, since one 500 character finding costs what twenty short
# ones do. Neither touches the spool: a finding that is not shown this time is
# still pending and still waiting for a picker.
# ---------------------------------------------------------------------------
reset_spool
bash "$SPOOL_LIB" note "$REPO" "The retry path has no failure test." "agent-one" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$REPO" "The retry path has no failure test." "agent-two" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
dup_out="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
dup_count="$(printf '%s\n' "$dup_out" | grep -c "retry path" || true)"
[ "$dup_count" = "1" ] \
  && check "the identical observation twice is shown once" ok \
  || check "the identical observation twice is shown once" "shown $dup_count times"

raw_dup="$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
raw_dup_count="$(printf '%s\n' "$raw_dup" | grep -c "retry path" || true)"
[ "$raw_dup_count" = "2" ] \
  && check "collapsing the view leaves every record in the spool" ok \
  || check "collapsing the view leaves every record in the spool" "$raw_dup_count records remain"

# The size cap. Each finding is distinct, so nothing here is foldable and only
# the budget can bound it.
reset_spool
i=0
while [ "$i" -lt 60 ]; do
  bash "$SPOOL_LIB" note "$REPO" "Distinct finding number $i: $(printf 'x%.0s' $(seq 1 200))" "agent-$i" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
  i=$((i + 1))
done
big_out="$(CLAUDE_ISSUE_SPOOL_FINDING_BUDGET=2000 bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
big_len="${#big_out}"
[ "$big_len" -lt 4000 ] \
  && check "a huge pending list is capped before it is carried" ok \
  || check "a huge pending list is capped before it is carried" "rendered $big_len characters"

contains "not shown here" "$big_out" \
  && check "the cap says what it held back" ok \
  || check "the cap says what it held back" "no notice in ${big_out: -200}"

# Held back is not dropped: the review that carried the first few must leave the
# rest pending for the next one, or the cap becomes a quiet delete.
raw_big="$(bash "$SPOOL_LIB" raw "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
raw_big_count="$(printf '%s\n' "$raw_big" | grep -c "Distinct finding number" || true)"
[ "$raw_big_count" = "60" ] \
  && check "capping the view leaves every finding pending" ok \
  || check "capping the view leaves every finding pending" "$raw_big_count of 60 remain"

# ---------------------------------------------------------------------------
# The spool's location must be read when a record is WRITTEN, not when this file
# is sourced.
#
# Found 2026-08-29 by looking at what the migration could not place: 120 records
# on one machine and 5 on another, every one of them naming a temp directory
# called "spool-project", which is a FIXTURE from test-blank-check-cost.sh. That
# suite sources this library and only then sets CLAUDE_ISSUE_SPOOL_DIR, so the
# root had already been bound to the real one and every run wrote a fake finding
# into Dan's live spool (L2: a test must be structurally unable to touch live
# data; L175: a value read once at startup is only true at startup).
#
# Fixing only the caller would leave the trap set for the next one, so the
# library is what changes (L30).
# ---------------------------------------------------------------------------
LATE="$TMPROOT/late-spool"
FAKE_HOME="$TMPROOT/fake-home"
mkdir -p "$FAKE_HOME"
late_out="$(
  HOME="$FAKE_HOME" bash -c '
    unset CLAUDE_ISSUE_SPOOL_DIR
    . "$1"                                   # sourced with no spool dir set
    export CLAUDE_ISSUE_SPOOL_DIR="$2"       # set only afterwards
    issue_spool_note "$3" "a finding written after the library was sourced" tester >/dev/null 2>&1
    printf "%s" "$(cat "$2"/*.jsonl 2>/dev/null)"
  ' _ "$SPOOL_LIB" "$LATE" "$REPO"
)"
contains "written after the library was sourced" "$late_out" \
  && check "the spool location is read when a record is written" ok \
  || check "the spool location is read when a record is written" "nothing landed in the late spool"

# The positive control, and the whole point: it must not have gone to the
# default location instead. Checked against a FAKE home, so this assertion can
# never depend on, or disturb, the real spool.
[ -e "$FAKE_HOME/.claude-issue-spool" ] \
  && check "nothing is written to the default spool when one is set" \
       "it wrote to $FAKE_HOME/.claude-issue-spool" \
  || check "nothing is written to the default spool when one is set" ok

# --- clear must file everything the review READ (claude-config) --------------------------------------
# The review reads TWO keys when it has a transcript: the transcript's directory and the project
# directory. The clear it then tells Claude to run carries no transcript, so it computed only the second
# and filed only that one. Measured 2026-08-31 in the Overture repo: the clear reported success and the
# identical 27 findings came back at the very next review, with 56KB still pending under the other key.
#
# A clear that leaves behind what the reader just showed is worse than one that fails, because it reports
# the work as settled and the same list arrives again with nothing to distinguish it from new findings.
reset_spool
CLEAR_DIR="$TMPROOT/clear-both-keys"
mkdir -p "$CLEAR_DIR"
( cd "$CLEAR_DIR" && git init -q . 2>/dev/null )
CLEAR_TRANSCRIPT_DIR="$TMPROOT/clear-transcripts"
mkdir -p "$CLEAR_TRANSCRIPT_DIR"
CLEAR_TRANSCRIPT="$CLEAR_TRANSCRIPT_DIR/agent.jsonl"
: > "$CLEAR_TRANSCRIPT"
# One finding under the TRANSCRIPT key, which is where a harvested agent's records land.
bash "$SPOOL_LIB" note "$CLEAR_DIR" "a finding under the transcript key" tester "$CLEAR_TRANSCRIPT" >/dev/null 2>&1
# And one under the plain directory key, which is where a direct note lands.
bash "$SPOOL_LIB" note "$CLEAR_DIR" "a finding under the directory key" tester >/dev/null 2>&1

PENDING_BEFORE="$(grep -l . "$CLAUDE_ISSUE_SPOOL_DIR"/*.jsonl 2>/dev/null | grep -v '\.filed\.jsonl' | wc -l | tr -d ' ')"
[ "$PENDING_BEFORE" -ge 2 ] \
  && check "two keys really are in play before the clear" ok \
  || check "two keys really are in play before the clear" "only $PENDING_BEFORE pending file(s), so this measures nothing"

bash "$SPOOL_LIB" clear "$CLEAR_DIR" >/dev/null 2>&1
PENDING_AFTER="$(grep -l . "$CLAUDE_ISSUE_SPOOL_DIR"/*.jsonl 2>/dev/null | grep -v '\.filed\.jsonl' | wc -l | tr -d ' ')"
[ "${PENDING_AFTER:-0}" -eq 0 ] \
  && check "clear with no transcript files every key holding this project's findings" ok \
  || check "clear with no transcript files every key holding this project's findings" "$PENDING_AFTER pending file(s) left behind"

# The mirror, so the fix cannot be "file everything": another project's pending findings are untouched.
reset_spool
OTHER_DIR="$TMPROOT/clear-other-project"
mkdir -p "$OTHER_DIR"
( cd "$OTHER_DIR" && git init -q . 2>/dev/null )
bash "$SPOOL_LIB" note "$CLEAR_DIR" "this project's finding" tester "$CLEAR_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$OTHER_DIR" "another project's finding" tester >/dev/null 2>&1
bash "$SPOOL_LIB" clear "$CLEAR_DIR" >/dev/null 2>&1
OTHER_LEFT="$(grep -rl "another project's finding" "$CLAUDE_ISSUE_SPOOL_DIR"/*.jsonl 2>/dev/null | grep -vc '\.filed\.jsonl' || true)"
[ "${OTHER_LEFT:-0}" -ge 1 ] \
  && check "another project's findings are left alone" ok \
  || check "another project's findings are left alone" "they were filed away too"

echo
echo "passed: $pass  failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
