#!/usr/bin/env bash
# Tests for the advisory AI review on push (claude-config#433): ai-review-on-push.sh, which STARTS a
# review detached after a successful `git push`, and ai-review-nudge.sh, which SHOWS finished reviews
# once per session on a later prompt. Their shared pieces, lib/ai-review-common.sh and the detached
# runner lib/ai-review-run.py, are driven through the hooks rather than on their own.
#
# The real `claude` is NEVER called. A fake first on PATH records its arguments, its environment and
# its stdin, sleeps when told to, and prints a fixed review. That is what lets the suite assert the
# three things a reader of the real hook cannot see: that CLAUDECODE was removed from the child's
# environment (a nested claude refuses to start with it set), that the prompt sent is the text of
# lib/ai-review-prompt.txt and not a copy (L41), and that exactly ONE review was started per push
# (L467: a presence check is blind to a second call).
#
# Every push here is a real `git push` into a bare repository in the scratch directory, so the
# upstream reflog the hook reads is the one git actually writes. And every push in sections 1 to 9
# is of the DEFAULT branch, main, because that is where this review still runs: a push of any other
# branch is held by pr-review-push-gate.sh for the lessons review of the whole branch, and this
# review stands down there (claude-config#1007, exercised on its own in section 10).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUSH_HOOK="$DIR/ai-review-on-push.sh"
NUDGE="$DIR/ai-review-nudge.sh"
PROMPT="$DIR/lib/ai-review-prompt.txt"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.aireview.XXXXXXXX")" || WORKDIR=""
case "${WORKDIR%/}" in
  ''|/|"${HOME%/}") echo "$(basename "${BASH_SOURCE[0]}"): refusing to run: throwaway directory came back as '$WORKDIR'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: $3"; fi }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: $3"; fi }

# ---------------------------------------------------------------------------
# The state directory is the scratch directory's, never Dan's (L2). Exported before anything runs.
# CLAUDECODE is set explicitly, so the assertion that the fake did NOT see it holds in CI as well as
# inside a real session.
# ---------------------------------------------------------------------------
export AI_REVIEW_STATE_DIR="$WORKDIR/state"
export CLAUDECODE=1
# The review runs only on the computers AI_REVIEW_HOSTS names, and this suite runs on whichever
# machine it is given, so every check below judges as a named host the list allows. The host gate
# itself is exercised on its own in section 3.
export AI_REVIEW_HOST="review-host"
export AI_REVIEW_HOSTS="review-host"

# ---------------------------------------------------------------------------
# The fake claude. Arguments are recorded separated by the record separator so a prompt spanning
# many lines stays one argument; the environment and stdin go to their own files.
# ---------------------------------------------------------------------------
FAKEBIN="$WORKDIR/bin"; mkdir -p "$FAKEBIN"
export FAKE_LOG="$WORKDIR/fakelog"; mkdir -p "$FAKE_LOG"
cat > "$FAKEBIN/claude" <<'EOS'
#!/usr/bin/env bash
printf 'called\n' >> "$FAKE_LOG/calls"
printf '%s\x1e' "$@" > "$FAKE_LOG/args"
env > "$FAKE_LOG/env"
cat > "$FAKE_LOG/stdin"
sleep "${FAKE_CLAUDE_SLEEP:-0}"
if [ -n "${FAKE_CLAUDE_OUT:-}" ]; then printf '%s\n' "$FAKE_CLAUDE_OUT"; exit 0; fi
printf 'src/calendar.ts:12: deleteEvent still throws the raw error while createEvent got the typed one. Should be: the same typed error in both. [severity: major]\n'
EOS
chmod +x "$FAKEBIN/claude"
export PATH="$FAKEBIN:$PATH"
calls(){ grep -c . "$FAKE_LOG/calls" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------
# Fixture: a bare origin and a clone pushing to it. Every git call carries its own identity because
# CI has none.
# ---------------------------------------------------------------------------
ORIGIN="$WORKDIR/origin.git"
git init -q --bare "$ORIGIN"
REPO="$WORKDIR/repo"
mkdir -p "$REPO/src"
git init -q "$REPO"
G(){ git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
G symbolic-ref HEAD refs/heads/main
printf '{"name":"fixture","dependencies":{"next":"16.0.0","react":"19.0.0"}}\n' > "$REPO/package.json"
cat > "$REPO/src/calendar.ts" <<'EOS'
export async function createEvent(id: string) {
  try {
    return await api.create(id);
  } catch (e) {
    throw e;
  }
}
export async function deleteEvent(id: string) {
  try {
    return await api.remove(id);
  } catch (e) {
    throw e;
  }
}
EOS
printf '# fixture\n' > "$REPO/README.md"
G add package.json src/calendar.ts README.md
G commit -q -m seed
G remote add origin "$ORIGIN"
G push -q -u origin main 2>/dev/null

# The planted sibling omission: createEvent gets the typed error, deleteEvent does not.
python3 - "$REPO/src/calendar.ts" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("return await api.create(id);\n  } catch (e) {\n    throw e;", "return await api.create(id);\n  } catch (e) {\n    throw new CalendarError(e);", 1)
open(p, "w").write(s)
EOF
G add src/calendar.ts
G commit -q -m "typed error on create"
G push -q origin main 2>/dev/null
SHA_FIX="$(G rev-parse HEAD)"

ms(){ python3 -c 'import time; print(int(time.time() * 1000))'; }

payload(){ # payload <command> <exit code or "none"> <cwd> <session>
  local cmd="$1" code="$2" cwd="$3" session="$4" resp
  if [ "$code" = "none" ]; then resp='"tool_response":"a string"'
  else resp="\"tool_response\":{\"exit_code\":$code,\"stdout\":\"\",\"stderr\":\"\"}"; fi
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"%s"},%s}' \
    "$session" "$cwd" "$cmd" "$resp"
}

OUT=""; RC=0; ELAPSED=0
fire_push(){ # fire_push <command> <exit code> [cwd]
  local t0 t1
  t0="$(ms)"
  OUT="$(payload "$1" "$2" "${3:-$REPO}" s1 | bash "$PUSH_HOOK" 2>&1)"; RC=$?
  t1="$(ms)"
  ELAPSED=$((t1 - t0))
}

wait_for_final(){ # wait_for_final <sha> <seconds>  -> 0 when the finished file appears
  local f="$AI_REVIEW_STATE_DIR"/*"-$1.txt" ticks=0
  while [ "$ticks" -lt "$(( $2 * 10 ))" ]; do
    # shellcheck disable=SC2086
    for cand in $f; do [ -f "$cand" ] && return 0; done
    sleep 0.1; ticks=$((ticks + 1))
  done
  return 1
}

# ===========================================================================
# 1. A successful push starts exactly one detached review and returns at once.
# ===========================================================================
# The review sleeps REVIEW_SLEEP seconds and the hook must return well inside that, which is what
# proves it does not wait for the review. 5 rather than 2 since claude-config#1007 gave the hook
# the push gate's own scope check to run first: at a load average near 400 (measured 2026-10-09,
# many agents at once) that check alone took 0.6 to 1 s, and the 2 s margin was missed by 39 ms.
REVIEW_SLEEP=5
FAKE_CLAUDE_SLEEP=$REVIEW_SLEEP fire_push "git push origin main" 0
check_eq "the push hook exits 0" 0 "$RC"
check "and says the review started" "started in the background" "$OUT"
check "naming the model it used" "with sonnet" "$OUT"
[ "$ELAPSED" -lt $((REVIEW_SLEEP * 1000)) ] && ok || bad "the hook returned in ${ELAPSED} ms, which is not within $REVIEW_SLEEP seconds of a push that takes a $REVIEW_SLEEP second review"

pending_now=( "$AI_REVIEW_STATE_DIR"/*-"$SHA_FIX".txt.pending )
[ -f "${pending_now[0]:-}" ] && ok || bad "a .pending file exists while the review runs"
pending_body="$(cat "${pending_now[0]:-/dev/null}" 2>/dev/null)"
check "and it carries the start time" "started=" "$pending_body"
check "and the branch" "branch=main" "$pending_body"

wait_for_final "$SHA_FIX" 20 && ok || bad "the finished file appears within 20 seconds"
final=( "$AI_REVIEW_STATE_DIR"/*-"$SHA_FIX".txt )
FINAL_FIX="${final[0]:-}"
[ -f "${pending_now[0]:-}" ] && bad "the .pending file is gone once the review has finished" || ok
[ -e "$AI_REVIEW_STATE_DIR"/*-"$SHA_FIX".diff ] && bad "the diff file is removed once the review has finished" || ok
final_body="$(cat "$FINAL_FIX" 2>/dev/null)"
check "the finished file records status=ok" "status=ok" "$final_body"
check "and holds the review text" "deleteEvent still throws" "$final_body"
check "and the model" "model=sonnet" "$final_body"

check_eq "exactly one review was started for the push" 1 "$(calls)"
[ -f "$FAKE_LOG/env" ] && ! grep -q '^CLAUDECODE=' "$FAKE_LOG/env" \
  && ok || bad "CLAUDECODE was removed from the environment claude runs in"
grep -q '^AI_REVIEW_STATE_DIR=' "$FAKE_LOG/env" \
  && ok || bad "and the rest of the environment reached claude (a positive control for the env file)"

# The prompt sent is the FILE's text, verbatim, so the file is the prompt and not a copy of it.
python3 - "$FAKE_LOG/args" "$PROMPT" <<'EOF' && ok || bad "the prompt sent to claude is the exact text of lib/ai-review-prompt.txt, after -p"
import sys
args = open(sys.argv[1], encoding="utf-8").read().split("\x1e")
prompt = open(sys.argv[2], encoding="utf-8").read()
i = args.index("-p")
sent = args[i + 1]
sys.exit(0 if sent.endswith(prompt) and prompt.strip() in sent else 1)
EOF
args_blob="$(tr '\036' '\n' < "$FAKE_LOG/args")"
check "the framework line names Next.js, read from package.json" "Next.js/React application" "$args_blob"
check "the model flag is passed" "--model" "$args_blob"
# No MCP servers (claude-config#956). The reviewer reads a diff and the lessons and calls no tool a
# server offers, yet a launch without the flag loads every server Dan has connected: 12 in the
# real run's init event on 2026-10-08, with --strict-mcp-config and no --mcp-config it was 0. The
# flag only empties the list while nothing is named, so the check is both halves, read from the
# arguments the stand in actually received.
python3 - "$FAKE_LOG/args" <<'EOF' && ok || bad "the reviewer starts with no MCP servers: --strict-mcp-config exactly once and no --mcp-config"
import sys
args = open(sys.argv[1], encoding="utf-8").read().split("\x1e")
strict = args.count("--strict-mcp-config")
named = [a for a in args if a == "--mcp-config" or a.startswith("--mcp-config=")]
if strict != 1 or named:
    print(f"  --strict-mcp-config appeared {strict} times; --mcp-config arguments: {named}")
    sys.exit(1)
EOF
check "the prompt asks about a sibling not changed the same way" "sibling of a changed function that was not changed the same way" "$args_blob"
check "and about a class fix that missed a site" "class fix that missed one of its sites" "$args_blob"
check "and keeps the no issues line" "No issues found." "$args_blob"
stdin_blob="$(cat "$FAKE_LOG/stdin")"
check "the diff of the push went to claude on stdin" "+    throw new CalendarError(e);" "$stdin_blob"

# The review keeps the LESSONS on purpose and drops the rest of the global config (claude-config#539).
# It used to inherit the whole CLAUDE.md by accident; now the config is switched off on the launch
# and every lessons index file is read at run time into the prompt, never a copy of it (L41).
grep -qx 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1' "$FAKE_LOG/env" \
  && ok || bad "the review's claude runs with the global config switched off"
python3 - "$FAKE_LOG/args" "$DIR/.." <<'EOF' && ok || bad "every lessons index file beside the hooks reached the prompt, verbatim"
import glob, os, sys
args = open(sys.argv[1], encoding="utf-8").read().split("\x1e")
sent = args[args.index("-p") + 1]
files = sorted(glob.glob(os.path.join(sys.argv[2], "LESSONS-INDEX-*.md")))
if not files:
    print("  no LESSONS-INDEX-*.md beside the hooks, so there was nothing to check against")
    sys.exit(1)
missing = [os.path.basename(f) for f in files if open(f, encoding="utf-8").read().strip() not in sent]
if missing:
    print("  missing from the prompt: " + ", ".join(missing))
sys.exit(1 if missing else 0)
EOF
check "and the prompt asks for the lesson a repeat breaks, by number" "cite the lesson" "$args_blob"
check "as a diff of the code file" "src/calendar.ts" "$stdin_blob"
# The sibling the review exists to catch is NOT in the diff, so the changed file's full text must
# follow it: the first real run answered "No issues found." on this exact fixture because it was
# handed the diff alone and deleteEvent was never in front of it.
check "followed by the full text of the changed file" "===== FULL FILE at ${SHA_FIX:0:7}: src/calendar.ts" "$stdin_blob"
check "so the unchanged sibling is in front of the reviewer" "export async function deleteEvent" "$stdin_blob"
check "and the start line says what was sent" "diff plus the full text of 1 of 1 changed files" "$OUT"

# The same sha pushed again (a retry) is not reviewed twice.
fire_push "git push origin main" 0
check "a second push of the same sha is skipped out loud" "already been reviewed" "$OUT"
check_eq "and starts nothing" 1 "$(calls)"

# ===========================================================================
# 2. Commands that are not a successful push start nothing.
# ===========================================================================
fire_push "git status" 0
check_eq "a non push command says nothing" "" "$OUT"
check_eq "and exits 0" 0 "$RC"
check_eq "and starts nothing" 1 "$(calls)"

fire_push "echo git push" 0
check_eq "a command that merely mentions a push says nothing" "" "$OUT"

# A refused push sent nothing.
printf 'export const x = 1;\n' > "$REPO/src/x.ts"
G add src/x.ts; G commit -q -m x
fire_push "git push origin main" 1
check "a push that failed is skipped out loud" "did not succeed (exit 1)" "$OUT"
check_eq "and starts nothing" 1 "$(calls)"

# A payload whose tool_response cannot say goes ahead (a review of a push that did happen is worth
# more than silence over one that might not have). This commit IS pushed, for real, first. It also
# drives the diff-alone switch, so the full file section is proved to be off when asked.
G push -q origin main 2>/dev/null
SHA_REFUSED="$(G rev-parse HEAD)"
AI_REVIEW_FULL_FILES=0 fire_push "git push origin main" none
check "a payload that cannot say whether the push succeeded goes ahead" "started in the background" "$OUT"
check "and with AI_REVIEW_FULL_FILES=0 the start line says the diff went alone" "diff alone" "$OUT"
wait_for_final "$SHA_REFUSED" 20 && ok || bad "and that review finishes"
check_eq "starting one more review" 2 "$(calls)"
check_not "and no full file section was sent" "===== FULL FILE" "$(cat "$FAKE_LOG/stdin")"
check "while the diff itself was" "+export const x = 1;" "$(cat "$FAKE_LOG/stdin")"

# ===========================================================================
# 3. Skips, each out loud.
# ===========================================================================
# No claude on PATH. The tools the hook needs are linked into a bare directory so nothing else on
# this machine's PATH can answer for `claude`.
NOBIN="$WORKDIR/nobin"; mkdir -p "$NOBIN"
for t in bash git python3 jq shasum cut sed awk basename dirname cat tr wc date nohup env mkdir rm touch mv find head grep; do
  p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && [ "$p" != "$FAKEBIN/$t" ] && ln -s "$p" "$NOBIN/$t" 2>/dev/null
done
OUT="$(payload "git push origin main" 0 "$REPO" s1 | env PATH="$NOBIN" bash "$PUSH_HOOK" 2>&1)"; RC=$?
check "with no claude on PATH the skip says so" "no 'claude' command is on PATH" "$OUT"
check_eq "and exits 0" 0 "$RC"
check_eq "and starts nothing" 2 "$(calls)"

OUT="$(payload "git push" 0 "$REPO" s1 | CLAUDE_DETACHED_RUN=1 bash "$PUSH_HOOK" 2>&1)"
check "a detached run is skipped and says so" "detached run" "$OUT"

fire_push "SKIP_AI_REVIEW_CHECK=1 git push" 0
check "the escape hatch skips and names itself" "SKIP_AI_REVIEW_CHECK=1" "$OUT"
check "and tells the reader to explain to Dan" "Tell Dan" "$OUT"
check_eq "and none of those started anything" 2 "$(calls)"

# The host gate (Dan, 2026-09-18: the review should run on the work computer, not the personal
# one). A host the list does not name is skipped out loud and starts nothing.
OUT="$(payload "git push origin main" 0 "$REPO" s1 | AI_REVIEW_HOST="other-mac" bash "$PUSH_HOOK" 2>&1)"; RC=$?
check "a computer the list does not name is skipped and says so" "skipped: this computer (other-mac) is not one AI_REVIEW_HOSTS names" "$OUT"
check_eq "and exits 0" 0 "$RC"
# With no list set, the default names the work Mac only. Each allowed case below reaches the
# already-reviewed skip, which sits after the host gate, so passing the gate is proved without
# starting a review.
OUT="$(payload "git push origin main" 0 "$REPO" s1 | env -u AI_REVIEW_HOSTS AI_REVIEW_HOST="Daniels-MacBook-Pro-2" bash "$PUSH_HOOK" 2>&1)"
check "by default the personal Mac is skipped" "is not one AI_REVIEW_HOSTS names" "$OUT"
OUT="$(payload "git push origin main" 0 "$REPO" s1 | env -u AI_REVIEW_HOSTS AI_REVIEW_HOST="Dans-MacBook-Pro" bash "$PUSH_HOOK" 2>&1)"
check "by default the work Mac passes the gate" "already been reviewed" "$OUT"
OUT="$(payload "git push origin main" 0 "$REPO" s1 | env -u AI_REVIEW_HOSTS AI_REVIEW_HOST="Dans-MacBook-Pro.local" bash "$PUSH_HOOK" 2>&1)"
check "a trailing .local on the hostname is ignored" "already been reviewed" "$OUT"
OUT="$(payload "git push origin main" 0 "$REPO" s1 | AI_REVIEW_HOSTS="*" AI_REVIEW_HOST="other-mac" bash "$PUSH_HOOK" 2>&1)"
check "a list of * runs on every computer" "already been reviewed" "$OUT"
check_eq "and none of the host cases started anything" 2 "$(calls)"

# These two come after the host checks, which stand on a head already reviewed.
printf '\nmore\n' >> "$REPO/README.md"
G add README.md; G commit -q -m docs
G push -q origin main 2>/dev/null
SHA_DOCS="$(G rev-parse HEAD)"
fire_push "git push origin main" 0
check "an empty code diff is skipped and says so" "changed no code files" "$OUT"
check_eq "and exits 0" 0 "$RC"
check_eq "and starts nothing" 2 "$(calls)"
[ -e "$AI_REVIEW_STATE_DIR"/*-"$SHA_DOCS".txt.pending ] && bad "and leaves no pending file" || ok

# Over the size cap, at the DEFAULT cap, so the number in the header is the one exercised.
python3 -c '
import sys
with open(sys.argv[1], "w") as f:
    for i in range(12000):
        f.write(f"export const generatedValue{i} = {i};\n")
' "$REPO/src/huge.ts"
G add src/huge.ts; G commit -q -m huge
G push -q origin main 2>/dev/null
fire_push "git push origin main" 0
check "a diff over the cap is skipped and says the size and the cap" "over the 300 KB cap" "$OUT"
check_eq "and starts nothing" 2 "$(calls)"

# ===========================================================================
# 4. The deadline: a review that does not return is recorded as unfinished, and the fake is killed.
# ===========================================================================
printf 'export const slow = true;\n' > "$REPO/src/slow.ts"
G add src/slow.ts; G commit -q -m slow
G push -q origin main 2>/dev/null
SHA_SLOW="$(G rev-parse HEAD)"
: > "$FAKE_LOG/calls"
AI_REVIEW_DEADLINE_SECONDS=1 FAKE_CLAUDE_SLEEP=30 fire_push "git push origin main" 0
check "the slow review still starts" "started in the background" "$OUT"
t0="$(ms)"
wait_for_final "$SHA_SLOW" 15 && ok || bad "a review past its deadline still produces a finished file"
t1="$(ms)"
[ $((t1 - t0)) -lt 12000 ] && ok || bad "and it lands near the 1 second deadline, not after the 30 second sleep ($((t1 - t0)) ms)"
slow_final=( "$AI_REVIEW_STATE_DIR"/*-"$SHA_SLOW".txt )
slow_body="$(cat "${slow_final[0]:-/dev/null}" 2>/dev/null)"
check "and it records that the review did not finish" "status=timeout" "$slow_body"
check "in its own words" "did not finish inside 1 seconds" "$slow_body"
check_eq "the slow fake was started exactly once" 1 "$(calls)"

# ===========================================================================
# 5. The nudge: shows a finished review once per session, and nothing when there is nothing.
# ===========================================================================
nudge(){ # nudge <session> [cwd]  -> OUT, ERR, RC
  local p
  p="$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$1" "${2:-$REPO}")"
  OUT="$(printf '%s' "$p" | bash "$NUDGE" 2>"$WORKDIR/nudge.err")"; RC=$?
  ERR="$(cat "$WORKDIR/nudge.err")"
}

# Nothing at all: a state directory that does not exist.
OUT="$(printf '{"session_id":"n0","cwd":"%s"}' "$REPO" | AI_REVIEW_STATE_DIR="$WORKDIR/nowhere" bash "$NUDGE" 2>/dev/null)"; RC=$?
check_eq "with no state directory the nudge says nothing" "" "$OUT"
check_eq "and exits 0" 0 "$RC"

nudge n1
check_eq "the nudge exits 0" 0 "$RC"
check "a finished review is shown, headed with the repository" "AI review of repo, branch main at ${SHA_FIX:0:7}" "$OUT"
check "with how long it took" "ran " "$OUT"
check "and the review text" "deleteEvent still throws the raw error" "$OUT"
check "and the review that timed out is reported as unfinished, once" "did not finish inside its deadline" "$OUT"
check "the header says the review is advisory" "advisory" "$OUT"
check_not "the unfinished review carries no review text" "status=timeout" "$OUT"

nudge n1
check_eq "the same session is not shown it twice" "" "$OUT"
check_eq "and the nudge still exits 0" 0 "$RC"

nudge n2
check "a different session is shown the same review" "deleteEvent still throws the raw error" "$OUT"
check "and the unfinished one" "did not finish inside its deadline" "$OUT"
nudge n2
check_eq "and then not again" "" "$OUT"

# A session in a DIFFERENT repository is shown nothing of this one.
OTHER_ORIGIN="$WORKDIR/other.git"; git init -q --bare "$OTHER_ORIGIN"
OTHER="$WORKDIR/other"; git init -q "$OTHER"
git -C "$OTHER" remote add origin "$OTHER_ORIGIN"
printf 'x\n' > "$OTHER/f"; git -C "$OTHER" add f
git -C "$OTHER" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m seed
nudge n3 "$OTHER"
check_eq "a session in another repository is shown nothing" "" "$OUT"

# A pending review whose runner died: reported once as not finished, then never again. The key is
# taken from the shared function the hooks use, never recomputed here (L52).
# shellcheck source=lib/ai-review-common.sh
. "$DIR/lib/ai-review-common.sh"
stale_key="$(ar_repo_key "$REPO")"
stale_sha="0000000000000000000000000000000000000abc"
printf 'repo=repo\nbranch=fix/dead\nsha=%s\nstarted=%s\nmodel=sonnet\ndeadline=240\n' \
  "$stale_sha" "$(( $(date +%s) - 1000 ))" > "$AI_REVIEW_STATE_DIR/$stale_key-$stale_sha.txt.pending"
nudge n1
check "a review pending past its deadline is reported once as never finished" "was started and never finished" "$OUT"
check "naming its branch" "fix/dead" "$OUT"
[ -e "$AI_REVIEW_STATE_DIR/$stale_key-$stale_sha.txt.pending" ] && bad "and the stale pending file is retired" || ok
[ -f "$AI_REVIEW_STATE_DIR/$stale_key-$stale_sha.txt" ] && ok || bad "into a finished file that says so"
nudge n1
check_eq "and is not reported to that session again" "" "$OUT"

# A pending review still INSIDE its deadline is left alone and not mentioned.
fresh_sha="0000000000000000000000000000000000000def"
printf 'repo=repo\nbranch=fix/live\nsha=%s\nstarted=%s\nmodel=sonnet\ndeadline=240\n' \
  "$fresh_sha" "$(date +%s)" > "$AI_REVIEW_STATE_DIR/$stale_key-$fresh_sha.txt.pending"
nudge n1
check_eq "a review still inside its deadline is not mentioned" "" "$OUT"
[ -f "$AI_REVIEW_STATE_DIR/$stale_key-$fresh_sha.txt.pending" ] && ok || bad "and its pending file is left alone"
rm -f "$AI_REVIEW_STATE_DIR/$stale_key-$fresh_sha.txt.pending"

# No session id: it speaks rather than falling silent, and says on stderr why it could not dedupe.
OUT="$(printf '{"cwd":"%s"}' "$REPO" | bash "$NUDGE" 2>"$WORKDIR/nudge.err")"
check "with no session to key on it speaks" "deleteEvent still throws the raw error" "$OUT"
check "and says on stderr that it could not hold itself to once per session" "once per session" "$(cat "$WORKDIR/nudge.err")"

# ===========================================================================
# 6. The cost of the nudge when there is nothing to show, measured and printed (not asserted
# against a fixed number: a fixed bound measures the machine's load, L224).
# ===========================================================================
nudge n1   # settle: everything is shown and nothing is pending
python3 - "$NUDGE" "$REPO" <<'EOF'
import subprocess, sys, time
nudge, repo = sys.argv[1], sys.argv[2]
payload = '{"session_id":"n1","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' % repo
times = []
for _ in range(20):
    t0 = time.perf_counter()
    r = subprocess.run(["bash", nudge], input=payload.encode(), capture_output=True)
    times.append((time.perf_counter() - t0) * 1000)
    if r.stdout:
        print("FAIL: the nudge printed something with nothing to show:", r.stdout.decode()[:200])
        sys.exit(1)
times.sort()
print("nudge cost with nothing to show over 20 runs: median %.1f ms, max %.1f ms" % (times[len(times)//2], times[-1]))
EOF
[ $? -eq 0 ] && ok || bad "the nudge stayed silent across 20 quiet prompts"

# 6b. The nudge's process count does not grow with the number of review files on disk. The state
# directory holds every repository's reviews for 14 days (1,975 files measured 2026-10-03), and the
# full path ran `basename` once per file: on a machine at load 200 each launch cost about 7 ms and
# the hook took 15 to 17 s against its 5 s timeout, so its output was discarded on every prompt.
# Counted rather than timed (L224): every external command the hook could start is shimmed to log
# its name, and the count with 300 unrelated review files must equal the count with none (L63).
# ===========================================================================
SHIMBIN="$WORKDIR/shimbin"; mkdir -p "$SHIMBIN"
export SHIM_LOG="$WORKDIR/shim.log"
REAL_PATH="$PATH"
for c in basename dirname cat date mkdir touch find git cksum cut jq python3 awk rm mv sed grep wc head tail tr sort uniq stat ls; do
  real="$(command -v "$c" 2>/dev/null)" || continue
  printf '#!/bin/sh\nprintf "%%s\\n" %s >> "$SHIM_LOG"\nexec %s "$@"\n' "$c" "$real" > "$SHIMBIN/$c"
  chmod +x "$SHIMBIN/$c"
done
launches(){ # launches -> number of shimmed commands one full path nudge started
  # The fast path is skipped by dating this session's record before the last write, not by sleeping.
  : > "$SHIM_LOG"; touch -t 202001010000 "$AI_REVIEW_STATE_DIR/shown/n1.list"; touch "$AI_REVIEW_STATE_DIR/.updated"
  PATH="$SHIMBIN:$REAL_PATH" nudge n1
  grep -c . "$SHIM_LOG" 2>/dev/null || echo 0
}
nudge n1   # settle
base_launches="$(launches)"
check_eq "a settled full path nudge prints nothing" "" "$OUT"
[ "$base_launches" -gt 0 ] && ok || bad "the shims saw the nudge start something (a zero means the shims are not on its PATH)"
i=0; while [ "$i" -lt 300 ]; do
  printf 'repo=unrelated\nbranch=b\nsha=%040d\nstarted=1\nfinished=2\nstatus=ok\n\nx\n' "$i" > "$AI_REVIEW_STATE_DIR/999-$(printf '%040d' "$i").txt"
  i=$((i + 1))
done
many_launches="$(launches)"
check_eq "300 more review files start no more processes (was $base_launches with none)" "$base_launches" "$many_launches"
rm -f "$AI_REVIEW_STATE_DIR"/999-*.txt

# ===========================================================================
# 7. A push of THREE commits is reviewed from the upstream's previous tip, not one commit short
# (claude-config#441). After a push the upstream is HEAD, so the plain push answer lands on HEAD~1;
# the range comes from ps_pushed_base in the shared library. Its own repository, so nothing above
# is disturbed.
# ===========================================================================
R3_ORIGIN="$WORKDIR/r3.git"; git init -q --bare "$R3_ORIGIN"
R3="$WORKDIR/r3"; git init -q "$R3"
G3(){ git -C "$R3" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
G3 symbolic-ref HEAD refs/heads/main
mkdir -p "$R3/src"; printf 'export const a = 0;\n' > "$R3/src/a.ts"
G3 add src/a.ts; G3 commit -q -m seed
G3 remote add origin "$R3_ORIGIN"; G3 push -q -u origin main 2>/dev/null
R3_BEFORE="$(G3 rev-parse --short HEAD)"
for n in 1 2 3; do printf 'export const a%s = %s;\n' "$n" "$n" >> "$R3/src/a.ts"; G3 add src/a.ts; G3 commit -q -m "c$n"; done
G3 push -q 2>/dev/null
R3_HEAD="$(G3 rev-parse --short HEAD)"
fire_push "git push" 0 "$R3"
check "a three commit push is reviewed from the upstream's previous tip" "($R3_BEFORE..$R3_HEAD," "$OUT"

# ===========================================================================
# 10. Where the push gate's lessons review reads the branch, no second review starts
# (claude-config#1007, L301). pr-review-push-gate.sh holds every push of a branch other than the
# default one for the whole branch review, every file type, on both Macs, so this review of the
# pushed code files would be a second model run over a subset of the same diff. It runs only where
# the gate does not hold the push: the default branch, and a push carrying the gate's override.
# Both halves in ONE repository, with the same fake claude, so the skip cannot pass merely because
# nothing in this fixture could have started a review (L159). Counted as a difference, because the
# sections above leave the call count wherever they left it.
# ===========================================================================
GR_ORIGIN="$WORKDIR/gated.git"; git init -q --bare "$GR_ORIGIN"
GR="$WORKDIR/gated"; git init -q "$GR"
GG(){ git -C "$GR" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
GG symbolic-ref HEAD refs/heads/main
mkdir -p "$GR/src"; printf 'export const g = 0;\n' > "$GR/src/g.ts"
GG add src/g.ts; GG commit -q -m seed
GG remote add origin "$GR_ORIGIN"; GG push -q -u origin main 2>/dev/null
before_gated="$(calls)"

# A branch push: the gate reads it, so nothing starts here, and the skip says so out loud.
GG checkout -q -b feat/covered
printf 'export const covered = 1;\n' > "$GR/src/covered.ts"
GG add src/covered.ts; GG commit -q -m covered
GG push -q -u origin feat/covered 2>/dev/null
SHA_COVERED="$(GG rev-parse HEAD)"
fire_push "git push -u origin feat/covered" 0 "$GR"
check_eq "a branch push the gate reviews exits 0" 0 "$RC"
check "and says the push gate's review reads the branch instead" "skipped: pr-review-push-gate.sh holds this push for the lessons review of the whole branch" "$OUT"
check_not "and starts nothing" "started in the background" "$OUT"
[ -e "$AI_REVIEW_STATE_DIR"/*-"$SHA_COVERED".txt.pending ] && bad "a branch push the gate reviews writes no pending marker" || ok

# The same branch pushed with the gate's override was NOT held for the gate's review, so this one
# still runs: the positive control on a branch, in the same repository.
printf 'export const overridden = 1;\n' > "$GR/src/overridden.ts"
GG add src/overridden.ts; GG commit -q -m overridden
GG push -q 2>/dev/null
SHA_OVERRIDDEN="$(GG rev-parse HEAD)"
fire_push "SKIP_PR_REVIEW=1 git push" 0 "$GR"
check "a branch push carrying SKIP_PR_REVIEW=1 is reviewed here, since the gate did not hold it" "started in the background" "$OUT"
wait_for_final "$SHA_OVERRIDDEN" 20 && ok || bad "and that review finishes"

# A push of the default branch: the gate does not run there, so this review does.
GG checkout -q main
printf 'export const onmain = 1;\n' > "$GR/src/onmain.ts"
GG add src/onmain.ts; GG commit -q -m onmain
GG push -q 2>/dev/null
SHA_ONMAIN="$(GG rev-parse HEAD)"
fire_push "git push" 0 "$GR"
check "a push of the default branch is reviewed here" "started in the background" "$OUT"
wait_for_final "$SHA_ONMAIN" 20 && ok || bad "and that review finishes"

# A push that only deletes a remote branch, made while standing on the default branch, sends no
# commits, so there is nothing for any review to read. The head it stands on is a new commit nobody
# has reviewed, so the skip cannot be the already reviewed one (L159); the positive control is the
# same head then pushed for real, which is reviewed.
printf 'export const afterdelete = 1;\n' > "$GR/src/afterdelete.ts"
GG add src/afterdelete.ts; GG commit -q -m afterdelete
GG push -q 2>/dev/null
GG push -q origin --delete feat/covered 2>/dev/null
SHA_AFTERDELETE="$(GG rev-parse HEAD)"
fire_push "git push origin --delete feat/covered" 0 "$GR"
check "a push that only deletes a branch is skipped, saying it sent no commits" "skipped: the push only deletes, so it sends no commits" "$OUT"
check_not "and starts nothing" "started in the background" "$OUT"
[ -e "$AI_REVIEW_STATE_DIR"/*-"$SHA_AFTERDELETE".txt.pending ] && bad "a delete only push writes no pending marker" || ok
fire_push "git push" 0 "$GR"
check "the control: the same head pushed for real is reviewed" "started in the background" "$OUT"
wait_for_final "$SHA_AFTERDELETE" 20 && ok || bad "and that review finishes"

check_eq "the fake claude was reached by the three pushes that sent commits the gate does not hold, and by nothing else" 3 "$(( $(calls) - before_gated ))"
covered_final=( "$AI_REVIEW_STATE_DIR"/*-"$SHA_COVERED".txt )
[ -e "${covered_final[0]}" ] && bad "and the covered push has no review file of its own" || ok

# One predicate, not two (L261): both hooks ask mt_push_gate_scope, and neither judges the default
# branch, a delete or the override for itself, so they cannot drift apart about which pushes the
# gate holds. Read from code lines only, because a comment naming a function is not a call (L135).
for hook in ai-review-on-push.sh pr-review-push-gate.sh; do
  hook_code="$(grep -v '^[[:space:]]*#' "$DIR/$hook")"
  case "$hook_code" in *'mt_push_gate_scope "'*) ok ;; *) bad "$hook asks mt_push_gate_scope which pushes the gate holds" ;; esac
  case "$hook_code" in *ps_on_default_branch*) bad "$hook judges the default branch itself rather than through mt_push_gate_scope" ;; *) ok ;; esac
done

# ===========================================================================
# 6. The reader the background reviewer runs under.
# ===========================================================================
# LAST in the suite on purpose: the control below starts a real review, and several cases above
# assert an ABSOLUTE count of how many the fake `claude` has been asked for.
# No python3 on PATH (claude-config#486). The runner this hook starts, lib/ai-review-run.py, is a
# python3 program. With no python3 the `nohup python3 ...` died at once and the line straight after
# it said the review had started in the background, which is a claim about something that never
# ran (L12, L11). The fake `claude` IS linked in, so what is missing is only the interpreter.
. "$DIR/lib/no-python-path.sh"
NOPY="$WORKDIR/nopy/bin"
npp_build_bin "$NOPY" jq
ln -s "$FAKEBIN/claude" "$NOPY/claude" 2>/dev/null
if npp_reaches_python3 "$NOPY"; then
  bad "the bare directory really reaches no python3: it found one, so nothing below measures its absence"
else ok; fi
printf 'export const nopy = 1;\n' > "$REPO/src/nopy.ts"
G add src/nopy.ts; G commit -q -m nopy
G push -q origin main 2>/dev/null
before_nopy="$(calls)"
OUT="$(payload "git push origin main" 0 "$REPO" s1 | env PATH="$NOPY" "$NOPY/bash" "$PUSH_HOOK" 2>&1)"; RC=$?
check "with no python3 the skip names the reader that is missing" "python3" "$OUT"
check_not "and never claims a review started" "started in the background" "$OUT"
check_eq "and exits 0, because this hook never blocks a push" 0 "$RC"
check_eq "and starts nothing" "$before_nopy" "$(calls)"
# The control: the same push with python3 present really does start one, so the case above is the
# interpreter's absence and not a branch that skips everything (L159).
SHA_NOPY="$(G rev-parse HEAD)"
fire_push "git push origin main" 0
check "the control still starts a review for the same push with python3 present" "started in the background" "$OUT"
# Waited for, so the review this suite started is finished before the scratch directory it writes
# into is removed. A detached child still writing while its parent's trap deletes the tree leaves
# both the directory and the process behind (claude-config#465).
wait_for_final "$SHA_NOPY" 20 && ok || bad "and that control review finishes"

# ===========================================================================
# 8. A review that could not find the lessons says so in its own answer (claude-config#539).
# Running on without them silently would read as a review that applied them and found nothing.
# ===========================================================================
printf 'export const n = 1;\n' > "$REPO/src/nolessons.ts"
G add src/nolessons.ts; G commit -q -m nolessons
G push -q origin main 2>/dev/null
SHA_NOLESSONS="$(G rev-parse HEAD)"
mkdir -p "$WORKDIR/no-lessons-here"
AI_REVIEW_LESSONS_DIR="$WORKDIR/no-lessons-here" fire_push "git push origin main" 0
wait_for_final "$SHA_NOLESSONS" 20 && ok || bad "the review with no lessons still finishes"
nolessons_final=( "$AI_REVIEW_STATE_DIR"/*-"$SHA_NOLESSONS".txt )
nolessons_body="$(cat "${nolessons_final[0]:-/dev/null}" 2>/dev/null)"
check "and its answer says it ran without the lessons" "ran without the lessons index: no LESSONS-INDEX-*.md in" "$nolessons_body"
# Matched on the folder's own name, because TMPDIR ends in a slash on macOS and the runner prints
# the path normalised.
check "naming where it looked" "/no-lessons-here, so no recorded lesson" "$nolessons_body"
check "while still carrying the review itself" "deleteEvent still throws" "$nolessons_body"
# ===========================================================================
# 9. The reviewer is told which files the push changed, and a finding that says a changed file was
# NOT changed is marked false (claude-config#533). On bidspoke 39cb11b the review said, at critical
# severity, that the push held no change to .github/workflows/deploy.yml. It did: the review is sent
# code files only, and its prompt called that diff everything the push added, so a filtered out
# file read as an unchanged one.
# ===========================================================================
mkdir -p "$REPO/.github/workflows"
printf 'export const wired = true;\n' > "$REPO/src/wiring.ts"
printf 'on: push\njobs: {}\n' > "$REPO/.github/workflows/deploy.yml"
G add src/wiring.ts .github/workflows/deploy.yml; G commit -q -m wiring
G push -q origin main 2>/dev/null
SHA_WIRE="$(G rev-parse HEAD)"
: > "$FAKE_LOG/stdin"
FAKE_CLAUDE_OUT='src/wiring.ts:1: The tests expect deploy.yml to call the hash script, but the diff contains no change to `.github/workflows/deploy.yml` to add this wiring. Should be: update .github/workflows/deploy.yml in this push. [severity: critical]
src/wiring.ts:1: wired is exported but never read. Should be: read it or remove it. [severity: minor]' \
  fire_push "git push origin main" 0
wait_for_final "$SHA_WIRE" 20 && ok || bad "the workflow review finishes"
wire_stdin="$(cat "$FAKE_LOG/stdin")"
check "the reviewer is given the complete list of changed files" "===== FILES THIS PUSH CHANGED" "$wire_stdin"
check "which names the workflow file it is not shown" ".github/workflows/deploy.yml	(changed, not shown" "$wire_stdin"
check "and the code file it is shown" "src/wiring.ts	(changed, shown below)" "$wire_stdin"
args_blob="$(tr '\036' '\n' < "$FAKE_LOG/args")"
check_not "the prompt no longer calls the code diff everything the push added" "It is everything one push added" "$args_blob"
check "the prompt says the file list is complete" "That list is complete" "$args_blob"
wire_final=( "$AI_REVIEW_STATE_DIR"/*-"$SHA_WIRE".txt )
wire_body="$(cat "${wire_final[0]:-/dev/null}" 2>/dev/null)"
check "the finding that calls a changed file unchanged is marked false" "IS in this push" "$wire_body"
check "and the mark names the file" "harness: .github/workflows/deploy.yml IS in this push" "$wire_body"
minor_line="$(printf '%s\n' "$wire_body" | grep 'never read')"
check_not "an ordinary finding beside it is not marked" "IS in this push" "$minor_line"
check "and the answer says how many findings were marked" "1 finding below" "$wire_body"

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
