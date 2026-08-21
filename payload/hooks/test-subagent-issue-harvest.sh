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

records() { bash "$SPOOL_LIB" raw "$REPO" 2>/dev/null; }
reset_spool() { rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; }

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
lines="$(bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null | grep -c "HARVEST FAILED" || true)"
[ "$lines" = "1" ] \
  && check "one repeated failure is reported once, not once per occurrence" ok \
  || check "one repeated failure is reported once, not once per occurrence" "printed $lines lines"

# Two DIFFERENT failures are still two, or deduping would hide a second fault.
reset_spool
stub 'exit 7'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
payload "$REPO" OMIT | bash "$HARVEST" >/dev/null 2>&1
lines="$(bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null | grep -c "HARVEST FAILED" || true)"
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
bash "$SPOOL_LIB" clear "$REPO" >/dev/null 2>&1
unset CLAUDE_ISSUE_SPOOL_MIDCLEAR

still_pending="$(bash "$SPOOL_LIB" raw "$REPO" 2>/dev/null)"
archived="$(bash "$SPOOL_LIB" archive "$REPO" 2>/dev/null)"
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

pending="$(bash "$SPOOL_LIB" pending "$REPO" 2>&1)"
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
pending_again="$(bash "$SPOOL_LIB" pending "$REPO" 2>&1)"
printf '%s' "$pending_again" | grep -q "queue rebuild is not measured" \
  && check "reading pending does not consume it" ok \
  || check "reading pending does not consume it" "out=$pending_again"

bash "$SPOOL_LIB" clear "$REPO" >/dev/null 2>&1
bash "$SPOOL_LIB" pending "$REPO" >/dev/null 2>&1
[ $? -ne 0 ] \
  && check "clear empties pending" ok \
  || check "clear empties pending" "pending survived clear"

archive="$(bash "$SPOOL_LIB" archive "$REPO" 2>/dev/null)"
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
printf '%s' "$out" | grep -q "spool injection marker seven" \
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
printf '%s' "$out_err_cold" | grep -q "HARVEST FAILED" \
  && check "a failure is still reported at the next ordinary review" ok \
  || check "a failure is still reported at the next ordinary review" "not mentioned"

# With the spool empty, the cooldown must still hold, or the review fires every turn.
bash "$SPOOL_LIB" clear "$REPO" >/dev/null 2>&1
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
bash "$SPOOL_LIB" note "$REPO" "the retry path has no failure test" "nested-agent" >/dev/null 2>&1
rm -f "$REVIEW_STAMP"
out_settle="$(printf '%s' "$review_payload" | bash "$REVIEW" 2>/dev/null)"
# The positive control. Every "gone from pending" assertion below is satisfied by
# a review that never carried the record at all, so what was delivered is checked
# first, in the same fixture (L159).
printf '%s' "$out_settle" | grep -q "HARVEST FAILED" \
  && printf '%s' "$out_settle" | grep -q "retry path has no failure test" \
  && check "the review that settles a failure really carried it" ok \
  || check "the review that settles a failure really carried it" "out=${out_settle:0:200}"

# The instruction riding with it has to match what the code then does. It tells
# Claude to run `clear` after the picker is answered, and a failure is never in a
# picker, so without this line the reader is told to expect back a record that has
# already been filed (L32: a doc states a testable claim, and this one is delivered
# to the reader inside the same message).
printf '%s' "$out_settle" | grep -q "it will not come back" \
  && check "the delivered review says a failure will not come back" ok \
  || check "the delivered review says a failure will not come back" "out=${out_settle:0:200}"

pend_settle="$(bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null)"
printf '%s' "$pend_settle" | grep -q "HARVEST FAILED" \
  && check "a reported failure is not offered a second time" "still pending: ${pend_settle:0:200}" \
  || check "a reported failure is not offered a second time" ok
printf '%s' "$pend_settle" | grep -q "retry path has no failure test" \
  && check "a finding in the same spool is left pending" ok \
  || check "a finding in the same spool is left pending" "pending=${pend_settle:0:200}"
arch_settle="$(bash "$SPOOL_LIB" archive "$REPO" 2>/dev/null)"
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
out_nodel="$(printf '%s' "$review_payload" | CLAUDE_INJECT_SPOOL_FORCE_FAIL=1 bash "$REVIEW" 2>/dev/null)"
printf '%s' "$out_nodel" | grep -q "HARVEST FAILED" \
  && check "the undelivered review really left the failure out" "it carried it: ${out_nodel:0:200}" \
  || check "the undelivered review really left the failure out" ok
pend_nodel="$(bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null)"
printf '%s' "$pend_nodel" | grep -q "HARVEST FAILED" \
  && check "a failure nobody was shown stays pending" ok \
  || check "a failure nobody was shown stays pending" "pending=${pend_nodel:0:200}"

# An unreadable record is NOT an error record: nothing classified it, so filing it
# would settle something nobody has read (L11). It stays until a person files it.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
printf 'this is not a record at all\n' >> "$(bash "$SPOOL_LIB" path "$REPO")"
bash "$SPOOL_LIB" file-errors "$REPO" >/dev/null 2>&1
pend_corrupt="$(bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null)"
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
lost="$(cat "${TMPDIR:-/tmp}/claude-issue-spool-lost.jsonl" 2>/dev/null)"
printf '%s' "$lost" | grep -q "read-only spool" \
  && check "a record that cannot be written lands in the lost file" ok \
  || check "a record that cannot be written lands in the lost file" "lost=$lost"
rm -f "${TMPDIR:-/tmp}/claude-issue-spool-lost.jsonl"

# A hung model must not take the whole hook down with it and leave no trace.
reset_spool
stub 'sleep 30'
start=$SECONDS
payload "$REPO" | CLAUDE_ISSUE_HARVEST_TIMEOUT=2 bash "$HARVEST" >/dev/null 2>&1
elapsed=$((SECONDS - start))
got="$(records)"
[ "$elapsed" -lt 15 ] && printf '%s' "$got" | grep -q '"status": *"error"' \
  && check "a hung model is cut off and recorded" ok \
  || check "a hung model is cut off and recorded" "took ${elapsed}s spool=$got"

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
bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null | grep -q "COULD NOT BE READ" \
  && check "unparseable model output is reported to the reader" ok \
  || check "unparseable model output is reported to the reader" "not surfaced"

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
printf 'this is not json\n' >> "$(bash "$SPOOL_LIB" path "$REPO")"
bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null | grep -q "UNREADABLE SPOOL" \
  && check "a corrupt spool line is reported" ok \
  || check "a corrupt spool line is reported" "silently skipped"

# append must refuse anything that would break one record per line.
reset_spool
bash "$SPOOL_LIB" append "$REPO" 'not json at all' 2>/dev/null \
  && check "append refuses a non-JSON record" "it accepted it" \
  || check "append refuses a non-JSON record" ok
bash "$SPOOL_LIB" append "$REPO" '{"a":1}
{"b":2}' 2>/dev/null \
  && check "append refuses a multi-line record" "it accepted it" \
  || check "append refuses a multi-line record" ok

# The archive must not grow forever.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
arch="$(bash "$SPOOL_LIB" archive-path "$REPO" 2>/dev/null)"
if [ -n "$arch" ]; then
  python3 -c "
import sys
open(sys.argv[1],'w').write(''.join('{\"ts\":\"t\",\"status\":\"none\",\"n\":%d}\n' % i for i in range(9000)))
" "$arch"
  bash "$SPOOL_LIB" append "$REPO" '{"ts":"t","status":"found","findings":["trigger"]}'
  bash "$SPOOL_LIB" clear "$REPO" >/dev/null 2>&1
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
bash "$SPOOL_LIB" raw "$REPO" >/dev/null 2>&1 \
  && check "raw exits 0 on an empty spool" ok \
  || check "raw exits 0 on an empty spool" "exited non-zero"
bash "$SPOOL_LIB" archive "$REPO" >/dev/null 2>&1 \
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
out_inj="$(printf '%s' "$review_payload" | CLAUDE_INJECT_SPOOL_FORCE_FAIL=1 bash "$REVIEW" 2>/dev/null)"
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
" "$(bash "$SPOOL_LIB" path "$REPO")"
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
bash "$SPOOL_LIB" note "$REPO" "the queue rebuild is unmeasured" "fix/2693 agent" >/dev/null 2>&1 \
  && check "note records a finding" ok \
  || check "note records a finding" "note exited non-zero"
bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null | grep -q "queue rebuild is unmeasured" \
  && check "a noted finding reaches the reader" ok \
  || check "a noted finding reaches the reader" "not surfaced"
bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null | grep -q "fix/2693 agent" \
  && check "a noted finding says who reported it" ok \
  || check "a noted finding says who reported it" "source not shown"
bash "$SPOOL_LIB" has-findings "$REPO" >/dev/null 2>&1 \
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
bash "$SPOOL_LIB" note "$REPO" "a finding that must survive compaction" "early agent" >/dev/null 2>&1
for i in $(seq 1 60); do
  bash "$SPOOL_LIB" append "$REPO" '{"ts":"t","status":"error","agent":"subagent","error":"the named agent transcript does not exist"}' >/dev/null 2>&1
done
CLAUDE_ISSUE_SPOOL_PENDING_MAX=20 bash "$SPOOL_LIB" append "$REPO" '{"ts":"t","status":"error","agent":"subagent","error":"the named agent transcript does not exist"}' >/dev/null 2>&1
remaining="$(bash "$SPOOL_LIB" raw "$REPO" 2>/dev/null | grep -c . || true)"
[ "$remaining" -lt 40 ] \
  && check "the pending file is compacted once it grows" ok \
  || check "the pending file is compacted once it grows" "$remaining records remain"

bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null | grep -q "a finding that must survive compaction" \
  && check "compaction never drops a finding" ok \
  || check "compaction never drops a finding" "the finding was lost"

# The count a person reads must still be the true number of occurrences, or
# compaction quietly turns 61 failures into 1 and the scale of a fault vanishes.
bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null | grep -q "61 times" \
  && check "compaction preserves the true failure count" ok \
  || check "compaction preserves the true failure count" "count wrong: $(bash "$SPOOL_LIB" pending "$REPO" 2>/dev/null | grep 'HARVEST FAILED' | cut -c1-90)"

echo
echo "passed: $pass  failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
