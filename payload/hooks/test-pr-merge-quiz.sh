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

# The third tool, and the one this hook never named: lib/merge-target.sh reads WHICH pull request
# and WHICH repository the merge names with python3 (claude-config#475). Without it both come back
# empty, so the label is read from whatever pull request the current branch resolves to, and the
# quiet record above silences the quiz for a merge nobody identified. Its own verdict name,
# because one name covering two causes cannot tell them apart (L11).
#
# /usr/bin holds a python3, so this one needs a bare directory rather than a trimmed PATH: the
# tools the hook needs, its fake gh included, and nothing else.
NOPY="$FIXTURE/nopython"; mkdir -p "$NOPY"
for t in bash sh git jq node grep sed awk tr cat cut head sort dirname basename env uname mkdir mv rm; do
  p="$(command -v "$t" 2>/dev/null)"
  [ -n "$p" ] && [ "$p" != "$FIXTURE/bin/$t" ] && ln -s "$p" "$NOPY/$t" 2>/dev/null
done
ln -s "$FIXTURE/bin/gh" "$NOPY/gh" 2>/dev/null
if PATH="$NOPY" bash -c 'command -v python3 >/dev/null 2>&1'; then
  fail=$((fail+1)); echo "FAIL: the bare directory still reaches a python3, so this case measures nothing"
else pass=$((pass+1)); fi
forget_verdicts
run "python3 not on PATH quizzes"       fire 'gh pr merge 42' "PATH=$NOPY"
saw no-python3 1 "a merge whose own arguments could not be read"
forget_verdicts
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

# A CUT is not something the label gate recorded (#1817): it is the held quiz release giving up on a
# GitHub answer. So the notice, which names what the GATE recorded, never lists it, or a slow
# GitHub at turn end would read as a reason the gate is failing (L11).
forget_verdicts
mkdir -p "$CLAUDE_QUIZ_VERDICT_DIR"
printf 'cut 3\nno-label 9\nfired_since_quiet 9\nwarned 0\n' > "$CLAUDE_QUIZ_VERDICT_DIR/counts"
record '[{"name":"priority-p2"}]'
tenth="$(reason_of "$MERGE_CMD 42")"
if holds "$tenth" "without once silencing" && holds "$tenth" "no-label 10"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the seeded notice did not fire, so the cut case below measures nothing"; fi
if holds "$tenth" "cut 3"; then
  fail=$((fail+1)); echo "FAIL: the label gate's notice lists the release's cut answers as something the gate recorded"
else pass=$((pass+1)); fi
saw cut 3 "a merge quizzed after earlier cut answers"

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

# The notice is one valid JSON object whatever the repository is called, with jq or without it
# (claude-config#1906). Without jq it used to be built by hand, escaping only backslashes and
# quotes, so a folder name holding a tab made it invalid output, a hook failure nobody reads.
NOJQ="$FIXTURE/nojq"; mkdir -p "$NOJQ"
IFS=: read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  for f in "$d"/*; do
    n="${f##*/}"
    [ "$n" = jq ] && continue
    [ -x "$f" ] && [ ! -e "$NOJQ/$n" ] && ln -s "$f" "$NOJQ/$n"
  done
done
ODD_REPO="$FIXTURE/odd	repo"
cp -R "$FIXTURE/repo" "$ODD_REPO"
. "$DIR/lib/hook-notice.sh"
for arm in "$PATH" "$NOJQ"; do
  name="with jq"; [ "$arm" = "$NOJQ" ] && name="without jq"
  out="$(python3 -c 'import json, sys; print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$MERGE_CMD 42" "$ODD_REPO" \
    | ( cd "$ODD_REPO" && env "PATH=$FIXTURE/bin:$arm" "$HOOK" ) 2>/dev/null)"
  why="$(hook_notice_verdict "$out" 'odd\trepo has opted out')"
  if [ -z "$why" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: #1906 $name, the opt out notice for a folder named with a tab is not one valid systemMessage: $why"; fi
done
rm -rf "$ODD_REPO"

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
  echo "SUITE-PART-UNMEASURED not running from the claude-config checkout, so its own opt out was not checked"
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
# Three guards the 2026-10-15 trim first dropped and the lessons review caught: the issue goes to the
# repo the merge ran in (a session's repo can differ: a cd, a --repo, several merges), no coding
# starts mid quiz, and a merge named without a number is resolved before its diff is read.
needs "files the issue where the merge ran"  'in the repo you just merged in'
needs "does not start coding mid quiz"       'do NOT start coding in the middle of the quiz'
needs "resolves a merge with no number"      'resolve the PR for the merged branch first'

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

# Failure behavior Dan kept IN (2026-08-03), despite being invisible while things work.
needs "counts failure behavior"            'what happens when something goes wrong'

# BUG FIXES ARE NOT QUIZZED, a rare edge case fix included (Dan's standing rule, 2026-09-07, on
# #2048: "skip quiz. this is a bug fix, not a change"; approved into the hook 2026-10-15). A fix
# makes the product do what it was always meant to do, so there is nothing new to learn, and he is
# usually the one who reported it. The quiz is for deliberate changes. This reverses the 2026-08-03
# rule that counted a rare edge case fix IN, so its old wording must be gone.
needs "quizzes only deliberate changes"    'deliberate change'
needs "skips bug fixes"                    'bug fixes, including a fix to a rare edge case'
absent "no longer counts an edge case fix in" 'something goes wrong, or a fix to a rare edge case'
absent "no longer counts an edge case fix in, old wording" 'since that situation now behaves differently'

# SHORT (hook trim, 2026-10-15). The instruction was 5,213 characters on every quizzed merge, 878K
# characters in Slate sessions Oct 1 to 15 2026, each re-read by every later request. Every rule
# above still has to fit; this keeps a regrowth from going unnoticed.
quiz_len="$(printf '%s' "$REASON" | jq -r '.reason // ""' 2>/dev/null | python3 -c 'import sys; print(len(sys.stdin.read()))')"
if [ "${quiz_len:-0}" -gt 0 ] && [ "$quiz_len" -le 2600 ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the quiz instruction stays at or under 2,600 characters (it is ${quiz_len:-unreadable})"
fi

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

# --- Every merge in a command is read, not only the first (claude-config#1082) ---
#
# The merge gates refuse a command merging more than one pull request (#1072), so this hook sees two
# only when an override let them through. It read the first merge's record alone, so a quiet first
# merge silenced the quiz for a visible second one. The overrides go on the command as they would be
# typed; this hook reads none of them.
pair_record other/repo '[{"name":"changelog/none"}]'
pair_record acme/widget '[{"name":"changelog/visible"}]'
TWO="SKIP_PR_REVIEW=1 $MERGE_CMD 7 --repo other/repo --squash && $MERGE_CMD 7 --repo acme/widget --squash"
pair_run "a quiet first merge does not silence a visible second one" fire "$TWO"
if pair_asked_about "pr view 7 --repo acme/widget"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: #1082 the second merge's record was never read: $(cat "$GH_CALL_LOG")"; fi
two_out="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$TWO" "$PAIR/repo" \
  | ( cd "$PAIR/repo" && env "PATH=$PAIR/bin:$PATH" "$HOOK" ) 2>/dev/null)"
if holds "$two_out" "#7 in other/repo" && holds "$two_out" "#7 in acme/widget"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: #1082 the quiz does not name every pull request the command merged: $two_out"; fi
# Both quiet: nothing user facing in either, so the quiz is silenced as for one merge.
pair_record acme/widget '[{"name":"changelog/none"}]'
pair_run "two quiet merges are silenced together" skip "$TWO"
# One merge in a repository that opted out does not opt the other one out.
mkdir -p "$PAIR/quiet"
( cd "$PAIR/quiet" && git init -q && git remote add origin "https://github.com/other/repo.git" )
printf 'no quiz here\n' > "$PAIR/quiet/.no-pr-quiz"
pair_record other/repo '[{"name":"changelog/visible"}]'
pair_record acme/widget '[{"name":"changelog/visible"}]'
pair_run "an opted out first merge does not skip the second" fire \
  "cd $PAIR/quiet && SKIP_PR_REVIEW=1 $MERGE_CMD 7 --squash; cd $PAIR/repo && $MERGE_CMD 7 --squash"
printf 'no quiz here\n' > "$PAIR/repo/.no-pr-quiz"
pair_run "both merges in opted out repositories skip" skip \
  "cd $PAIR/quiet && SKIP_PR_REVIEW=1 $MERGE_CMD 7 --squash; cd $PAIR/repo && $MERGE_CMD 7 --squash"
rm -f "$PAIR/repo/.no-pr-quiz"
forget_verdicts
rm -rf "$PAIR"
unset GH_FIXTURE GH_CALL_LOG

# --- #568: a slow gh never silences the quiz ---------------------------------------------------
# The hook is registered with a 15 second timeout (a setting, not a measurement), and a hook the harness kills emits nothing,
# which reads exactly like a decision not to quiz. So the label read has its own, shorter deadline:
# past it the quiz FIRES, says the label could not be read in time, and the verdict store says why.
# The pull request carries changelog/none, which WOULD silence the quiz if it were read in time, so
# a fire here can only come from the deadline (L159). And the hook records that it started before
# any network read, so even a kill leaves a trace (#354).
forget_verdicts
record '[{"name":"changelog/none"}]'
SLOW="$FIXTURE/slowbin"; mkdir -p "$SLOW"
cat > "$SLOW/gh" <<'SH'
case "$*" in
  *"auth status"*) : ;;
  *"pr view"*) sleep 30; cat "$FAKE_PR_JSON" ;;
esac
SH
chmod +x "$SLOW/gh"
slow_payload="$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":"gh pr merge 42 --squash"},"cwd":sys.argv[1]}))' "$FIXTURE/repo")"
t0=$SECONDS
slow_out="$(printf '%s' "$slow_payload" | ( cd "$FIXTURE/repo" && env "PATH=$SLOW:$PATH" QUIZ_LABEL_DEADLINE_SECONDS=1 "$HOOK" ) 2>/dev/null)"
took=$((SECONDS - t0))
if holds "$slow_out" '"decision":"block"'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a label read past its deadline still fires the quiz (got: ${slow_out:0:200})"; fi
if [ "$took" -lt 10 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the hook answered inside the harness's 15 second timeout (took ${took}s)"; fi
if holds "$slow_out" 'could not be read in time'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the quiz says the label could not be read in time"; fi
saw label-timeout 1 "a label read past its deadline"
saw started 1 "a hook run that reached the label gate"
# A gate past its deadline is stopped outright and reaped before the hook says anything (#1989). It
# was asked to stop with TERM and left: a gh ignoring TERM went on running after the hook had
# answered, and the gate, never waited for on that path, could exit while the hook was printing its
# decision, which bash 3.2 then cuts short (L1035). The stand in ignores TERM, so only a KILL ends it.
forget_verdicts
STUBBORN="$FIXTURE/stubbornbin"; mkdir -p "$STUBBORN"
cat > "$STUBBORN/gh" <<'SH'
case "$*" in
  *"auth status"*) : ;;
  *"pr view"*) echo "$$" > "$STUBBORN_PID_FILE"; exec perl -e '$SIG{TERM} = "IGNORE"; sleep 30' ;;
esac
SH
chmod +x "$STUBBORN/gh"
rm -f "$FIXTURE/stubborn.pid"
stubborn_out="$(printf '%s' "$slow_payload" | ( cd "$FIXTURE/repo" && env "PATH=$STUBBORN:$PATH" STUBBORN_PID_FILE="$FIXTURE/stubborn.pid" QUIZ_LABEL_DEADLINE_SECONDS=1 "$HOOK" ) 2>/dev/null)"
stubborn_pid="$(cat "$FIXTURE/stubborn.pid" 2>/dev/null)"
stubborn_left=""
if [ -n "$stubborn_pid" ]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$stubborn_pid" 2>/dev/null || break; sleep 0.2; done
  kill -0 "$stubborn_pid" 2>/dev/null && stubborn_left=1
fi
if [ -n "$stubborn_pid" ] && [ -z "$stubborn_left" ] && holds "$stubborn_out" '"decision":"block"'; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: #1989 a label gate past its deadline is stopped even when it ignores TERM, and the quiz still fires (gate pid '${stubborn_pid:-never recorded}', still running: ${stubborn_left:-no}; got: ${stubborn_out:0:120})"; fi
[ -n "$stubborn_pid" ] && kill -9 "$stubborn_pid" 2>/dev/null
# And the control: the same label read in time silences the quiz, so the fire above is the deadline.
forget_verdicts
run "the same changelog/none label read in time is quiet" skip "gh pr merge 42 --squash"

# ---- skipped for the rest of a session (claude-config#623) ----
# Dan answered "skip" about 13 times across 8 Sonar sessions, once as "skip all quizzes for the
# rest of this session", which held only while Claude remembered it. The hook now reads a snooze
# kept per session id, set by the command its own instruction names, so a later merge in that
# session is skipped by the hook itself, and announced in one line, never silently (L98).
forget_verdicts
record '[{"name":"changelog/visible"}]'
session_line() {  # $1 = session id ; prints the hook's whole output for a visible merge
  python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": "gh pr merge 42 --squash"}, "cwd": sys.argv[1], "session_id": sys.argv[2]}))
' "$FIXTURE/repo" "$1" | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" ) 2>/dev/null
}
SID_A="3f1c2b8e-0a4d-4c55-9e21-7b6d1a2c9f00"
SID_B="8d2e4f60-1b3c-4a7d-8e9f-0c1d2e3f4a5b"

# Before any snooze the quiz fires, and its instruction names the exact command that snoozes
# this session, with this session's id in it, and says one skip ends the whole set.
out="$(session_line "$SID_A")"
reason="$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null)"
if holds "$out" '"block"'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a visible merge with no snooze does not quiz (got: ${out:0:200})"; fi
if holds "$reason" "bash $(printf '%q' "$HOOK") --snooze-session $SID_A"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the quiz does not name the snooze command for this session"; fi
if holds "$reason" "skips every remaining question"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the quiz does not say a skip ends the whole set"; fi

# The command it names: run as the instruction gives it, it snoozes that session alone.
snooze_out="$(bash "$HOOK" --snooze-session "$SID_A" 2>&1)"; snooze_rc=$?
if [ "$snooze_rc" = 0 ] && holds "$snooze_out" "rest of this session"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the snooze command did not confirm (rc=$snooze_rc, got: $snooze_out)"; fi
out="$(session_line "$SID_A")"
msg="$(printf '%s' "$out" | jq -r '.systemMessage // ""' 2>/dev/null)"
if holds "$out" '"block"'; then fail=$((fail+1)); echo "FAIL: a snoozed session was quizzed"; else pass=$((pass+1)); fi
if holds "$msg" "rest of this session" && [ "$(printf '%s\n' "$msg" | wc -l | tr -d ' ')" = "1" ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the snoozed skip does not say so in one line (got: $out)"; fi
# Another session is still quizzed: the snooze is this session's, not the machine's.
out="$(session_line "$SID_B")"
if holds "$out" '"block"'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a snooze in one session silenced another"; fi
# A snoozed merge is not a quiz the label gate failed to silence (#354).
saw fired_since_quiet 2 "two quizzed merges and one snoozed merge"

# An id that is not one refuses, rather than writing a path built from it.
# The path checked is the one that id would write if it were accepted (the snooze folder plus the
# id), and the folder's listing must not change, so the "nothing written" half can fail (#790, L159).
snoozed_before="$(ls -A "$CLAUDE_QUIZ_VERDICT_DIR/snoozed" 2>/dev/null)"
bad_out="$(bash "$HOOK" --snooze-session '../escaped' 2>&1)"; bad_rc=$?
if [ "$bad_rc" != 0 ] && [ ! -e "$CLAUDE_QUIZ_VERDICT_DIR/snoozed/../escaped" ] \
   && [ "$(ls -A "$CLAUDE_QUIZ_VERDICT_DIR/snoozed" 2>/dev/null)" = "$snoozed_before" ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: a malformed session id was accepted (rc=$bad_rc, got: $bad_out)"; fi
# And with no session id in the payload the snooze cannot apply, so the quiz fires (fails open).
run "a merge whose payload carries no session id still quizzes" fire "gh pr merge 42 --squash"

# ---- the review findings on #779 (claude-config#790) ----
# A snoozed merge is recorded, so a skip leaves a trace in the counts (L357).
forget_verdicts
bash "$HOOK" --snooze-session "$SID_A" >/dev/null 2>&1
session_line "$SID_A" >/dev/null
saw snoozed 1 "a merge in a snoozed session"
saw fired_since_quiet 0 "a merge in a snoozed session"

# A snooze older than its expiry no longer silences the quiz, whether or not any newer snooze was
# written to sweep it (L523).
SID_OLD="5a6b7c8d-1111-4222-8333-944455556666"
bash "$HOOK" --snooze-session "$SID_OLD" >/dev/null 2>&1
touch -t "$(date -v-15d +%Y%m%d%H%M 2>/dev/null || date -d '15 days ago' +%Y%m%d%H%M)" "$CLAUDE_QUIZ_VERDICT_DIR/snoozed/$SID_OLD"
out="$(session_line "$SID_OLD")"
if holds "$out" '"block"'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a snooze past its expiry still silenced the quiz (got: ${out:0:200})"; fi
# And one inside its expiry still holds, so the fire above is the age.
touch -t "$(date -v-13d +%Y%m%d%H%M 2>/dev/null || date -d '13 days ago' +%Y%m%d%H%M)" "$CLAUDE_QUIZ_VERDICT_DIR/snoozed/$SID_OLD"
out="$(session_line "$SID_OLD")"
if holds "$out" '"block"'; then fail=$((fail+1)); echo "FAIL: a snooze inside its expiry did not hold"; else pass=$((pass+1)); fi

# The snooze command works in a detached run too: the early exit for a run with nobody to quiz is
# about quizzing, and must not swallow a command that was asked for by name (L98).
SID_DET="7e8f9a0b-2222-4333-8444-a55566667777"
det_out="$(CLAUDE_DETACHED_RUN=1 bash "$HOOK" --snooze-session "$SID_DET" 2>&1)"
if [ -f "$CLAUDE_QUIZ_VERDICT_DIR/snoozed/$SID_DET" ] && holds "$det_out" "rest of this session"; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the snooze command in a detached run wrote nothing (got: $det_out)"; fi

# The command the quiz names is RUN, exactly as written, from a hooks folder whose path holds an
# apostrophe and a space, and it must snooze the session (L406: a remedy is executed by a test).
QDIR="$FIXTURE/Dan's hooks"
ln -s "$DIR" "$QDIR"
SID_Q="9c0d1e2f-3333-4444-8555-b66677778888"
q_reason="$(python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": "gh pr merge 42 --squash"}, "cwd": sys.argv[1], "session_id": sys.argv[2]}))
' "$FIXTURE/repo" "$SID_Q" | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" bash "$QDIR/pr-merge-quiz.sh" ) 2>/dev/null | jq -r '.reason // ""')"
q_cmd="${q_reason##*run exactly this command, then confirm in one line: }"
if [ -n "$q_cmd" ] && [ "$q_cmd" != "$q_reason" ]; then
  bash -c "$q_cmd" >/dev/null 2>&1
  if [ -f "$CLAUDE_QUIZ_VERDICT_DIR/snoozed/$SID_Q" ]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL: the named snooze command, run as written, snoozed nothing (it was: $q_cmd)"; fi
else
  fail=$((fail+1)); echo "FAIL: the quiz from a quoted path named no snooze command"
fi

# ---- a merge command still running in the background is not quizzed yet (claude-config#1768) ----
# A merge command that passes the Bash tool's 600 s foreground limit is moved to the background, and
# PostToolUse fires right then, before anything merged. Seen 2026-10-26 in PostRoll: the quiz was
# demanded at 19:41:32 UTC and the merge landed at 19:43. Claude Code says so in tool_response: the
# moved call carried {"backgroundTaskId": "b1y5zlrqd", "timedOutAfterMs": 600000} in that session's
# transcript, and a run_in_background call reached a PostToolUse hook carrying backgroundTaskId in
# tool_response (measured with a headless run, 2026-10-26). So the quiz is HELD, per session, and
# asked by the Stop hook (--release-held) at the first turn end after GitHub says it merged.
forget_verdicts
# The session registry the sweep of old holds asks (#1787), pointed at a fixture so no case here
# reads the registry of the sessions really running on this Mac.
export CLAUDE_SESSION_REGISTRY_DIR="$FIXTURE/registry"
SID_H="5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
SID_H2="6b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e"
held_file() { printf '%s/held/%s' "$CLAUDE_QUIZ_VERDICT_DIR" "$1"; }
# $1 = session id ("" for none), $2 = bg|rib|fg ; prints the PostToolUse output for gh pr merge 42
post_merge() {
  python3 -c '
import json, sys
sid, how = sys.argv[2], sys.argv[3]
resp = {"stdout": "", "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False}
inp = {"command": "gh pr merge 42 --squash"}
if how == "bg":
    resp.update({"backgroundTaskId": "b1y5zlrqd", "timedOutAfterMs": 600000})
elif how == "rib":
    inp["run_in_background"] = True
    resp["backgroundTaskId"] = "bglcf09qp"
else:
    resp["stdout"] = "Merged pull request #42"
d = {"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": inp, "tool_response": resp, "cwd": sys.argv[1]}
if sid:
    d["session_id"] = sid
print(json.dumps(d))
' "$FIXTURE/repo" "$1" "$2" | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" ) 2>/dev/null
}
# $1 = session id ; prints the Stop hook's output
turn_end() {
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "Stop", "session_id": sys.argv[2], "stop_hook_active": False, "cwd": sys.argv[1]}))
' "$FIXTURE/repo" "$1" | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" --release-held ) 2>/dev/null
}
pr_state() {  # $1 = OPEN|MERGED|CLOSED
  printf '{"number":42,"url":"https://github.com/acme/widget/pull/42","state":"%s","mergedAt":%s,"labels":[{"name":"changelog/visible"}]}' \
    "$1" "$([ "$1" = MERGED ] && printf '"2026-10-26T19:43:00Z"' || printf 'null')" > "$FAKE_PR_JSON"
}
check() {  # $1 = 0 when the assertion held, $2 = what failed
  if [ "$1" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $2"; fi
}

# A merge moved to the background demands no quiz, says it is held, and is recorded for the session.
pr_state OPEN
out="$(post_merge "$SID_H" bg)"
holds "$out" '"block"'; check $((! $?)) "a merge moved to the background demanded the quiz before it merged (got: ${out:0:200})"
holds "$out" "held"; check $? "the held quiz is not announced (got: ${out:0:200})"
[ -s "$(held_file "$SID_H")" ]; check $? "a merge moved to the background was not recorded as held"
saw started 0 "a held merge (the label gate is read when it is released, not now)"
saw held 1 "a held merge"

# run_in_background is the same case from the start.
out="$(post_merge "$SID_H2" rib)"
holds "$out" '"block"'; check $((! $?)) "a run_in_background merge demanded the quiz before it merged (got: ${out:0:200})"
[ -s "$(held_file "$SID_H2")" ]; check $? "a run_in_background merge was not recorded as held"

# A finished foreground merge, with the same tool_response shape, still quizzes at once.
out="$(post_merge "$SID_H" fg)"
holds "$out" '"block"'; check $? "a finished foreground merge no longer quizzes (got: ${out:0:200})"

# With no session id the hold cannot be kept, so the quiz fires (fails open) but says the merge was
# still running, so Claude waits for its output before Step 1.
out="$(post_merge "" bg)"
holds "$out" '"block"'; check $? "a backgrounded merge with no session id was silenced"
holds "$out" "moved to the background"; check $? "the fallback quiz does not say the merge was still running (got: ${out:0:300})"

# A turn end while the pull request is still open: nothing asked, the hold kept.
pr_state OPEN
out="$(turn_end "$SID_H")"
[ -z "$out" ]; check $? "a turn end with the merge still open said something (got: ${out:0:200})"
[ -s "$(held_file "$SID_H")" ]; check $? "a turn end with the merge still open dropped the hold"

# A turn end when GitHub answers nothing: kept, never released and never dropped.
no_record
out="$(turn_end "$SID_H")"
holds "$out" '"block"'; check $((! $?)) "a turn end with no answer from GitHub released the quiz"
[ -s "$(held_file "$SID_H")" ]; check $? "a turn end with no answer from GitHub dropped the hold"

# Another session's turn end does not touch this session's hold.
pr_state MERGED
rm -f "$(held_file "$SID_H2")"
out="$(turn_end "$SID_H2")"
[ -z "$out" ]; check $? "a session with nothing held said something at its turn end (got: ${out:0:200})"
[ -s "$(held_file "$SID_H")" ]; check $? "another session's turn end released this session's hold"

# Once GitHub says it merged, the next turn end asks for the quiz, naming the merge, and only once.
started_before="$(count_of started)"
out="$(turn_end "$SID_H")"
holds "$out" '"block"'; check $? "a backgrounded merge that later merged was never quizzed (got: ${out:0:200})"
reason="$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null)"
holds "$reason" "comprehension quiz"; check $? "the released block is not the quiz instruction (got: ${reason:0:200})"
holds "$reason" "#42"; check $? "the released quiz does not name the merged pull request (got: ${reason:0:200})"
[ ! -s "$(held_file "$SID_H")" ]; check $? "a released hold was kept, so it would quiz again"
saw started $((started_before + 1)) "a released merge goes through the label gate"
out="$(turn_end "$SID_H")"
[ -z "$out" ]; check $? "a released quiz was asked again at the next turn end (got: ${out:0:200})"

# The released quiz still honours the label gate: a quiet label releases the hold with no quiz.
post_merge "$SID_H" bg >/dev/null
printf '{"number":42,"url":"https://github.com/acme/widget/pull/42","state":"MERGED","mergedAt":"2026-10-26T19:43:00Z","labels":[{"name":"changelog/none"}]}' > "$FAKE_PR_JSON"
out="$(turn_end "$SID_H")"
holds "$out" '"block"'; check $((! $?)) "a released merge with a quiet label was quizzed"
[ ! -s "$(held_file "$SID_H")" ]; check $? "a released merge with a quiet label kept its hold"

# Closed without merging: the hold is dropped, said in one line, no quiz.
post_merge "$SID_H" bg >/dev/null
pr_state CLOSED
out="$(turn_end "$SID_H")"
holds "$out" '"block"'; check $((! $?)) "a pull request closed without merging was quizzed"
holds "$out" "closed without merging"; check $? "a dropped hold for a closed pull request is not said (got: ${out:0:200})"
[ ! -s "$(held_file "$SID_H")" ]; check $? "a closed pull request's hold was kept"

# A hold is never dropped for its age (Dan, 2026-10-26: "Never drop it"): a pull request still open
# days later keeps its hold, says nothing, and is still quizzed once GitHub says it merged.
post_merge "$SID_H" bg >/dev/null
jq -c '.heldAt = (.heldAt - 864000)' "$(held_file "$SID_H")" > "$FIXTURE/held.tmp" && mv "$FIXTURE/held.tmp" "$(held_file "$SID_H")"
pr_state OPEN
out="$(turn_end "$SID_H")"
[ -z "$out" ]; check $? "a ten day old hold on an open pull request said something (got: ${out:0:200})"
[ -s "$(held_file "$SID_H")" ]; check $? "a ten day old hold on an open pull request was dropped for its age"
pr_state MERGED
out="$(turn_end "$SID_H")"
holds "$out" '"block"'; check $? "a ten day old hold was not quizzed once it merged (got: ${out:0:200})"
[ ! -s "$(held_file "$SID_H")" ]; check $? "a ten day old hold was kept after its quiz was released"

# The sweep of old hold files removes a file only once its SESSION has ended (#1787). A session left
# open with no turn end for days never rewrites its file, so the file's age says nothing about whether
# the session is still there; the session registry does (open: not closed, and beating within five
# minutes). Every other session's hold written meanwhile runs the sweep, here SID_H's.
SID_IDLE="7c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f"     # open, idle three days: kept
SID_CLOSED="8d9e0f1a-2b3c-4d4e-9f5a-6b7c8d9e0f1a"   # closed cleanly: removed
SID_SILENT="9e0f1a2b-3c4d-4e5f-8a6b-7c8d9e0f1a2b"   # crashed, silent for an hour: removed
SID_GONE="0f1a2b3c-4d5e-4f6a-9b7c-8d9e0f1a2b3c"     # ended long ago, its record archived: removed
SID_DAMAGED="1a2b3c4d-5e6f-4a7b-8c8d-9e0f1a2b3c4d"  # its record cannot be read: kept
NOW_MS="$(( $(date +%s) * 1000 ))"
reg_record() {  # $1 = session id, $2 = lastSeen ms, $3 = closedAt ms or null
  mkdir -p "$CLAUDE_SESSION_REGISTRY_DIR"
  printf '{"v":1,"sessionId":"%s","cwd":"%s","repoRoot":null,"startedAt":1,"lastSeen":%s,"closedAt":%s,"transcriptPath":null,"edits":[]}' \
    "$1" "$FIXTURE/repo" "$2" "$3" > "$CLAUDE_SESSION_REGISTRY_DIR/$1.json"
}
old_hold() {  # $1 = file name under held/ ; a hold untouched for three days
  mkdir -p "$CLAUDE_QUIZ_VERDICT_DIR/held"
  printf '{"heldAt":1,"merges":[{"dir":"","repo":"","slug":"acme/widget","pr":"42"}],"payload":{}}\n' > "$CLAUDE_QUIZ_VERDICT_DIR/held/$1"
  touch -t "$(date -v-3d +%Y%m%d%H%M 2>/dev/null || date -d '3 days ago' +%Y%m%d%H%M)" "$CLAUDE_QUIZ_VERDICT_DIR/held/$1"
}
seed_old_holds() {
  rm -rf "$CLAUDE_QUIZ_VERDICT_DIR/held" "$CLAUDE_SESSION_REGISTRY_DIR"
  old_hold "$SID_IDLE"; old_hold "$SID_CLOSED"; old_hold "$SID_SILENT"; old_hold "$SID_GONE"; old_hold "$SID_DAMAGED"
  old_hold "$SID_CLOSED.releasing.4242"; old_hold "$SID_IDLE.releasing.4243"
  reg_record "$SID_H" "$NOW_MS" null
  reg_record "$SID_IDLE" "$((NOW_MS - 30000))" null
  reg_record "$SID_CLOSED" "$((NOW_MS - 3600000))" "$((NOW_MS - 3600000))"
  reg_record "$SID_SILENT" "$((NOW_MS - 3600000))" null
  printf '{"v":1,"sessionId":' > "$CLAUDE_SESSION_REGISTRY_DIR/$SID_DAMAGED.json"
}
pr_state OPEN
seed_old_holds
post_merge "$SID_H" bg >/dev/null
[ -s "$(held_file "$SID_IDLE")" ]; check $? "the sweep removed the old hold of a session that is open but idle (#1787)"
[ -s "$(held_file "$SID_IDLE.releasing.4243")" ]; check $? "the sweep removed an open session's part released hold"
[ ! -e "$(held_file "$SID_CLOSED")" ]; check $? "the sweep kept the old hold of a session that has closed"
[ ! -e "$(held_file "$SID_CLOSED.releasing.4242")" ]; check $? "the sweep kept a closed session's part released hold"
[ ! -e "$(held_file "$SID_SILENT")" ]; check $? "the sweep kept the old hold of a session silent for an hour"
[ ! -e "$(held_file "$SID_GONE")" ]; check $? "the sweep kept the old hold of a session no longer in the registry"
[ -s "$(held_file "$SID_DAMAGED")" ]; check $? "the sweep removed a hold whose session's record cannot be read"
[ -s "$(held_file "$SID_H")" ]; check $? "the sweeping session's own new hold is missing"

# An unreadable answer about liveness keeps everything: no registry folder at all, and a registry that
# does not show the sweeping session itself open (so its absences are not evidence anything ended).
seed_old_holds
rm -rf "$CLAUDE_SESSION_REGISTRY_DIR"
post_merge "$SID_H" bg >/dev/null
[ -s "$(held_file "$SID_CLOSED")" ] && [ -s "$(held_file "$SID_GONE")" ]; check $? "the sweep removed holds with no session registry to ask"
seed_old_holds
rm -f "$CLAUDE_SESSION_REGISTRY_DIR/$SID_H.json"
post_merge "$SID_H" bg >/dev/null
[ -s "$(held_file "$SID_GONE")" ] && [ -s "$(held_file "$SID_SILENT")" ]; check $? "the sweep believed a registry that does not show the sweeping session open"
# No python3 to ask the registry with: nothing is removed, and the new hold is still kept.
. "$DIR/lib/no-python-path.sh"
NOPY="$FIXTURE/nopy-bin"
npp_build_bin "$NOPY" jq
ln -s "$FIXTURE/bin/gh" "$NOPY/gh"
if npp_reaches_python3 "$NOPY"; then check 1 "the no python3 PATH still reaches python3, so the case below measures nothing"; fi
seed_old_holds
python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash", "session_id": sys.argv[2], "cwd": sys.argv[1],
  "tool_input": {"command": "gh pr merge 42 --squash"},
  "tool_response": {"stdout": "", "stderr": "", "backgroundTaskId": "b1y5zlrqd", "timedOutAfterMs": 600000}}))
' "$FIXTURE/repo" "$SID_H" | ( cd "$FIXTURE/repo" && PATH="$NOPY" "$NOPY/bash" "$HOOK" ) >/dev/null 2>&1
[ -s "$(held_file "$SID_H")" ]; check $? "with no python3 the backgrounded merge was not held, so the sweep below was never reached"
[ -s "$(held_file "$SID_CLOSED")" ]; check $? "with no python3 to ask the registry, the sweep removed a hold"
rm -rf "$CLAUDE_QUIZ_VERDICT_DIR/held" "$CLAUDE_SESSION_REGISTRY_DIR"

# The incident itself, replayed: PostRoll's merge tool in a worktree, moved to the background with the
# tool_response its transcript recorded. Held under its own number, and released after the worktree it
# ran in was removed, which is the usual end of a worktree merge, by the repository resolved at hold time.
WT="$FIXTURE/PostRoll-wt-adopt"
mkdir -p "$WT/tools" && ( cd "$WT" && git init -q && git remote add origin "https://github.com/acme/widget.git" ) && : > "$WT/tools/wait_for_checks.py"
incident="$(python3 -c '
import json, sys
wt = sys.argv[1]
cmd = "cd \"%s\" && venv/bin/python tools/wait_for_checks.py 1582 --merge > \"%s/merge.log\" 2>&1; echo \"exit=$?\"; tail -15 \"%s/merge.log\"" % (wt, wt, wt)
print(json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash", "session_id": sys.argv[2], "cwd": sys.argv[3],
  "tool_input": {"command": cmd, "description": "Wait for CI on PR 1582 and merge it"},
  "tool_response": {"stdout": "", "stderr": "", "interrupted": False, "isImage": False, "noOutputExpected": False,
    "backgroundTaskId": "b1y5zlrqd", "timedOutAfterMs": 600000,
    "backgroundCwdHint": "Session cwd remains %s; directory changes made by the backgrounded command do not apply to subsequent commands." % sys.argv[3]}}))
' "$WT" "$SID_H2" "$FIXTURE/repo")"
rm -f "$(held_file "$SID_H2")"
out="$(printf '%s' "$incident" | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" ) 2>/dev/null)"
holds "$out" '"block"'; check $((! $?)) "the PostRoll incident, replayed, still demanded the quiz before the merge (got: ${out:0:200})"
holds "$out" "#1582"; check $? "the PostRoll incident's hold does not name #1582 (got: ${out:0:200})"
rm -rf "$WT"
printf '{"number":1582,"url":"https://github.com/acme/widget/pull/1582","state":"MERGED","mergedAt":"2026-10-26T19:43:00Z","labels":[{"name":"changelog/visible"}]}' > "$FAKE_PR_JSON"
out="$(turn_end "$SID_H2")"
holds "$out" '"block"'; check $? "a held merge whose worktree was removed was never released (got: ${out:0:200})"
[ ! -s "$(held_file "$SID_H2")" ]; check $? "a held merge whose worktree was removed kept its hold"

# EACH GITHUB QUESTION HAS ITS OWN DEADLINE (#1786). The release is a Stop hook with a 60 second
# timeout (a setting, not measured), and a hook the harness kills says nothing: every hold behind a hung answer waited a turn
# too. So each question is asked through lib/bounded-run.sh. Pull request 41 hangs (it and a child
# it starts, so the kill of the whole process tree is seen), and would say MERGED if it were ever
# waited for, so a release that waited would quiz #41 and drop its hold: that is what the cut is
# seen by, never by how long the turn end took (L290). Pull request 42 answers MERGED at once.
# The hang's own ceiling is the suite's one hang ceiling, which only a missing bound reaches. The
# child does not hold the answer's capture open, so a bound that killed only gh would return at once
# with the child still running, rather than wait for it and hide the fault (as test-bounded-run.sh).
. "$DIR/lib/hang-wait.sh" || { echo "FAIL: lib/hang-wait.sh is missing"; fail=$((fail+1)); }
HANGBIN="$FIXTURE/hangbin"; mkdir -p "$HANGBIN"
cat > "$HANGBIN/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view 41 "*|*"pr view 43 "*)
    a="\$*"; n="\${a#*pr view }"; n="\${n%% *}"
    echo "\$n" >> "$FIXTURE/hang-asked"
    ( t=\$SECONDS; while [ ! -e "$FIXTURE/hang-release" ] && [ \$((SECONDS - t)) -lt $HANG_S ]; do sleep 0.1; done ) > /dev/null 2>&1 &
    echo "\$!" > "$FIXTURE/hang-child-\$n.pid"
    echo "\$\$" > "$FIXTURE/hang-gh-\$n.pid"
    t=\$SECONDS; while [ ! -e "$FIXTURE/hang-release" ] && [ \$((SECONDS - t)) -lt $HANG_S ]; do sleep 0.1; done
    printf '{"number":%s,"url":"https://github.com/acme/widget/pull/%s","state":"MERGED","mergedAt":"2026-10-26T19:43:00Z","labels":[{"name":"changelog/visible"}]}' "\$n" "\$n"
    ;;
  *"pr view"*) cat "$FAKE_PR_JSON" ;;
esac
SH
chmod +x "$HANGBIN/gh"
hang_turn_end() {  # $1 = session id, then any VAR=value settings ; the Stop hook's output, gh hanging on 41 and 43
  local sid="$1"; shift
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "Stop", "session_id": sys.argv[2], "stop_hook_active": False, "cwd": sys.argv[1]}))
' "$FIXTURE/repo" "$sid" | ( cd "$FIXTURE/repo" && env "PATH=$HANGBIN:$PATH" "$@" "$HOOK" --release-held ) 2>/dev/null
}
# Rewritten through awk and a rename, never sed -i, whose suffix argument BSD and GNU read
# differently: on Linux `sed -i '' -e '$d' f` reads '' as a file, fails, and still edits f, so the
# fallback after it deleted a second line and CI saw these holds vanish (PR #1803).
hold_for() {  # $1 = pull request number ; appends a hold for it to SID_H's file, made from a real one for 42
  local f last
  f="$(held_file "$SID_H")"
  post_merge "$SID_H" bg >/dev/null
  last="$(tail -n 1 "$f")"
  awk 'NR > 1 { print prev } { prev = $0 }' "$f" > "$f.fixture" && mv "$f.fixture" "$f"
  printf '%s' "$last" | jq -c --arg n "$1" '.merges[0].pr = $n | .payload.tool_input.command = "gh pr merge \($n) --squash"' >> "$f"
}
held_prs() { jq -r '.merges[].pr' "$(held_file "$SID_H")" 2>/dev/null | tr '\n' ' '; }
alive() {  # the pids in the named files still running, if any
  local f p r=""
  for f in "$@"; do p="$(cat "$f" 2>/dev/null)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null && r="$r $p"; done
  printf '%s' "$r"
}
rm -f "$(held_file "$SID_H")" "$FIXTURE/hang-release" "$FIXTURE/hang-asked" "$FIXTURE"/hang-*.pid
pr_state MERGED
hold_for 41; hold_for 42
# A fixture that did not come out as built makes every case below measure something else, so it
# is ONE loud failure and the cases are skipped, rather than a cascade that reads as eight faults.
if [ "$(held_prs)" != "41 42 " ]; then
  check 1 "FIXTURE BROKEN, the deadline cases were skipped: the holds came out as '$(held_prs)', not '41 42 '"
else
cut_before="$(count_of cut)"
out="$(hang_turn_end "$SID_H" QUIZ_RELEASE_ASK_SECONDS=5)"
still="$(alive "$FIXTURE/hang-gh-41.pid" "$FIXTURE/hang-child-41.pid")"
: > "$FIXTURE/hang-release"
# A CUT ANSWER IS COUNTED (#1817). The release used to run before the counters were defined, so a
# question cut at its deadline left no trace in the counts and read as fewer quizzes, not quizzes cut
# (L357). Exactly one: #41 was cut, #42 answered.
saw cut "$((cut_before + 1))" "a GitHub answer cut at its deadline by the release"
grep -qx 41 "$FIXTURE/hang-asked" 2>/dev/null; check $? "the hung question for #41 was never asked, so nothing below measures its deadline"
[ -f "$FIXTURE/hang-child-41.pid" ] && [ -z "$still" ]; check $? "a hung GitHub answer, and the child it started, were still running after the release returned:${still:- no child pid was written}"
reason="$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null)"
holds "$reason" "#41"; check $((! $?)) "a GitHub answer cut at its deadline was waited for and believed: #41 was quizzed (got: ${reason:0:200})"
[ "$(held_prs)" = "41 " ]; check $? "a hung GitHub answer did not keep its hold, or the next hold was kept (holds: $(held_prs))"
holds "$reason" "#42"; check $? "the hold after a hung GitHub answer was not released (got: ${out:0:200})"
holds "$reason" "comprehension quiz"; check $? "the hold released after a hung answer is not the quiz instruction (got: ${reason:0:200})"
# And the kept hold is released at the next turn end once GitHub answers: delayed, never lost.
printf '{"number":41,"url":"https://github.com/acme/widget/pull/41","state":"MERGED","mergedAt":"2026-10-26T19:43:00Z","labels":[{"name":"changelog/visible"}]}' > "$FAKE_PR_JSON"
out="$(turn_end "$SID_H")"
holds "$out" "#41"; check $? "the hold kept past a hung answer was released without naming #41 (got: ${out:0:200})"
holds "$out" '"block"'; check $? "a hold kept past a hung answer was not released at the next turn end (got: ${out:0:200})"
[ ! -s "$(held_file "$SID_H")" ]; check $? "a hold kept past a hung answer was still held after GitHub answered (holds: $(held_prs))"
# An answer that came back in time is not a cut.
saw cut "$((cut_before + 1))" "a release whose every answer came back in time"
fi

# THE RELEASE AS A WHOLE HAS A BUDGET (#1786), so however many holds hang, the hook ends inside its
# timeout. Once the budget is spent nothing more is asked and every hold not asked is kept, written
# back AHEAD of the ones that were, so a hold that keeps hanging cannot starve the ones behind it.
# A budget of 2 with a 5 second question (both set here, not measured): #41 is cut when the budget runs out, and #43 and #42 are
# never asked. Judged by what was asked and what was kept (L290).
rm -f "$(held_file "$SID_H")" "$FIXTURE/hang-release" "$FIXTURE/hang-asked" "$FIXTURE"/hang-*.pid
pr_state MERGED
hold_for 41; hold_for 43; hold_for 42
if [ "$(held_prs)" != "41 43 42 " ]; then
  check 1 "FIXTURE BROKEN, the budget cases were skipped: the holds came out as '$(held_prs)', not '41 43 42 '"
else
cut_before="$(count_of cut)"
out="$(hang_turn_end "$SID_H" QUIZ_RELEASE_ASK_SECONDS=5 QUIZ_RELEASE_BUDGET_SECONDS=2)"
still="$(alive "$FIXTURE/hang-gh-41.pid" "$FIXTURE/hang-child-41.pid")"
: > "$FIXTURE/hang-release"
asked="$(tr '\n' ' ' < "$FIXTURE/hang-asked" 2>/dev/null)"
# The question the budget cut is counted (#1817); the holds never asked are not cuts, since nothing
# was cut short for them. When the budget was spent before #41 was asked, nothing was cut either.
if grep -qx 41 "$FIXTURE/hang-asked" 2>/dev/null; then
  saw cut "$((cut_before + 1))" "a GitHub answer cut short by the release's budget"
else
  saw cut "$cut_before" "a release whose budget ran out before it asked anything"
fi
[ -z "$still" ]; check $? "a question cut by the release's budget was still running after the release returned:$still"
! grep -qx 43 "$FIXTURE/hang-asked" 2>/dev/null; check $? "the release went on asking GitHub after its budget was spent (asked: $asked)"
holds "$out" '"block"'; check $((! $?)) "a release whose budget ran out quizzed a hold it never asked about (got: ${out:0:200})"
case "$(held_prs)" in
  "43 42 41 ") check 0 "" ;;
  "41 43 42 ")
    check "$(grep -qx 41 "$FIXTURE/hang-asked" 2>/dev/null && echo 1 || echo 0)" "a hold asked and kept was written back ahead of the holds never asked, so it can starve them (holds: $(held_prs))"
    # A Mac loaded enough that the hook spent its budget (2 s, set above, not measured) before the
    # first question leaves the order unmeasured rather than failed (L411).
    grep -qx 41 "$FIXTURE/hang-asked" 2>/dev/null || echo "SUITE-PART-UNMEASURED the order of kept holds after a spent budget: the hook spent its 2 s before #41 was asked" ;;
  *) check 1 "a release whose budget ran out did not keep every hold (holds: $(held_prs), asked: $asked)" ;;
esac
fi
: > "$FIXTURE/hang-release"
rm -f "$(held_file "$SID_H")"

# A Stop payload that cannot be read is quiet, never a crash or a block.
out="$(printf 'not json' | ( cd "$FIXTURE/repo" && env "PATH=$FIXTURE/bin:$PATH" "$HOOK" --release-held ) 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ]; check $? "an unreadable Stop payload was not quiet (rc=$rc, got: ${out:0:200})"

# The Stop hook is registered, so the release runs at all (L3: built is not wired).
grep -q 'pr-merge-quiz.sh --release-held' "$(. "$DIR/lib/settings-file.sh"; hook_settings_file "$DIR/..")"; check $? "the hooks settings do not run pr-merge-quiz.sh --release-held"

rm -rf "$FIXTURE"

echo
echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
