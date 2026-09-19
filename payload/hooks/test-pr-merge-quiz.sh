#!/usr/bin/env bash
# WHOLE-HOOK tests for pr-merge-quiz.sh: feeds it real PostToolUse(Bash) payloads and asserts
# whether it FIRES (emits a decision:block instruction telling Claude to run the comprehension
# quiz) or STAYS QUIET (exit 0, no output).
#
# The hook fires only on a `gh pr merge` command. It deliberately does NOT try to judge from the
# shell whether the merge succeeded or whether the change is trivial: both of those are handed to
# Claude in the injected instruction, which can see the real command output and the diff. So these
# tests only pin down the ONE thing the shell owns: did this command merge a PR, and should the
# quiz instruction fire.
#
# The matcher works on the LEADING TOKENS of each shell segment, never anywhere in the string, so a
# command whose PAYLOAD merely mentions "gh pr merge" (an echo, an issue comment) must not fire.
# Same command-vs-payload distinction that check-closing-keyword.sh had to learn the hard way.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/pr-merge-quiz.sh"

pass=0
fail=0

# One repo and one fake gh for the whole suite, because every case now reaches the
# label check and a case that reached the REAL gh would be a test talking to a live
# service (L2) and paying a network round trip to do it.
#
# The repo is real, with a real remote, because mt_pr_view refuses an answer that is
# not about the repo the remote names: a fixture without one would exercise a
# different path from the one that ships.
#
# With FAKE_PR_JSON unset the fake gh says NOTHING, which is the fail open case, so
# every case below that does not choose a record fires exactly as it did before the
# label gate existed.
FIXTURE="$(mktemp -d)"
mkdir -p "$FIXTURE/repo" "$FIXTURE/bin"
( cd "$FIXTURE/repo" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
cat > "$FIXTURE/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*)
    if [ -n "${FAKE_PR_JSON:-}" ] && [ -f "$FAKE_PR_JSON" ]; then cat "$FAKE_PR_JSON"; fi
    ;;
esac
SH
chmod +x "$FIXTURE/bin/gh"

# Where the fake gh reads its answer. Exported ONCE for the whole suite rather than
# threaded through run()'s env argument, because a case that also has to override PATH
# would otherwise have to pass two assignments, and the one that quietly went missing
# is the one that decides what is being tested (it did: the two missing-tool cases
# below were firing because gh had no answer, not because the tool was absent).
#
# So the record's presence is state a case SETS, and every case that cares says which
# it wants. An exported variable is inherited by every later subprocess (L439), which
# is the point here and the reason each case is explicit rather than relying on order.
export FAKE_PR_JSON="$FIXTURE/pr.json"

# Where the gate records what it decided. A named seam with a default OUTSIDE ~/.claude,
# the same shape as the issue spool's, because anything under ~/.claude auto pushes to the
# other Mac within seconds and a counter that ticks on every merge is not config.
export CLAUDE_QUIZ_VERDICT_DIR="$FIXTURE/verdicts"

verdicts() { cat "$CLAUDE_QUIZ_VERDICT_DIR/counts" 2>/dev/null; }
forget_verdicts() { rm -rf "$CLAUDE_QUIZ_VERDICT_DIR"; }
count_of() {  # $1 = verdict name
  verdicts | awk -v k="$1" '$1 == k { print $2; found = 1 } END { if (!found) print 0 }'
}
saw() {  # $1 = verdict name, $2 = expected count, $3 = what
  local got; got="$(count_of "$1")"
  if [ "$got" = "$2" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: $3: wanted $1=$2, got $1=$got"; fi
}
# Matched with the shell's own builtin, WITHOUT a pipe. A producer piped into a quiet grep
# is the short circuiting shape test-pipefail-shortcircuit.sh ratchets down: the reader
# leaves on its first match, the producer dies of SIGPIPE, and under `set -o pipefail` the
# pipeline reports a failure that never happened (L183).
holds() {  # $1 = the text, $2 = a LITERAL needle
  case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

reason_of() {  # $1 = command ; prints the emitted reason
  printf '{"tool_input": {"command": "%s"}, "cwd": "%s"}' "$1" "$FIXTURE/repo" \
    | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" ) 2>/dev/null
}

record() {  # $1 = a JSON labels array
  printf '{"number":42,"url":"https://github.com/acme/widget/pull/42","labels":%s}' "$1" \
    > "$FAKE_PR_JSON"
}
no_record() { rm -f "$FAKE_PR_JSON"; }

# The matcher cases below choose no record, so gh answers nothing and every merge fires
# exactly as it did before the label gate existed.
no_record

# run <description> <fire|skip> <command-string> [env-assignment]
# Builds a PostToolUse payload, pipes it to the hook, and checks stdout for a decision:block.
run() {
  local desc="$1" want="$2" command="$3" envassign="${4:-}"
  local payload out fired
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))
' "$command" "$FIXTURE/repo")"
  if [ -n "$envassign" ]; then
    out="$(printf '%s' "$payload" \
      | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$envassign" "$HOOK" ) 2>/dev/null)"
  else
    out="$(printf '%s' "$payload" \
      | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" ) 2>/dev/null)"
  fi
  if printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
    fired="fire"
  else
    fired="skip"
  fi
  if [ "$fired" = "$want" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "FAIL: $desc (wanted $want, got $fired)"
  fi
}

# --- A real merge must fire ---
run "a plain merge by number"        fire 'gh pr merge 42'
run "a squash auto-merge"            fire 'gh pr merge --squash --auto'
run "a merge of the current branch"  fire 'gh pr merge'
run "an env-prefixed merge"          fire 'GH_TOKEN=abc gh pr merge 42'
run "a merge at the end of a chain"  fire 'git fetch origin && gh pr merge 42 --squash'

# --- The merge-when-green.sh wrapper merges internally, so it must fire too (its real `gh pr merge`
#     runs in a subprocess the hook can't see; matching the wrapper is the only way it isn't dodged) ---
run "the wrapper by relative path"   fire 'scripts/merge-when-green.sh 42'
run "the wrapper with a ./ prefix"   fire './scripts/merge-when-green.sh 1367'
run "the wrapper after a chain"      fire 'git fetch origin && ./scripts/merge-when-green.sh 42'
run "the wrapper run via bash"       fire 'bash scripts/merge-when-green.sh 42'
run "the wrapper bare"               fire 'merge-when-green.sh 42'
run "wrapper override still skips"   skip 'SKIP_PR_QUIZ=1 ./scripts/merge-when-green.sh 42'
run "the wrapper name only mentioned" skip 'echo "run scripts/merge-when-green.sh 42 next"'
run "the wrapper name as a bare arg" skip 'ls merge-when-green.sh'

# --- agent-onboarding's own wrapper, and the npm script that runs it. That repo's merge gate
#     REFUSES a plain `gh pr merge`, so the wrapper is the ONLY route there: a matcher that knew only
#     the old form would mean the quiz never fires in that repo again, silently. ---
run "the shell wrapper by path"      fire 'bash .github/scripts/merge-pr.sh 680'
run "the shell wrapper bare"         fire 'merge-pr.sh 680'
run "the shell wrapper after a cd"   fire 'cd /tmp/repo && bash .github/scripts/merge-pr.sh 680'
run "the npm script that runs it"    fire 'npm run merge -- 680'
run "the npm script with no args"    fire 'npm run merge'
run "npm script override still skips" skip 'SKIP_PR_QUIZ=1 npm run merge -- 680'
run "the wrapper only mentioned"     skip 'echo "use npm run merge -- 680 instead"'
run "the wrapper name as a bare arg" skip 'ls .github/scripts/merge-pr.sh'
# The readiness check REPORTS and merges nothing, so quizzing on it would fire on every look at a
# pull request. `merge` has to match exactly, not as a prefix.
run "the readiness check alone"      skip 'npm run merge-ready -- 680'
run "an unrelated npm script"        skip 'npm run test'

# PET's own commit pinned tool, run under a python interpreter. block-red-merge refuses
# the direct command in that repo, so this is the only route there, and the quiz had
# never once fired in PET (claude-config#351).
run "PET's tool merging"             fire 'venv/bin/python tools/wait_for_checks.py 7 --merge'
run "the same tool under python3"    fire 'python3 tools/wait_for_checks.py 7 --merge'
# Without --merge it only waits for the checks, so quizzing on it would fire on every
# look at a pull request.
run "the same tool only waiting"     skip 'venv/bin/python tools/wait_for_checks.py 7'
run "PET's tool only mentioned"      skip 'echo "run venv/bin/python tools/wait_for_checks.py 7 --merge"'

# --- Things that are not a merge must stay quiet ---
run "closing without merging"        skip 'gh pr close 42'
run "viewing a pr"                   skip 'gh pr view 42 --json state'
run "a plain push"                   skip 'git push -u origin branch'
run "creating a pr"                  skip 'gh pr create --title x --body y'

# --- A command is not its payload: a mere mention of the phrase must not fire ---
run "an echo of the phrase"          skip 'echo "gh pr merge 42"'
run "an issue comment mentioning it" skip 'gh issue comment 5 --body "then run gh pr merge"'
run "a grep for the phrase"          skip 'grep -r "gh pr merge" .'

# --- The override, and the detached-run guard ---
run "the documented override"        skip 'SKIP_PR_QUIZ=1 gh pr merge 42'
run "a detached headless run"        skip 'gh pr merge 42' 'CLAUDE_DETACHED_RUN=1'

# --- The changelog label decides whether the quiz fires at all (claude-config#348) ---
#
# Dan's call, 2026-09-10, after the quiz fired five times in one session and was
# declined five times, every one correctly judged internal. He was offered turning it
# off and chose to narrow it instead.
#
# changelog/visible means exactly what the quiz's own user facing gate means, it is set
# by a person at pull request time, and PET and Slate already enforce it at merge. So
# the label narrows what reaches Claude. It does NOT replace the judgement: a mixed
# pull request can carry changelog/technical while touching something visible, so the
# instruction keeps its own gate and the cases further down still pin it.
record '[{"name":"changelog/technical"}]'
run "a technical record does not quiz"  skip 'gh pr merge 42'
record '[{"name":"changelog/none"}]'
run "a none record does not quiz"       skip 'gh pr merge 42'
record '[{"name":"changelog/visible"}]'
run "a visible record quizzes"          fire 'gh pr merge 42'
# Mixed labels: visible wins, because the quiz is owed wherever any part of it shows.
record '[{"name":"changelog/technical"},{"name":"changelog/visible"}]'
run "visible beside technical quizzes"  fire 'gh pr merge 42'
# Case and stray whitespace are the label reader's business, not this hook's, and the
# reader is the same module the merge gate enforces with, so this proves the two agree.
record '[{"name":"  Changelog/Technical  "}]'
run "a label is read case blind"        skip 'gh pr merge 42'

# THE FALLBACK, and it is the one that matters most: a repo that does not use the
# convention has to keep working exactly as before, with Claude doing the judging. It
# is also the case a future edit would quietly break, since every other case here would
# still pass.
record '[{"name":"priority-p2"}]'
run "no changelog label quizzes"        fire 'gh pr merge 42'
record '[]'
run "no labels at all quizzes"          fire 'gh pr merge 42'

# Fail OPEN on every way the reading can fail. A hook that silently stops asking is
# worse than one that asks too often, and firing is the behaviour that already shipped.
no_record
run "gh saying nothing quizzes"         fire 'gh pr merge 42'
printf 'not json at all' > "$FAKE_PR_JSON"
run "a corrupt answer quizzes"          fire 'gh pr merge 42'
# An answer about a DIFFERENT repo is not this pull request's record, so reading its
# label would skip the quiz on the strength of somebody else's pull request (L70). The
# label chosen here is the one that WOULD silence the quiz, so this fails if the repo
# identity check is dropped.
printf '{"number":42,"url":"https://github.com/someone/else/pull/42","labels":[{"name":"changelog/none"}]}' \
  > "$FAKE_PR_JSON"
run "an answer about another repo quizzes" fire 'gh pr merge 42'

# A tool missing entirely is the same fail open by a different route, and each route
# needs its own case rather than being assumed to share one (L173).
#
# Both are set up with a QUIET record deliberately, which is the strong form of the
# assertion: not merely that an unreadable state fires, but that a record which WOULD
# silence the quiz cannot silence it while the reading is impossible.
#
# Measured, rather than assumed, by mutating the hook: dropping the node guard and
# making an unreadable verdict mean quiet turns "node not on PATH" red, so that guard is
# what carries it. "gh not on PATH" stays green under the same mutation, because gh's
# absence is ALSO answered downstream by mt_pr_view finding nothing. Its guard is an
# early exit rather than the safeguard, and the case pins the OUTCOME on that route,
# which is what the contract promises.
NODE_DIR="$(dirname "$(command -v node)")"
record '[{"name":"changelog/none"}]'
run "gh not on PATH quizzes"            fire 'gh pr merge 42' "PATH=$NODE_DIR:/usr/bin:/bin"
run "node not on PATH quizzes"          fire 'gh pr merge 42' "PATH=$FIXTURE/bin:/usr/bin:/bin"
# The control, on the SAME record with both tools present: it DOES silence the quiz, so
# the two above are not passing because this fixture never skips at all (L159).
run "the same record with both tools"   skip 'gh pr merge 42'
no_record

# --- The gate records what it decided, so a gate that never fires is visible (#354) ---
#
# The label gate fails open on every route, which is right, but it means a gate that never
# once silences a quiz is indistinguishable from one that is working and simply meeting a
# visible change every time. Dan would go on declining quizzes exactly as before with
# nothing reporting that the fix was inert (L557).

MERGE_CMD="gh pr me""rge"

forget_verdicts
record '[{"name":"changelog/none"}]'
run "a quiet verdict is recorded"       skip "$MERGE_CMD 42"
saw quiet 1 "a skip"
saw visible 0 "a skip"

record '[{"name":"changelog/visible"}]'
run "a visible verdict is recorded"     fire "$MERGE_CMD 42"
saw visible 1 "a quiz"
saw quiet 1 "a quiz"

# Each fail open ROUTE is recorded under its own name, so "the gate never skips" and "gh
# has been answering nothing for a fortnight" are different readings rather than one
# number that cannot tell them apart (L11).
forget_verdicts
no_record
run "no answer is its own verdict"      fire "$MERGE_CMD 42"
saw no-answer 1 "gh saying nothing"
record '[{"name":"priority-p2"}]'
run "no label is its own verdict"       fire "$MERGE_CMD 42"
saw no-label 1 "a pull request with no changelog label"
saw no-answer 1 "a pull request with no changelog label"

# The store stays small however many merges pass through it: one line per verdict kind,
# never one per merge, so nothing has to drain it (L526).
before_lines="$(verdicts | wc -l | tr -d ' ')"
for _ in 1 2 3 4 5; do run "repeat merges" fire "$MERGE_CMD 42"; done
after_lines="$(verdicts | wc -l | tr -d ' ')"
if [ "$after_lines" = "$before_lines" ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the verdict store grew a line per merge ($before_lines to $after_lines)"; fi
saw no-label 6 "six merges with no changelog label"

# And it SPEAKS. After ten quizzes with not one silenced, the instruction carries a line
# saying so and naming what it has been recording, because a store nobody reads is not a
# detector (L46, L357).
forget_verdicts
record '[{"name":"priority-p2"}]'
for _ in 1 2 3 4 5 6 7 8; do run "before the tenth" fire "$MERGE_CMD 42"; done
ninth="$(reason_of "$MERGE_CMD 42")"
if holds "$ninth" "without once silencing"; then
  fail=$((fail+1)); echo "FAIL: the notice fired before the threshold"
else pass=$((pass+1)); fi
tenth="$(reason_of "$MERGE_CMD 42")"
if holds "$tenth" "without once silencing"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the notice did not fire at the threshold"; fi
# It names the breakdown, because that is the whole diagnosis: no-label means the repo
# does not use the convention, no-answer means gh is not answering.
if holds "$tenth" "no-label"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the notice does not name what it recorded"; fi
# It is still the quiz instruction, not a replacement for it.
if holds "$tenth" "could notice a difference"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the notice replaced the instruction instead of adding to it"; fi

# ONCE, not on every merge afterwards. A notice repeated every time is what teaches
# somebody to skim the whole thing (L36).
eleventh="$(reason_of "$MERGE_CMD 42")"
if holds "$eleventh" "without once silencing"; then
  fail=$((fail+1)); echo "FAIL: the notice repeated on the next merge"
else pass=$((pass+1)); fi

# The latch is cleared by the thing it was waiting for, so if the gate starts working and
# later stops again, it says so again rather than staying silent for ever (L523).
record '[{"name":"changelog/none"}]'
run "a skip clears the latch"           skip "$MERGE_CMD 42"
record '[{"name":"priority-p2"}]'
for _ in 1 2 3 4 5 6 7 8 9; do run "building up again" fire "$MERGE_CMD 42"; done
again="$(reason_of "$MERGE_CMD 42")"
if holds "$again" "without once silencing"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the notice never fired again after the gate stopped working a second time"; fi

# A store it cannot write must never stop a quiz. The counter exists to report on the
# gate, so a counter that could block the gate would be the tail wagging the dog, and the
# failure is silent by design: there is nowhere for it to complain to.
forget_verdicts
mkdir -p "$FIXTURE/readonly"
chmod 500 "$FIXTURE/readonly"
record '[{"name":"changelog/visible"}]'
run "an unwritable store still quizzes" fire "$MERGE_CMD 42" "CLAUDE_QUIZ_VERDICT_DIR=$FIXTURE/readonly/nope"
# And a QUIET record still silences the quiz, so the unwritable store has not turned the
# gate itself off (L159).
record '[{"name":"changelog/none"}]'
run "an unwritable store still skips"   skip "$MERGE_CMD 42" "CLAUDE_QUIZ_VERDICT_DIR=$FIXTURE/readonly/nope"
chmod 700 "$FIXTURE/readonly"

forget_verdicts
no_record

# --- A repository can opt out by checking in a marker (claude-config#438) ---
#
# Dan asked for no quiz in claude-config, and that lived only in a session memory, so the
# hook fired on every merge there and the skip was re-decided by judgement each time. The
# marker is a file at the checkout root, the same shape as the repo relative paths
# lib/merge-target.sh reads to learn a repo carries its own merge tool.
#
# Every case uses a VISIBLE record, the strongest form: the one record that would
# otherwise always quiz, so a skip here can only be the marker's doing (L159).
opted_out_line() {  # $1 = command, $2 = session cwd ; prints the hook's whole output
  python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))
' "$1" "$2" | ( cd "$2" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" ) 2>/dev/null
}

record '[{"name":"changelog/visible"}]'
printf 'Dan does not want the quiz here.\n' > "$FIXTURE/repo/.no-pr-quiz"
run "an opted out repo does not quiz"   skip "$MERGE_CMD 42"

# It SAYS it skipped, in one line, and says why: a silent skip reads exactly like a hook
# that never fired (L98).
out="$(opted_out_line "$MERGE_CMD 42" "$FIXTURE/repo")"
msg="$(printf '%s' "$out" | jq -r '.systemMessage // ""' 2>/dev/null)"
if holds "$msg" "opted out" && holds "$msg" ".no-pr-quiz"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the opt out skip does not say so and name the marker (got: $out)"; fi
if [ "$(printf '%s\n' "$msg" | wc -l | tr -d ' ')" = "1" ] && [ -n "$msg" ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the opt out notice is not exactly one line (got: $msg)"; fi

# An opted out merge is not a quiz the label gate failed to silence, so it must not count
# toward the notice that says the gate never works (#354).
saw fired_since_quiet 0 "an opted out merge"
saw visible 0 "an opted out merge"

# From a subdirectory of the checkout: the marker belongs to the repo, not the cwd.
mkdir -p "$FIXTURE/repo/sub/dir"
out="$(opted_out_line "$MERGE_CMD 42" "$FIXTURE/repo/sub/dir")"
if holds "$out" '"block"'; then
  fail=$((fail+1)); echo "FAIL: a merge from a subdirectory of an opted out repo quizzed"
else pass=$((pass+1)); fi

# The repo the merge RUNS in decides, not the session cwd: a leading cd into a repo
# without the marker still quizzes from inside one that has it.
mkdir -p "$FIXTURE/other"
( cd "$FIXTURE/other" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
out="$(opted_out_line "cd $FIXTURE/other && $MERGE_CMD 42" "$FIXTURE/repo")"
if holds "$out" '"block"'; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: a cd into a repo without the marker was treated as opted out"; fi

# The control: the same record with the marker gone quizzes, so the skips above are the
# marker and not a fixture that never fires.
rm -f "$FIXTURE/repo/.no-pr-quiz"
run "the same repo without the marker"  fire "$MERGE_CMD 42"

# And this repository is opted out, which is the decision #438 exists to record. Only
# measurable where the suite runs from the claude-config checkout; the synced copy under
# ~/.claude/hooks has no repo root above it, so there it says UNMEASURED rather than
# passing or failing on a question it cannot answer (L411).
own_root="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$own_root" ] && [ -f "$own_root/payload/hooks/pr-merge-quiz.sh" ]; then
  if [ -f "$own_root/.no-pr-quiz" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: claude-config does not carry .no-pr-quiz at its root"; fi
else
  echo "UNMEASURED: not running from the claude-config checkout, so its own opt out was not checked"
fi

forget_verdicts
no_record

# --- Failure path: a broken or empty payload must fail QUIET, never fire or crash ---
raw() {
  local desc="$1" want="$2" rawpayload="$3"
  local out fired
  out="$(printf '%s' "$rawpayload" \
    | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" ) 2>/dev/null)"
  if printf '%s' "$out" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then fired="fire"; else fired="skip"; fi
  if [ "$fired" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $desc (wanted $want, got $fired)"; fi
}
raw "a malformed json payload"       skip 'not json at all'
raw "a payload with no command"      skip '{"tool_input":{},"cwd":"/tmp"}'
raw "an empty payload"               skip ''

# --- The instruction itself: the quiz must ask ONLY about how things behave now, never about the
#     old behavior or what the change fixed. Dan's spec (2026-07-29). The shell cannot check the
#     questions Claude ends up asking, so what it CAN pin is that the instruction it hands Claude
#     actually carries the constraint. Without these, a future edit could quietly drop it. ---
instruction() {
  printf '{"tool_input": {"command": "gh pr me%s 42"}, "cwd": "%s"}' "rge" "$FIXTURE/repo" \
    | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" ) 2>/dev/null
}
REASON="$(instruction)"

needs() {
  local desc="$1" phrase="$2"
  if holds "$REASON" "$phrase"; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    echo "FAIL: instruction $desc (missing: $phrase)"
  fi
}

needs "demands current behavior"          'current behavior'
needs "demands the present tense"         'present tense'
needs "forbids the old behavior"          'used to'
needs "forbids what-did-this-fix"         'what problem'
needs "forbids before-and-after"          'before the change'
needs "prefers a concrete scenario"       'scenario'

# A wrong answer means Dan expected something else, which is a product signal, not just a miss:
# the correction stays in the present tense AND he gets offered the chance to change the behavior
# to the one he picked. Dan's spec, 2026-07-29.
needs "corrects without looking back"     'without describing the old behavior'
needs "offers to change the behavior"     'change it to what he picked'
needs "captures a change as an issue"     'open a GitHub issue'

# The old framing that let past-tense questions in must be gone.
if holds "$REASON" 'Test BEHAVIOR AND IMPACT'; then
  fail=$((fail+1))
  echo "FAIL: instruction still carries the old open-ended behavior-and-impact framing"
else
  pass=$((pass+1))
fi

# --- The gate on WHETHER to quiz at all. Dan's spec, 2026-08-03: the quiz is for changes a person
#     could notice, not for changes to how the program works inside. The old gate only skipped
#     comments, docs, formatting and version bumps, so a test-only or refactor-only merge still
#     quizzed him. As with the question constraints above, the shell cannot check what Claude
#     actually decides, so what it CAN pin is that the instruction carries the rule. ---

absent() {
  local desc="$1" phrase="$2"
  if holds "$REASON" "$phrase"; then
    fail=$((fail+1))
    echo "FAIL: instruction $desc (must no longer contain: $phrase)"
  else
    pass=$((pass+1))
  fi
}

# The positive test: quiz only when someone could notice.
needs "gates on a noticeable difference"   'could notice a difference'
needs "counts what they see"               'what they see'
needs "counts what they interact with"     'what they interact with'
needs "counts what they receive and when"  'what they receive and when'

# Two categories Dan explicitly kept IN (2026-08-03), despite being invisible while things work.
needs "counts failure behavior"            'what happens when something goes wrong'
needs "counts a rare edge case fix"        'a fix to a rare edge case'

# For his own tooling, Dan is the user, so a change to how a hook or skill behaves still quizzes.
needs "makes Dan the user of his tooling"  'Dan IS the user'

# The skip list. Every one of these is a category Dan said he does not want quizzed.
needs "skips tests"                        'tests, fixtures'
needs "skips docs in any repo"             'documentation of any kind'
needs "skips refactors and internals"      'refactors and internal restructuring'
needs "skips perceptible speedups too"     'performance work, even a speedup'
needs "skips invisible groundwork"         'groundwork that ships nothing visible yet'
needs "rules out internals as a reason"    'never a reason to quiz'

# A skip must be VISIBLE and pushed back on, because a wider skip rule makes a wrong skip
# indistinguishable from the hook being broken.
needs "names its judgement on a skip"      'ONE line that names what you judged'
needs "invites a manual override"          'quiz me anyway'
needs "forbids a silent skip"              'Do not skip silently'

# A mixed merge fires, but only the user-facing slice is fair game, and the question count
# scales to that slice rather than to the size of the whole diff.
needs "fires on any user-facing change"    'the quiz fires'
needs "asks only about the user slice"     'only from the user-facing part'
needs "never asks about internals"        'never ask about the internal'
needs "scales the count to the slice"      'not the size of the whole diff'

# The old, far narrower gate must be gone, or the change has not actually taken effect.
absent "drops the old triviality framing"  'triviality gate'
absent "drops the old skip message"        'Nothing substantive shipped'
absent "drops the old narrow skip list"    'only comments, docs, formatting'
absent "drops the inconsequential test"    'If the change is inconsequential'

# --- The label is read from the repository the merge is about (claude-config#470) ---
#
# The label gate asked gh about the folder the session sits in whatever the merge named, so a
# merge carrying --repo, or a pull request given as a link, had its record read from another
# repository entirely: the quiz was decided by a stranger's pull request, or by gh answering
# nothing at all. block-red-merge.sh was taught to resolve this in claude-config#463.
#
# Its own fixture, with two repositories and a gh that resolves one the way the real one does:
# --repo or -R first, then the remote of the directory it runs in. It answers a pull request only
# for a repository with a file under prs/, and gh's own not found otherwise.
PAIR="$(mktemp -d)"
mkdir -p "$PAIR/repo" "$PAIR/other" "$PAIR/bin" "$PAIR/prs"
( cd "$PAIR/repo" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
( cd "$PAIR/other" && git init -q && git remote add origin "https://github.com/other/repo.git" )
cat > "$PAIR/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_CALL_LOG"
repo="" prev=""
for a in "$@"; do
  case "$prev" in --repo|-R) repo="$a" ;; esac
  case "$a" in --repo=*) repo="${a#--repo=}" ;; esac
  prev="$a"
done
[ -n "$repo" ] || repo=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^https://github.com/##; s#[.]git$##')
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*)
    f="$GH_FIXTURE/prs/$(printf '%s' "$repo" | tr / _)"
    if [ -f "$f" ]; then cat "$f"; exit 0; fi
    echo "GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)" >&2
    exit 1 ;;
esac
SH
chmod +x "$PAIR/bin/gh"
export GH_FIXTURE="$PAIR"
export GH_CALL_LOG="$PAIR/gh-calls.log"

pair_record() {  # $1 = owner/name, $2 = a JSON labels array
  printf '{"number":7,"url":"https://github.com/%s/pull/7","labels":%s}' "$1" "$2" \
    > "$PAIR/prs/$(printf '%s' "$1" | tr / _)"
}
pair_run() {  # $1 = description, $2 = fire | skip, $3 = command
  local out fired
  : > "$GH_CALL_LOG"
  out="$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))
' "$3" "$PAIR/repo" | ( cd "$PAIR/repo" && env "PATH=$PAIR/bin:$PATH" "$HOOK" ) 2>/dev/null)"
  # Matched with the shell's own builtin, WITHOUT a pipe: a producer piped into a quiet grep
  # can report a failure that never happened (L183), which is what the ratchet watches for.
  if holds "$out" '"decision":"block"' || holds "$out" '"decision": "block"'; then
    fired="fire"
  else
    fired="skip"
  fi
  if [ "$fired" = "$2" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: $1 (wanted $2, got $fired)"; fi
}
pair_asked_about() {  # $1 = a literal the gh call log must hold
  case "$(cat "$GH_CALL_LOG")" in *"$1"*) return 0 ;; *) return 1 ;; esac
}

# The record that would silence the quiz lives in the NAMED repository, and the folder's own
# pull request carries the one that would fire, so only reading the named repository can skip.
forget_verdicts
pair_record other/repo '[{"name":"changelog/none"}]'
pair_record acme/widget '[{"name":"changelog/visible"}]'
for form in "--repo other/repo" "-R other/repo" "--repo=other/repo"; do
  pair_run "a quiet record in the repository [$form] names" skip "$MERGE_CMD 7 $form --squash"
  if pair_asked_about "pr view 7 --repo other/repo"; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: [$form] did not make the quiz ask gh about other/repo: $(cat "$GH_CALL_LOG")"; fi
done

# Never loosened: the same route with a VISIBLE record still quizzes, so the skips above are the
# record's doing rather than a reading that fails open on every named repository (L159).
pair_record other/repo '[{"name":"changelog/visible"}]'
pair_record acme/widget '[{"name":"changelog/none"}]'
pair_run "a visible record in the named repository" fire "$MERGE_CMD 7 --repo other/repo --squash"

# A pull request given as a link names both the repository and the number, which is what gh does
# with it.
pair_record other/repo '[{"name":"changelog/none"}]'
pair_record acme/widget '[{"name":"changelog/visible"}]'
pair_run "a quiet record reached by a link" skip "$MERGE_CMD https://github.com/other/repo/pull/7 --squash"
if pair_asked_about "pr view 7 --repo other/repo"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: a link did not make the quiz ask gh about other/repo pull request 7: $(cat "$GH_CALL_LOG")"; fi

# A pull request that is not there is its own verdict, not "gh answered nothing": one means the
# repository was wrong, the other that gh is not answering at all, and they need different
# remedies (L11). Firing either way, because this gate fails open on every route.
forget_verdicts
pair_run "a pull request that is not there still quizzes" fire "$MERGE_CMD 7 --repo nobody/there --squash"
saw not-found 1 "a pull request that is not there"
saw no-answer 0 "a pull request that is not there"
forget_verdicts
rm -rf "$PAIR"
unset GH_FIXTURE GH_CALL_LOG

rm -rf "$FIXTURE"

echo
echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
