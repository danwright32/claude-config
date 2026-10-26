#!/usr/bin/env bash
# Tests for stacked-branch-delete-gate.sh (claude-config#1723): a Bash command that deletes a branch
# on GitHub is refused while an open pull request is based on that branch, because GitHub closes such
# a pull request the moment its base goes, and a closed pull request's base can never be changed.
#
# On 2026-10-25 in bidspoke, deleting the merged branch 2337-http-service with
# `gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>` closed #2763, stacked on it, with
# nothing said. The three ways a command here deletes a branch on GitHub are covered: that API call,
# `git push <remote> --delete <branch>` (or `:<branch>`), and `gh pr merge --delete-branch`.
#
# gh is stubbed on PATH, so nothing here reaches GitHub. Each case hands the hook a PreToolUse payload
# and reads its exit code, what it said, and which gh calls it made.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/stacked-branch-delete-gate.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  expected NOT to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-stacked-branch-delete-gate: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

# The stub gh. ST holds what GitHub would answer:
#   stacked       the open pull requests based on the branch, as gh pr list --json prints them
#   list-fails    present: listing them fails, with this file's text on stderr
#   merged        the merged pull requests whose head is the branch, as gh pr list --json prints them
#   view          what gh pr view prints for the pull request being merged
#   view-fails    present: gh pr view fails
# Every call is logged to gh-calls, one line each, with the GH_TOKEN it ran under in front.
ST="$WORKDIR/state"
STUB="$WORKDIR/bin"
mkdir -p "$ST" "$STUB"
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf 'GH_TOKEN=%s %s\n' "${GH_TOKEN:-}" "$*" >> "$ST/gh-calls"
case "$*" in
  "auth token -u "*) printf 'tok-%s\n' "${@: -1}" ;;
  "pr list"*"--head"*) cat "$ST/merged" 2>/dev/null || echo '[]' ;;
  "pr list"*"--base"*)
    if [ -e "$ST/list-fails" ]; then cat "$ST/list-fails" >&2; exit 1; fi
    cat "$ST/stacked" 2>/dev/null || echo '[]' ;;
  "pr view"*)
    if [ -e "$ST/view-fails" ]; then echo "gh: Could not resolve to a PullRequest" >&2; exit 1; fi
    cat "$ST/view" ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 64 ;;
esac
STUBEOF
chmod +x "$STUB/gh"
export ST

# A checkout whose origin is acme/widget on GitHub, the repository a {owner}/{repo} or a remote
# name stands for, and one whose origin is not on GitHub at all.
REPO="$WORKDIR/widget"
git init -q "$REPO"
git -C "$REPO" remote add origin https://github.com/acme/widget.git
git -C "$REPO" remote add mirror git@gitlab.example.com:acme/widget.git

fresh(){ rm -rf "$ST"; mkdir -p "$ST"; }
payload(){ # payload <command> [cwd]
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "${2:-$REPO}"
}
judge(){ # judge <command> [cwd]: sets out, rc and calls
  out="$(payload "$1" "${2:-$REPO}" | PATH="$STUB:$PATH" bash "$HOOK" 2>&1)"; rc=$?
  calls="$(cat "$ST/gh-calls" 2>/dev/null)"
}

echo "stacked-branch-delete-gate (claude-config#1723)"

# 1. The case from the issue: the API delete of a branch with a pull request stacked on it.
fresh
echo '[{"number":2763}]' > "$ST/stacked"
echo '[{"number":2760,"baseRefName":"main"}]' > "$ST/merged"
judge "gh api -X DELETE repos/acme/widget/git/refs/heads/2337-http-service"
check_eq "#1723 the API delete of a branch with an open pull request based on it is refused" "2" "$rc"
check "#1723 the refusal names the stacked pull request" "#2763" "$out"
check "#1723 and the command that moves it onto the merged one's base" "gh pr edit 2763 --repo acme/widget --base main" "$out"
check "#1723 the stacked pull requests are listed by the branch they are based on" "pr list --repo acme/widget --base 2337-http-service --state open" "$calls"
check "#1723 and the refusal offers the one command override" "SKIP_STACKED_CHECK=1" "$out"

# 2. Nothing stacked: the delete runs, and nothing is said.
fresh
echo '[]' > "$ST/stacked"
judge "gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1723 with nothing based on the branch the delete is allowed in silence" "0|" "$rc|$out"
check "#1723 control: and the list was asked, so the allow is a reading, not a skip" "--base feat/x" "$calls"

# 3. THE FAILURE PATH: a list GitHub will not give is never read as "nothing stacked".
fresh
echo 'gh: Resource not accessible by integration (HTTP 403)' > "$ST/list-fails"
judge "gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1723 a list that fails refuses the delete" "2" "$rc"
check "#1723 and says the list could not be read" "could not list" "$out"
check "#1723 carrying GitHub's own error" "HTTP 403" "$out"
fresh
echo '{"message":"Bad credentials"}' > "$ST/stacked"
judge "gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1723 an answer that is not a list refuses the delete too" "2" "$rc"

# 4. Every spelling of the API delete, in every command position.
fresh
echo '[{"number":9}]' > "$ST/stacked"
judge "gh api --method=DELETE /repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1723 --method=DELETE and a leading slash are read" "2" "$rc"
judge "gh api --method DELETE repos/acme/widget/git/refs/heads/feat/x --silent"
check_eq "#1723 --method DELETE is read" "2" "$rc"
judge "rtk gh api -XDELETE repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1723 -XDELETE behind rtk is read" "2" "$rc"
judge "cd /tmp && gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1723 after a cd" "2" "$rc"
judge "bash -c 'gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x'"
check_eq "#1723 inside bash -c" "2" "$rc"
fresh
echo '[{"number":9}]' > "$ST/stacked"
judge "gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/feat/x"
check_eq "#1723 {owner}/{repo} is read as the checkout's origin" "2" "$rc"
check "#1723 and listed in that repository" "pr list --repo acme/widget --base feat/x" "$calls"

# 5. The account the delete names is the account the list is read as.
fresh
echo '[]' > "$ST/stacked"
judge 'GH_TOKEN=$(gh auth token -u bob) gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x'
check_eq "#1723 a delete run as another account is judged" "0" "$rc"
check "#1723 the list is read as that account" "GH_TOKEN=tok-bob pr list --repo acme/widget --base feat/x" "$calls"

# 6. git push --delete, -d and :branch, to a GitHub remote.
fresh
echo '[{"number":9}]' > "$ST/stacked"
echo '[{"number":7,"baseRefName":"develop"}]' > "$ST/merged"
judge "git push origin --delete feat/x"
check_eq "#1723 git push --delete of a branch with a stacked pull request is refused" "2" "$rc"
check "#1723 naming the base the merged pull request went into" "gh pr edit 9 --repo acme/widget --base develop" "$out"
judge "git push -d origin feat/x"
check_eq "#1723 git push -d is read" "2" "$rc"
judge "git push origin :feat/x"
check_eq "#1723 git push origin :branch is read" "2" "$rc"
judge "git -C $REPO push origin --delete refs/heads/feat/x" "/tmp"
check_eq "#1723 git -C names the checkout, and refs/heads/ is read as the branch" "2" "$rc"
fresh
echo '[{"number":9}]' > "$ST/stacked"
judge "git push https://github.com/acme/widget.git --delete feat/x" "/tmp"
check_eq "#1723 a remote given as a URL is read" "2" "$rc"
check "#1723 as its repository" "pr list --repo acme/widget --base feat/x" "$calls"

# 7. With no merged pull request to read a base from, the refusal still names the stacked one and
# says where to move it, never a guessed branch.
fresh
echo '[{"number":9}]' > "$ST/stacked"
echo '[]' > "$ST/merged"
judge "git push origin --delete feat/x"
check_eq "#1723 refused with no merged pull request found" "2" "$rc"
check "#1723 naming the stacked pull request" "#9" "$out"
check_not "#1723 and no base it did not read" "--base main" "$out"

# 8. gh pr merge --delete-branch deletes the head branch the moment it merges.
fresh
echo '{"number":7,"headRefName":"feat/x","baseRefName":"main","isCrossRepository":false}' > "$ST/view"
echo '[{"number":9}]' > "$ST/stacked"
judge "gh pr merge 7 --squash --delete-branch"
check_eq "#1723 gh pr merge --delete-branch over a stacked pull request is refused" "2" "$rc"
check "#1723 naming it" "#9" "$out"
check "#1723 and the helper that merges, moves and then deletes" "merge-when-ready.sh 7 --repo acme/widget --squash --delete-branch" "$out"
judge "gh pr merge 7 -sd -R acme/widget"
check_eq "#1723 -sd and -R are read" "2" "$rc"
check "#1723 and the pull request is read in the repository named" "pr view 7 --repo acme/widget" "$calls"
fresh
echo '{"number":7,"headRefName":"feat/x","baseRefName":"main","isCrossRepository":false}' > "$ST/view"
echo '[]' > "$ST/stacked"
judge "gh pr merge 7 --squash --delete-branch"
check_eq "#1723 with nothing stacked the merge goes ahead" "0|" "$rc|$out"
fresh
touch "$ST/view-fails"
judge "gh pr merge 7 --squash --delete-branch"
check_eq "#1723 a merge whose branch cannot be read is refused" "2" "$rc"
check "#1723 saying the pull request could not be read" "could not read" "$out"
fresh
echo '{"number":7,"headRefName":"feat/x","baseRefName":"main","isCrossRepository":true}' > "$ST/view"
judge "gh pr merge 7 --squash --delete-branch"
check_eq "#1723 a fork's pull request deletes no branch here, so it is not asked about" "0" "$rc"
check_not "#1723 and nothing is listed for it" "--base" "$calls"

# 9. Controls: nothing that does not delete a branch on GitHub is asked about, or refused.
fresh
echo '[{"number":9}]' > "$ST/stacked"
for c in \
  "echo gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x" \
  "gh api repos/acme/widget/git/refs/heads/feat/x" \
  "gh api -X DELETE repos/acme/widget/issues/comments/5" \
  "gh api -X DELETE repos/acme/widget/git/refs/tags/v1" \
  "git push origin feat/x" \
  "git push origin --delete refs/tags/v1" \
  "git push mirror --delete feat/x" \
  "git branch -d feat/x" \
  "gh pr merge 7 --squash" \
  "SKIP_STACKED_CHECK=1 gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x"; do
  judge "$c"
  check_eq "#1723 control: allowed in silence: $c" "0|" "$rc|$out"
done
check_eq "#1723 control: and none of them asked GitHub anything" "" "$calls"

# 10. Without its reader the gate cannot see what a delete removes, so a command naming a delete is
# refused rather than passed unjudged; one naming none passes even then.
LONE="$WORKDIR/lone"
mkdir -p "$LONE/lib"
cp "$HOOK" "$LONE/"
cp "$DIR/lib/push-scope.sh" "$DIR/lib/stacked-prs.sh" "$LONE/lib/"
fresh
out="$(payload "gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x" | PATH="$STUB:$PATH" bash "$LONE/stacked-branch-delete-gate.sh" 2>&1)"; rc=$?
check_eq "#1723 with lib/shell-words.py missing a delete is refused" "2" "$rc"
check "#1723 and names that file" "shell-words.py" "$out"
out="$(payload "ls -la" | PATH="$STUB:$PATH" bash "$LONE/stacked-branch-delete-gate.sh" 2>&1)"; rc=$?
check_eq "#1723 control: a command naming no delete passes in silence with the reader missing" "0|" "$rc|$out"

# 11. ONE reading of the stacked pull requests (L370): merge-when-ready.sh, which moves them before
# deleting a merged branch (claude-config#1337), and this gate ask through the same function, so
# the two cannot come to disagree about what "stacked" means or what a failed list is.
MWR="$DIR/lib/merge-when-ready.sh"
check "#1723 merge-when-ready.sh reads the stacked pull requests through lib/stacked-prs.sh" "sp_read_stacked" "$(cat "$MWR")"
check "#1723 and so does this gate" "sp_read_stacked" "$(cat "$HOOK")"
check_eq "#1723 and neither lists them with a gh pr list of its own" "0 0" \
  "$(grep -c 'pr list --repo "\$slug" --base' "$MWR") $(grep -c 'pr list --repo "\$slug" --base' "$HOOK")"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
