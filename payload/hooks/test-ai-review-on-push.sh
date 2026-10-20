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

# The sessions the nudge cases below speak as, begun HERE, before any push, as a real session's first
# prompt comes before the reviews of its own pushes (claude-config#1216): a session is shown the
# reviews that finish during it, and those finished before it began are recorded as a baseline and
# not replayed. Begun with the state folder not yet there, which is the case of a first prompt with
# nothing to baseline.
for s in n1 n2 n3 p30 p300 killed; do
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$s" "$REPO" | bash "$NUDGE" >/dev/null 2>&1
done
[ -f "$AI_REVIEW_STATE_DIR/shown/n1.list" ] && ok || bad "a session's first prompt with nothing to baseline still records an empty list"

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
# No skills either (hook trim, 2026-10-15): the reviewer invokes none, and the skills list is sent on
# every request of the run otherwise.
python3 - "$FAKE_LOG/args" <<'EOF' && ok || bad "the reviewer starts with no skills: --disable-slash-commands exactly once"
import sys
args = open(sys.argv[1], encoding="utf-8").read().split("\x1e")
sys.exit(0 if args.count("--disable-slash-commands") == 1 else 1)
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

# A pending review of ANOTHER repository past its deadline (claude-config#1095). Every session's
# fast path is off while any pending marker exists, and a session settled only its own repository's,
# so one dead review kept the sessions of every other repository on the full path until a session
# of its own prompted. Any session settles it now, and only its own repository's sessions are told.
other_key="$(ar_repo_key "$OTHER")"
other_sha="0000000000000000000000000000000000000fed"
other_pending="$AI_REVIEW_STATE_DIR/$other_key-$other_sha.txt.pending"
printf 'repo=other\nbranch=fix/elsewhere\nsha=%s\nstarted=%s\nmodel=sonnet\ndeadline=240\n' \
  "$other_sha" "$(( $(date +%s) - 1000 ))" > "$other_pending"
nudge n1
check_eq "another repository's dead review is not shown to this repository's session" "" "$OUT"
[ -e "$other_pending" ] && bad "but it is settled, so it no longer holds every session off the fast path" || ok
[ -f "${other_pending%.pending}" ] && ok || bad "into a finished file saying so"
nudge n3 "$OTHER"
check "a session in that repository is told it never finished" "was started and never finished" "$OUT"
check "naming its branch" "fix/elsewhere" "$OUT"
# Still inside its deadline, another repository's review is left running.
printf 'repo=other\nbranch=fix/elsewhere\nsha=%s\nstarted=%s\nmodel=sonnet\ndeadline=240\n' \
  "$other_sha" "$(date +%s)" > "$other_pending"
rm -f "${other_pending%.pending}"
nudge n1
[ -f "$other_pending" ] && ok || bad "another repository's review inside its deadline is left alone"
rm -f "$other_pending"
# A marker with no start time to judge it by is judged by when it was written, so a damaged one
# (a write cut short on a full disk) cannot hold every session off the fast path for ever.
damaged_pending="$AI_REVIEW_STATE_DIR/$other_key-0000000000000000000000000000000000000dad.txt.pending"
printf 'repo=other\nbranch=fix/damaged\n' > "$damaged_pending"
touch -t 202001010000 "$damaged_pending"
nudge n1
[ -e "$damaged_pending" ] && bad "a marker with no start time, written long ago, is settled" || ok
nudge n3 "$OTHER"
check "and reported in its repository as never finished" "fix/damaged" "$OUT"
printf 'repo=other\nbranch=fix/damaged\n' > "$damaged_pending"
nudge n1
[ -f "$damaged_pending" ] && ok || bad "while one with no start time written just now is left alone"
rm -f "$damaged_pending" "${damaged_pending%.pending}"
# Written in the SAME second as the session last looked. bash 3.2's -nt compares whole seconds, so
# the fast path's "nothing written since" read a write in that second as older and hid it until
# some later write; which way a run fell depended on the clock (found by the tests above, #1095).
same_sec="$AI_REVIEW_STATE_DIR/$stale_key-0000000000000000000000000000000000000555.txt"
printf 'repo=repo\nbranch=fix/same-second\nsha=0000000000000000000000000000000000000555\nstarted=1\nfinished=2\nstatus=ok\n\nsrc/a.ts:1: written in the same second. Should be: shown.\n' > "$same_sec"
touch -t 202501010000.00 "$AI_REVIEW_STATE_DIR/shown/n1.list" "$AI_REVIEW_STATE_DIR/.updated"
nudge n1
check "a review written in the same second the session last looked is still shown" "written in the same second" "$OUT"
rm -f "$same_sec"

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

# 6c. The same count where the per file work really was: unshown reviews of the session's OWN
# repository (claude-config#1090). 6b's files belong to another repository, which the name filter
# drops before any work, so it never saw that a fresh session walked every review of its own
# repository from the last 14 days (1,200 for claude-config on 2026-10-12), running read_meta, the
# capped body and the left out note for each before the output budget decided to hold it: 9.7 to
# 10 s against the hook's 5 s timeout, on the first prompt of every new session. Both kinds:
#   - a whole branch lessons review (kind=pr, named <key>-pr-<sha>.txt) is not the nudge's to show
#     any more (Dan, 2026-10-12). The merge gate shows its findings and issues their read key, so
#     300 of them must start exactly what none do, and print nothing.
#   - a push review is shown while it fits the budget and held after, and a held one costs nothing
#     until a prompt shows it, so 300 start exactly what 30 do (both well past the budget).
# ===========================================================================
count_launches(){ # count_launches <session> -> LAUNCHES (commands one full path nudge started), OUT
  : > "$SHIM_LOG"
  [ -f "$AI_REVIEW_STATE_DIR/shown/$1.list" ] && touch -t 202001010000 "$AI_REVIEW_STATE_DIR/shown/$1.list"
  touch "$AI_REVIEW_STATE_DIR/.updated"
  PATH="$SHIMBIN:$REAL_PATH" nudge "$1"
  LAUNCHES="$(grep -c . "$SHIM_LOG")"
}
own_key="$stale_key"
own_review(){ # own_review <kind: pr or push> <n> -> one finished review of this repository
  local sha name l
  sha="$(printf '%040d' "$2")"
  name="$own_key-$sha.txt"; [ "$1" = pr ] && name="$own_key-pr-$sha.txt"
  {
    printf 'repo=repo\nbranch=feat/b%s\nsha=%s\nstarted=1\nfinished=2\nstatus=ok\n' "$2" "$sha"
    [ "$1" = pr ] && printf 'kind=pr\nfindings=5\n'
    printf '\n'
    for l in 1 2 3 4 5; do printf 'src/calendar.ts:%s: own review %s finding %s, long enough to weigh on the output budget the way a real finding line does. Should be: fixed.\n' "$l" "$2" "$l"; done
  } > "$AI_REVIEW_STATE_DIR/$name"
  [ "$1" = pr ] && printf '100\tscripts/fixtures/x.json\tfixture\tfixture data\n' > "$AI_REVIEW_STATE_DIR/$name.leftout"
  return 0
}
nudge n1   # settle
count_launches n1; own_base="$LAUNCHES"
i=0; while [ "$i" -lt 300 ]; do own_review pr "$i"; i=$((i + 1)); done
count_launches n1
check_eq "300 unshown whole branch reviews of this repository start no more processes (was $own_base with none)" "$own_base" "$LAUNCHES"
check_eq "and none of them is shown, since the merge gate shows them with their read key" "" "$OUT"
rm -f "$AI_REVIEW_STATE_DIR/$own_key"-pr-*

i=0; while [ "$i" -lt 30 ]; do own_review push "$i"; i=$((i + 1)); done
count_launches p30; push30="$LAUNCHES"
check "30 unshown push reviews of this repository: the first is shown" "own review 0 finding 1" "$OUT"
check "and those past the budget are held, saying so" "not shown" "$OUT"
while [ "$i" -lt 300 ]; do own_review push "$i"; i=$((i + 1)); done
count_launches p300
check_eq "300 unshown push reviews of this repository start no more processes than 30 do ($push30)" "$push30" "$LAUNCHES"
[ "${#OUT}" -lt 10000 ] && ok || bad "and the output stays under the 10,000 character hook cap (was ${#OUT})"
first_shown="$OUT"
# The held ones are shown on the next prompt, as the line above promises, and not again after.
nudge p300
check "a review held back is shown on the next prompt" "own review" "$OUT"
check_not "and the next prompt does not repeat what the first showed" "$(printf '%s\n' "$first_shown" | grep -m1 -o 'own review [0-9]* finding 1')," "$OUT,"

# 6d. A review is marked shown only once its text is out (claude-config#1090). When the platform
# kills the hook at its timeout it throws the output away, so a review recorded as shown before
# the hook finished was never seen and never shown again. Killed after printing, from inside the
# housekeeping sweep the hook runs once it has printed: a find that kills the hook that started it.
KILLBIN="$WORKDIR/killbin"; mkdir -p "$KILLBIN"
printf '#!/bin/sh\nkill -9 "$PPID"\nexit 0\n' > "$KILLBIN/find"; chmod +x "$KILLBIN/find"
PATH="$KILLBIN:$REAL_PATH" nudge killed
check "the killed nudge had printed a review before it was stopped" "own review" "$OUT"
[ "$RC" -ne 0 ] && ok || bad "and it really was killed (exit $RC), or the case proves nothing"
killed_listed="$(cat "$AI_REVIEW_STATE_DIR/shown/killed.list" 2>/dev/null)"
check_eq "a nudge killed after printing records nothing as shown" "" "$killed_listed"
nudge killed
check "so the next prompt shows those reviews again" "own review 0 finding 1" "$OUT"

# 6e. Per session records are swept with the reviews (claude-config#1090): one shown/<session>.list
# per session ever started, 2,380 on 2026-10-12 and 404 of them past 14 days. Another session's
# old record goes; a recent one, and this session's own however old, stay.
touch -t 202001010000 "$AI_REVIEW_STATE_DIR/shown/n1.list"
printf 'x\n' > "$AI_REVIEW_STATE_DIR/shown/gone.list"; touch -t 202001010000 "$AI_REVIEW_STATE_DIR/shown/gone.list"
: > "$AI_REVIEW_STATE_DIR/shown/gone.held"; touch -t 202001010000 "$AI_REVIEW_STATE_DIR/shown/gone.held"
printf 'x\n' > "$AI_REVIEW_STATE_DIR/shown/recent.list"
touch "$AI_REVIEW_STATE_DIR/.updated"
nudge n1
[ -e "$AI_REVIEW_STATE_DIR/shown/gone.list" ] && bad "a session record older than 14 days is swept" || ok
[ -e "$AI_REVIEW_STATE_DIR/shown/gone.held" ] && bad "and so is its held marker" || ok
[ -s "$AI_REVIEW_STATE_DIR/shown/recent.list" ] && ok || bad "a recent session record is kept"
[ -s "$AI_REVIEW_STATE_DIR/shown/n1.list" ] && ok || bad "and this session's own record is kept, however old"
rm -f "$AI_REVIEW_STATE_DIR/$own_key"-0000000000*.txt

# 6f. A new session is shown the reviews that finish during it, never the last 14 days of them
# (claude-config#1216). Seen live in a Slate session on 2026-10-15: about 650 earlier reviews, mostly
# background agents' pushes from other sessions, printed 8,000 characters at a time on every prompt
# for dozens of prompts. Its first look records them as a baseline and says so in one line.
# How many finished push reviews of this repository the folder holds, counted here by listing it,
# not through the hook's own filter, so the two can disagree (L721).
own_finished(){ ls "$AI_REVIEW_STATE_DIR" | grep -c "^$own_key-[0-9a-f]*\.txt\$"; }
i=900; while [ "$i" -lt 903 ]; do own_review push "$i"; i=$((i + 1)); done
touch "$AI_REVIEW_STATE_DIR/.updated"
earlier="$(own_finished)"
[ "$earlier" -ge 3 ] && ok || bad "the folder holds the 3 reviews just written (it holds $earlier)"
nudge fresh1
check "a new session's first prompt says how many earlier reviews it left out" "$earlier review(s) of this repository finished before this session began" "$OUT"
check "and where they are" "$AI_REVIEW_STATE_DIR" "$OUT"
check_not "and shows none of them" "own review 90" "$OUT"
check_eq "in one line" 1 "$(printf '%s\n' "$OUT" | grep -c .)"
check_eq "and exits 0" 0 "$RC"
nudge fresh1
check_eq "the next prompt says nothing more about them" "" "$OUT"
own_review push 903; touch "$AI_REVIEW_STATE_DIR/.updated"
nudge fresh1
check "a review finished after the first look is shown" "own review 903 finding 1" "$OUT"
check_not "and the earlier ones still are not" "own review 900" "$OUT"
# A review still running at the first look is not part of the baseline: shown once it finishes.
run_sha="$(printf '%040d' 904)"
printf 'repo=repo\nbranch=feat/b904\nsha=%s\nstarted=%s\nmodel=sonnet\ndeadline=240\n' "$run_sha" "$(date +%s)" > "$AI_REVIEW_STATE_DIR/$own_key-$run_sha.txt.pending"
nudge fresh2
check_not "a review still running at a session's first look is not shown yet" "own review 904" "$OUT"
rm -f "$AI_REVIEW_STATE_DIR/$own_key-$run_sha.txt.pending"; own_review push 904; touch "$AI_REVIEW_STATE_DIR/.updated"
nudge fresh2
check "and is shown when it finishes" "own review 904 finding 1" "$OUT"
# One the hook itself settles at that first look (its runner died) finished during the session too.
dead_sha="$(printf '%040d' 905)"
printf 'repo=repo\nbranch=feat/dead905\nsha=%s\nstarted=%s\nmodel=sonnet\ndeadline=240\n' "$dead_sha" "$(( $(date +%s) - 1000 ))" > "$AI_REVIEW_STATE_DIR/$own_key-$dead_sha.txt.pending"
nudge fresh3
check "a dead review settled at a session's first look is reported to it" "feat/dead905" "$OUT"
# Only this repository's reviews make the baseline: another repository's session still sees its own.
other_new="$AI_REVIEW_STATE_DIR/$other_key-0000000000000000000000000000000000000906.txt"
printf 'repo=other\nbranch=fix/other906\nsha=0000000000000000000000000000000000000906\nstarted=1\nfinished=2\nstatus=ok\n\nsrc/o.ts:1: the other repository finding. Should be: shown.\n' > "$other_new"
touch "$AI_REVIEW_STATE_DIR/.updated"
nudge fresh4
check_not "a new session's baseline holds only its own repository's reviews" "other repository finding" "$OUT"
nudge n3 "$OTHER"
check "so a session in the other repository is still shown that repository's review" "the other repository finding" "$OUT"
rm -f "$other_new"
# A first look killed before it finished records no baseline, so the next prompt takes it again.
PATH="$KILLBIN:$REAL_PATH" nudge fresh5
[ "$RC" -ne 0 ] && ok || bad "the first look really was killed (exit $RC), or the case proves nothing"
[ -e "$AI_REVIEW_STATE_DIR/shown/fresh5.list" ] && bad "a first look killed before it finished records no baseline" || ok
nudge fresh5
check "so the next prompt takes the baseline again" "review(s) of this repository finished before this session began" "$OUT"
check_not "still showing none of them" "own review 90" "$OUT"
# With nothing of its repository to baseline it says nothing, and still records its list.
nudge fresh6 "$OTHER"
check_eq "a first look with nothing of its repository to baseline says nothing" "" "$OUT"
[ -f "$AI_REVIEW_STATE_DIR/shown/fresh6.list" ] && ok || bad "and records its list all the same"
# On a computer where no review ever runs, a first look with nothing to baseline is the only pass
# that writes a session record, so it also sweeps other sessions' records past 14 days, as the full
# path does, or one empty list per session would pile up for ever.
EMPTY_STATE="$WORKDIR/empty-state"; mkdir -p "$EMPTY_STATE/shown"
: > "$EMPTY_STATE/shown/old.list"; touch -t 202001010000 "$EMPTY_STATE/shown/old.list"
: > "$EMPTY_STATE/shown/recent.list"
OUT="$(printf '{"session_id":"e1","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | AI_REVIEW_STATE_DIR="$EMPTY_STATE" bash "$NUDGE" 2>/dev/null)"
check_eq "a first look in a state folder holding no review prints nothing" "" "$OUT"
[ -f "$EMPTY_STATE/shown/e1.list" ] && ok || bad "and records its list"
[ -e "$EMPTY_STATE/shown/old.list" ] && bad "and sweeps another session's record older than 14 days" || ok
[ -e "$EMPTY_STATE/shown/recent.list" ] && ok || bad "while a recent one is kept"
# The baseline pass starts no process per review: 300 earlier reviews cost what 30 do.
rm -f "$AI_REVIEW_STATE_DIR/$own_key"-0000000000*.txt
i=0; while [ "$i" -lt 30 ]; do own_review push "$i"; i=$((i + 1)); done
earlier="$(own_finished)"
count_launches fresh30; base30="$LAUNCHES"
check "a first look over 30 earlier reviews says so" "$earlier review(s) of this repository" "$OUT"
while [ "$i" -lt 300 ]; do own_review push "$i"; i=$((i + 1)); done
earlier="$(own_finished)"
count_launches fresh300
check "and over 300" "$earlier review(s) of this repository" "$OUT"
check_eq "300 earlier reviews start no more processes at a first look than 30 do ($base30)" "$base30" "$LAUNCHES"
rm -f "$AI_REVIEW_STATE_DIR/$own_key"-0000000000*.txt

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
# Section 7's review runs detached and is not waited for there, so its call to the fake can land
# AFTER this baseline is read, and did on CI (4 calls counted where 3 were made here). Waited for
# first, so the difference below counts this section's pushes and nothing else (L134).
wait_for_final "$(G3 rev-parse HEAD)" 20 && ok || bad "section 7's review finishes before this section counts calls"
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

# ===========================================================================
# 11. The premise mark is for a claim about a WHOLE FILE, never a symbol or part inside one
# (claude-config#1354). The mark of section 9 was set by any absence wording anywhere in a finding
# plus any listed path anywhere in it, and every finding starts with its own path, which a review
# of a push is almost always reading because the push changed it. So "`pickerVendors` was not
# updated like the other call sites" was called false. Measured 2026-10-19 on the personal
# MacBook: 11 distinct marked findings (10 in ~/.claude/state/ai-review, 1 more only in a session
# transcript), and every mark was wrong. 10 matched only on the finding's own location; the 11th
# named a file in the list but claimed a ROW in it was not updated. The two that do claim a whole
# file was left out named files the push really had not changed, so they were true.
#
# Dan's decision (2026-10-19): a finding naming a symbol or part inside a listed changed file is
# left unmarked, and only a finding claiming a whole file was left out of the push is marked.
#
# Each fixture keeps the sentence shape of a real marked finding, with its identifiers and paths
# invented, since several came from other repositories (L155). The function is called directly,
# because the end to end run of section 9 can carry one answer per push and these are many.
# ===========================================================================
RUNNER="$DIR/lib/ai-review-run.py"
premise_out="$(python3 - "$RUNNER" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ai_review_run", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

S = " Should be: fix it. [severity: major]"
# (name, finding, changed paths, should it be marked)
cases = [
    # Symbols and parts inside a listed file: the shapes of the real marked findings. None is marked.
    ("a symbol not updated like its siblings",
     "src/billing/ledger.ts:52: `vendorPicker` was not updated like the other call sites in src/billing/ledger.ts." + S,
     ["src/billing/ledger.ts"], False),
    ("a header comment not updated",
     "src/app/orders/page.tsx:12: the header comment was not updated for #3641, so it still names the old route." + S,
     ["src/app/orders/page.tsx"], False),
    ("a block in a plan doc not updated for a fix in a listed file",
     "docs/plans/2026-01-01-widget.md:300: Task 1's `readPrefs` block and its tests were not updated for the newest wins fix shipped in `src/lib/prefs/store.ts`. The plan still has `if (saved) return saved;`." + S,
     ["docs/plans/2026-01-01-widget.md", "src/lib/prefs/store.ts"], False),
    ("a test suite not updated to a reworded message, named by its basename",
     "tools/entry-check.sh:116: The message no longer contains `INDEX.md`, but `test-entry-check.sh` still asserts it. That check now fails, and the suite was not updated to match the reworded message." + S,
     ["tools/entry-check.sh", "tools/test-entry-check.sh"], False),
    ("the text of a function not changed",
     "lib/review-gate.sh:1131: The comments here say the refusal asks for a quoted answer. The refusal text in `do_check` was not changed. It still only says to comment." + S,
     ["lib/review-gate.sh"], False),
    ("a range of lines not changed since it was first raised",
     "lib/night-queue.sh:206: When every goal fails to read, `goal` stays empty and the refusal blames a goal that was named. Lines 203 to 209 have not changed since this was first raised." + S,
     ["lib/night-queue.sh"], False),
    ("the same, in a TypeScript file",
     "mods/night/driver.ts:394: `decideFailure` has no no goal check, though `decideStop` now stops a worker with no goal. Lines 391 to 397 have not changed since this was first raised." + S,
     ["mods/night/driver.ts"], False),
    ("not in the push SEGMENT, which is no absence claim at all",
     "hooks/push-gate.sh:83: The delete exemption matches `-d` anywhere in the whole command, not in the push segment, so `rm -d dir && git push origin feat` skips the gate." + S,
     ["hooks/push-gate.sh"], False),
    ("a sentence in a listed doc not updated",
     "mods/kit/types/index.d.ts:63: The rest of the docs were not updated for the new `tray` slot. `docs/mods-look.md` still states the settled order with no `tray`." + S,
     ["mods/kit/types/index.d.ts", "docs/mods-look.md"], False),
    ("a row in a listed table not updated",
     "scripts/test-plan.sh:187: The suite opens `scripts/notify.sh` from a non comment line. The `notify.sh` row in `scripts/lib/roles.tsv` lists its callers and was not updated to include this suite." + S,
     ["scripts/test-plan.sh", "scripts/lib/roles.tsv"], False),
    ("an array in a listed test file not updated to include new cases",
     "Tests/SignInTests/AuthManagerTests.swift:445: The `all` array in `noMessageNamesAnyApp` was not updated to include the new `.grantMissing` and `.scopesRefused(...)` cases, so their error text is never checked." + S,
     ["Tests/SignInTests/AuthManagerTests.swift"], False),
    # Raised by the lessons review of this change: a listed file as the subject, with the clause
    # going on to say WHAT in it was not updated, is a part too.
    ("a listed doc not updated to mention a new flag",
     "src/cli.ts:40: the new `--quiet` flag is parsed here, but `docs/guide.md` was not updated to mention the new flag." + S,
     ["src/cli.ts", "docs/guide.md"], False),
    ("a listed file not updated for an issue",
     "src/a.ts:9: src/app/page.tsx was not updated for #3641, so its header still names the old route." + S,
     ["src/a.ts", "src/app/page.tsx"], False),
    ("a possessive: a part of the file, however the clause reads",
     "src/a.ts:1: the diff contains no change to `src/config.ts`'s `retryLimit`, which the new caller needs." + S,
     ["src/a.ts", "src/config.ts"], False),

    # Whole file claims about a file the list names: these premises are false, so each is marked.
    ("the original bidspoke shape: the diff holds no change to a listed file",
     "src/wiring.ts:1: The tests expect deploy.yml to call the hash script, but the diff contains no change to `.github/workflows/deploy.yml` to add this wiring." + S,
     ["src/wiring.ts", ".github/workflows/deploy.yml"], True),
    ("a listed file said to be not changed, in parentheses",
     "mods/night/bedtime.ts:154: `trayIn` and `trayMark` are new exports with no production caller in this branch (mods/night/register.ts is not changed)." + S,
     ["mods/night/bedtime.ts", "mods/night/register.ts"], True),
    ("a listed suite said to be not updated in this branch",
     "skills/labels/labels-lib.sh:36: The failure message changed, and `skills/labels/test-ensure-labels.sh` was not updated in this branch." + S,
     ["skills/labels/labels-lib.sh", "skills/labels/test-ensure-labels.sh"], True),
    ("this push does not touch a listed file",
     "src/a.ts:3: the new export is read in src/b.ts, but this push does not touch `src/b.ts`." + S,
     ["src/a.ts", "src/b.ts"], True),
    ("a listed file said to be not part of the diff",
     "src/a.ts:3: `src/b.ts` is not part of the diff, so its caller still passes the old shape." + S,
     ["src/a.ts", "src/b.ts"], True),
    ("a listed file said to be missing from this push",
     "src/a.ts:3: src/b.ts is missing from this push." + S,
     ["src/a.ts", "src/b.ts"], True),

    # The same whole file claims about a file the list does NOT name are true, so none is marked.
    ("a file really not changed, in parentheses",
     "mods/night/bedtime.ts:154: `trayIn` has no production caller in this branch (mods/night/register.ts is not changed)." + S,
     ["mods/night/bedtime.ts"], False),
    ("a suite really not updated in this branch",
     "skills/labels/labels-lib.sh:36: `skills/labels/test-ensure-labels.sh` was not updated in this branch." + S,
     ["skills/labels/labels-lib.sh"], False),
]
for name, finding, paths, want in cases:
    text, n = m.mark_false_absences(finding, paths)
    got = n == 1 and "premise is false" in text
    if n not in (0, 1) or got != want:
        print(f"FAIL\t{name}: expected {'marked' if want else 'unmarked'}, got {n} marks: {text}")
    else:
        print(f"PASS\t{name}")
EOF
)"
premise_ran=0
while IFS=$'\t' read -r verdict rest; do
  case "$verdict" in
    PASS) ok; premise_ran=$((premise_ran + 1)) ;;
    FAIL) bad "premise mark: $rest"; premise_ran=$((premise_ran + 1)) ;;
    *) [ -n "$verdict" ] && bad "premise mark fixture printed something unexpected: $verdict $rest" ;;
  esac
done <<< "$premise_out"
# Counted, so a runner that crashed on import and printed nothing reads as a failure, never a pass.
[ "$premise_ran" -eq 22 ] && ok || bad "the premise mark fixtures ran $premise_ran of 22 cases"

# ===========================================================================
# 12. A finding is placed by the line it QUOTES, never by the number it cites (claude-config#1357).
# In a hand judged sample of 60 lessons review findings on 2026-10-19, 44 cited the wrong line,
# usually a blank line, a lone brace or a neighbour within about 20 lines of the real one, and
# everything keyed on file and line (the earlier review history, the answered findings match) was
# misled by it. So the reviewer quotes the line it means on a "Quote:" line under each finding, and
# the runner moves the finding to the line of the file at the reviewed head that matches the quote,
# the occurrence nearest the cited number when it is there more than once. A finding it cannot
# place (no quote, a quote matching nothing, a file not at the head) keeps its number and SAYS it
# was not placed, so a guess never reads as a checked line. A number written "~N", the reviewer's
# own way of saying it is approximate, is a finding like any other (it was refused as unparsed on
# 2026-10-19, blocking a push whose only finding was real). The code is invented.
# ===========================================================================
PLACE="$WORKDIR/place"
mkdir -p "$PLACE/src"
git init -q "$PLACE"
P(){ git -C "$PLACE" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
cat > "$PLACE/src/ledger.ts" <<'EOF'
export function settle(entries) {
  let total = 0;

  for (const e of entries) {
    total += e.amount;
  }

  return total;
}

export function refund(entries) {
  let total = 0;
  for (const e of entries) {
    total -= e.amount;
  }
  return total;
}
EOF
printf 'export const gone = 1;\n' > "$PLACE/src/old.ts"
# A file whose real lines begin with "-", as a Markdown list does: line 2 is the item, line 3 the
# same words without the marker, so a quote of the item that is wrongly stripped lands on line 3.
mkdir -p "$PLACE/docs"
printf '# Steps\n- run the tests\nrun the tests\n' > "$PLACE/docs/list.md"
P add src/ledger.ts src/old.ts docs/list.md; P commit -q -m seed
P rm -q src/old.ts; P commit -q -m "remove old"
PLACE_SHA="$(P rev-parse HEAD)"
place_out="$(python3 - "$RUNNER" "$PLACE" "$PLACE_SHA" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ai_review_run", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
repo, sha = sys.argv[2], sys.argv[3]

S = " Should be: fix it. [severity: major]"
def one(name, answer, want_line, want_mark):
    """want_line: the location the finding must start with; want_mark: a phrase the line must
    carry, or None for no harness mark at all."""
    text, counts = m.place_findings(answer, repo, sha)
    lines = [l for l in text.splitlines() if m.FINDING.match(l)]
    problems = []
    if len(lines) != 1:
        problems.append(f"{len(lines)} finding lines")
    elif not lines[0].startswith(want_line):
        problems.append(f"placed at {lines[0].split(' ')[0]}")
    if lines and want_mark is None and "[review harness:" in lines[0]:
        problems.append("marked though placed")
    if lines and want_mark is not None and want_mark not in lines[0]:
        problems.append(f"missing the mark {want_mark!r}")
    if "Quote:" in text:
        problems.append("a Quote line was left in the stored text")
    if "~" in (lines[0].split(" ")[0] if lines else ""):
        problems.append("the approximate marker was kept in the location")
    print(("FAIL\t" + name + ": " + "; ".join(problems) + " | " + repr(text)) if problems else ("PASS\t" + name))

one("a finding citing a blank line moves to the line it quotes",
    "src/ledger.ts:3: total is never checked for overflow." + S + "\nQuote: total += e.amount;",
    "src/ledger.ts:5: ", None)
one("a finding citing a lone brace moves to the line it quotes",
    "src/ledger.ts:6: the loop reads entries without a null check." + S + "\nQuote: for (const e of entries) {",
    "src/ledger.ts:4: ", None)
one("a quote at the cited line leaves it where it is, unmarked",
    "src/ledger.ts:14: refund subtracts where it should add." + S + "\nQuote: total -= e.amount;",
    "src/ledger.ts:14: ", None)
one("a quote found twice goes to the occurrence nearest the cited line, the later one",
    "src/ledger.ts:15: refund returns a negative total." + S + "\nQuote: return total;",
    "src/ledger.ts:16: ", None)
one("a quote found twice goes to the nearest occurrence even when it is not the first",
    "src/ledger.ts:9: total starts at zero for refunds too." + S + "\nQuote: let total = 0;",
    "src/ledger.ts:12: ", None)
one("spacing inside and around the quote is not held against it",
    "src/ledger.ts:3: total is never checked." + S + "\nQuote:    total   +=  e.amount;   ",
    "src/ledger.ts:5: ", None)
one("a quote wrapped in backticks is read without them",
    "src/ledger.ts:7: settle returns the raw total." + S + "\nQuote: `return total;`",
    "src/ledger.ts:8: ", None)
one("a quote matching no line keeps the cited number and says so",
    "src/ledger.ts:5: total is multiplied." + S + "\nQuote: total *= e.amount;",
    "src/ledger.ts:5: ", "matches no line of src/ledger.ts")
one("a finding with no quote is kept, at its number, marked as not placed",
    "src/ledger.ts:5: total is never checked." + S,
    "src/ledger.ts:5: ", "quoted no line")
one("an approximate number is read and placed by its quote",
    "src/ledger.ts:~3: total is never checked." + S + "\nQuote: total += e.amount;",
    "src/ledger.ts:5: ", None)
one("an approximate number with no quote is kept as a plain number, marked as not placed",
    "src/ledger.ts:~14: refund subtracts." + S,
    "src/ledger.ts:14: ", "quoted no line")
one("a finding about a file not at the reviewed head keeps its number and says why",
    "src/old.ts:1: gone is still imported elsewhere." + S + "\nQuote: export const gone = 1;",
    "src/old.ts:1: ", "src/old.ts is not a file at the reviewed head")

# A quote copied from the diff keeps the leading marker of the diff (claude-config#1368). The quote
# is tried exactly as given first, and only when that matches nothing is one leading + or - dropped
# and the rest tried, because a real line can begin with either. A leading space needs nothing: the
# quote is trimmed before it is compared.
one("a quote copied from an added diff line with its leading + places on that line",
    "src/ledger.ts:3: total is never checked for overflow." + S + "\nQuote: +    total += e.amount;",
    "src/ledger.ts:5: ", None)
one("a quote with a leading - that matches only once the marker is dropped places on that line",
    "src/ledger.ts:13: refund subtracts where it should add." + S + "\nQuote: -    total -= e.amount;",
    "src/ledger.ts:14: ", None)
one("a quote with a leading + inside backticks places once the marker is dropped",
    "src/ledger.ts:7: settle returns the raw total." + S + "\nQuote: `+  return total;`",
    "src/ledger.ts:8: ", None)
one("a quote of a line that really begins with - places by the exact form, not the nearer stripped one",
    "docs/list.md:3: the step names no command." + S + "\nQuote: - run the tests",
    "docs/list.md:2: ", None)
one("a quote matching no line as given or without its marker keeps its number and says both were tried",
    "src/ledger.ts:5: total is multiplied." + S + "\nQuote: + total *= e.amount;",
    "src/ledger.ts:5: ", "matches no line of src/ledger.ts at the reviewed head, as given or without its leading +")
one("a quote that is only a diff marker is never stripped to nothing and matched to a blank line",
    "src/ledger.ts:3: something is wrong here." + S + "\nQuote: +",
    "src/ledger.ts:3: ", "matches no line of src/ledger.ts")

# Several findings at once: each takes its own quote, and the lines that are not findings stay.
two, counts = m.place_findings(
    "src/ledger.ts:3: first." + S + "\nQuote: total += e.amount;\n"
    "src/ledger.ts:1: second." + S + "\n"
    "src/ledger.ts:14: third." + S + "\nQuote: return total;", repo, sha)
got = [l.split(" ")[0] for l in two.splitlines() if m.FINDING.match(l)]
print("PASS\tthree findings each placed by their own quote" if got == ["src/ledger.ts:5:", "src/ledger.ts:1:", "src/ledger.ts:16:"]
      else f"FAIL\tthree findings each placed by their own quote: {got} | {two!r}")
print("PASS\tthe counts say how many were placed and how many not" if counts == {"placed": 2, "unplaced": 1}
      else f"FAIL\tthe counts say how many were placed and how many not: {counts}")
# The approximate marker is a finding to the parse the runner gates on, so an answer whose only
# finding is approximate is a review, not "unparsed".
n = m.count_findings("src/ledger.ts:~253: total is never checked." + S)
print("PASS\tan approximate finding is counted" if n == 1 else f"FAIL\tan approximate finding is counted: {n}")
# A head the runner cannot read places nothing and says so on every finding, never guessing.
text, counts = m.place_findings("src/ledger.ts:3: x." + S + "\nQuote: total += e.amount;", repo, "0" * 40)
print("PASS\ta head that cannot be read leaves the finding at its number, marked" if
      text.startswith("src/ledger.ts:3: ") and "could not be read" in text and counts == {"placed": 0, "unplaced": 1}
      else f"FAIL\ta head that cannot be read leaves the finding at its number, marked: {counts} | {text!r}")
EOF
)"
place_ran=0
while IFS=$'\t' read -r verdict rest; do
  case "$verdict" in
    PASS) ok; place_ran=$((place_ran + 1)) ;;
    FAIL) bad "placement: $rest"; place_ran=$((place_ran + 1)) ;;
    *) [ -n "$verdict" ] && bad "placement fixture printed something unexpected: $verdict $rest" ;;
  esac
done <<< "$place_out"
[ "$place_ran" -eq 22 ] && ok || bad "the placement fixtures ran $place_ran of 22 cases"

# End to end, through the hook and the detached runner: the stored review holds the placed line and
# no Quote line, and an answer whose only finding is approximate is a review, not unparsed.
cat > "$REPO/src/placed.ts" <<'EOF'
export function total(xs) {

  return xs.reduce((a, b) => a + b);
}
EOF
G add src/placed.ts; G commit -q -m placed
G push -q origin main 2>/dev/null
SHA_PLACED="$(G rev-parse HEAD)"
FAKE_CLAUDE_OUT='src/placed.ts:2: reduce with no initial value throws on an empty list. Should be: pass 0. [severity: major]
Quote: return xs.reduce((a, b) => a + b);
src/placed.ts:~1: total has no type for xs. Should be: type it. [severity: minor]' \
  fire_push "git push origin main" 0
wait_for_final "$SHA_PLACED" 20 && ok || bad "the placement review finishes"
placed_final=( "$AI_REVIEW_STATE_DIR"/*-"$SHA_PLACED".txt )
placed_body="$(cat "${placed_final[0]:-/dev/null}" 2>/dev/null)"
check "the stored review is a review, not unparsed" "status=ok" "$placed_body"
check "the finding citing a blank line is stored at the line it quoted" "src/placed.ts:3: reduce with no initial value" "$placed_body"
check_not "and its Quote line is not stored" "Quote:" "$placed_body"
check "the approximate finding with no quote is stored at its number" "src/placed.ts:1: total has no type" "$placed_body"
check "marked as not placed" "quoted no line" "$placed_body"
check_not "and the approximate marker is gone from it" "src/placed.ts:~1:" "$placed_body"

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
