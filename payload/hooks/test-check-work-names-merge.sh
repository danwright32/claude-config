#!/usr/bin/env bash
#
# test-check-work-names-merge.sh: the merge gate that refuses a pull request whose title, description
# or commit messages name a work organisation, in a repository that guards its files against them
# (claude-config#1995).
#
# Every case runs the REAL hook with a fake `gh` first on PATH and the REAL lib/work-names.py, so
# what is tested is the gate's own reading of GitHub's answer, not a rewrite of its logic here (L52).
# The scanner's rule has its own suite, test-work-names.sh; this one is about the gate around it:
# which repositories it judges, which commands, what it asks GitHub, and that it refuses rather than
# passes whenever it cannot tell (L98, L490).
#
# The organisation is an invented one, handed to the scanner by hash (WORK_NAMES_EXTRA_HASHES), and
# the registry reader is a stub, so nothing here depends on what this Mac's registry holds. No work
# organisation or repository name belongs in this file. The merge command is assembled from $MERGE
# rather than written out, because writing it literally trips the merge gates on the way in.

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/check-work-names-merge.sh"
MERGE="gh pr me""rge"
passed=0
failed=0
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }

# Named with no "merge" in it: the gate's first filter is that word anywhere in the payload.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/work-names-gate-test.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "$(basename "$0"): refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# The gate's own limits, read from its source rather than written out again here (claude-config#2243),
# so a change to one moves every expectation built on it, and what can still fail on such a change is
# the check against something the gate does not hold: the timeout settings.hooks.json registers it
# with (section 3). Each is one whole line of the gate. A line rewritten past recognition stops the
# suite naming it, never leaves an expectation built on nothing (L100).
gate_number() {  # $1 = variable to set, $2 = what it is, $3 = extended regex for its whole line, the number its one group
  local hits
  hits="$(sed -n -E "s/$3/\1/p" "$HOOK")"
  case "$hits" in
    ''|*[!0-9]*)
      echo "  FAIL: $2 could not be read from check-work-names-merge.sh as one whole number (got [$hits]), so nothing built on it can be checked"
      printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$((failed + 1))"
      exit 1 ;;
  esac
  printf -v "$1" '%s' "$hits"
}
gate_number READ_CAP "the read budget cap" '^READ_BUDGET_CAP=([0-9]+)$'
gate_number READ_DEFAULT "the default read budget" '^READ_DEADLINE="\$\(mt_gate_read_budget "\$\{WN_MERGE_READ_BUDGET_SECONDS:-\}" ([0-9]+)\)"$'
gate_number LIST_SECONDS "the seconds the work repository list is given after the reads" '^repos_budget=\$\(\( READ_DEADLINE \+ ([0-9]+) - SECONDS \)\)$'
# The budget the reads get when none is set is the default held to the cap, and the work repository
# list is handed what is left of that plus its own seconds: these are the most it can be handed.
READ_USED=$(( READ_DEFAULT < READ_CAP ? READ_DEFAULT : READ_CAP ))
LIST_MOST=$(( READ_USED + LIST_SECONDS ))
LIST_MOST_CAPPED=$(( READ_CAP + LIST_SECONDS ))

FAKE_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"
printf 'console.log(JSON.stringify({state: "missing", file: "/nowhere/repos.local.json"}))\n' > "$WORK/registry-missing.js"
printf 'console.log("not json")\n' > "$WORK/registry-broken.js"
# The work repository list the fake gh answers with: an invented owner and repository, neither of
# which is the acme/widget the pull requests below come from.
printf '{"repos":[{"owner":"Globex-Corp","name":"halcyon"}]}\n' > "$WORK/list.json"

# A checkout of acme/widget, and a fake gh whose answers are chosen here: the pull request from
# $FAKE_PR_JSON, and the scanner at its base present unless FAKE_SCOPE says absent or fails.
mkdir -p "$WORK/repo" "$WORK/bin"
( cd "$WORK/repo" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
  # The work repository list (claude-config#2111), from $FAKE_LIST; every name in it is invented.
  *"contents/repos.json"*)
    [ -f "${FAKE_LIST:-}" ] || { printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; }
    cat "$FAKE_LIST" ;;
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*)
    # A read that "took" until the hook's clock read FAKE_CLOCK_AT_VIEW, written where the hook reads
    # its test clock (WN_MERGE_CLOCK_FILE), so no case waits in real time (claude-config#2169, L524).
    if [ -n "${FAKE_CLOCK_AT_VIEW+set}" ]; then printf '%s\n' "$FAKE_CLOCK_AT_VIEW" > "$WN_MERGE_CLOCK_FILE"; fi
    if [ -n "${FAKE_PR_ERR:-}" ]; then printf '%s\n' "$FAKE_PR_ERR" >&2; exit 1; fi
    cat "$FAKE_PR_JSON" ;;
  *"/contents/payload/hooks/lib/work-names.py"*)
    if [ -n "${FAKE_CLOCK_AT_SCOPE+set}" ]; then printf '%s\n' "$FAKE_CLOCK_AT_SCOPE" > "$WN_MERGE_CLOCK_FILE"; fi
    case "${FAKE_SCOPE:-present}" in
      absent) printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1 ;;
      fails) printf 'gh: Bad Gateway (HTTP 502)\n' >&2; exit 1 ;;
      *) printf '{"name":"work-names.py"}\n' ;;
    esac ;;
  *"api graphql"*) printf '%s\n' "${FAKE_NODE_JSON:-}" ;;
esac
SH
chmod +x "$WORK/bin/gh"

pr_json() {  # $1 = title, $2 = body, $3 = second commit's body ; $4 = url
  python3 -c '
import json, sys
commits = [
    {"oid": "1a2b3c4d5e6f7a8b9c0d", "messageHeadline": "Add the reader", "messageBody": "refs widget#3"},
    {"oid": "5d6e7f8a9b0c1d2e3f4a", "messageHeadline": "Quote the refusal", "messageBody": sys.argv[3]},
]
print(json.dumps({"number": 7, "url": sys.argv[4], "baseRefOid": "b0b0b0b0b0b0b0b0b0b0",
                  "title": sys.argv[1], "body": sys.argv[2], "commits": commits}))
' "$1" "$2" "$3" "${4:-https://github.com/acme/widget/pull/7}"
}

# run_hook <command> [VAR=value ...] ; prints the hook's stdout and stderr, sets hook_rc.
# HOOK_TESTS_RUNNING=1 is what run-all-tests.sh exports to every suite, and the gate honours its
# WN_MERGE_SCANNER seam only with it (claude-config#2217). It is set here as well so the suite run
# on its own behaves as it does inside a full run; a case after it in "$@" can clear it.
run_hook() {
  local cmd="$1"; shift
  : > "$WORK/gh.log"
  rm -f "$WORK/clock" "$WORK/budget"
  # HOOK_ALARM bounds one run in seconds, for a case whose looser gate would hang rather than fail.
  local alarm=()
  [ -n "${HOOK_ALARM:-}" ] && alarm=(perl -e 'alarm shift; exec @ARGV' "$HOOK_ALARM")
  hook_out="$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
      "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "$(printf '%s' "$WORK/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | ( cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" FAKE_PR_JSON="$WORK/pr.json" FAKE_GH_LOG="$WORK/gh.log" FAKE_LIST="$WORK/list.json" \
          WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" WORK_NAMES_REGISTRY_READER="$WORK/registry-missing.js" \
          WN_MERGE_SLEEP=true HOOK_TESTS_RUNNING=1 WN_MERGE_CLOCK_FILE="$WORK/clock" STUB_BUDGET_FILE="$WORK/budget" \
          "$@" ${alarm[@]+"${alarm[@]}"} bash "$HOOK" 2>&1 ))"
  hook_rc=$?
}
denied() { local re='"permissionDecision": *"deny"'; [[ "$hook_out" =~ $re ]]; }
says() { [[ "$hook_out" == *"$1"* ]]; }
expect_deny() {  # $1 = description, $2 = a needle the refusal must carry
  if denied && says "$2"; then pass; else fail "$1: wanted a refusal carrying [$2], got (exit $hook_rc): $hook_out"; fi
}
expect_allow() {  # $1 = description
  if [ "$hook_rc" -eq 0 ] && ! denied; then pass; else fail "$1: wanted an allow, got (exit $hook_rc): $hook_out"; fi
}
never_repeats() {  # $1 = description
  if [[ "$(printf '%s' "$hook_out" | tr '[:upper:]' '[:lower:]')" == *"acme-hq"* ]]; then fail "$1: the refusal repeated the name: $hook_out"; else pass; fi
}

echo "work names: the merge gate"

if [ ! -f "$HOOK" ]; then
  fail "$HOOK is missing"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
  exit 1
fi

# 1. The rule, over each thing a squash merge publishes.
pr_json "Add the Acme-HQ reader" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "a title naming a work organisation" "title:1: a work organisation name"
expect_deny "the refusal carries the message check's own remedy" "never write owner/name#123 or name#123"
expect_deny "and how to fix a title" "gh pr edit 7"
never_repeats "a title refusal"
pr_json "Add the reader" "Adds the reader.

Seen in https://github.com/ACME-HQ/widget/pull/9" "clean" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "a description naming one" "description:3: a work organisation name"
never_repeats "a description refusal"
pr_json "Add the reader" "Adds the reader." "it named acme-hq/widget#4 in the fixture" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "a commit message naming one, which a squash merge copies into main" "commit 5d6e7f8:3: a work organisation name"
expect_deny "and how to reword a pushed commit" "force push"
if says "commit 1a2b3c4:"; then fail "a clean commit was named too: $hook_out"; else pass; fi
# The base the scanner is looked for at is the pull request's own base commit.
if grep -q 'contents/payload/hooks/lib/work-names.py?ref=b0b0b0b0b0b0b0b0b0b0' "$WORK/gh.log"; then pass; else fail "the scope was not read at the base commit: $(cat "$WORK/gh.log")"; fi

# A work REPOSITORY in a commit message is published by the squash merge just as an organisation is,
# so the messages are checked against the work repository list too (claude-config#2111), in prose.
pr_json "Add the reader" "Adds the reader." "copied from the Halcyon checkout" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "a commit message naming a listed work repository" "commit 5d6e7f8:3: a work repository or owner name"
expect_deny "and the refusal says repository" "names a work organisation or repository"
if [[ "$(printf '%s' "$hook_out" | tr '[:upper:]' '[:lower:]')" == *"halcyon"* ]]; then fail "the refusal repeated the repository: $hook_out"; else pass; fi
if says "commit 1a2b3c4:"; then fail "a clean commit was named too: $hook_out"; else pass; fi
pr_json "Move it to globex-corp/thing" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "a title naming a listed work owner" "title:1: a work repository or owner name"
# Cannot tell is refused, never passed (L98, L345).
pr_json "Add the reader" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash" FAKE_LIST="$WORK/no-such-list.json"
expect_deny "a work repository list that cannot be read refuses the merge" "work repository list"
expect_deny "as the scanner giving no verdict" "gave no verdict"
# Under 3 seconds of the budget left for the list is refused before the scanner starts, since a hook
# killed at its timeout gives no verdict at all. The default read budget leaves the list LIST_MOST
# seconds from the hook's start, and a scope read that "took" until 2 seconds before that leaves 2,
# so the list is never asked for. The scope read moves the hook's clock through its test clock file
# rather than sleeping, so the case runs at once and the same under load (claude-config#2169, L290,
# L524). Every number here is one this test or the hook sets, not measured.
run_hook "$MERGE 7 --squash" FAKE_CLOCK_AT_SCOPE=$(( LIST_MOST - 2 ))
expect_deny "under 3 seconds left for the work repository list refuses the merge" "had no time left to be read"
if grep -q 'contents/payload/hooks/lib/work-names.py' "$WORK/gh.log"; then pass; else fail "the late case never reached the scope read: $(cat "$WORK/gh.log")"; fi
if grep -q 'contents/repos.json' "$WORK/gh.log"; then fail "the list was read with no budget left for it: $(cat "$WORK/gh.log")"; else pass; fi
run_hook "$MERGE 7 --squash"
expect_allow "(control) clean text with the list read merges"

# The test clock can only move the hook's clock FORWARD, so whoever can set WN_MERGE_CLOCK_FILE (any
# process whose environment the hook inherits) can make the gate refuse sooner, never later: what the
# list read is handed is never more than the real clock leaves (claude-config#2169). Each case reads
# that hand off through a stub scanner that records WORK_NAMES_REPOS_BUDGET_SECONDS and passes.
printf 'import os\nopen(os.environ["STUB_BUDGET_FILE"], "w").write(os.environ.get("WORK_NAMES_REPOS_BUDGET_SECONDS", "unset"))\n' > "$WORK/scanner-stub.py"
budget_at_most() {  # $1 = description, $2 = the most the list read may be handed
  local got; got="$(cat "$WORK/budget" 2>/dev/null)"
  case "$got" in
    ''|*[!0-9]*) fail "$1: the list read was handed [${got:-nothing}], wanted at most $2 (exit $hook_rc): $hook_out" ;;
    *) if [ "$got" -le "$2" ]; then pass; else fail "$1: the list read was handed $got seconds, more than $2"; fi ;;
  esac
}
stub_run() { run_hook "$MERGE 7 --squash" WN_MERGE_SCANNER="$WORK/scanner-stub.py" "$@"; }
stub_run FAKE_CLOCK_AT_SCOPE=20
budget_at_most "a clock moved forward to 20 leaves the list at most $(( LIST_MOST - 20 )) of the $LIST_MOST seconds" $(( LIST_MOST - 20 ))
stub_run FAKE_CLOCK_AT_VIEW=14 FAKE_CLOCK_AT_SCOPE=0
budget_at_most "a later, earlier reading never moves the clock back" $(( LIST_MOST - 14 ))
stub_run FAKE_CLOCK_AT_SCOPE=-100
budget_at_most "a negative reading is ignored, never a longer budget" "$LIST_MOST"
stub_run FAKE_CLOCK_AT_VIEW=14 FAKE_CLOCK_AT_SCOPE=99999999999999999999
budget_at_most "a reading too long to be a clock, which bash would wrap to 0, is ignored" $(( LIST_MOST - 14 ))
stub_run FAKE_CLOCK_AT_VIEW=14 FAKE_CLOCK_AT_SCOPE=1000
budget_at_most "a reading of four digits or more is out of range and ignored" $(( LIST_MOST - 14 ))
stub_run FAKE_CLOCK_AT_VIEW=14 FAKE_CLOCK_AT_SCOPE=" 3"
budget_at_most "a reading that is not plain digits is ignored" $(( LIST_MOST - 14 ))
# Text that bash arithmetic would run as a command is never evaluated: a subscript of a set variable,
# since under the hook's set -u an unset one stops the shell before the subscript runs.
stub_run FAKE_CLOCK_AT_SCOPE="SECONDS[\$(touch $WORK/clock-ran)]"
if [ -e "$WORK/clock-ran" ]; then fail "a test clock reading ran as a command"; rm -f "$WORK/clock-ran"; else pass; fi
budget_at_most "and that reading is ignored" "$LIST_MOST"
# A clock file that is not a regular file is never opened: a fifo with no writer would hold the hook
# until its timeout, and a hook killed there gives no verdict at all. The alarm bounds a looser gate.
mkfifo "$WORK/clock-fifo"
HOOK_ALARM=10 stub_run WN_MERGE_CLOCK_FILE="$WORK/clock-fifo"
budget_at_most "a fifo for a clock file is ignored, never waited on" "$LIST_MOST"
# The read budget's cap (claude-config#2217) holds for what the list read is handed, not only for
# what the refusal says: a budget of 100 or merge-when-ready.sh's 90 still leaves the list at most
# the cap plus the list's own seconds (LIST_MOST_CAPPED), with the test clock moved or not. Every
# number here is one this test or the hook sets, not measured.
stub_run WN_MERGE_READ_BUDGET_SECONDS=100 FAKE_CLOCK_AT_SCOPE=20
budget_at_most "a budget past the cap leaves the list no more than the cap does" $(( LIST_MOST_CAPPED - 20 ))
stub_run MT_GATE_READ_BUDGET_SECONDS=90
budget_at_most "merge-when-ready.sh's budget leaves the list no more than the cap does" "$LIST_MOST_CAPPED"
# And the stub scanner these cases use is the gate's verdict only under the test marker: with it
# cleared, the gate's own scanner judges and the stub never runs (claude-config#2217).
stub_run HOOK_TESTS_RUNNING=
if [ -e "$WORK/budget" ]; then fail "the stub scanner ran without the test marker: $(cat "$WORK/budget")"; else pass; fi

# Every route to a merge.
pr_json "Add the Acme-HQ reader" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "gh api -X PUT repos/acme/widget/pulls/7/merge -f merge_method=squash"
expect_deny "a merge through the REST API is judged the same" "title:1"
run_hook "env GH_TOKEN=x $MERGE 7 --squash"
expect_deny "a merge behind env is judged the same" "title:1"
run_hook "$MERGE 7 --repo acme/widget --squash"
expect_deny "a merge naming its repository is judged the same" "title:1"
# No override: another gate's word does not clear it, and nor does any skip word.
run_hook "SKIP_CLOSING_CHECK=1 SKIP_SCANNERS_CHECK=1 $MERGE 7 --squash"
expect_deny "another gate's override does not clear a privacy refusal" "title:1"

# 2. What it leaves alone.
pr_json "Add the reader" "Adds the reader. Part of widget#3." "refs widget#5" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_allow "a pull request that names no organisation"
pr_json "Add the Acme-HQ reader" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash" FAKE_SCOPE=absent
expect_allow "a repository whose base holds no work names scanner is not judged"
run_hook "gh pr view 7 --json body"
expect_allow "a command that merges nothing"
if [ -s "$WORK/gh.log" ]; then fail "a command that merges nothing still asked GitHub: $(cat "$WORK/gh.log")"; else pass; fi

# 3. Cannot tell is never "nothing wrong" (L98, L490).
run_hook "$MERGE 7 --squash" FAKE_SCOPE=fails WN_MERGE_READ_TRIES=3
expect_deny "a scope read that keeps failing is a refusal" "Cannot tell"
tries="$(grep -c 'contents/payload' "$WORK/gh.log")"
if [ "$tries" -ge 3 ]; then pass; else fail "a transient scope failure was asked $tries times, wanted 3"; fi
run_hook "$MERGE 7 --squash" FAKE_PR_ERR="HTTP 401: Bad credentials (https://api.github.com/graphql)"
expect_deny "GitHub refusing the pull request read is a refusal" "Cannot tell"
run_hook "$MERGE 7 --squash" FAKE_PR_ERR="GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)"
expect_deny "a pull request GitHub does not have is named, with where it was looked for" "acme/widget"
pr_json "Add the reader" "Adds the reader." "clean" "https://github.com/someone/else/pull/7" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "an answer about another repository is refused" "someone/else"
printf '%s' '{"number":7,"url":"https://github.com/acme/widget/pull/7","baseRefOid":"b0b0","title":"t","body":"b"}' > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "an answer with no commit list cannot be judged" "Cannot tell"
# gh reads a pull request's commits a page at a time and hands back one page, so a list as long as a
# page may be cut short, with the later messages never seen: that is no clean list.
python3 -c '
import json
commits = [{"oid": "%040x" % i, "messageHeadline": "Step %d" % i, "messageBody": ""} for i in range(100)]
print(json.dumps({"number": 7, "url": "https://github.com/acme/widget/pull/7", "baseRefOid": "b0b0",
                  "title": "t", "body": "b", "commits": commits}))' > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "a commit list as long as one page of gh's answer may be cut short, and is refused" "100 commits"
pr_json "Add the reader" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash" WORK_NAMES_REGISTRY_READER="$WORK/registry-broken.js"
expect_deny "a scanner that cannot judge refuses rather than passes" "gave no verdict"
run_hook "$MERGE 7 --squash" WN_MERGE_SCANNER="$WORK/no-such-scanner.py"
expect_deny "a missing scanner refuses rather than passes" "no-such-scanner.py is missing"

# Its test seams hold only under its tests, and its read budget stays inside its timeout
# (claude-config#2217). The hook reads Claude Code's own environment, so a scanner named there would
# be the verdict on every merge, and a budget past the timeout lets the hook be killed mid read.
# Outside its tests the scanner's own seams are ignored too (claude-config#2231), so the invented
# organisation is nobody's there: these cases name the listed work owner instead, which the scanner
# matches through the work repository list the fake gh serves, and run with an empty HOME so this
# Mac's own dev update registry plays no part.
printf 'import sys\nsys.exit(0)\n' > "$WORK/scanner-passes.py"
mkdir -p "$WORK/empty-home"
pr_json "Move it to globex-corp/thing" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash" WN_MERGE_SCANNER="$WORK/scanner-passes.py" HOOK_TESTS_RUNNING= HOME="$WORK/empty-home"
expect_deny "outside its tests, a scanner named in the environment is not the verdict" "title:1: a work repository or owner name"
run_hook "$MERGE 7 --squash" WN_MERGE_SCANNER="$WORK/scanner-passes.py" HOOK_TESTS_RUNNING=0 HOME="$WORK/empty-home"
expect_deny "nor with the test marker set to anything but 1" "title:1: a work repository or owner name"
run_hook "$MERGE 7 --squash" WN_MERGE_SCANNER="$WORK/scanner-passes.py"
expect_allow "(control) under its tests the named scanner is the verdict, so the seam still works"
pr_json "Add the reader" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash" WN_MERGE_SCANNER="$WORK/no-such-scanner.py" HOOK_TESTS_RUNNING= HOME="$WORK/empty-home"
expect_allow "outside its tests the gate's own scanner judges, whatever file the environment names"
# The scanner's own registry reader, named in the gate's environment, is not asked outside its tests
# either: one that answers "nothing registered" would empty the registry half of every real merge.
printf 'require("fs").writeFileSync(process.env.READER_RAN, "ran"); console.log(JSON.stringify({state: "missing", file: "/nowhere/repos.local.json"}))\n' > "$WORK/marking-reader.js"
rm -f "$WORK/reader-ran"
run_hook "$MERGE 7 --squash" WORK_NAMES_REGISTRY_READER="$WORK/marking-reader.js" READER_RAN="$WORK/reader-ran" HOOK_TESTS_RUNNING= HOME="$WORK/empty-home"
expect_allow "(control) clean text outside its tests merges with the real registry reader"
if [ -e "$WORK/reader-ran" ]; then fail "outside its tests the gate's scanner ran a registry reader named in the environment"; else pass; fi
rm -f "$WORK/reader-ran"
run_hook "$MERGE 7 --squash" WORK_NAMES_REGISTRY_READER="$WORK/marking-reader.js" READER_RAN="$WORK/reader-ran"
if [ -e "$WORK/reader-ran" ]; then pass; else fail "(control) under its tests the named registry reader is asked: $hook_out"; fi

# The retry settings hold only under its tests too, and the wait between reads is capped whoever set
# it (claude-config#2231): a wait or a count of tries named in Claude Code's environment could hold
# the hook past its timeout, and a gate killed there gives no verdict at all. Each wait is read off a
# sleep that records what it was asked for and returns at once, so no case waits in real time (L524).
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$SLEPT_FILE"\n' > "$WORK/record-sleep"
chmod +x "$WORK/record-sleep"
slept_run() {  # [VAR=value ...] ; a scope read that keeps failing, its waits in $WORK/slept
  rm -f "$WORK/slept"
  run_hook "$MERGE 7 --squash" FAKE_SCOPE=fails WN_MERGE_SLEEP="$WORK/record-sleep" SLEPT_FILE="$WORK/slept" "$@"
  slept="$(cat "$WORK/slept" 2>/dev/null | tr '\n' ' ')"
}
slept_run WN_MERGE_READ_TRIES=1 HOOK_TESTS_RUNNING=
expect_deny "outside its tests a count of tries named in the environment is not honoured" "(3 tries, 15 seconds)"
tries="$(grep -c 'contents/payload' "$WORK/gh.log")"
if [ "$tries" -eq 3 ]; then pass; else fail "outside its tests the scope was asked $tries times, wanted the default 3"; fi
slept_run WN_MERGE_READ_RETRY_SECONDS=4 HOOK_TESTS_RUNNING=
if [ "$slept" = "2 2 " ]; then pass; else fail "outside its tests a wait named in the environment was honoured: slept [$slept], wanted the default [2 2 ]"; fi
slept_run WN_MERGE_READ_RETRY_SECONDS=4 HOOK_TESTS_RUNNING=0
if [ "$slept" = "2 2 " ]; then pass; else fail "nor with the test marker set to anything but 1: slept [$slept]"; fi
slept_run WN_MERGE_READ_TRIES=2 WN_MERGE_READ_RETRY_SECONDS=3
if [ "$slept" = "3 " ]; then pass; else fail "(control) under its tests the retry settings are its own: slept [$slept], wanted [3 ]"; fi
slept_run WN_MERGE_READ_TRIES=2 WN_MERGE_READ_RETRY_SECONDS=12
if [ "$slept" = "5 " ]; then pass; else fail "a wait past the cap is clamped to 5 seconds: slept [$slept]"; fi
slept_run WN_MERGE_READ_TRIES=2 WN_MERGE_READ_RETRY_SECONDS=123456789012345678901234567890
if [ "$slept" = "5 " ]; then pass; else fail "a wait too long for the shell's arithmetic is clamped too: slept [$slept]"; fi
if says "integer expression expected"; then fail "a wait too long for the shell's arithmetic reached a comparison: $hook_out"; else pass; fi
slept_run WN_MERGE_READ_TRIES=2 WN_MERGE_READ_RETRY_SECONDS=03
if [ "$slept" = "3 " ]; then pass; else fail "a wait padded with zeros is read as its value: slept [$slept]"; fi
slept_run WN_MERGE_READ_TRIES=2 WN_MERGE_READ_RETRY_SECONDS=soon
if [ "$slept" = "2 " ]; then pass; else fail "a wait that is not a number is not believed, and the default holds: slept [$slept]"; fi

# The budget, read off the refusal a scope read that keeps failing gives, which names it. The cases
# below ask for 90 and more to be clamped and for 5 to be kept, so they test the clamp only while the
# cap sits between the two.
if [ 5 -lt "$READ_CAP" ] && [ "$READ_CAP" -lt 90 ]; then pass; else fail "the read budget cap of $READ_CAP is not between the 5 these cases keep and the 90 they clamp, so they no longer test the clamp"; fi
run_hook "$MERGE 7 --squash" FAKE_SCOPE=fails WN_MERGE_READ_TRIES=3 WN_MERGE_READ_BUDGET_SECONDS=100
expect_deny "a read budget past the cap is clamped to it" "(3 tries, $READ_CAP seconds)"
run_hook "$MERGE 7 --squash" FAKE_SCOPE=fails WN_MERGE_READ_TRIES=3 MT_GATE_READ_BUDGET_SECONDS=90
expect_deny "so is the budget merge-when-ready.sh hands every gate" "(3 tries, $READ_CAP seconds)"
run_hook "$MERGE 7 --squash" FAKE_SCOPE=fails WN_MERGE_READ_TRIES=3 WN_MERGE_READ_BUDGET_SECONDS=123456789012345678901234567890
expect_deny "a budget too long for the shell's arithmetic is clamped too" "(3 tries, $READ_CAP seconds)"
if says "integer expression expected"; then fail "a budget too long for the shell's arithmetic reached a comparison: $hook_out"; else pass; fi
run_hook "$MERGE 7 --squash" FAKE_SCOPE=fails WN_MERGE_READ_TRIES=3 WN_MERGE_READ_BUDGET_SECONDS=lots MT_GATE_READ_BUDGET_SECONDS=-5
expect_deny "a budget that is not a number is not believed, and the read still refuses" "(3 tries, $READ_USED seconds)"
run_hook "$MERGE 7 --squash" FAKE_SCOPE=fails WN_MERGE_READ_TRIES=3 WN_MERGE_READ_BUDGET_SECONDS=5
expect_deny "(control) a budget under the cap is still the test's own" "(3 tries, 5 seconds)"
run_hook "$MERGE 7 --squash" FAKE_SCOPE=fails WN_MERGE_READ_TRIES=3 WN_MERGE_READ_BUDGET_SECONDS=0005
expect_deny "a budget padded with zeros is read as its value, not clamped for its length" "(3 tries, 5 seconds)"
run_hook "$MERGE 7 --squash" WN_MERGE_READ_BUDGET_SECONDS=08
expect_allow "a budget with a leading zero is read in base ten, not crashed on"
pr_json "Add the Acme-HQ reader" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash" WN_MERGE_READ_BUDGET_SECONDS=lots MT_GATE_READ_BUDGET_SECONDS=lots
expect_deny "a budget that is not a number never opens the gate" "title:1: a work organisation name"
# The cap is held below the timeout the gate is registered with, less the seconds the work
# repository list is given after it: a gate killed at its timeout gives no verdict of its own. All
# three numbers are settings, not measured. The cap and the list's seconds are read from the gate
# (READ_CAP, LIST_SECONDS) and the timeout from settings.hooks.json, which the gate never reads, so
# this is the check that fails when either of the gate's numbers grows past it (claude-config#2243,
# L721).
. "$HOOK_DIR/lib/settings-file.sh"
timeout="$(jq -r '[.. | objects | select((.command? // "") | endswith("/check-work-names-merge.sh")) | .timeout] | first // empty' "$(hook_settings_file "$HOOK_DIR/..")" 2>/dev/null)"
case "$timeout" in
  ''|*[!0-9]*) fail "no timeout for check-work-names-merge.sh could be read from settings.hooks.json (got '$timeout')" ;;
  *) if [ "$LIST_MOST_CAPPED" -lt "$timeout" ]; then pass; else fail "the read budget cap of $READ_CAP plus the list's $LIST_SECONDS seconds is not inside the registered timeout of $timeout"; fi ;;
esac

# 4. One pull request per command: the text read is one pull request's (claude-config#1062).
run_hook "$MERGE 7 --squash && $MERGE 8 --squash"
expect_deny "a command merging two pull requests" "Cannot judge"

# 5. Without its readers (claude-config#480, #486).
. "$HOOK_DIR/lib/no-python-path.sh"
NOREADER="$WORK/noreader"
npp_build_bin "$NOREADER"
run_hook "$MERGE 7 --squash" PATH="$NOREADER"
if [ "$hook_rc" -eq 2 ] && says "jq or python3"; then pass; else fail "with neither jq nor python3 a merge is refused naming them, got (exit $hook_rc): $hook_out"; fi
run_hook "git status" PATH="$NOREADER"
if [ "$hook_rc" -eq 0 ]; then pass; else fail "with neither jq nor python3 a command naming no merge is let through, got (exit $hook_rc): $hook_out"; fi
NOPY="$WORK/nopy"
npp_build_bin "$NOPY" jq
ln -s "$WORK/bin/gh" "$NOPY/gh"
TOOL_MERGE="bash scripts/merge-when-green.sh 7"
pr_json "Add the reader" "Adds the reader." "clean" > "$WORK/pr.json"
run_hook "$TOOL_MERGE" PATH="$NOPY"
expect_deny "with no python3 a pull request in a guarded repository is refused, not passed unread" "python3"
run_hook "$TOOL_MERGE" PATH="$NOPY" FAKE_SCOPE=absent
expect_allow "with no python3 a repository that is not guarded loses nothing"

echo
echo "passed: $passed   failed: $failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
