#!/usr/bin/env bash
# Tests for lessons-advisory.sh (PreToolUse Bash hook).
# Run: ./test-lessons-advisory.sh   Exits nonzero on any failure.
#
# Every case builds a REAL git repo with a REAL bare remote and lets the hook run
# its own git commands, rather than stubbing git. A stub would only ever confirm
# this file's guess at what git prints (LESSONS.md L52).

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lessons-advisory.sh"
PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

payload() {
  # $1 command, $2 cwd
  python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$2"
}

# Build a repo with an upstream, one baseline commit already pushed, then commit
# $2 as the content of file $3. The pushed range is therefore exactly that commit.
make_repo() {
  # $1 repo name, $2 content, $3 filename
  local name="$1" content="$2" file="$3"
  local repo="$WORK/$name" bare="$WORK/$name.git"
  git init -q --bare "$bare"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  git -C "$repo" config commit.gpgsign false
  echo "baseline" > "$repo/README.md"
  git -C "$repo" add -A && git -C "$repo" commit -qm baseline
  git -C "$repo" remote add origin "$bare"
  git -C "$repo" push -q -u origin main
  mkdir -p "$(dirname "$repo/$file")"
  printf '%s\n' "$content" > "$repo/$file"
  git -C "$repo" add -A && git -C "$repo" commit -qm change
  printf '%s' "$repo"
}

run_hook() {
  # $1 command, $2 cwd, remaining: extra env assignments
  # The payload is materialized BEFORE the pipe: piping a python process
  # straight into a hook that exits early makes python spew a BrokenPipeError
  # into the test output, which is noise the next reader has to learn to ignore.
  local cmd="$1" cwd="$2"; shift 2
  local p; p="$(payload "$cmd" "$cwd")"
  printf '%s' "$p" | env -u CLAUDE_DETACHED_RUN TMPDIR="$WORK/tmp" "$@" "$HOOK" 2>/dev/null
}

assert_json_field() {
  # $1 desc, $2 dotted path, $3 expected, $4 output. Parses rather than
  # substring-matching, so the test pins the CONTRACT and not the whitespace
  # json.dumps happens to emit.
  local got
  got="$(printf '%s' "$4" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("<unparseable>"); raise SystemExit
for k in sys.argv[1].split("."):
    d = d.get(k, {}) if isinstance(d, dict) else {}
print(d if isinstance(d, str) else "<missing>")
' "$2" 2>/dev/null)"
  if [ "$got" = "$3" ]; then
    PASS=$((PASS+1)); echo "PASS: $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $1 (expected $3, got $got)"
  fi
}

assert_contains() {
  # $1 desc, $2 needle, $3 haystack
  if printf '%s' "$3" | grep -qF "$2"; then
    PASS=$((PASS+1)); echo "PASS: $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $1 (missing: $2)"
  fi
}

assert_absent() {
  if printf '%s' "$3" | grep -qF "$2"; then
    FAIL=$((FAIL+1)); echo "FAIL: $1 (unexpectedly present: $2)"
  else
    PASS=$((PASS+1)); echo "PASS: $1"
  fi
}

assert_silent() {
  # $1 desc, $2 output
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then
    PASS=$((PASS+1)); echo "PASS: $1"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $1 (expected no output, got: $2)"
  fi
}

if [ ! -x "$HOOK" ]; then
  echo "FAIL: hook not found or not executable at $HOOK"
  exit 1
fi
mkdir -p "$WORK/tmp"

# --- 1. A swallowed error in added code raises the error-path lessons ----------
R=$(make_repo swallow 'try {
  await send()
} catch (e) {
  return []
}' src/send.ts)
out=$(run_hook "git push" "$R")
assert_json_field "swallowed catch produces valid PreToolUse JSON" "hookSpecificOutput.hookEventName" "PreToolUse" "$out"
assert_contains "swallowed catch carries additionalContext" 'additionalContext' "$out"
assert_contains "swallowed catch cites the error-path lesson" 'L11' "$out"

# --- 2. It never auto-approves the push ---------------------------------------
assert_absent "advisory does not decide the permission" 'permissionDecision' "$out"

# --- 3. It never reports a clean bill of health -------------------------------
assert_absent "advisory never claims clean" 'no issues' "$out"
assert_contains "advisory states it is only a partial check" 'not a full audit' "$out"

# --- 4. A new API route raises the security-scoping lessons -------------------
R=$(make_repo route 'export async function POST(req: Request) {
  return Response.json({ ok: true })
}' app/api/thing/route.ts)
out=$(run_hook "git push" "$R")
assert_contains "new route cites the authorization lesson" 'L18' "$out"

# --- 5. A destructive data operation raises the data-safety lessons ----------
R=$(make_repo destructive 'DELETE FROM contacts WHERE stale = true;' migrations/003.sql)
out=$(run_hook "git push" "$R")
assert_contains "destructive SQL cites the data-safety lesson" 'L5' "$out"

# --- 6. Silence where there is nothing to say --------------------------------
R=$(make_repo docs 'Some prose about the feature.' docs/notes.md)
out=$(run_hook "git push" "$R")
assert_silent "docs-only push is silent" "$out"

R=$(make_repo notpush 'try { x() } catch (e) { return [] }' src/a.ts)
out=$(run_hook "git status" "$R")
assert_silent "non-push command is silent" "$out"

out=$(run_hook 'echo "remember to git push later"' "$R")
assert_silent "a command merely mentioning git push is silent" "$out"

P="$(payload "git push" "$R")"
out=$(printf '%s' "$P" | env TMPDIR="$WORK/tmp" CLAUDE_DETACHED_RUN=1 "$HOOK" 2>/dev/null)
assert_silent "detached run is silent" "$out"

# --- 7. Matching is on ADDED lines, not the whole file ------------------------
# The trigger already existed and is pushed. This push appends an innocuous line
# to THAT SAME FILE, so a hook scanning the changed files' contents would fire
# while one scanning the added lines stays quiet. Touching a different file would
# pass either way and prove nothing.
R=$(make_repo preexisting 'try { x() } catch (e) { return [] }' src/old.ts)
git -C "$R" push -q origin main
echo "// an unrelated comment" >> "$R/src/old.ts"
git -C "$R" add -A && git -C "$R" commit -qm unrelated
out=$(run_hook "git push" "$R")
assert_silent "a pre-existing pattern in a touched file does not re-fire" "$out"

# --- 8. An unresolvable lesson id is reported, never silently dropped ---------
# LESSONS.md renumbering must not empty the map behind everyone's back.
cat > "$WORK/thin-lessons.md" <<'EOF'
- **L1. A test or guard is only real once it has been seen to fail.** Break it once.
EOF
R=$(make_repo missingid 'try { x() } catch (e) { return [] }' src/b.ts)
out=$(run_hook "git push" "$R" LESSONS_FILE="$WORK/thin-lessons.md")
assert_contains "an unresolvable lesson id is called out loudly" 'NOT FOUND' "$out"

# --- 9. A missing lessons file is loud, not silent ----------------------------
R=$(make_repo nolessons 'try { x() } catch (e) { return [] }' src/c.ts)
out=$(run_hook "git push" "$R" LESSONS_FILE="$WORK/does-not-exist.md")
assert_contains "a missing lessons file is reported" 'COULD NOT READ' "$out"

# --- 10. Cooldown: a repeated push does not repeat the advisory --------------
R=$(make_repo cooldown 'try { x() } catch (e) { return [] }' src/d.ts)
first=$(run_hook "git push" "$R")
second=$(run_hook "git push" "$R")
assert_contains "first push of a repo advises" 'additionalContext' "$first"
assert_silent "the SAME finding pushed again is silent" "$second"

# A different problem inside the same window must still get through: the quiet
# is for repetition, not for the repo. Otherwise silence, which is supposed to
# mean "nothing matched", would sometimes mean "something matched and was eaten".
git -C "$R" push -q origin main
printf 'DELETE FROM contacts WHERE stale = true;\n' > "$R/cleanup.sql"
git -C "$R" add -A && git -C "$R" commit -qm cleanup
third=$(run_hook "git push" "$R")
assert_contains "a DIFFERENT finding in the same window still advises" 'L5' "$third"

# --- 11. A branch with no upstream still gets scanned -------------------------
# The base falls back through origin/HEAD, origin/main, main. On a repo with no
# remote that lands on the CURRENT branch, making the range empty. Silence there
# would mean "scanned nothing" while reading as "matched nothing".
NR="$WORK/noremote"
git init -q -b main "$NR"
git -C "$NR" config user.email t@t.t
git -C "$NR" config user.name t
echo baseline > "$NR/README.md"
git -C "$NR" add -A && git -C "$NR" commit -qm baseline
mkdir -p "$NR/src"
printf 'try { x() } catch (e) { return [] }\n' > "$NR/src/e.ts"
git -C "$NR" add -A && git -C "$NR" commit -qm change
out=$(run_hook "git push" "$NR")
assert_contains "a repo with no upstream is still scanned" 'additionalContext' "$out"

# --- 12. The repo comes from the command when the cwd is not one --------------
# A session rooted outside the project pushes with `cd <repo> && git push` or
# `git -C <repo> push`. Resolving only the payload cwd would make every such
# push invisible, and invisible reads exactly like nothing-to-say.
R=$(make_repo fromcd 'try { x() } catch (e) { return [] }' src/f.ts)
out=$(run_hook "cd $R && git push" "$WORK")
assert_contains "a cd-then-push resolves the repo from the command" 'additionalContext' "$out"

R=$(make_repo fromdashc 'try { x() } catch (e) { return [] }' src/g.ts)
out=$(run_hook "git -C $R push" "$WORK")
assert_contains "a git -C push resolves the repo from the command" 'additionalContext' "$out"

# --- 13. It reports WHERE, so the advice is actionable ------------------------
R=$(make_repo location 'try { x() } catch (e) { return [] }' src/where.ts)
out=$(run_hook "git push" "$R")
assert_contains "advisory names the file that triggered it" 'src/where.ts' "$out"

# --- 14. A fixed timer wait added to a TEST file raises the test speed lessons -----------
# The trigger is path scoped: a sleep in production code is a retry's business (section 15),
# a sleep in a test is a test waiting on the machine's load instead of on a condition.
R=$(make_repo sleepy 'await page.waitForTimeout(500)' e2e/rows.spec.ts)
out=$(run_hook "git push" "$R")
assert_contains "a waitForTimeout in a spec file raises the fixed-wait lesson" 'L290' "$out"
assert_contains "and the injectable sleep lesson" 'L524' "$out"
assert_contains "it says what it spotted" 'a test that waits a fixed time' "$out"

R=$(make_repo sleepy-swift 'try await Task.sleep(nanoseconds: 2_050_000_000)' Tests/RepoTests/ClockTests.swift)
out=$(run_hook "git push" "$R")
assert_contains "a Task.sleep in a Swift test target raises it too" 'L290' "$out"

R=$(make_repo sleepy-shell 'sleep 2' hooks/test-lock.sh)
out=$(run_hook "git push" "$R")
assert_contains "a bare sleep in a test-*.sh raises it too" 'L290' "$out"

R=$(make_repo not-a-test 'await page.waitForTimeout(500)' src/lib/scrape.ts)
out=$(run_hook "git push" "$R")
assert_absent "the same line outside a test file does not raise the test lesson" 'L290' "$out"

# --- 16. A workflow job added with no timeout raises L313 (claude-config#223) -------------
# The 2026-08-29 audit found a CI job with no timeout-minutes in nine repositories out of nine.
# The platform default is six HOURS, a hang is worse than a failure because it reads as slowness,
# and on a metered macOS runner at the 10x multiplier one such hang costs two months of a free
# account's whole allowance. Raising it here, in the push that adds the job, is the only moment
# anybody is looking at that block.
#
# It cannot be a regex over the added lines, because what is wrong is a key that is ABSENT. So the
# trigger takes a small awk pass over the added hunk instead: a two space job key, followed inside
# its own block by runs-on or uses, and no timeout-minutes before the next such key.
WF_JOB_NONE='jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: make test'
R=$(make_repo wf-no-timeout "$WF_JOB_NONE" .github/workflows/ci.yml)
out=$(run_hook "git push" "$R")
assert_contains "a workflow job added with no timeout raises the CI timeout lesson" 'L313' "$out"
assert_contains "it says what it spotted" 'no timeout' "$out"
assert_contains "and it names the workflow file" '.github/workflows/ci.yml' "$out"

# The negative case the issue asks for by name. A job that DOES carry one must say nothing, or the
# trigger fires on every workflow push and stops being read (L36).
WF_JOB_OK='jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - run: make test'
R=$(make_repo wf-with-timeout "$WF_JOB_OK" .github/workflows/ci.yml)
out=$(run_hook "git push" "$R")
assert_absent "a workflow job that carries a timeout raises nothing" 'L313' "$out"

# Scoped to workflow files. The same shape of YAML elsewhere is somebody else's config, and a
# trigger that fires on every two space key in every file is noise (L104).
R=$(make_repo wf-not-a-workflow "$WF_JOB_NONE" deploy/k8s.yml)
out=$(run_hook "git push" "$R")
assert_absent "the same block outside .github/workflows raises nothing" 'L313' "$out"

# Two jobs, one of each. The one without a timeout is what matters, and a reader that stopped at
# the first job would miss it (L215).
WF_JOB_MIXED='jobs:
  fine:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - run: true
  careless:
    runs-on: ubuntu-latest
    steps:
      - run: true'
R=$(make_repo wf-mixed "$WF_JOB_MIXED" .github/workflows/ci.yml)
out=$(run_hook "git push" "$R")
assert_contains "a second job with no timeout is caught beside one that has it" 'L313' "$out"

# A block that is NOT a job. `on:` has two space keys of its own, and treating those as jobs would
# fire on every workflow that adds a trigger. What makes a job a job is runs-on or uses.
WF_NOT_A_JOB='on:
  push:
    branches: [main]
  pull_request:'
R=$(make_repo wf-on-block "$WF_NOT_A_JOB" .github/workflows/ci.yml)
out=$(run_hook "git push" "$R")
assert_absent "a two space key that is not a job raises nothing" 'L313' "$out"

echo
# --- 15. New retry logic carries the injectable sleep lesson -----------------
R=$(make_repo retry-seam 'const backoff = attempt * 1000; await new Promise(r => setTimeout(r, backoff)); // retry' src/lib/fetch.ts)
out=$(run_hook "git push" "$R")
assert_contains "a retry in production code points at the injectable sleep lesson" 'L524' "$out"

echo
# ---------------------------------------------------------------------------
# A LARGE diff. The trigger matching used to feed the added lines to `grep -q` through a pipe, and
# `grep -q` leaves on its first match: a string bigger than the pipe buffer means the writer is
# killed by SIGPIPE, the pipeline reports failure under `pipefail`, and the code reads that as no
# match. The advisory would go quiet on exactly the pushes that add the most lines, which is when
# it has most to say (L183, claude-config#132).
#
# The trigger is planted FIRST, with the bulk after it, and that ordering is the whole fixture.
# `grep -q` leaves the moment it matches. Put the trigger at the END and the reader has to consume
# everything before it can match, so the writer always finishes and the failure can never occur:
# the test would pass against the broken code and prove nothing. Put it FIRST and the reader
# leaves while there are still 200KB to write, which is the case (measured: with the pipe in
# place this fixture makes the advisory go silent).
big_body="$(python3 -c '
pad = "a harmless line of code that triggers nothing at all\n" * 4000
print("rm -rf \"$target_directory\"\n" + pad)
')"
BIGREPO="$(make_repo bigdiff "$big_body" "cleanup.sh")"
out_big="$(run_hook "git push" "$BIGREPO")"
big_bytes="$(printf '%s' "$big_body" | wc -c | tr -d ' ')"
if [ "$big_bytes" -gt 65536 ]; then
  PASS=$((PASS+1)); echo "PASS: the large-diff fixture is bigger than a pipe buffer ($big_bytes bytes)"
else
  FAIL=$((FAIL+1)); echo "FAIL: the large-diff fixture is only $big_bytes bytes, so it proves nothing"
fi
assert_contains "the advisory still fires on a diff too big to fit a pipe" "L5" "$out_big"

# ---- the six trigger tables are one table (claude-config#234) ----
# The triggers live as six parallel arrays indexed together: TRIG_IDS, TRIG_WHAT, TRIG_RE1,
# TRIG_RE2, TRIG_PATH and TRIG_FN. Adding one means adding an entry to all six in matching order.
# Nothing checked they were the same length, and a trigger added to five of the six leaves every
# entry after it attached to the wrong lesson id, the wrong description or the wrong file scope,
# while the hook goes on running and its output looks entirely normal: every id it prints exists
# and every description reads sensibly.
#
# Under `set -u` a SHORTER array is the loud case. The dangerous one is an array long enough to
# index that holds the PREVIOUS trigger's value, which is exactly what an insertion in the middle
# produces.
#
# Read out of the hook by sourcing the tables alone, so this measures what the hook will actually
# index rather than a count of lines that look like entries (L107).
trig_lengths="$(
  # shellcheck disable=SC1090
  eval "$(sed -n '/^TRIG_IDS=(/,/^)/p; /^TRIG_WHAT=(/,/^)/p; /^TRIG_RE1=(/,/^)/p; /^TRIG_RE2=(/,/^)/p; /^TRIG_PATH=(/,/^)/p; /^TRIG_FN=(/,/^)/p' "$HOOK")"
  printf '%s %s %s %s %s %s\n' "${#TRIG_IDS[@]}" "${#TRIG_WHAT[@]}" "${#TRIG_RE1[@]}" "${#TRIG_RE2[@]}" "${#TRIG_PATH[@]}" "${#TRIG_FN[@]}"
)"
# One definition of the question, so the probes below exercise THIS comparison rather than a
# second one written beside it that drifts (L107).
trig_agree(){   # $@ = the lengths -> 0 when they are all equal and above zero
  local first="${1:-0}" len
  case "$first" in ''|*[!0-9]*|0) return 1 ;; esac
  for len in "$@"; do [ "$len" = "$first" ] || return 1; done
  return 0
}
# Watched giving both answers before it is believed, against lists built here, because a
# comparison that has only ever been seen to pass is not yet a check (L1). The all-zero case is
# in because six arrays that all failed to parse agree perfectly, and that must not read as
# agreement (L98).
trig_agree 3 3 3 3 3 3 \
  && { PASS=$((PASS+1)); echo "PASS: the table comparison accepts six equal lengths"; } \
  || { FAIL=$((FAIL+1)); echo "FAIL: the table comparison rejected six equal lengths"; }
trig_agree 3 3 2 3 3 3 \
  && { FAIL=$((FAIL+1)); echo "FAIL: the table comparison accepted a short table"; } \
  || { PASS=$((PASS+1)); echo "PASS: the table comparison catches one short table"; }
trig_agree 0 0 0 0 0 0 \
  && { FAIL=$((FAIL+1)); echo "FAIL: the table comparison read six empty tables as agreement"; } \
  || { PASS=$((PASS+1)); echo "PASS: six empty tables are not read as agreement"; }

set -- $trig_lengths
trig_n="${1:-0}"
trig_same=0
trig_agree "$@" && trig_same=1
if [ "$trig_same" = 1 ]; then
  PASS=$((PASS+1)); echo "PASS: all six trigger tables hold $trig_n entries"
else
  FAIL=$((FAIL+1)); echo "FAIL: the trigger tables are not one length (IDS WHAT RE1 RE2 PATH FN = $trig_lengths). An entry added to some of them silently attaches every later trigger to the wrong lesson."
fi

# --- claude-config#457 item 3: a commit then push, on the shared helpers -------
# A command that commits before it pushes, on a branch level with its upstream: the plain push
# range (HEAD~1) re-read the last commit already on the remote, and advised about it again.
R=$(make_repo pendingbase 'try { x() } catch (e) { return [] }' src/g.ts)
git -C "$R" push -q origin main
printf 'export const clean = 1;\n' > "$R/src/clean.ts"
out=$(run_hook "git add src/clean.ts && git commit -qm clean && git push" "$R")
assert_silent "a commit then push does not re-advise on the commit already on the remote" "$out"

# The pending commit is what the add names. An UNTRACKED file the add names was never read (the
# hook read only tracked changes for any add), so a trigger in a new file went unmentioned.
R=$(make_repo pendingnew 'export const base = 1;' src/h.ts)
git -C "$R" push -q origin main
printf 'try { x() } catch (e) { return [] }\n' > "$R/src/new.ts"
out=$(run_hook "git add src/new.ts && git commit -qm new && git push" "$R")
assert_contains "a trigger in a new file the add names is advised on" 'additionalContext' "$out"
# And a stranger nobody named stays out of it.
R=$(make_repo pendingstranger 'export const base = 1;' src/i.ts)
git -C "$R" push -q origin main
printf 'try { x() } catch (e) { return [] }\n' > "$R/src/stranger.ts"
printf 'export const mine = 1;\n' > "$R/src/mine.ts"
out=$(run_hook "git add src/mine.ts && git commit -qm mine && git push" "$R")
assert_silent "a trigger in an untracked file the add does not name is not advised on" "$out"

echo "passed: $PASS, failed: $FAIL"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
