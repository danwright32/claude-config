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
# The AMBIENT session is unset for the whole file. A record now carries the session that produced
# it, and a clear files only its own (claude-config#222), so a suite that inherited whichever
# session happened to be running it would attribute its fixtures to that session and every
# assertion about filing would depend on who typed the command (L504). Every case that means
# something by a session names it.
unset CLAUDE_CODE_SESSION_ID
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

# NAMED AFTER THE SESSION, because a real one is: SubagentStop fires in the parent session, so its
# payload's session_id and the basename of its transcript_path are the same string. A fixture where
# they differ made every clear file nothing once records started carrying their session
# (claude-config#222), which is the fixture being unrealistic rather than the rule being wrong.
PARENT_TRANSCRIPT="$TMPROOT/test-session.jsonl"
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

# ---------------------------------------------------------------------------
# The 12 hex characters a key is MADE of (claude-config#281).
#
# Measured on this Mac 2026-09-03: shasum costs 11.5ms a call against openssl's 5.2ms, because
# shasum is a perl script, and this library computes a key on nearly every operation. One run of
# this suite made 690 of them, about a quarter of its whole cost. The digest is taken with openssl
# where that works, and `cut` is gone with it.
#
# THE VALUE MUST NOT CHANGE BY A CHARACTER. A key is a FILENAME, so a different digest strands
# every record already pending under the old name with nothing left that could find it (L92). It is
# pinned three ways below: against a recorded constant, against shasum itself, which is the
# reference implementation and the fallback, and by proving the fast path is the one being taken,
# because an agreement test where both sides ran shasum agrees about nothing (L159, L3).
sha12(){ bash "$SPOOL_LIB" sha12 "$1" 2>/dev/null; }

[ "$(sha12 /some/path)" = "39359e3abc60" ] \
  && check "#281 the key digest is the value it has always been" ok \
  || check "#281 the key digest is the value it has always been" "got $(sha12 /some/path)"

sha_disagreed=""
for _sha_in in "/some/path" "/a path with spaces/x" "/tmp" "" "/opt/deep/nested/checkout"; do
  _sha_want="$(printf '%s' "$_sha_in" | shasum | cut -c1-12)"
  _sha_got="$(sha12 "$_sha_in")"
  [ "$_sha_got" = "$_sha_want" ] || sha_disagreed="$sha_disagreed [$_sha_in: $_sha_got vs $_sha_want]"
done
[ -z "$sha_disagreed" ] \
  && check "#281 and it agrees with shasum on every shape of input" ok \
  || check "#281 and it agrees with shasum on every shape of input" "$sha_disagreed"

# The fast path is LIVE, proved by a stub that answers differently from shasum: if the digest were
# quietly always falling back, this would return the shasum value and the agreement above would be
# proving nothing. Both output shapes are covered, because the two openssl builds a Mac can have
# print differently (Homebrew's prints "SHA1(stdin)= <hex>", the system LibreSSL prints bare hex).
FAKESSL="$TMPROOT/fakessl"
cat > "$FAKESSL" <<'FAKESSL_EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "SHA1(stdin)= aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd"
FAKESSL_EOF
chmod +x "$FAKESSL"
[ "$(CLAUDE_ISSUE_SPOOL_SHA="$FAKESSL" sha12 /some/path)" = "aaaaaaaaaaaa" ] \
  && check "#281 the openssl path is the one actually taken" ok \
  || check "#281 the openssl path is the one actually taken" "got $(CLAUDE_ISSUE_SPOOL_SHA="$FAKESSL" sha12 /some/path)"

FAKESSL_BARE="$TMPROOT/fakessl-bare"
cat > "$FAKESSL_BARE" <<'FAKESSL_EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "aaaaaaaaaaaabbbbbbbbbbbbccccccccccccdddd"
FAKESSL_EOF
chmod +x "$FAKESSL_BARE"
[ "$(CLAUDE_ISSUE_SPOOL_SHA="$FAKESSL_BARE" sha12 /some/path)" = "aaaaaaaaaaaa" ] \
  && check "#281 and a build that prints the bare hex is read too" ok \
  || check "#281 and a build that prints the bare hex is read too" "got $(CLAUDE_ISSUE_SPOOL_SHA="$FAKESSL_BARE" sha12 /some/path)"

# Every way the fast path can fail falls back to shasum and still produces the right key: a tool
# that is not installed, one that errors, and one that answers with something that is not a SHA-1.
# Falling back is correct and merely slower, which is exactly why it is silent and has to be tested
# (L289).
GOOD12="$(printf '%s' /some/path | shasum | cut -c1-12)"
JUNKSSL="$TMPROOT/junkssl"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "not a digest at all"\n' > "$JUNKSSL"; chmod +x "$JUNKSSL"
DEADSSL="$TMPROOT/deadssl"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 3\n' > "$DEADSSL"; chmod +x "$DEADSSL"
sha_fallback_bad=""
for _sha_tool in "$TMPROOT/not-installed-at-all" "$JUNKSSL" "$DEADSSL" ""; do
  _sha_got="$(CLAUDE_ISSUE_SPOOL_SHA="$_sha_tool" sha12 /some/path)"
  [ "$_sha_got" = "$GOOD12" ] || sha_fallback_bad="$sha_fallback_bad [${_sha_tool:-<none>}: $_sha_got]"
done
[ -z "$sha_fallback_bad" ] \
  && check "#281 and every way that path can fail falls back to the same key" ok \
  || check "#281 and every way that path can fail falls back to the same key" "$sha_fallback_bad"

# THE RATCHET, on the thing that was actually measured (claude-config#281). A saving that quietly
# stops happening looks exactly like one still working, because the fallback is correct and merely
# slower (L289). Counted in PROCESS LAUNCHES rather than in seconds, because elapsed time on this
# machine is set by whatever else is running on it and a threshold on it measures the machine
# (L224, L364).
#
# One `note` is the representative operation: it builds a record and appends it, which is every
# expensive step the library has. Measured 2026-09-03 it launches 2 python3, 2 openssl and 1 git,
# and nothing else. The ceiling is deliberately close to that: it is here to catch a shasum coming
# back, or a third python3, not to leave room for one.
#
# It was 3 when this was written, and went to 5 in claude-config#294, which stamps the project key
# on every record: that is one more digest and one git, resolved while the directory still exists.
# The ratchet is what made that cost visible on the way in rather than a month later, so the number
# is RAISED with its reason rather than quietly loosened, and the composition is asserted beside it
# so a swap back to the slow digest fails even though the count would not move.
FORKSHIM="$TMPROOT/forkshim"
FORKLOG="$TMPROOT/forkshim.log"
mkdir -p "$FORKSHIM"
for _fs_bin in shasum cut openssl python3 git; do
  _fs_real="$(command -v "$_fs_bin" 2>/dev/null || true)"
  [ -n "$_fs_real" ] || continue
  {
    printf '#!/bin/sh\n'
    printf 'echo %s >> "$FORKSHIM_LOG"\n' "$_fs_bin"
    printf 'exec %s "$@"\n' "$_fs_real"
  } > "$FORKSHIM/$_fs_bin"
  chmod +x "$FORKSHIM/$_fs_bin"
done
: > "$FORKLOG"
PATH="$FORKSHIM:$PATH" FORKSHIM_LOG="$FORKLOG" \
  bash "$SPOOL_LIB" note "$REPO" "a finding whose cost is being counted" tester "$PARENT_TRANSCRIPT" >/dev/null 2>&1
fork_total="$(grep -c . "$FORKLOG" 2>/dev/null || true)"
fork_seen="$(sort "$FORKLOG" 2>/dev/null | uniq -c | tr -s ' ' | tr '\n' ' ')"
# A count of ZERO would satisfy any ceiling, and it means the shim was never on the path rather
# than that the work got cheap (L98).
[ "${fork_total:-0}" -ge 1 ] \
  && check "#281 the fork counter really saw the work happen" ok \
  || check "#281 the fork counter really saw the work happen" "it counted nothing, so the shim was not used"
[ "${fork_total:-99}" -le 5 ] \
  && check "#281 one spooled note still costs at most five process launches" ok \
  || check "#281 one spooled note still costs at most five process launches" "$fork_total launches: $fork_seen"
# And specifically not the slow digest, which is the saving this protects.
case "$fork_seen" in
  *shasum*) check "#281 and it does not reach for shasum" "$fork_seen" ;;
  *)        check "#281 and it does not reach for shasum" ok ;;
esac

# And the key itself, which is what all of that exists to keep stable.
[ "$(bash "$SPOOL_LIB" key "$TMPROOT" 2>/dev/null)" = "$(printf '%s' "$(cd "$TMPROOT" && pwd -P)" | shasum | cut -c1-12)" ] \
  && check "#281 a directory key is still the digest of its resolved path" ok \
  || check "#281 a directory key is still the digest of its resolved path" "key=$(bash "$SPOOL_LIB" key "$TMPROOT" 2>/dev/null)"

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

# BULK FIXTURE RECORDS, written in one launch (claude-config#281).
#
# Three cases below needed 60, 60 and 40 records to exist before they could ask their question, and
# each made one launch of the spool library per record: 160 launches, each paying a bash, a python3
# and a digest to add one line to a file. That was about a fifth of this suite's whole cost, and
# none of the three cases is ABOUT the append path. They are about compaction, about the finding
# budget, and about how many findings a review is shown.
#
# So the bulk is written straight into the pending file, and the TEMPLATE is a line the LIBRARY
# itself just wrote: each case still makes at least one record through the real library first, and
# the copies are that record with one field varied. A fixture shaped by hand would be this file's
# idea of a record rather than the library's, and would go on passing after the real shape changed
# (L48, L52). The record that TRIGGERS the behaviour under test goes through the library too, so
# what is short circuited is only the filling.
pending_file() { bash "$SPOOL_LIB" path "${1:-$REPO}" "${2:-$PARENT_TRANSCRIPT}" 2>/dev/null; }
#
# THE LEVERS DELIBERATELY NOT PULLED, written down so the next speed pass does not rediscover them
# (L308). Measured 2026-09-03 with a counting shim on the whole suite, before and after:
# shasum 690 and cut 690 became openssl 509, python3 591 became 338, and the tracked launches went
# from 2495 to 1458. Alternating runs of the old and new file in the same session, so the machine's
# load hit both equally (L224): 39, 40, 40, 43 seconds against 26, 26, 28, 29.
#
# What is LEFT, and why:
#
#   python3, 338 launches at about 20ms each, is now the largest single cost by far. Most of them
#   are one per record written: issue_spool_note builds the record and issue_spool_append then
#   parses, stamps and re-dumps it, and both have to, because append validates whatever any caller
#   hands it and that contract is what keeps a bad line out of the spool. Merging them would put
#   the stamping rule in two places, which is the shape of L370, and it is not worth that.
#
#   The harvest reads its payload with SIX separate jq calls, one per field, about 1.8ms each. The
#   exact fix reads them in one launch, but a value carrying a newline would then be truncated,
#   and the forms that avoid that cost more complexity than the 10ms they save per subagent stop.
#
#   git, 305 launches, is issue_spool_key asking for the repository root. Memoising the key inside
#   one process would remove some, but a memo has to be keyed on a directory and a transcript path,
#   and any delimiter used to hold that in a shell string can appear in a path. A wrong key is a
#   record filed where nobody looks (L131, L215), and this is not a saving worth that risk.

bulk_dup() { # bulk_dup <pending-file> <n>   -> n more copies of the last record in it
  local f="$1" n="$2" last i=0
  last="$(tail -1 "$f" 2>/dev/null)"
  [ -n "$last" ] || return 1
  while [ "$i" -lt "$n" ]; do printf '%s\n' "$last" >> "$f"; i=$((i + 1)); done
  return 0
}

bulk_vary() { # bulk_vary <pending-file> <n> <finding text, with %d for the number>
  python3 - "$1" "$2" "$3" <<'PY_BULK'
import json, sys
path, n, tmpl = sys.argv[1], int(sys.argv[2]), sys.argv[3]
with open(path) as fh:
    lines = [ln for ln in fh if ln.strip()]
template = json.loads(lines[-1])
with open(path, "a") as fh:
    # Numbered from 1, because the record the LIBRARY wrote is number 0 and a copy repeating its
    # text would be folded together with it by the reader's own deduplication, leaving one finding
    # fewer than the case asked for.
    for i in range(1, n + 1):
        rec = dict(template)
        rec["findings"] = [tmpl % i]
        rec["agent"] = "agent-%d" % i
        fh.write(json.dumps(rec) + "\n")
PY_BULK
}

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
grep -q '"status": *"found"' <<< "$got" \
  && grep -q 'EventPlace' <<< "$got" \
  && check "a finding is spooled as found" ok \
  || check "a finding is spooled as found" "spool=$got"

# A harvest that finds NOTHING must still leave a record. Otherwise "looked and
# found nothing" and "never ran" are the same empty file (L98).
reset_spool
stub 'echo NONE'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
grep -q '"status": *"none"' <<< "$got" \
  && check "an empty harvest records that it looked" ok \
  || check "an empty harvest records that it looked" "spool=$got"

# A harvest that FAILED must say so in its own words, not borrow the empty one.
reset_spool
stub 'echo "model unavailable" >&2; exit 7'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
grep -q '"status": *"error"' <<< "$got" \
  && check "a failed harvest records an error, not none" ok \
  || check "a failed harvest records an error, not none" "spool=$got"

# A harvest whose model returns nothing at all is a failure too, not an empty answer.
reset_spool
stub 'exit 0'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
grep -q '"status": *"error"' <<< "$got" \
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
grep -q "EventPlace has no test" <<< "$sent" \
  && ! grep -q "PARENT_SESSION_MARKER" <<< "$sent" \
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
grep -q '"status": *"error"' <<< "$got" \
  && grep -q "named no agent_transcript_path" <<< "$got" \
  && ! grep -q "should never be reached" <<< "$got" \
  && check "no agent transcript is an error, never a fallback to the parent" ok \
  || check "no agent transcript is an error, never a fallback to the parent" "spool=$got"

# Belt and braces: if the two paths ever arrive equal, that is the parent again.
reset_spool
stub 'echo "FINDING: should never be reached."'
payload "$REPO" "$PARENT_TRANSCRIPT" "$PARENT_TRANSCRIPT" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
grep -q '"status": *"error"' <<< "$got" \
  && check "an agent path equal to the parent's is refused" ok \
  || check "an agent path equal to the parent's is refused" "spool=$got"

# A transcript that was named but is not there is an error, not silence: we were
# told where to look and it was not there, which is a fault worth seeing.
reset_spool
stub 'echo NONE'
payload "$REPO" "$TMPROOT/does-not-exist.jsonl" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
grep -q '"status": *"error"' <<< "$got" \
  && check "a named but missing transcript is an error" ok \
  || check "a named but missing transcript is an error" "spool=$got"

# Every record has to say what it read and who it read, or the next version of
# this defect is again only findable by hand.
reset_spool
stub 'echo "FINDING: something."'
payload "$REPO" | bash "$HARVEST" >/dev/null 2>&1
got="$(records)"
grep -q "$FAKE_TRANSCRIPT" <<< "$got" \
  && check "the record names the transcript it read" ok \
  || check "the record names the transcript it read" "spool=$got"
grep -q '"agent": *"Explore"' <<< "$got" \
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
grep -q '"status": *"error"' <<< "$got" \
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
grep -q '"status": *"none"' <<< "$got" \
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
grep -q "arrived-mid-clear" <<< "$still_pending" \
  && check "a finding arriving during filing is not eaten by it" ok \
  || check "a finding arriving during filing is not eaten by it" "pending=$still_pending"
grep -q "filed before the clear" <<< "$archived" \
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
grep -q "queue rebuild is not measured" <<< "$pending" \
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
grep -q "queue rebuild is not measured" <<< "$pending_again" \
  && check "reading pending does not consume it" ok \
  || check "reading pending does not consume it" "out=$pending_again"

bash "$SPOOL_LIB" clear "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
[ $? -ne 0 ] \
  && check "clear empties pending" ok \
  || check "clear empties pending" "pending survived clear"

archive="$(bash "$SPOOL_LIB" archive "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
grep -q "queue rebuild is not measured" <<< "$archive" \
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
grep -q '"decision"' <<< "$out_cold" \
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
grep -q "HARVEST FAILED" <<< "$pend_settle" \
  && check "a reported failure is not offered a second time" "still pending: ${pend_settle:0:200}" \
  || check "a reported failure is not offered a second time" ok
grep -q "retry path has no failure test" <<< "$pend_settle" \
  && check "a finding in the same spool is left pending" ok \
  || check "a finding in the same spool is left pending" "pending=${pend_settle:0:200}"
arch_settle="$(bash "$SPOOL_LIB" archive "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
grep -q '"status": *"error"' <<< "$arch_settle" \
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
grep -q "HARVEST FAILED" <<< "$out_nodel" \
  && check "the undelivered review really left the failure out" "it carried it: ${out_nodel:0:200}" \
  || check "the undelivered review really left the failure out" ok
pend_nodel="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
grep -q "HARVEST FAILED" <<< "$pend_nodel" \
  && check "a failure nobody was shown stays pending" ok \
  || check "a failure nobody was shown stays pending" "pending=${pend_nodel:0:200}"

# An unreadable record is NOT an error record: nothing classified it, so filing it
# would settle something nobody has read (L11). It stays until a person files it.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
printf 'this is not a record at all\n' >> "$(bash "$SPOOL_LIB" path "$REPO" "$PARENT_TRANSCRIPT")"
bash "$SPOOL_LIB" file-errors "$REPO" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
pend_corrupt="$(bash "$SPOOL_LIB" pending "$REPO" "$PARENT_TRANSCRIPT" 2>/dev/null)"
grep -q "UNREADABLE SPOOL RECORDS" <<< "$pend_corrupt" \
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
grep -q "spool library is missing" <<< "$lost" \
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
grep -q "read-only spool" <<< "$lost" \
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
[ "$elapsed" -le "$hang_max" ] && grep -q '"status": *"error"' <<< "$got" \
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
grep -q '"status": *"unparsed"' <<< "$got" \
  && grep -q "the parser is wrong" <<< "$got" \
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
grep -q '"decision"' <<< "$out_inj" \
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
grep -q '"decision"' <<< "$out_big" \
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
# One through the library, so the 59 copies below are copies of a record the library wrote, then
# the 61st through the library again, which is the one that trips compaction.
bash "$SPOOL_LIB" append "$REPO" '{"ts":"t","status":"error","agent":"subagent","error":"the harvest model exited 1"}' "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bulk_dup "$(pending_file)" 59 \
  || check "the compaction fixture was written" "the library wrote no record to copy"
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
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$REPO" "Distinct finding number 0: $(printf 'x%.0s' $(seq 1 200))" "agent-0" "$PARENT_TRANSCRIPT" >/dev/null 2>&1
bulk_vary "$(pending_file)" 59 "Distinct finding number %d: $(printf 'x%.0s' $(seq 1 200))"
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

# ---------------------------------------------------------------------------
# A spool a review cannot drain (claude-config#241).
# ---------------------------------------------------------------------------
# One spool was measured holding 219 pending findings, of which the review carried four and a line
# saying "and 215 more findings not shown here". The clear that follows the picker files ALL of
# them, so everything past the first few was archived unread, silently. The 8,000 character cap
# came from when the list went into the MESSAGE; since claude-config#243 it goes to a file the
# reader opens, so the reason for the small number went away and the number stayed.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
MANY_TRANSCRIPT="$TMPROOT/many-sess.jsonl"; : > "$MANY_TRANSCRIPT"
MANY_TEXT="about a subject long enough to cost a few hundred characters of budget, so that forty of them comfortably exceed the eight thousand the old cap allowed and the difference is visible"
bash "$SPOOL_LIB" note "$REPO" "finding number 0, $MANY_TEXT" tester "$MANY_TRANSCRIPT" >/dev/null 2>&1
bulk_vary "$(pending_file "$REPO" "$MANY_TRANSCRIPT")" 39 "finding number %d, $MANY_TEXT"
out_many="$(bash "$SPOOL_LIB" pending "$REPO" "$MANY_TRANSCRIPT" 2>/dev/null)"
_shown="$(grep -c '^FINDING' <<< "$out_many" || true)"
[ "${_shown:-0}" -ge 40 ] \
  && check "#241 a review is shown every pending finding, not the first few" ok \
  || check "#241 a review is shown every pending finding, not the first few" "only $_shown of 40 were shown"
# The old cap really would have cut it, or this measures nothing (L159).
out_capped="$(CLAUDE_ISSUE_SPOOL_FINDING_BUDGET=8000 bash "$SPOOL_LIB" pending "$REPO" "$MANY_TRANSCRIPT" 2>/dev/null)"
_capped="$(grep -c '^FINDING' <<< "$out_capped" || true)"
[ "${_capped:-0}" -lt 40 ] \
  && check "#241 and the old cap would have cut the same list short" ok \
  || check "#241 and the old cap would have cut the same list short" "it showed $_capped of 40 even at 8000"
# When something IS cut, the notice says what happens to the remainder, because the clear files
# them and a line saying they "stay in the spool until filed" reads as the opposite (L11).
case "$out_capped" in
  *"went unread"*) check "#241 and a truncated list says the rest are filed away unread" ok ;;
  *) check "#241 and a truncated list says the rest are filed away unread" "out=${out_capped: -300}" ;;
esac

# ---------------------------------------------------------------------------
# WHETHER A WRITTEN FINDING CAN BE READ BY ANYBODY (claude-config#242).
# ---------------------------------------------------------------------------
# A review opens exactly one key, the one derived from its own session's transcript directory, so a
# finding under a key no session resolves to is never offered to anyone: the harvest reports
# success, the review reports nothing to show, and both are telling the truth about different files
# (L98). Measured on 2026-08-31, the spool held 142 distinct keys and the records inside named
# about 42 working directories, and nothing anywhere reported whether any of it was reachable.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
REACH_ROOT="$TMPROOT/reach-projects"
mkdir -p "$REACH_ROOT/a-real-project"
REACH_TRANSCRIPT="$REACH_ROOT/a-real-project/sess.jsonl"; : > "$REACH_TRANSCRIPT"
bash "$SPOOL_LIB" note "$REPO" "a finding a session can reach" tester "$REACH_TRANSCRIPT" >/dev/null 2>&1
out_reach="$(CLAUDE_TRANSCRIPT_ROOT="$REACH_ROOT" bash "$SPOOL_LIB" reach-report 2>&1)"; reach_rc=$?
[ "$reach_rc" -eq 0 ] \
  && check "#242 a key a session resolves to is reported as reachable" ok \
  || check "#242 a key a session resolves to is reported as reachable" "exit=$reach_rc out=$out_reach"
case "$out_reach" in
  *"1 holding records"*) check "#242 and the count of keys holding records is stated" ok ;;
  *) check "#242 and the count of keys holding records is stated" "out=$out_reach" ;;
esac

# A finding written under a key nothing resolves to. Written by hand under a key of its own,
# because that is exactly the state the measurement found and there is no way to reach it through
# the library, which always keys on something real.
printf '{"ts":"2026-08-31T00:00:00Z","status":"found","agent":"a","cwd":"/gone","findings":["a finding nobody will ever be offered"]}\n' \
  > "$CLAUDE_ISSUE_SPOOL_DIR/deadbeefdead.jsonl"
out_un="$(CLAUDE_TRANSCRIPT_ROOT="$REACH_ROOT" bash "$SPOOL_LIB" reach-report 2>&1)"; un_rc=$?
[ "$un_rc" -ne 0 ] \
  && check "#242 a key no session resolves to fails the report" ok \
  || check "#242 a key no session resolves to fails the report" "exit=$un_rc out=$out_un"
case "$out_un" in
  *"deadbeefdead.jsonl (1 record(s))"*)
    check "#242 and the unreachable key is named with what it holds" ok ;;
  *)
    check "#242 and the unreachable key is named with what it holds" "out=$out_un" ;;
esac

# Reading NO transcript directory must not report every key as unreachable: that is a wall of false
# alarms built out of having measured nothing (L98, L36).
EMPTY_ROOT="$TMPROOT/reach-empty"; mkdir -p "$EMPTY_ROOT"
out_nodirs="$(CLAUDE_TRANSCRIPT_ROOT="$EMPTY_ROOT" bash "$SPOOL_LIB" reach-report 2>&1)"; nodirs_rc=$?
[ "$nodirs_rc" -ne 0 ] \
  && check "#242 no transcript directory at all is a refusal, not a verdict" ok \
  || check "#242 no transcript directory at all is a refusal, not a verdict" "exit=$nodirs_rc out=$out_nodirs"
case "$out_nodirs" in
  *"could not be worked out"*"Nothing is being reported as unreachable"*)
    check "#242 and it says it could not work out which keys are reachable" ok ;;
  *)
    check "#242 and it says it could not work out which keys are reachable" "out=$out_nodirs" ;;
esac

# The second question the measurement raised: on 2026-08-31, 131 of 157 files were ZERO BYTES. They are made by
# the filing path writing an empty keep set back with `cat >>`, which creates the file, so a spool
# holding 8 findings looks like it holds 139 keys.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
ZERO_TRANSCRIPT="$TMPROOT/zero-sess.jsonl"; : > "$ZERO_TRANSCRIPT"
printf '{"ts":"2026-09-02T00:00:00Z","status":"error","agent":"a","session":"zero-sess","cwd":"%s","error":"a failure with a remedy"}\n' "$REPO" \
  > "$(bash "$SPOOL_LIB" path "$REPO" "$ZERO_TRANSCRIPT")"
bash "$SPOOL_LIB" file-errors "$REPO" "$ZERO_TRANSCRIPT" >/dev/null 2>&1
ZERO_LEFT="$(ls -1 "$CLAUDE_ISSUE_SPOOL_DIR"/*.jsonl 2>/dev/null | grep -v '\.filed\.jsonl' | grep -c . || true)"
[ "${ZERO_LEFT:-0}" -eq 0 ] \
  && check "#242 filing everything leaves no empty pending file behind" ok \
  || check "#242 filing everything leaves no empty pending file behind" "$ZERO_LEFT pending file(s) left, sized: $(wc -c < "$(ls -1 "$CLAUDE_ISSUE_SPOOL_DIR"/*.jsonl 2>/dev/null | grep -v '\.filed\.jsonl' | awk 'NR<=1')" 2>/dev/null)"

# ---------------------------------------------------------------------------
# A clear files ITS OWN session's findings and leaves everybody else's (claude-config#222).
# ---------------------------------------------------------------------------
# The spool is keyed on the PROJECT, deliberately, so an agent in a worktree reaches the same spool
# as the session that reads it. Dan runs several sessions against one project at once, and that
# keying cannot tell them apart: whichever session's Stop hook fires first is handed EVERY session's
# findings and is then told to clear. Measured in one PostRoll session on 2026-08-29, four
# consecutive reviews were each handed the same 25 findings about work that session had never
# touched, and they had to be copied aside by hand every time or they would have been filed unseen.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
SESS_A="$TMPROOT/session-a.jsonl"; : > "$SESS_A"
SESS_B="$TMPROOT/session-b.jsonl"; : > "$SESS_B"
bash "$SPOOL_LIB" note "$REPO" "a finding session A must settle" tester "$SESS_A" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$REPO" "a finding session B has not seen yet" tester "$SESS_B" >/dev/null 2>&1
# Both are in play before anything is cleared, or the check below is satisfied by a spool that
# never held B's record at all (L159, L100).
pend_two="$(bash "$SPOOL_LIB" pending "$REPO" "$SESS_A" 2>/dev/null)"
case "$pend_two" in
  *"session A must settle"*) check "#222 both sessions' findings are pending to begin with" ok ;;
  *) check "#222 both sessions' findings are pending to begin with" "pending=${pend_two:0:200}" ;;
esac

# Read from B's point of view BEFORE anything is filed, while both findings are still pending.
pend_marked="$(bash "$SPOOL_LIB" pending "$REPO" "$SESS_B" 2>/dev/null)"
bash "$SPOOL_LIB" clear "$REPO" "$SESS_A" >/dev/null 2>&1
arch_a="$(bash "$SPOOL_LIB" archive "$REPO" "$SESS_A" 2>/dev/null)"
case "$arch_a" in
  *"session A must settle"*) check "#222 a clear files the calling session's own finding" ok ;;
  *) check "#222 a clear files the calling session's own finding" "archive=${arch_a:0:200}" ;;
esac
case "$arch_a" in
  *"session B has not seen yet"*)
    check "#222 and it does NOT file the other session's" "B's finding was filed by A's clear" ;;
  *)
    check "#222 and it does NOT file the other session's" ok ;;
esac
pend_b="$(bash "$SPOOL_LIB" pending "$REPO" "$SESS_B" 2>/dev/null)"
case "$pend_b" in
  *"session B has not seen yet"*)
    check "#222 and the other session's finding is still there for its own review" ok ;;
  *)
    check "#222 and the other session's finding is still there for its own review" "pending=${pend_b:0:200}" ;;
esac
# And B can then settle it, or the rule has moved the loss rather than removed it.
bash "$SPOOL_LIB" clear "$REPO" "$SESS_B" >/dev/null 2>&1
arch_b="$(bash "$SPOOL_LIB" archive "$REPO" "$SESS_B" 2>/dev/null)"
case "$arch_b" in
  *"session B has not seen yet"*) check "#222 and B's own clear settles it afterwards" ok ;;
  *) check "#222 and B's own clear settles it afterwards" "archive=${arch_b:0:200}" ;;
esac

# A review that is handed another session's finding SAYS so. It has no context for judging one it
# did not cause, and would either file it badly or drop it.
case "$pend_marked" in
  *"session A must settle"*"from another session working in this project"*)
    check "#222 a finding from another session is marked as one" ok ;;
  *)
    check "#222 a finding from another session is marked as one" "pending=${pend_marked:0:300}" ;;
esac
# And the reader's OWN finding is not, or the mark says nothing (L159).
case "$pend_marked" in
  *"session B has not seen yet"*"from another session"*)
    check "#222 and its own finding is not marked" "B's own finding was marked as somebody else's" ;;
  *)
    check "#222 and its own finding is not marked" ok ;;
esac

# ---------------------------------------------------------------------------
# A finding this session CANNOT settle is not shown to it for ever (claude-config#322).
# ---------------------------------------------------------------------------
# The two rules above collide. A clear files only the calling session's records (#222), which is
# right, and a review shows another session's so they are not dropped, which is also right.
# Together they mean the reviewing session is handed findings it can never settle, at every
# review, for as long as the owning session does not run its own, and a session that has ended
# never will. Seen in Slate on 2026-09-07: the same five findings at two consecutive reviews, the
# documented clear line run verbatim twice, and both times "nothing was pending under the key(s)
# this project reads, so nothing was filed", whose advice is to run the line that was just run.
#
# So a clear MARKS the records it had to leave as seen by this session. They are not filed, not
# moved, and not changed for the session that owns them: they simply stop being re-rendered to a
# reader who has already been shown them and has answered the picker.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
SEEN_A="$TMPROOT/seen-a.jsonl"; : > "$SEEN_A"
SEEN_B="$TMPROOT/seen-b.jsonl"; : > "$SEEN_B"
bash "$SPOOL_LIB" note "$REPO" "a finding owned by seen-session A" tester "$SEEN_A" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$REPO" "a finding owned by seen-session B" tester "$SEEN_B" >/dev/null 2>&1
# Both reach A's first review, or everything below is satisfied by a spool that never held B's
# record (L159).
seen_first="$(bash "$SPOOL_LIB" pending "$REPO" "$SEEN_A" 2>/dev/null)"
case "$seen_first" in
  *"owned by seen-session B"*) check "#322 the other session's finding reaches the first review" ok ;;
  *) check "#322 the other session's finding reaches the first review" "pending=${seen_first:0:300}" ;;
esac
seen_clear1="$(bash "$SPOOL_LIB" clear "$REPO" "$SEEN_A" 2>&1)"
seen_second="$(bash "$SPOOL_LIB" pending "$REPO" "$SEEN_A" 2>/dev/null)"
case "$seen_second" in
  *"owned by seen-session B"*)
    check "#322 and does not come back at this session's next review" "pending=${seen_second:0:300}" ;;
  *) check "#322 and does not come back at this session's next review" ok ;;
esac
# The exact sequence the issue reports: the reader runs the documented clear line a SECOND time,
# with nothing of its own left and somebody else's records still under the key. That used to answer
# "nothing was pending under the key(s) this project reads, so nothing was filed" and advise
# running the line the findings file names, which is the line that had just been run: a remedy that
# cannot change the state it names (L111).
seen_clear2="$(bash "$SPOOL_LIB" clear "$REPO" "$SEEN_A" 2>&1)"
case "$seen_clear2" in
  *"nothing of THIS session's was pending"*"belong to other sessions"*)
    check "#322 a second clear says whose records are actually under the key" ok ;;
  *) check "#322 a second clear says whose records are actually under the key" "said=${seen_clear2:0:500}" ;;
esac
case "$seen_clear2" in
  *"run the line the findings file names"*)
    check "#322 and does not send the reader back to the command they just ran" "said=${seen_clear2:0:500}" ;;
  *) check "#322 and does not send the reader back to the command they just ran" ok ;;
esac
# The empty-key message must not ALSO be printed: two sentences, one saying nothing was pending and
# one saying whose it is, read as a contradiction over the same key (L11).
case "$seen_clear2" in
  *"nothing was pending under the key(s) this project reads"*)
    check "#322 and does not also claim the key is empty" "said=${seen_clear2:0:500}" ;;
  *) check "#322 and does not also claim the key is empty" ok ;;
esac

# The whole point of leaving it: its OWN session must still be offered it. Marking it seen by one
# reader that could not judge it must not take it away from the reader that can (L116).
seen_owner="$(bash "$SPOOL_LIB" pending "$REPO" "$SEEN_B" 2>/dev/null)"
case "$seen_owner" in
  *"owned by seen-session B"*) check "#322 while its own session is still offered it" ok ;;
  *) check "#322 while its own session is still offered it" "pending=${seen_owner:0:300}" ;;
esac
# And it can still be settled there, or this has moved the loss rather than removed it.
bash "$SPOOL_LIB" clear "$REPO" "$SEEN_B" >/dev/null 2>&1
seen_arch="$(bash "$SPOOL_LIB" archive "$REPO" "$SEEN_B" 2>/dev/null)"
case "$seen_arch" in
  *"owned by seen-session B"*) check "#322 and its own session can still file it" ok ;;
  *) check "#322 and its own session can still file it" "archive=${seen_arch:0:300}" ;;
esac

# The message. "nothing was pending under this key" and "records are pending under this key but
# belong to another session" had the same words, and the advice given for the second was to run
# the line that had just been run (L11).
case "$seen_clear1" in
  *"other sessions"*"not yours to settle"*)
    check "#322 the clear says the records it left belong to other sessions" ok ;;
  *) check "#322 the clear says the records it left belong to other sessions" "said=${seen_clear1:0:400}" ;;
esac
# It says HOW MANY, so the sentence is a measurement rather than a standing warning that reads the
# same whether one record was left or forty (L11).
case "$seen_clear1" in
  *"left 1 record(s)"*) check "#322 and how many it left" ok ;;
  *) check "#322 and how many it left" "said=${seen_clear1:0:400}" ;;
esac
case "$seen_clear1" in
  *"run the line the findings file names"*)
    check "#322 and does not answer with the step that was just taken" "said=${seen_clear1:0:400}" ;;
  *) check "#322 and does not answer with the step that was just taken" ok ;;
esac

# ---------------------------------------------------------------------------
# A finding NOBODY EVER CLAIMS does not sit here for ever (claude-config#326).
# ---------------------------------------------------------------------------
# claude-config#322 stopped an unsettleable finding being re-rendered at every review by marking it
# as seen by the reader it was shown to. That silences the repeat but does not settle the record: a
# clear files only the calling session's, so a finding produced by a session that has since ended
# belongs to nobody and nothing would ever file it. Counted and visible, but unfileable, is where
# the previous defect started.
#
# So ownership EXPIRES. Past a window a record is treated exactly like one that names no session at
# all: shown to whoever is reviewing, and filed by whoever clears. The alternative, filing it away
# unread, empties the spool while losing the finding, which is the worse of the two.
#
# The fixture's age is DERIVED from the window rather than written as a literal, because the third
# party to that relationship is a constant somebody can change, and a literal chosen to sit past
# today's window silently stands for a different case the day it moves (L401, L130).
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
OLD_A="$TMPROOT/old-a.jsonl"; : > "$OLD_A"
OLD_B="$TMPROOT/old-b.jsonl"; : > "$OLD_B"
CLAIM_WINDOW="${CLAUDE_ISSUE_SPOOL_CLAIM_AFTER:-604800}"
old_ts="$(python3 -c 'import sys,datetime; w=int(sys.argv[1]); print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=w + 86400)).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$CLAIM_WINDOW")"
new_ts="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
SPOOL_FILE="$(bash "$SPOOL_LIB" path "$REPO" "$OLD_A")"
{
  printf '{"ts":"%s","status":"found","agent":"tester","cwd":"%s","findings":["a finding nobody has claimed since before the window"],"session":"old-b","seen_by":["old-a"]}\n' "$old_ts" "$REPO"
  printf '{"ts":"%s","status":"found","agent":"tester","cwd":"%s","findings":["a finding still inside the window"],"session":"old-b","seen_by":["old-a"]}\n' "$new_ts" "$REPO"
} > "$SPOOL_FILE"
pend_old="$(bash "$SPOOL_LIB" pending "$REPO" "$OLD_A" 2>/dev/null)"
case "$pend_old" in
  *"nobody has claimed since before the window"*)
    check "#326 a finding older than the window is shown again, marked seen or not" ok ;;
  *) check "#326 a finding older than the window is shown again, marked seen or not" "pending=${pend_old:0:400}" ;;
esac
# The control, in the same fixture: one that is still inside the window and marked seen stays
# hidden, or this passes for a rule about age that is really a rule about nothing (L159).
case "$pend_old" in
  *"still inside the window"*)
    check "#326 while one inside the window stays settled for this reader" "the recent one came back too" ;;
  *) check "#326 while one inside the window stays settled for this reader" ok ;;
esac
# And this session can now FILE the expired one, which is the whole point: shown but unfileable is
# the state being fixed, not a new spelling of it.
bash "$SPOOL_LIB" clear "$REPO" "$OLD_A" >/dev/null 2>&1
arch_old="$(bash "$SPOOL_LIB" archive "$REPO" "$OLD_A" 2>/dev/null)"
case "$arch_old" in
  *"nobody has claimed since before the window"*)
    check "#326 and a clear from any session files it once ownership has expired" ok ;;
  *) check "#326 and a clear from any session files it once ownership has expired" "archive=${arch_old:0:400}" ;;
esac
case "$arch_old" in
  *"still inside the window"*)
    check "#326 and the one inside the window is still left for its own session" "it was filed by the wrong session" ;;
  *) check "#326 and the one inside the window is still left for its own session" ok ;;
esac

# A record with NO session cannot be claimed by anybody, so it is filed by whoever clears first,
# which is what every record did before this existed. Leaving it pending for ever would be a worse
# failure than the one being fixed (L526).
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$REPO" "a finding no session claims" tester >/dev/null 2>&1
bash "$SPOOL_LIB" clear "$REPO" "$SESS_A" >/dev/null 2>&1
# Read WITHOUT the transcript, because a note that named none landed under the plain directory key
# and that is the archive it goes to. Reading the transcript key here would report an empty archive
# and be indistinguishable from a record that was never filed (L11).
arch_u="$(bash "$SPOOL_LIB" archive "$REPO" 2>/dev/null)"
case "$arch_u" in
  *"no session claims"*) check "#222 a finding belonging to no session is still filed" ok ;;
  *) check "#222 a finding belonging to no session is still filed" "archive=${arch_u:0:200}" ;;
esac

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

# ---- a clear says what it filed, and a review says what it read (claude-config#260) ----
# Measured on project-enrollment-tracker, 2026-09-01: a clear was run exactly as CLAUDE.md
# instructs, it exited 0, the pending file was gone afterwards, and the review fired again later
# in the same session naming the same 49 findings from a file rebuilt at that moment. The archive
# for that key had not been written to since 21 August. Three explanations fit those facts and
# nothing anywhere distinguished them, because `clear` printed nothing at all and the review never
# said which files it read.
#
# So neither of them is silent any more. This does not itself decide which explanation was right;
# it makes the next occurrence answerable instead of arguable (L11, L98).
reset_spool
REP_DIR="$TMPROOT/report-clear"; mkdir -p "$REP_DIR"
( cd "$REP_DIR" && git init -q . 2>/dev/null )
REP_TDIR="$TMPROOT/report-clear-transcript"; mkdir -p "$REP_TDIR"
REP_TRANSCRIPT="$REP_TDIR/agent.jsonl"; : > "$REP_TRANSCRIPT"

# Nothing pending. "It worked" and "it matched nothing" are the two answers that used to look
# identical at the call site, and telling them apart is the whole of this.
REP_EMPTY="$(bash "$SPOOL_LIB" clear "$REP_DIR" "$REP_TRANSCRIPT" 2>&1)"
contains "nothing was pending" "$REP_EMPTY" \
  && check "a clear that matched nothing says so" ok \
  || check "a clear that matched nothing says so" "said: $REP_EMPTY"

bash "$SPOOL_LIB" note "$REP_DIR" "the first finding" tester "$REP_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$REP_DIR" "the second finding" tester "$REP_TRANSCRIPT" >/dev/null 2>&1
REP_FULL="$(bash "$SPOOL_LIB" clear "$REP_DIR" "$REP_TRANSCRIPT" 2>&1)"
contains "filed 2 record" "$REP_FULL" \
  && check "a clear that filed records says how many" ok \
  || check "a clear that filed records says how many" "said: $REP_FULL"
# And WHERE they went, so the archive question that started this can be answered by looking at the
# file the clear names rather than at the one somebody assumed it used.
contains ".filed.jsonl" "$REP_FULL" \
  && check "and names the archive it put them in" ok \
  || check "and names the archive it put them in" "said: $REP_FULL"
REP_ARCHIVE_LINES="$(cat "$CLAUDE_ISSUE_SPOOL_DIR"/*.filed.jsonl 2>/dev/null | grep -c . || true)"
[ "${REP_ARCHIVE_LINES:-0}" -eq 2 ] \
  && check "and the records really are in the archive it named" ok \
  || check "and the records really are in the archive it named" "archive holds ${REP_ARCHIVE_LINES:-0} line(s)"

# A clear where a key could NOT be filed must not also say nothing was pending. Both would be
# printed, one of them false, and the reassuring one is the one a reader keeps (L10, L11).
# Driven by making the archive unwritable, so the append genuinely fails rather than being staged.
bash "$SPOOL_LIB" note "$REP_DIR" "a finding that cannot be archived" tester "$REP_TRANSCRIPT" >/dev/null 2>&1
REP_KEY_NOW="$(bash "$SPOOL_LIB" key "$REP_DIR" "$REP_TRANSCRIPT" 2>/dev/null)"
REP_ARCH="$CLAUDE_ISSUE_SPOOL_DIR/$REP_KEY_NOW.filed.jsonl"
: > "$REP_ARCH"; chmod 444 "$REP_ARCH"
REP_FAIL="$(bash "$SPOOL_LIB" clear "$REP_DIR" "$REP_TRANSCRIPT" 2>&1)"; REP_FAIL_RC=$?
chmod 644 "$REP_ARCH" 2>/dev/null || true
contains "could NOT append" "$REP_FAIL" \
  && check "a clear that could not file says so" ok \
  || check "a clear that could not file says so" "said: $REP_FAIL"
contains "nothing was pending" "$REP_FAIL" \
  && check "and it does not ALSO say nothing was pending" "it printed both, and one of them is false" \
  || check "and it does not ALSO say nothing was pending" ok
[ "$REP_FAIL_RC" -ne 0 ] \
  && check "and it exits non-zero so a caller can tell" ok \
  || check "and it exits non-zero so a caller can tell" "it exited 0"
# The records are still there, since the only copy must survive a failed archive (L5).
[ -n "$(ls "$CLAUDE_ISSUE_SPOOL_DIR"/*.filing.* 2>/dev/null)" ] \
  && check "and the records it could not archive are left, named" ok \
  || check "and the records it could not archive are left, named" "the staged copy is gone"
rm -f "$CLAUDE_ISSUE_SPOOL_DIR"/*.filing.* 2>/dev/null || true

# The review's side. A findings list that names its source can be compared with what the clear
# said it emptied; one that does not leaves the reader with two counts and no way to relate them.
bash "$SPOOL_LIB" note "$REP_DIR" "a finding to render" tester "$REP_TRANSCRIPT" >/dev/null 2>&1
REP_PENDING="$(bash "$SPOOL_LIB" pending "$REP_DIR" "$REP_TRANSCRIPT" 2>&1)"
contains "SPOOL SOURCE" "$REP_PENDING" \
  && check "a rendered findings list names the spool files it was built from" ok \
  || check "a rendered findings list names the spool files it was built from" "rendered: $REP_PENDING"
REP_KEY="$(bash "$SPOOL_LIB" key "$REP_DIR" "$REP_TRANSCRIPT" 2>/dev/null)"
contains "$REP_KEY" "$REP_PENDING" \
  && check "and the source it names is the key a clear would empty" ok \
  || check "and the source it names is the key a clear would empty" "key=$REP_KEY rendered: $REP_PENDING"

echo
# ---- a finding says how old it is, and whether the code it names has moved (#202) ----
# A finding was offered as current however old it was, and one project's oldest pending findings
# cited file and line references from eleven days earlier. Code moves, so a finding can send you
# to a line number that no longer means what it did, and the time is spent before you find out.
#
# There is deliberately no age threshold: measured on this Mac 2026-09-02, the 618 archived
# findings span 1.0 to 17.2 days with a median of 13.0, so every candidate number sits inside the
# dense middle of that distribution and would move dozens across at once on a small shift (L172).
# What is measured instead is whether the file the finding names has changed since it was written,
# which is the thing the age was standing in for.
reset_spool
AGE_DIR="$TMPROOT/finding-age"; mkdir -p "$AGE_DIR"
( cd "$AGE_DIR" && git init -q . 2>/dev/null )
AGE_TDIR="$TMPROOT/finding-age-transcript"; mkdir -p "$AGE_TDIR"
AGE_TRANSCRIPT="$AGE_TDIR/agent.jsonl"; : > "$AGE_TRANSCRIPT"
printf 'first\n' > "$AGE_DIR/moved.py"
printf 'first\n' > "$AGE_DIR/still.py"
bash "$SPOOL_LIB" note "$AGE_DIR" "moved.py line 12 needs a guard" tester "$AGE_TRANSCRIPT" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$AGE_DIR" "still.py line 3 needs a guard" tester "$AGE_TRANSCRIPT" >/dev/null 2>&1
# BOTH ends are pinned, not just one. The meaning here is the RELATIONSHIP between a file's
# timestamp and the finding's, and the finding's is recorded to the second while a file's carries
# a fraction, so leaving the untouched file at "now" made it land a fraction AFTER the finding
# often enough to matter and the control failed for a reason that had nothing to do with the code
# (L130, L134). Set rather than waited for, so it is instant and cannot drift (L290).
touch -t "$(date -v+1d '+%Y%m%d%H%M' 2>/dev/null || date -d 'tomorrow' '+%Y%m%d%H%M')" "$AGE_DIR/moved.py"
touch -t "$(date -v-1d '+%Y%m%d%H%M' 2>/dev/null || date -d 'yesterday' '+%Y%m%d%H%M')" "$AGE_DIR/still.py"
AGE_OUT="$(bash "$SPOOL_LIB" pending "$AGE_DIR" "$AGE_TRANSCRIPT" 2>&1)"
contains "ago)" "$AGE_OUT" \
  && check "#202 a rendered finding says how old it is" ok \
  || check "#202 a rendered finding says how old it is" "rendered: $AGE_OUT"
contains "moved.py has changed since this was written" "$AGE_OUT" \
  && check "#202 and a finding whose file has changed since is marked" ok \
  || check "#202 and a finding whose file has changed since is marked" "rendered: $AGE_OUT"
contains "still.py has changed since this was written" "$AGE_OUT" \
  && check "#202 and one whose file has not is left alone" "it marked the untouched file too" \
  || check "#202 and one whose file has not is left alone" ok

# ---------------------------------------------------------------------------
# The clear must drain the key the review READ (claude-config#287, claude-config#284).
# ---------------------------------------------------------------------------
# Observed live in Slate on 2026-09-03. The review's findings file named its source,
# `bfea61f932c1.jsonl (107 records)`, and the clear documented in the instruction was then run
# exactly as written, `issue-spool.sh clear "$PWD"`, and answered `nothing was pending under the
# key(s) this project reads (ac694bb5abad)`. Both statements were true and they were about
# different files. 138 records sat unfiled across 9 keys and the identical five findings came back
# at the next review.
#
# The cause is two independent derivations of one key. The review renders with the session
# TRANSCRIPT, which keys on the transcript's directory; the documented clear passes only a
# directory, which keys on the git common dir. They agree only when those two roots coincide, and
# nothing anywhere compared them (L70, L285).
#
# So the RENDERER writes the clear command, out of the same two values it rendered from, into the
# findings file it produces. There is one derivation and the two cannot disagree by construction.
CLEARK="$TMPROOT/cleartest"
# The record's own cwd is a DIFFERENT directory from the project being reviewed, which is what a
# harvested record looks like: the agent worked somewhere else under the same parent session. It is
# also what defeats the multi key fallback, which matches a record by ITS cwd, and it is the shape
# the live failure had (the records named ~/claude-config-sync and ~/trypennie while the review was
# in a third project).
mkdir -p "$CLEARK/proj" "$CLEARK/agentdir"
CLEAR_TRANSCRIPT="$TMPROOT/clear-session.jsonl"
cat > "$CLEAR_TRANSCRIPT" <<'JSONL'
{"type":"user","message":{"content":"do the work"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{}}]}}
JSONL

# The fixture's whole point: the transcript's directory and the project directory are different
# places, so the two derivations give different keys. Asserted, not assumed, because if they
# happened to coincide every check below would pass while measuring nothing (L70).
ck_read_key="$(bash "$SPOOL_LIB" key "$CLEARK/proj" "$CLEAR_TRANSCRIPT" 2>/dev/null)"
ck_dir_key="$(bash "$SPOOL_LIB" key "$CLEARK/proj" 2>/dev/null)"
[ -n "$ck_read_key" ] && [ "$ck_read_key" != "$ck_dir_key" ] \
  && check "#287 the fixture really does key the two ways apart" ok \
  || check "#287 the fixture really does key the two ways apart" "read=$ck_read_key dir=$ck_dir_key"

reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$CLEARK/agentdir" "a finding the review will render and must then be able to file" tester "$CLEAR_TRANSCRIPT" >/dev/null 2>&1

ck_payload="$(python3 - "$CLEARK/proj" "$CLEAR_TRANSCRIPT" <<'PY'
import json, sys
print(json.dumps({"transcript_path": sys.argv[2], "cwd": sys.argv[1], "stop_hook_active": False}))
PY
)"
CLAUDE_PROJECT_DIR="$CLEARK/proj" bash -c 'printf "%s" "$1" | bash "$2" >/dev/null 2>&1' _ "$ck_payload" "$REVIEW"
ck_out="$(CLAUDE_PROJECT_DIR="$CLEARK/proj" bash -c 'printf "%s" "$1" | bash "$2" 2>/dev/null' _ "$ck_payload" "$REVIEW")"
ck_file="$(printf '%s' "$ck_out" | python3 -c '
import json, re, sys
try:
    reason = json.loads(sys.stdin.read()).get("reason") or ""
except Exception:
    reason = ""
m = re.search(r"waiting in (\S+?)\. They", reason)
print(m.group(1) if m else "")
')"
[ -n "$ck_file" ] && [ -f "$ck_file" ] \
  && check "#287 the review rendered a findings file" ok \
  || check "#287 the review rendered a findings file" "pointer=${ck_file:-<none>}"

# The findings file carries the command that files exactly what it rendered.
ck_cmd="$(grep -n 'issue-spool.sh' "$ck_file" 2>/dev/null | tail -1 | cut -d: -f2- | sed 's/^ *//')"
case "$ck_cmd" in
  *"clear"*) check "#287 the findings file names the command that files what it rendered" ok ;;
  *)         check "#287 the findings file names the command that files what it rendered" "last spool line: ${ck_cmd:-<none>}" ;;
esac

# And running EXACTLY that line files them. This is the whole issue: the command a reader is told
# to run has to drain the file the reader read.
ck_filed="$(eval "$ck_cmd" 2>&1)"
case "$ck_filed" in
  *"filed 1 record"*) check "#287 running that line files the record the review rendered" ok ;;
  *)                  check "#287 running that line files the record the review rendered" "said: $ck_filed" ;;
esac
ck_left="$(bash "$SPOOL_LIB" raw "$CLEARK/proj" "$CLEAR_TRANSCRIPT" 2>/dev/null | grep -c . || true)"
[ "${ck_left:-1}" = "0" ] \
  && check "#287 and nothing is left pending under the key it read" ok \
  || check "#287 and nothing is left pending under the key it read" "$ck_left record(s) remain"

# THE CONTROL, and without it none of the above measures anything: the form that was documented,
# a directory and no transcript, really does miss this spool. If it did not, the checks above would
# pass whatever the fix did (L159).
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$CLEARK/agentdir" "a finding the review will render and must then be able to file" tester "$CLEAR_TRANSCRIPT" >/dev/null 2>&1
ck_dironly="$(bash "$SPOOL_LIB" clear "$CLEARK/proj" 2>&1)"
case "$ck_dironly" in
  *"nothing was pending"*) check "#287 the control: a clear given only a directory misses it" ok ;;
  *)                       check "#287 the control: a clear given only a directory misses it" "said: $ck_dironly" ;;
esac

# A clear that matched nothing must say whether the spool is holding records it did not match,
# because "nothing was pending" and "nothing was pending under the key I happened to compute" read
# identically and only the second one was ever true here (L11, L98).
case "$ck_dironly" in
  *"1 record"*|*"other key"*) check "#287 and it says the spool is still holding records it did not match" ok ;;
  *)                          check "#287 and it says the spool is still holding records it did not match" "said: $ck_dironly" ;;
esac

# A genuinely empty spool must NOT gain that sentence, or it becomes noise on the normal case and
# stops distinguishing anything (L36).
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
ck_empty="$(bash "$SPOOL_LIB" clear "$CLEARK/proj" 2>&1)"
case "$ck_empty" in
  *"other key"*) check "#287 and an empty spool is not accused of holding anything" "said: $ck_empty" ;;
  *)             check "#287 and an empty spool is not accused of holding anything" ok ;;
esac

# ---------------------------------------------------------------------------
# A finding is still attributable after the worktree it was written in has gone (claude-config#294).
# ---------------------------------------------------------------------------
# issue_spool_keys_written_from attributed a pending file by resolving its FIRST record's own `cwd`
# through issue_spool_key. That resolution needs the directory to still exist: the key falls back
# to git's common dir, and every AGENTS.md in the consuming repos tells people to remove a worktree
# once its PR merges. Once it is gone the git call fails, the path is hashed as itself, and the
# record belongs to no project.
#
# Measured on this Mac 2026-09-03 in Slate: 106 unfiled findings sat in one file whose first record
# named a deleted worktree, and 111 of the 170 pending records across the whole spool were written
# from a worktree cwd, so this is the majority case rather than an edge. Reading only the first
# record made it worse: one unattributable record at the top stranded every record behind it.
#
# Two answers, because one of them cannot see the backlog. Every record now carries the project key
# resolved at APPEND time, when the directory is guaranteed to exist. That does nothing for records
# already written (L223), so the cwd is still resolved as before, and a worktree path also resolves
# through the checkout it belongs to.
WT="$TMPROOT/worktree294"
mkdir -p "$WT/project/.claude/worktrees" "$WT/other"
git -C "$WT/project" init -q 2>/dev/null
git -C "$WT/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
WT_AGENT="$WT/project/.claude/worktrees/agent-deadbeef"
mkdir -p "$WT_AGENT"

wt_keys(){ bash "$SPOOL_LIB" read-keys "$WT/project" 2>/dev/null; }
wt_reset(){ rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"; }

# A record written from the worktree, keyed under a transcript so it lands in a file the project's
# own directory key does not name. That is the shape a harvested finding has.
WT_TRANSCRIPT="$TMPROOT/wt-session.jsonl"; : > "$WT_TRANSCRIPT"
wt_reset
bash "$SPOOL_LIB" note "$WT_AGENT" "a finding an agent made inside a worktree" tester "$WT_TRANSCRIPT" >/dev/null 2>&1
wt_file="$(bash "$SPOOL_LIB" path "$WT_AGENT" "$WT_TRANSCRIPT" 2>/dev/null)"
[ -s "$wt_file" ] \
  && check "#294 the worktree finding was written" ok \
  || check "#294 the worktree finding was written" "nothing at ${wt_file:-<none>}"

# THE WORKTREE IS THEN DELETED, which is what every AGENTS.md tells people to do.
rm -rf "$WT_AGENT"
[ ! -d "$WT_AGENT" ] \
  && check "#294 the worktree really is gone" ok \
  || check "#294 the worktree really is gone" "$WT_AGENT is still there"

wt_found="$(bash "$SPOOL_LIB" read-keys "$WT/project" 2>/dev/null | tr '\n' ' ')"
wt_key="$(basename "$wt_file" .jsonl)"
case " $wt_found " in
  *" $wt_key "*) check "#294 the project still reaches a finding from a deleted worktree" ok ;;
  *)             check "#294 the project still reaches a finding from a deleted worktree" "keys=$wt_found wanted=$wt_key" ;;
esac

# ONE unattributable record at the top must not strand the ones behind it. Only the first record
# was ever read, so a single stranger at the head hid the whole file.
wt_reset
STRANGE="$TMPROOT/wt-strange.jsonl"; : > "$STRANGE"
bash "$SPOOL_LIB" note "$WT/other" "a finding from somewhere else entirely" tester "$STRANGE" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$WT/project" "a finding that belongs to this project" tester "$STRANGE" >/dev/null 2>&1
wt_file2="$(bash "$SPOOL_LIB" path "$WT/other" "$STRANGE" 2>/dev/null)"
wt_key2="$(basename "$wt_file2" .jsonl)"
wt_found2="$(bash "$SPOOL_LIB" read-keys "$WT/project" 2>/dev/null | tr '\n' ' ')"
case " $wt_found2 " in
  *" $wt_key2 "*) check "#294 a record behind an unattributable one is still reached" ok ;;
  *)              check "#294 a record behind an unattributable one is still reached" "keys=$wt_found2 wanted=$wt_key2" ;;
esac

# THE CONTROL, and without it the widening above could simply be "attribute everything" (L104).
# A file holding only another project's records must not be reached from here.
wt_reset
ONLY_OTHER="$TMPROOT/wt-other-only.jsonl"; : > "$ONLY_OTHER"
bash "$SPOOL_LIB" note "$WT/other" "a finding that belongs to another project" tester "$ONLY_OTHER" >/dev/null 2>&1
wt_file3="$(bash "$SPOOL_LIB" path "$WT/other" "$ONLY_OTHER" 2>/dev/null)"
wt_key3="$(basename "$wt_file3" .jsonl)"
wt_found3="$(bash "$SPOOL_LIB" read-keys "$WT/project" 2>/dev/null | tr '\n' ' ')"
case " $wt_found3 " in
  *" $wt_key3 "*) check "#294 another project's file is still not reached from here" "keys=$wt_found3 wrongly include $wt_key3" ;;
  *)              check "#294 another project's file is still not reached from here" ok ;;
esac

# The stamp itself, which is what makes this work for a directory that has gone entirely rather
# than only for a worktree whose parent survives.
wt_reset
GONE="$WT/vanishes"; mkdir -p "$GONE"
GONE_TRANSCRIPT="$TMPROOT/wt-gone.jsonl"; : > "$GONE_TRANSCRIPT"
gone_key_before="$(bash "$SPOOL_LIB" key "$GONE" 2>/dev/null)"
bash "$SPOOL_LIB" note "$GONE" "a finding from a directory that will not exist" tester "$GONE_TRANSCRIPT" >/dev/null 2>&1
gone_rec="$(bash "$SPOOL_LIB" raw "$GONE" "$GONE_TRANSCRIPT" 2>/dev/null)"
case "$gone_rec" in
  *"\"project\": \"$gone_key_before\""*) check "#294 a record carries the project key resolved when it was written" ok ;;
  *)                                     check "#294 a record carries the project key resolved when it was written" "record=$gone_rec" ;;
esac

# ---------------------------------------------------------------------------
# A clear files only what the review that wrote it had READ (claude-config#381).
# ---------------------------------------------------------------------------
# Seen in an Ovation session on 2026-09-14. A review rendered 4 findings out of a pending file
# holding 326 records. While its picker was open three more subagents finished and the harvest
# appended their findings to that same file. The clear line the review had written then filed 179
# records, and the later agents' findings were never shown to anybody: they were recovered only
# from those agents' final reports.
#
# Rename then drain protects a record appended DURING the clear. Nothing protected one appended
# during the minutes a picker is open, because the clear line named files, and a file is a place
# records keep arriving in (L285). So the render now writes down WHICH records it read, and the
# clear files only those, leaving anything later pending for the next review.
#
# Driven through the real hook, because the render and the command it writes are the two halves
# that must agree, and a test that built the command by hand would be a second derivation (L70).
r381_render() { # r381_render -> prints the findings file the hook wrote, or nothing
  local out
  out="$(CLAUDE_PROJECT_DIR="$CLEARK/proj" bash -c 'printf "%s" "$1" | bash "$2" 2>/dev/null' _ "$ck_payload" "$REVIEW")"
  printf '%s' "$out" | python3 -c '
import json, re, sys
try:
    reason = json.loads(sys.stdin.read()).get("reason") or ""
except Exception:
    reason = ""
m = re.search(r"waiting in (\S+?)\. They", reason)
print(m.group(1) if m else "")
'
}
r381_cmd_of() { grep 'issue-spool.sh' "$1" 2>/dev/null | tail -1 | sed 's/^ *//'; }

reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$CLEARK/agentdir" "a finding the review rendered before its picker opened" tester "$CLEAR_TRANSCRIPT" >/dev/null 2>&1
r381_file="$(r381_render)"
r381_cmd="$(r381_cmd_of "$r381_file")"
[ -n "$r381_file" ] && [ -f "$r381_file" ] && [ -n "$r381_cmd" ] \
  && check "#381 the review rendered a findings file with a clear line" ok \
  || check "#381 the review rendered a findings file with a clear line" "file=${r381_file:-<none>} cmd=${r381_cmd:-<none>}"

# THE LATE ARRIVAL: the same session, the same key, after the render and before the clear. That is
# exactly the Ovation shape, and it is what makes this hard, because nothing about the record
# itself says it was not shown.
bash "$SPOOL_LIB" note "$CLEARK/agentdir" "a finding harvested while the picker was open" tester "$CLEAR_TRANSCRIPT" >/dev/null 2>&1
# Preconditions, in the same fixture, or everything below is satisfied by a record that never
# reached the key the review read, or by one the review did show (L159).
r381_pre="$(bash "$SPOOL_LIB" raw "$CLEARK/proj" "$CLEAR_TRANSCRIPT" 2>/dev/null)"
contains "while the picker was open" "$r381_pre" \
  && check "#381 the late finding is pending under the key the review read" ok \
  || check "#381 the late finding is pending under the key the review read" "pending=${r381_pre:0:300}"
contains "while the picker was open" "$(cat "$r381_file" 2>/dev/null)" \
  && check "#381 and the review really never showed it" "the findings file carries it" \
  || check "#381 and the review really never showed it" ok

r381_said="$(eval "$r381_cmd" 2>&1)"
r381_rc=$?
r381_arch="$(bash "$SPOOL_LIB" archive "$CLEARK/proj" "$CLEAR_TRANSCRIPT" 2>/dev/null)"
r381_left="$(bash "$SPOOL_LIB" raw "$CLEARK/proj" "$CLEAR_TRANSCRIPT" 2>/dev/null)"
[ "$r381_rc" -eq 0 ] \
  && check "#381 the rendered clear line succeeds" ok \
  || check "#381 the rendered clear line succeeds" "exit $r381_rc said=${r381_said:0:400}"
contains "before its picker opened" "$r381_arch" \
  && check "#381 it files the finding the review showed" ok \
  || check "#381 it files the finding the review showed" "archive=${r381_arch:0:300} said=${r381_said:0:300}"
contains "while the picker was open" "$r381_arch" \
  && check "#381 and does NOT file the one harvested after the render" "it was filed unread" \
  || check "#381 and does NOT file the one harvested after the render" ok
contains "while the picker was open" "$r381_left" \
  && check "#381 which is still pending for the next review" ok \
  || check "#381 which is still pending for the next review" "pending=${r381_left:0:300}"
# It SAYS so, with a count, because a clear that left something behind and one that filed
# everything must not read alike, and the one it left is the fact that explains the next review.
case "$r381_said" in
  *"left 1 record(s)"*"after the review"*) check "#381 and the clear says it left one for the next review" ok ;;
  *) check "#381 and the clear says it left one for the next review" "said=${r381_said:0:500}" ;;
esac
# And it does not tell the reader the command was given the wrong key, which is the advice for a
# different fault and would send them to re-run the line they just ran (L111).
contains "run the line the findings file names" "$r381_said" \
  && check "#381 and does not blame the key" "said=${r381_said:0:500}" \
  || check "#381 and does not blame the key" ok
# The NEXT review shows the late finding, which is the whole point of leaving it.
r381_next="$(bash "$SPOOL_LIB" pending "$CLEARK/proj" "$CLEAR_TRANSCRIPT" 2>/dev/null)"
contains "while the picker was open" "$r381_next" \
  && check "#381 and the next review shows it" ok \
  || check "#381 and the next review shows it" "pending=${r381_next:0:300}"

# --- the stamp cannot be read: NOTHING is filed ---------------------------------------------------
# Falling back to filing every record would be the defect itself, so a missing or damaged record of
# what was read is a refusal, loud, with the findings left to come back (L173, L320).
R381_A="$TMPROOT/r381-a.jsonl"; : > "$R381_A"
R381_B="$TMPROOT/r381-b.jsonl"; : > "$R381_B"
R381_M="$TMPROOT/r381.manifest"
# The third damage keeps a good header over a body that cannot be decoded, so it gets past the
# header check and fails INSIDE the split, which is the other place a fallback could file everything.
for r381_damage in missing garbage undecodable; do
  reset_spool
  mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
  rm -f "$R381_M"
  bash "$SPOOL_LIB" note "$REPO" "a finding whose stamp is $r381_damage" tester "$R381_A" >/dev/null 2>&1
  bash "$SPOOL_LIB" pending "$REPO" "$R381_A" "$R381_M" >/dev/null 2>&1
  [ -s "$R381_M" ] \
    && check "#381 ($r381_damage) the render wrote its stamp to begin with" ok \
    || check "#381 ($r381_damage) the render wrote its stamp to begin with" "nothing at $R381_M"
  case "$r381_damage" in
    missing) rm -f "$R381_M" ;;
    garbage) printf 'not a stamp\n' > "$R381_M" ;;
    undecodable) printf '\xff\xfe\x00 not text\n' >> "$R381_M" ;;
  esac
  r381_bad="$(bash "$SPOOL_LIB" clear "$REPO" "$R381_A" "$R381_M" 2>&1)"
  r381_bad_rc=$?
  [ "$r381_bad_rc" -ne 0 ] \
    && check "#381 ($r381_damage) a clear whose stamp cannot be read fails" ok \
    || check "#381 ($r381_damage) a clear whose stamp cannot be read fails" "exit 0, said=${r381_bad:0:300}"
  contains "NOTHING was filed" "$r381_bad" \
    && check "#381 ($r381_damage) and says nothing was filed" ok \
    || check "#381 ($r381_damage) and says nothing was filed" "said=${r381_bad:0:300}"
  contains "whose stamp is $r381_damage" "$(bash "$SPOOL_LIB" archive "$REPO" "$R381_A" 2>/dev/null)" \
    && check "#381 ($r381_damage) and really filed nothing" "the finding was archived" \
    || check "#381 ($r381_damage) and really filed nothing" ok
  contains "whose stamp is $r381_damage" "$(bash "$SPOOL_LIB" raw "$REPO" "$R381_A" 2>/dev/null)" \
    && check "#381 ($r381_damage) and the finding is still pending" ok \
    || check "#381 ($r381_damage) and the finding is still pending" "it is gone from the spool"
done

# --- another session's record: seen if it was rendered, untouched if it arrived later -----------
# A clear marks the other session's records it had to leave as SEEN by this one (#322), so they are
# not shown here again. A record that arrived after the render was never shown, so marking it would
# hide a finding from this session that it has never seen, which is this issue in a different coat.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$REPO" "session A's own rendered finding" tester "$R381_A" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$REPO" "session B's finding that A's review rendered" tester "$R381_B" >/dev/null 2>&1
bash "$SPOOL_LIB" pending "$REPO" "$R381_A" "$R381_M" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$REPO" "session B's finding that arrived after A's render" tester "$R381_B" >/dev/null 2>&1
bash "$SPOOL_LIB" clear "$REPO" "$R381_A" "$R381_M" >/dev/null 2>&1
r381_again="$(bash "$SPOOL_LIB" pending "$REPO" "$R381_A" 2>/dev/null)"
contains "arrived after A's render" "$r381_again" \
  && check "#381 another session's late finding is still shown to this session" ok \
  || check "#381 another session's late finding is still shown to this session" "pending=${r381_again:0:400}"
# The control in the same fixture: the one A's review did render is still settled for A (L159).
contains "that A's review rendered" "$r381_again" \
  && check "#381 while the one it rendered is still marked seen" "it came back: ${r381_again:0:400}" \
  || check "#381 while the one it rendered is still marked seen" ok
r381_bown="$(bash "$SPOOL_LIB" pending "$REPO" "$R381_B" 2>/dev/null)"
case "$r381_bown" in
  *"that A's review rendered"*"arrived after A's render"*) check "#381 and both are still B's to settle" ok ;;
  *) check "#381 and both are still B's to settle" "pending=${r381_bown:0:400}" ;;
esac

# --- already filed between render and clear --------------------------------------------------------
# Another clear got there first. What was read is gone, what arrived since stays, and that is not a
# failure (L11): exit 0, and no claim that the command was given the wrong key.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$REPO" "a finding somebody else filed first" tester "$R381_A" >/dev/null 2>&1
bash "$SPOOL_LIB" pending "$REPO" "$R381_A" "$R381_M" >/dev/null 2>&1
bash "$SPOOL_LIB" clear "$REPO" "$R381_A" >/dev/null 2>&1
bash "$SPOOL_LIB" note "$REPO" "a finding that came after both" tester "$R381_A" >/dev/null 2>&1
r381_twice="$(bash "$SPOOL_LIB" clear "$REPO" "$R381_A" "$R381_M" 2>&1)"
r381_twice_rc=$?
[ "$r381_twice_rc" -eq 0 ] \
  && check "#381 a clear whose records were already filed is not a failure" ok \
  || check "#381 a clear whose records were already filed is not a failure" "exit $r381_twice_rc said=${r381_twice:0:300}"
contains "came after both" "$(bash "$SPOOL_LIB" raw "$REPO" "$R381_A" 2>/dev/null)" \
  && check "#381 and the later finding is still pending" ok \
  || check "#381 and the later finding is still pending" "said=${r381_twice:0:300}"
contains "run the line the findings file names" "$r381_twice" \
  && check "#381 and it does not blame the key" "said=${r381_twice:0:400}" \
  || check "#381 and it does not blame the key" ok

# --- the pending file is renamed away mid clear -----------------------------------------------------
# The seam rename then drain was tested with still holds with a stamp: an append during the clear
# lands in a fresh file and is neither filed nor lost, while the rendered record is filed.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$REPO" "a finding rendered before a mid clear append" tester "$R381_A" >/dev/null 2>&1
bash "$SPOOL_LIB" pending "$REPO" "$R381_A" "$R381_M" >/dev/null 2>&1
CLAUDE_ISSUE_SPOOL_MIDCLEAR="bash '$SPOOL_LIB' note '$REPO' 'arrived during the stamped clear' tester '$R381_A' >/dev/null 2>&1" \
  bash "$SPOOL_LIB" clear "$REPO" "$R381_A" "$R381_M" >/dev/null 2>&1
contains "arrived during the stamped clear" "$(bash "$SPOOL_LIB" raw "$REPO" "$R381_A" 2>/dev/null)" \
  && check "#381 a record appended during a stamped clear survives it" ok \
  || check "#381 a record appended during a stamped clear survives it" "it is gone"
r381_mid_arch="$(bash "$SPOOL_LIB" archive "$REPO" "$R381_A" 2>/dev/null)"
contains "before a mid clear append" "$r381_mid_arch" \
  && check "#381 and the rendered one is filed" ok \
  || check "#381 and the rendered one is filed" "archive=${r381_mid_arch:0:300}"

# --- nothing shown, no stamp -----------------------------------------------------------------------
# A stamp is only written for a render that showed something, since only such a render gets a clear
# line; one left behind by an empty read would be a record of nothing.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
rm -f "$R381_M"
bash "$SPOOL_LIB" pending "$REPO" "$R381_A" "$R381_M" >/dev/null 2>&1
[ -e "$R381_M" ] \
  && check "#381 an empty render writes no stamp" "found $R381_M" \
  || check "#381 an empty render writes no stamp" ok

# --- the hook cannot put its stamp in place: it writes no clear line --------------------------------
# A clear line without a stamp would be the old command that files everything, so the hook says the
# findings cannot be filed from this review instead, and they come back at the next one. Forced by
# putting a directory where the stamp has to go.
reset_spool
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
bash "$SPOOL_LIB" note "$CLEARK/agentdir" "a finding whose review could not stamp it" tester "$CLEAR_TRANSCRIPT" >/dev/null 2>&1
r381_hash="$(printf '%s' "$CLEARK/proj" | shasum | cut -c1-12)"
r381_blocker="${TMPDIR%/}/claude-issue-findings-${r381_hash}.clear-session.manifest"
rm -f "$r381_blocker"; mkdir -p "$r381_blocker"
r381_nofile="$(r381_render)"
r381_nocmd="$(r381_cmd_of "$r381_nofile")"
rm -rf "$r381_blocker"
[ -n "$r381_nofile" ] && [ -f "$r381_nofile" ] \
  && check "#381 the review still delivers its findings when the stamp cannot be placed" ok \
  || check "#381 the review still delivers its findings when the stamp cannot be placed" "no findings file"
case "$r381_nocmd" in
  *" clear "*) check "#381 and writes no clear line that would file without a stamp" "line=$r381_nocmd" ;;
  *)           check "#381 and writes no clear line that would file without a stamp" ok ;;
esac
contains "cannot be filed from this review" "$(cat "$r381_nofile" 2>/dev/null)" \
  && check "#381 and says why there is nothing to run" ok \
  || check "#381 and says why there is nothing to run" "file=$(tail -3 "$r381_nofile" 2>/dev/null)"

echo "passed: $pass  failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
