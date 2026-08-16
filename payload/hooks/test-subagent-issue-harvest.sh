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
stub 'cat >/dev/null; echo "FINDING: EventPlace has no test for the empty case (EventPlace.swift)."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"found"' \
  && printf '%s' "$got" | grep -q 'EventPlace' \
  && check "a finding is spooled as found" ok \
  || check "a finding is spooled as found" "spool=$got"

# A harvest that finds NOTHING must still leave a record. Otherwise "looked and
# found nothing" and "never ran" are the same empty file (L98).
reset_spool
stub 'cat >/dev/null; echo NONE'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"none"' \
  && check "an empty harvest records that it looked" ok \
  || check "an empty harvest records that it looked" "spool=$got"

# A harvest that FAILED must say so in its own words, not borrow the empty one.
reset_spool
stub 'cat >/dev/null; echo "model unavailable" >&2; exit 7'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"error"' \
  && check "a failed harvest records an error, not none" ok \
  || check "a failed harvest records an error, not none" "spool=$got"

# A harvest whose model returns nothing at all is a failure too, not an empty answer.
reset_spool
stub 'cat >/dev/null; exit 0'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
printf '%s' "$got" | grep -q '"status": *"error"' \
  && check "a silent model is an error, not none" ok \
  || check "a silent model is an error, not none" "spool=$got"

# Recursion guard: the harvest runs a headless Claude, whose own subagents must
# not harvest in turn.
reset_spool
stub 'cat >/dev/null; echo "FINDING: should never be written."'
payload "$REPO" | CLAUDE_DETACHED_RUN=1 bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
[ -z "$got" ] \
  && check "a detached run does not harvest" ok \
  || check "a detached run does not harvest" "spool=$got"

# A missing transcript writes nothing rather than an error record: there was no
# agent to read, so there is nothing to report either way.
reset_spool
stub 'cat >/dev/null; echo NONE'
payload "$REPO" "$TMPROOT/does-not-exist.jsonl" | bash "$HARVEST" >/dev/null 2>&1
[ -z "$(records)" ] \
  && check "a missing transcript is skipped silently" ok \
  || check "a missing transcript is skipped silently" "spool=$(records)"

# ---------------------------------------------------------------------------
# pending / clear: what the review reads, and what filing removes.
# ---------------------------------------------------------------------------
reset_spool
stub 'cat >/dev/null; echo "FINDING: the queue rebuild is not measured."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
stub 'cat >/dev/null; echo NONE'
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
stub 'cat >/dev/null; echo "FINDING: spool injection marker seven."'
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

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
