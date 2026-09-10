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
  if printf '%s' "$REASON" | grep -qF "$phrase"; then
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
if printf '%s' "$REASON" | grep -qF 'Test BEHAVIOR AND IMPACT'; then
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
  if printf '%s' "$REASON" | grep -qF "$phrase"; then
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

rm -rf "$FIXTURE"

echo
echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
