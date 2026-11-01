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

FAKE_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"
printf 'console.log(JSON.stringify({state: "missing", file: "/nowhere/repos.local.json"}))\n' > "$WORK/registry-missing.js"
printf 'console.log("not json")\n' > "$WORK/registry-broken.js"

# A checkout of acme/widget, and a fake gh whose answers are chosen here: the pull request from
# $FAKE_PR_JSON, and the scanner at its base present unless FAKE_SCOPE says absent or fails.
mkdir -p "$WORK/repo" "$WORK/bin"
( cd "$WORK/repo" && git init -q && git remote add origin "https://github.com/acme/widget.git" )
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$*" in
  *"auth status"*) printf 'Logged in to github.com account danwright32 (keyring)\n' ;;
  *"auth token -u "*) printf 'tok\n' ;;
  *"pr view"*)
    if [ -n "${FAKE_PR_ERR:-}" ]; then printf '%s\n' "$FAKE_PR_ERR" >&2; exit 1; fi
    cat "$FAKE_PR_JSON" ;;
  *"/contents/payload/hooks/lib/work-names.py"*)
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

# run_hook <command> [VAR=value ...] ; prints the hook's stdout and stderr, sets hook_rc
run_hook() {
  local cmd="$1"; shift
  : > "$WORK/gh.log"
  hook_out="$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
      "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "$(printf '%s' "$WORK/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | ( cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" FAKE_PR_JSON="$WORK/pr.json" FAKE_GH_LOG="$WORK/gh.log" \
          WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" WORK_NAMES_REGISTRY_READER="$WORK/registry-missing.js" \
          WN_MERGE_SLEEP=true "$@" bash "$HOOK" 2>&1 ))"
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
expect_deny "the refusal carries the file check's own remedy" "write name#123, never owner/name#123"
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
