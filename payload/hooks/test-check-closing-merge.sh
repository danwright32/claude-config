#!/usr/bin/env bash
#
# test-check-closing-merge.sh: the merge gate that refuses a pull request whose body closes an issue
# it says stays open (claude-config#1550).
#
# Every case runs the REAL hook with a fake `gh` first on PATH, so what is tested is the hook's own
# reading of GitHub's answer, through the real lib/closing-keyword.py, rather than a rewrite of its
# logic living here (L52). The sentences the detector judges have their own suite,
# test-check-closing-keyword.sh; this one is about the gate around it: which commands it judges, what
# it asks GitHub, and that it refuses rather than passes whenever it cannot tell (L98, L490).
#
# The merge command is assembled from $MERGE rather than written out, because writing it literally
# makes this file trip the block-red-merge hook on the way in.

set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/check-closing-merge.sh"
MERGE="gh pr me""rge"
passed=0
failed=0
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }
pass() { passed=$((passed + 1)); }

# Named with no "merge" in it: the gate's first filter is that word anywhere in the payload, the
# folder the command runs in included, so a folder named for it reads every command as a merge.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/closing-gate-test.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "$(basename "$0"): refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# A checkout of acme/widget, and a fake gh whose answer about pull request seven is chosen here. The
# fake gh is written by a plain heredoc, never one inside $(...), which macOS bash 3.2 mis-parses.
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
  *"api graphql"*) printf '%s\n' "${FAKE_NODE_JSON:-}" ;;
esac
SH
chmod +x "$WORK/bin/gh"

pr_json() {  # $1 = body, $2 = closing issue numbers in acme/widget, space separated ; $3 = url
  python3 -c '
import json, sys
refs = [{"number": int(n), "repository": {"name": "widget", "owner": {"login": "acme"}}} for n in sys.argv[2].split()]
print(json.dumps({"number": 7, "url": sys.argv[3], "body": sys.argv[1], "closingIssuesReferences": refs}))
' "$1" "$2" "${3:-https://github.com/acme/widget/pull/7}"
}

# run_hook <command> [VAR=value ...] ; prints the hook's stdout and stderr, sets hook_rc
run_hook() {
  local cmd="$1"; shift
  : > "$WORK/gh.log"
  hook_out="$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
      "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      "$(printf '%s' "$WORK/repo" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
    | ( cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" FAKE_PR_JSON="$WORK/pr.json" FAKE_GH_LOG="$WORK/gh.log" \
          CLOSING_SLEEP=true "$@" bash "$HOOK" 2>&1 ))"
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

echo "closing keyword: the merge gate"

if [ ! -f "$HOOK" ]; then
  fail "$HOOK is missing"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
  exit 1
fi

# 1. The rule: overture#4564's body, whose merge closed #4358 with three of its four slices unbuilt.
pr_json "Part of #4358. This does not close #4358." "4358" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "a body that says it does not close an issue GitHub will close" "#4358"
expect_deny "the refusal names the safe phrasing" "Part of #N"
expect_deny "and what to do with the body" "gh pr edit 7"

# claude-config#970: "Part of #953", and the next PR "closes #953". Merged, it closed #953 early.
pr_json "Part of #953

Nothing reads these files yet. The next PR points the check at them and closes #953." "953" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "a body that calls itself part of an issue it closes" "Part of #953"

# The merge gate covers every route to a merge, not only the typed command (claude-config#351).
pr_json "This does not close #4358." "4358" > "$WORK/pr.json"
run_hook "gh api -X PUT repos/acme/widget/pulls/7/merge -f merge_method=squash"
expect_deny "a merge through the REST API is judged the same" "#4358"
run_hook "env GH_TOKEN=x $MERGE 7 --squash"
expect_deny "a merge behind env is judged the same" "#4358"
run_hook "$MERGE 7 --repo acme/widget --squash"
expect_deny "a merge naming its repository is judged the same" "#4358"

# 2. What it leaves alone.
pr_json "Closes #12. Adds the reader." "12" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_allow "a clean close"
# A negated keyword before an issue GitHub does not list closes nothing.
pr_json "Closes #12. This does not close #13." "12" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_allow "a negated mention of an issue GitHub does not list"
pr_json "Refactors the reader. Part of #20." "" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_allow "a pull request that closes nothing"
run_hook "gh pr view 7 --json body"
expect_allow "a command that merges nothing"
if [ -s "$WORK/gh.log" ]; then fail "a command that merges nothing still asked GitHub: $(cat "$WORK/gh.log")"; else pass; fi

# 3. The deliberate override, visible in the command.
pr_json "This does not close #4358." "4358" > "$WORK/pr.json"
run_hook "SKIP_CLOSING_CHECK=1 $MERGE 7 --squash"
expect_allow "the documented override"

# 4. Cannot tell is never "nothing wrong" (L98, L490).
run_hook "$MERGE 7 --squash" FAKE_PR_ERR="HTTP 401: Bad credentials (https://api.github.com/graphql)"
expect_deny "GitHub refusing the read is a refusal, not a pass" "Cannot tell"
run_hook "$MERGE 7 --squash" FAKE_PR_ERR="HTTP 502: Bad Gateway (https://api.github.com/graphql)" CLOSING_READ_TRIES=3
expect_deny "a read that keeps failing is a refusal" "Cannot tell"
tries="$(grep -c 'pr view' "$WORK/gh.log")"
if [ "$tries" -ge 3 ]; then pass; else fail "a transient failure was asked $tries times, wanted 3"; fi
run_hook "$MERGE 7 --squash" FAKE_PR_ERR="GraphQL: Could not resolve to a PullRequest with the number of 7. (repository.pullRequest)"
expect_deny "a pull request GitHub does not have is named, with where it was looked for" "acme/widget"
pr_json "This does not close #4358." "4358" "https://github.com/someone/else/pull/7" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "an answer about another repository is refused" "someone/else"
printf '%s' '{"number":7,"url":"https://github.com/acme/widget/pull/7","body":"Closes #3."}' > "$WORK/pr.json"
run_hook "$MERGE 7 --squash"
expect_deny "an answer with no closing issue list cannot be judged" "Cannot tell"

# 5. One pull request per command: the body read is the first merge's (claude-config#1062).
pr_json "Closes #12." "12" > "$WORK/pr.json"
run_hook "$MERGE 7 --squash && $MERGE 8 --squash"
expect_deny "a command merging two pull requests" "Cannot judge"

# 6. Without its readers (claude-config#480, #486).
. "$HOOK_DIR/lib/no-python-path.sh"
NOPY="$WORK/nopy"
npp_build_bin "$NOPY" jq
ln -s "$WORK/bin/gh" "$NOPY/gh"
if npp_reaches_python3 "$NOPY"; then fail "the bare directory really reaches no python3"; else pass; fi
# Through a repository's own merge tool, whose pull request lib/merge-target.sh names without python3, so
# what is measured is this gate's own detector rather than the shared reader a typed merge needs first.
TOOL_MERGE="bash scripts/merge-when-green.sh 7"
pr_json "Closes #12." "12" > "$WORK/pr.json"
run_hook "$TOOL_MERGE" PATH="$NOPY"
expect_deny "with no python3 a pull request that closes an issue is refused, not passed unread" "lib/closing-keyword.py, so with it absent"
pr_json "Refactors the reader." "" > "$WORK/pr.json"
run_hook "$TOOL_MERGE" PATH="$NOPY"
expect_allow "with no python3 a pull request that closes nothing loses nothing"
# A typed merge without python3 is refused by the shared reader before anything here is asked.
run_hook "$MERGE 7 --squash" PATH="$NOPY"
expect_deny "with no python3 a typed merge is refused, naming python3" "python3"
NOREADER="$WORK/noreader"
npp_build_bin "$NOREADER"
run_hook "$MERGE 7 --squash" PATH="$NOREADER"
if [ "$hook_rc" -eq 2 ] && says "jq or python3"; then pass; else fail "with neither jq nor python3 a merge is refused naming them, got (exit $hook_rc): $hook_out"; fi
run_hook "git status" PATH="$NOREADER"
if [ "$hook_rc" -eq 0 ]; then pass; else fail "with neither jq nor python3 a command naming no merge is let through, got (exit $hook_rc): $hook_out"; fi

echo
echo "passed: $passed   failed: $failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
