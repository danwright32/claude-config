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
# upstream reflog the hook reads is the one git actually writes.
set -uo pipefail

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
G checkout -q -b fix/typed-error
python3 - "$REPO/src/calendar.ts" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("return await api.create(id);\n  } catch (e) {\n    throw e;", "return await api.create(id);\n  } catch (e) {\n    throw new CalendarError(e);", 1)
open(p, "w").write(s)
EOF
G add src/calendar.ts
G commit -q -m "typed error on create"
G push -q -u origin fix/typed-error 2>/dev/null
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
FAKE_CLAUDE_SLEEP=2 fire_push "git push -u origin fix/typed-error" 0
check_eq "the push hook exits 0" 0 "$RC"
check "and says the review started" "started in the background" "$OUT"
check "naming the model it used" "with sonnet" "$OUT"
[ "$ELAPSED" -lt 2000 ] && ok || bad "the hook returned in ${ELAPSED} ms, which is not within 2 seconds of a push that takes a 2 second review"

pending_now=( "$AI_REVIEW_STATE_DIR"/*-"$SHA_FIX".txt.pending )
[ -f "${pending_now[0]:-}" ] && ok || bad "a .pending file exists while the review runs"
pending_body="$(cat "${pending_now[0]:-/dev/null}" 2>/dev/null)"
check "and it carries the start time" "started=" "$pending_body"
check "and the branch" "branch=fix/typed-error" "$pending_body"

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
check "the prompt asks about a sibling not changed the same way" "sibling of a changed function that was not changed the same way" "$args_blob"
check "and about a class fix that missed a site" "class fix that missed one of its sites" "$args_blob"
check "and keeps the no issues line" "No issues found." "$args_blob"
stdin_blob="$(cat "$FAKE_LOG/stdin")"
check "the diff of the push went to claude on stdin" "+    throw new CalendarError(e);" "$stdin_blob"
check "as a diff of the code file" "src/calendar.ts" "$stdin_blob"
# The sibling the review exists to catch is NOT in the diff, so the changed file's full text must
# follow it: the first real run answered "No issues found." on this exact fixture because it was
# handed the diff alone and deleteEvent was never in front of it.
check "followed by the full text of the changed file" "===== FULL FILE at ${SHA_FIX:0:7}: src/calendar.ts" "$stdin_blob"
check "so the unchanged sibling is in front of the reviewer" "export async function deleteEvent" "$stdin_blob"
check "and the start line says what was sent" "diff plus the full text of 1 of 1 changed files" "$OUT"

# The same sha pushed again (a retry) is not reviewed twice.
fire_push "git push origin fix/typed-error" 0
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
G checkout -q -b fix/refused
printf 'export const x = 1;\n' > "$REPO/src/x.ts"
G add src/x.ts; G commit -q -m x
fire_push "git push -u origin fix/refused" 1
check "a push that failed is skipped out loud" "did not succeed (exit 1)" "$OUT"
check_eq "and starts nothing" 1 "$(calls)"

# A payload whose tool_response cannot say goes ahead (a review of a push that did happen is worth
# more than silence over one that might not have). This branch IS pushed, for real, first. It also
# drives the diff-alone switch, so the full file section is proved to be off when asked.
G push -q -u origin fix/refused 2>/dev/null
SHA_REFUSED="$(G rev-parse HEAD)"
AI_REVIEW_FULL_FILES=0 fire_push "git push -u origin fix/refused" none
check "a payload that cannot say whether the push succeeded goes ahead" "started in the background" "$OUT"
check "and with AI_REVIEW_FULL_FILES=0 the start line says the diff went alone" "diff alone" "$OUT"
wait_for_final "$SHA_REFUSED" 20 && ok || bad "and that review finishes"
check_eq "starting one more review" 2 "$(calls)"
check_not "and no full file section was sent" "===== FULL FILE" "$(cat "$FAKE_LOG/stdin")"
check "while the diff itself was" "+export const x = 1;" "$(cat "$FAKE_LOG/stdin")"

# ===========================================================================
# 3. Skips, each out loud.
# ===========================================================================
G checkout -q main
G checkout -q -b docs/only
printf '\nmore\n' >> "$REPO/README.md"
G add README.md; G commit -q -m docs
G push -q -u origin docs/only 2>/dev/null
SHA_DOCS="$(G rev-parse HEAD)"
fire_push "git push -u origin docs/only" 0
check "an empty code diff is skipped and says so" "changed no code files" "$OUT"
check_eq "and exits 0" 0 "$RC"
check_eq "and starts nothing" 2 "$(calls)"
[ -e "$AI_REVIEW_STATE_DIR"/*-"$SHA_DOCS".txt.pending ] && bad "and leaves no pending file" || ok

# Over the size cap, at the DEFAULT cap, so the number in the header is the one exercised.
G checkout -q main
G checkout -q -b feat/huge
python3 -c '
import sys
with open(sys.argv[1], "w") as f:
    for i in range(12000):
        f.write(f"export const generatedValue{i} = {i};\n")
' "$REPO/src/huge.ts"
G add src/huge.ts; G commit -q -m huge
G push -q -u origin feat/huge 2>/dev/null
fire_push "git push -u origin feat/huge" 0
check "a diff over the cap is skipped and says the size and the cap" "over the 300 KB cap" "$OUT"
check_eq "and starts nothing" 2 "$(calls)"

# No claude on PATH. The tools the hook needs are linked into a bare directory so nothing else on
# this machine's PATH can answer for `claude`.
NOBIN="$WORKDIR/nobin"; mkdir -p "$NOBIN"
for t in bash git python3 jq shasum cut sed awk basename dirname cat tr wc date nohup env mkdir rm touch mv find head grep; do
  p="$(command -v "$t" 2>/dev/null)"; [ -n "$p" ] && [ "$p" != "$FAKEBIN/$t" ] && ln -s "$p" "$NOBIN/$t" 2>/dev/null
done
G checkout -q fix/typed-error
OUT="$(payload "git push -u origin fix/typed-error" 0 "$REPO" s1 | env PATH="$NOBIN" bash "$PUSH_HOOK" 2>&1)"; RC=$?
check "with no claude on PATH the skip says so" "no 'claude' command is on PATH" "$OUT"
check_eq "and exits 0" 0 "$RC"
check_eq "and starts nothing" 2 "$(calls)"

OUT="$(payload "git push" 0 "$REPO" s1 | CLAUDE_DETACHED_RUN=1 bash "$PUSH_HOOK" 2>&1)"
check "a detached run is skipped and says so" "detached run" "$OUT"

fire_push "SKIP_AI_REVIEW_CHECK=1 git push" 0
check "the escape hatch skips and names itself" "SKIP_AI_REVIEW_CHECK=1" "$OUT"
check "and tells the reader to explain to Dan" "Tell Dan" "$OUT"
check_eq "and none of those started anything" 2 "$(calls)"

# ===========================================================================
# 4. The deadline: a review that does not return is recorded as unfinished, and the fake is killed.
# ===========================================================================
G checkout -q main
G checkout -q -b fix/slow
printf 'export const slow = true;\n' > "$REPO/src/slow.ts"
G add src/slow.ts; G commit -q -m slow
G push -q -u origin fix/slow 2>/dev/null
SHA_SLOW="$(G rev-parse HEAD)"
: > "$FAKE_LOG/calls"
AI_REVIEW_DEADLINE_SECONDS=1 FAKE_CLAUDE_SLEEP=30 fire_push "git push -u origin fix/slow" 0
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
check "a finished review is shown, headed with the repository" "AI review of repo, branch fix/typed-error at ${SHA_FIX:0:7}" "$OUT"
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

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
