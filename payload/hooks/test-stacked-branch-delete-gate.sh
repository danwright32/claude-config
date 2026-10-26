#!/usr/bin/env bash
# Tests for stacked-branch-delete-gate.sh (claude-config#1723): a Bash command that deletes a branch
# on GitHub is refused while an open pull request is based on that branch, because GitHub closes such
# a pull request the moment its base goes, and a closed pull request's base can never be changed.
#
# On 2026-10-25 in bidspoke, deleting the merged branch 2337-http-service with
# `gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/<branch>` closed #2763, stacked on it, with
# nothing said. The four ways a command here deletes a branch on GitHub are covered: that API call,
# a GraphQL deleteRef through `gh api graphql` (#1758), `git push <remote> --delete <branch>` (or
# `:<branch>`), and `gh pr merge --delete-branch`.
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
  # ghost is an account this Mac holds no token for: gh says so and fails.
  "auth token -u ghost") echo "no oauth token found for github.com account ghost" >&2; exit 1 ;;
  "auth token -u "*) printf 'tok-%s\n' "${@: -1}" ;;
  "pr list"*"--head"*) cat "$ST/merged" 2>/dev/null || echo '[]' ;;
  "pr list"*"--base"*)
    if [ -e "$ST/list-fails" ]; then cat "$ST/list-fails" >&2; exit 1; fi
    # stacked-in names the one repository the stacked pull requests are in; any other has none.
    if [ -e "$ST/stacked-in" ] && [[ "$*" != *"--repo $(cat "$ST/stacked-in") "* ]]; then echo '[]'; exit 0; fi
    cat "$ST/stacked" 2>/dev/null || echo '[]' ;;
  # The repository gh fills {owner}/{repo} with: the first of the remotes upstream, github and
  # origin, in that order (gh's BaseRepoFunc and remoteNameSortScore), as owner/name.
  "api repos/{owner}/{repo} --jq .full_name")
    if [ -e "$ST/resolve-fails" ]; then echo "none of the git remotes configured for this repository point to a known GitHub host" >&2; exit 1; fi
    for r in upstream github origin; do
      u="$(git remote get-url "$r" 2>/dev/null)" || continue
      u="${u%.git}"; printf '%s\n' "${u#*github.com[:/]}"; exit 0
    done
    echo "no git remotes found" >&2; exit 1 ;;
  # What GitHub says a ref's node id names.
  "api graphql"*"node(id"*)
    if [ -e "$ST/node-fails" ]; then echo "gh: Could not resolve to a node with the global id" >&2; exit 1; fi
    cat "$ST/node" ;;
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
check_eq "#1723 {owner}/{repo} is read as gh fills it, here the checkout's only GitHub remote, origin" "2" "$rc"
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

# 12. Three ways the gate used to pass a delete unjudged (lessons review of this branch).
# a. The method in lower case: gh sends it as written, and GitHub deletes all the same.
fresh
echo '[{"number":9}]' > "$ST/stacked"
judge "gh api -X delete repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1723 -X delete in lower case is read" "2" "$rc"
judge "gh api --method=delete repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1723 --method=delete in lower case is read" "2" "$rc"
judge "gh api --method Delete repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1723 --method Delete in mixed case is read" "2" "$rc"

# b. The account the command names has no token here: listing as the default account instead may
# not see the pull requests at all, and its empty list would allow the delete.
fresh
echo '[]' > "$ST/stacked"
judge 'GH_TOKEN=$(gh auth token -u ghost) gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x'
check_eq "#1723 a delete as an account whose token cannot be read is refused" "2" "$rc"
check "#1723 naming that account" "ghost" "$out"
check_not "#1723 and nothing is listed as some other account" "pr list" "$calls"
fresh
judge 'GH_TOKEN=$(gh auth token -u ghost) gh api -X DELETE repos/acme/widget/issues/comments/5'
check_eq "#1723 control: the same account on a command that deletes no branch passes, its token never asked" "0||" "$rc|$out|$calls"

# c. A remote that cannot be resolved is never read as one off GitHub.
fresh
echo '[]' > "$ST/stacked"
judge "git push nosuch --delete feat/x"
check_eq "#1723 a push to a remote the checkout does not have is refused" "2" "$rc"
check "#1723 naming the remote it could not resolve" "nosuch" "$out"
judge "git push --delete feat/x"
check_eq "#1723 a push whose first word git reads as the remote, and which names none, is refused" "2" "$rc"
judge "git -C $WORKDIR/missing push origin --delete feat/x" "/tmp"
check_eq "#1723 a push from a checkout that is not there is refused" "2" "$rc"
check_eq "#1723 and none of them asked GitHub anything" "" "$calls"
# Controls: a remote that is plainly not GitHub (another host, a local path) still passes unasked.
BARE="$WORKDIR/elsewhere.git"
git init -q --bare "$BARE"
for c in "git push mirror --delete feat/x" "git push $BARE --delete feat/x" "git push ./relative.git --delete feat/x" "git push file:///tmp/x.git --delete feat/x"; do
  judge "$c"
  check_eq "#1723 control: a remote plainly off GitHub passes in silence: $c" "0|" "$rc|$out"
done
check_eq "#1723 control: and asked GitHub nothing" "" "$calls"
# The default remote, read where git reads it, still lists: origin through a configured remote name.
fresh
echo '[{"number":9}]' > "$ST/stacked"
judge "git push origin --delete feat/x"
check_eq "#1723 control: a resolvable origin is still judged" "2" "$rc"

# 13. THE CLASS RULE (second lessons review of this branch): whenever the gate cannot establish who
# it is asking GitHub as, or which GitHub repository a delete hits, it refuses, never passes.
# a. A token set to an expression the gate cannot read: listing as the active account instead could
# see none of the pull requests, and its empty list would allow the delete.
for c in \
  'GH_TOKEN=$(cat ~/.tok) gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x' \
  'GH_TOKEN=$TOK gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x' \
  'GH_TOKEN=`cat tok` gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x' \
  'GITHUB_TOKEN=$TOK gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x' \
  'GH_HOST=$HOST gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x'; do
  fresh
  echo '[]' > "$ST/stacked"
  judge "$c"
  check_eq "#1723 a delete as a token or host the gate cannot read is refused: $c" "2" "$rc"
  check_eq "#1723 and nothing is listed as some other account: $c" "" "$calls"
done
fresh
echo '[]' > "$ST/stacked"
judge 'GH_TOKEN=literal123 gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x'
check_eq "#1723 control: a literal token is read, and listed as" "0" "$rc"
check "#1723 control: as that token" "GH_TOKEN=literal123 pr list" "$calls"
fresh
judge 'GH_TOKEN=$TOK gh api repos/acme/widget/pulls'
check_eq "#1723 control: an unreadable token on a command that deletes no branch passes, unasked" "0||" "$rc|$out|$calls"

# b. A file or folder in the checkout named like a configured remote: git pushes to the remote.
fresh
echo '[{"number":9}]' > "$ST/stacked"
touch "$REPO/origin"
judge "git push origin --delete feat/x"
check_eq "#1723 a file named origin does not hide the origin remote" "2" "$rc"
rm -f "$REPO/origin"
mkdir -p "$REPO/localmirror.git"
fresh
judge "git push localmirror.git --delete feat/x"
check_eq "#1723 control: a word git has no remote for, naming a folder in the checkout, is a path" "0||" "$rc|$out|$calls"
rmdir "$REPO/localmirror.git"
# A remote that fetches from off GitHub but pushes to it (a mirror's pushurl): a push goes to the
# push address, so that is the one judged (lessons review at 5f1b524).
git -C "$REPO" remote add pushmirror git@gitlab.example.com:acme/widget.git
git -C "$REPO" remote set-url --push pushmirror https://github.com/acme/widget.git
fresh
echo '[{"number":9}]' > "$ST/stacked"
judge "git push pushmirror --delete feat/x"
check_eq "#1723 a remote whose push address is on GitHub is judged by that address" "2" "$rc"
git -C "$REPO" remote remove pushmirror

# c. Every spelling of a GitHub URL is read as its repository, and a github.com URL with no
# owner/name in it is refused rather than read as a remote off GitHub.
. "$DIR/lib/stacked-prs.sh"
for pair in \
  "https://github.com/acme/widget/|acme/widget" \
  "https://github.com/acme/widget.git/|acme/widget" \
  "HTTPS://GitHub.com/acme/widget|acme/widget" \
  "https://user:tok@github.com/acme/widget|acme/widget" \
  "ssh://git@ssh.github.com:443/acme/widget.git|acme/widget" \
  "ssh://git@github.com:22/acme/widget|acme/widget" \
  "git@github.com:acme/widget.git|acme/widget" \
  "github.com:acme/widget|acme/widget" \
  "git://github.com/acme/widget.git|acme/widget"; do
  got="$(sp_github_slug "${pair%%|*}")"; grc=$?
  check_eq "#1723 sp_github_slug reads ${pair%%|*}" "0 ${pair#*|}" "$grc $got"
done
got="$(sp_github_slug "git@gitlab.example.com:acme/widget.git")"; grc=$?
check_eq "#1723 sp_github_slug: another host is off GitHub (exit 1, nothing printed)" "1 " "$grc $got"
got="$(sp_github_slug "https://notgithub.com/acme/widget")"; grc=$?
check_eq "#1723 sp_github_slug: a host merely ending in github.com is off GitHub" "1 " "$grc $got"
for u in "https://github.com/acme" "https://github.com/acme/widget/extra" "git@github.com:" "https://github.com/"; do
  got="$(sp_github_slug "$u")"; grc=$?
  check_eq "#1723 sp_github_slug: github.com with no owner/name to read is exit 2: $u" "2 " "$grc $got"
done
fresh
echo '[{"number":9}]' > "$ST/stacked"
judge "git push https://github.com/acme/widget/ --delete feat/x" "/tmp"
check_eq "#1723 a GitHub URL with a trailing slash is read" "2" "$rc"
check "#1723 as its repository" "pr list --repo acme/widget --base feat/x" "$calls"
fresh
judge "git push https://github.com/acme --delete feat/x" "/tmp"
check_eq "#1723 a github.com URL naming no repository is refused" "2" "$rc"
check_eq "#1723 without asking GitHub anything" "" "$calls"

# 14. A GraphQL deleteRef mutation deletes a branch just as the REST call does (claude-config#1758).
# Its ref is named by a node id, so the gate asks GitHub which branch and repository that id is.
NODE_FEAT='{"data":{"node":{"name":"feat/x","prefix":"refs/heads/","repository":{"nameWithOwner":"acme/widget"}}}}'
fresh
echo '[{"number":9}]' > "$ST/stacked"
echo '[{"number":7,"baseRefName":"main"}]' > "$ST/merged"
echo "$NODE_FEAT" > "$ST/node"
judge "gh api graphql -f query='mutation { deleteRef(input: {refId: \"REF_kwDOfeat\"}) { clientMutationId } }'"
check_eq "#1758 a GraphQL deleteRef of a branch with a stacked pull request is refused" "2" "$rc"
check "#1758 naming the stacked pull request" "#9" "$out"
check "#1758 and the command that moves it" "gh pr edit 9 --repo acme/widget --base main" "$out"
check "#1758 the ref id is looked up on GitHub" "REF_kwDOfeat" "$calls"
check "#1758 and the stacked pull requests are listed in the repository it names" "pr list --repo acme/widget --base feat/x --state open" "$calls"
for c in \
  "gh api graphql -f query='mutation(\$id: ID!) { deleteRef(input: {refId: \$id}) { clientMutationId } }' -f id=REF_kwDOfeat" \
  "gh api graphql -F id=REF_kwDOfeat -f query='mutation(\$id: ID!) { gone: deleteRef(input: {refId: \$id}) { clientMutationId } }'" \
  "gh api graphql -f query='mutation(\$input: DeleteRefInput!) { deleteRef(input: \$input) { clientMutationId } }' -F 'input[refId]=REF_kwDOfeat'" \
  "rtk gh api graphql --raw-field=query='mutation { deleteRef(input: {refId: \"REF_kwDOfeat\"}) { clientMutationId } }'"; do
  fresh
  echo '[{"number":9}]' > "$ST/stacked"
  echo "$NODE_FEAT" > "$ST/node"
  judge "$c"
  check_eq "#1758 every spelling of the ref id is read: $c" "2" "$rc"
  check "#1758 and looked up: $c" "REF_kwDOfeat" "$calls"
done
# The mutation read from a file is read from that file, where the command runs.
printf '%s\n' 'mutation { deleteRef(input: {refId: "REF_kwDOfeat"}) { clientMutationId } }' > "$REPO/del.graphql"
fresh
echo '[{"number":9}]' > "$ST/stacked"
echo "$NODE_FEAT" > "$ST/node"
judge "gh api graphql -F query=@del.graphql"
check_eq "#1758 a deleteRef read from a query file is judged" "2" "$rc"
check "#1758 and its ref id looked up" "REF_kwDOfeat" "$calls"
rm -f "$REPO/del.graphql"
# Nothing stacked: allowed, and only after asking.
fresh
echo '[]' > "$ST/stacked"
echo "$NODE_FEAT" > "$ST/node"
judge "gh api graphql -f query='mutation { deleteRef(input: {refId: \"REF_kwDOfeat\"}) { clientMutationId } }'"
check_eq "#1758 a deleteRef with nothing stacked is allowed in silence" "0|" "$rc|$out"
check "#1758 control: and the list was asked" "--base feat/x" "$calls"
# A tag is not a branch: nothing is based on it.
fresh
echo '[{"number":9}]' > "$ST/stacked"
echo '{"data":{"node":{"name":"v1","prefix":"refs/tags/","repository":{"nameWithOwner":"acme/widget"}}}}' > "$ST/node"
judge "gh api graphql -f query='mutation { deleteRef(input: {refId: \"REF_kwDOtag\"}) { clientMutationId } }'"
check_eq "#1758 a deleteRef of a tag is allowed" "0|" "$rc|$out"
check_not "#1758 and no pull request list is asked for a tag" "pr list" "$calls"
# THE FAILURE PATHS: a ref GitHub will not name, or an id the gate cannot read, refuses.
fresh
touch "$ST/node-fails"
judge "gh api graphql -f query='mutation { deleteRef(input: {refId: \"REF_kwDOfeat\"}) { clientMutationId } }'"
check_eq "#1758 a ref id GitHub will not look up refuses the deleteRef" "2" "$rc"
check "#1758 carrying GitHub's own words" "Could not resolve to a node" "$out"
fresh
echo '{"data":{"node":null}}' > "$ST/node"
judge "gh api graphql -f query='mutation { deleteRef(input: {refId: \"REF_kwDOfeat\"}) { clientMutationId } }'"
check_eq "#1758 a ref id GitHub answers with no ref for refuses" "2" "$rc"
for c in \
  "gh api graphql -f query='mutation(\$id: ID!) { deleteRef(input: {refId: \$id}) { clientMutationId } }' -f id=\$REF" \
  "gh api graphql -f query='mutation(\$id: ID!) { deleteRef(input: {refId: \$id}) { clientMutationId } }'" \
  "gh api graphql --input - <<'EOF'
{\"query\": \"mutation { deleteRef(input: {refId: \\\"REF_kwDOfeat\\\"}) { clientMutationId } }\"}
EOF" \
  "printf '%s' 'mutation { deleteRef(input: {refId: \"REF_kwDOfeat\"}) { clientMutationId } }' > q.graphql && gh api graphql -F query=@q.graphql"; do
  fresh
  echo '[]' > "$ST/stacked"
  judge "$c"
  check_eq "#1758 a deleteRef whose ref id cannot be read is refused: $c" "2" "$rc"
  check "#1758 saying the ref could not be read: $c" "deleteRef" "$out"
  check_eq "#1758 and nothing is listed: $c" "" "$calls"
done
rm -f "$REPO/q.graphql"
# Controls: a GraphQL call that deletes no ref is not asked about, or refused.
fresh
echo '[{"number":9}]' > "$ST/stacked"
echo "$NODE_FEAT" > "$ST/node"
for c in \
  "gh api graphql -f query='query { viewer { login } }'" \
  "gh api graphql -f query='mutation { addComment(input: {subjectId: \"I_1\", body: \"delete the ref later\"}) { clientMutationId } }'" \
  "gh api graphql -f query='mutation { deletePullRequestReview(input: {pullRequestReviewId: \"PRR_1\"}) { clientMutationId } }'" \
  "gh api graphql -F query=@missing.graphql" \
  "echo gh api graphql -f query='mutation { deleteRef(input: {refId: \"REF_kwDOfeat\"}) { clientMutationId } }'"; do
  judge "$c"
  check_eq "#1758 control: a GraphQL call deleting no ref passes in silence: $c" "0|" "$rc|$out"
done
check_eq "#1758 control: and none of them asked GitHub anything" "" "$calls"

# 15. A pull request from a fork based on the branch is stacked on it all the same: GitHub closes it
# when that branch goes, wherever its head lives (claude-config#1758). gh pr list --base lists
# them: measured on 2026-10-26, 20 of the 30 open pull requests based on trunk in cli/cli were.
fresh
echo '[{"number":9,"isCrossRepository":true,"headRepositoryOwner":{"login":"contributor"}}]' > "$ST/stacked"
judge "gh api -X DELETE repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1758 a fork's pull request based on the branch counts as stacked" "2" "$rc"
check "#1758 and is named" "#9" "$out"
# A checkout of a fork: origin is the fork, upstream the parent, and gh fills {owner}/{repo} with
# upstream, so the delete hits the parent, where the pull requests from the fork are based.
FORK="$WORKDIR/fork"
git init -q "$FORK"
git -C "$FORK" remote add origin https://github.com/dan/widget.git
git -C "$FORK" remote add upstream https://github.com/acme/widget.git
fresh
echo 'acme/widget' > "$ST/stacked-in"
echo '[{"number":9,"isCrossRepository":true}]' > "$ST/stacked"
judge "gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/feat/x" "$FORK"
check_eq "#1758 in a fork's checkout {owner}/{repo} is the repository gh fills it with, upstream" "2" "$rc"
check "#1758 and listed there" "pr list --repo acme/widget --base feat/x" "$calls"
check_not "#1758 never in the fork origin names" "pr list --repo dan/widget" "$calls"
fresh
touch "$ST/resolve-fails"
judge "gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/feat/x" "$FORK"
check_eq "#1758 a {owner}/{repo} gh cannot fill refuses the delete" "2" "$rc"
check "#1758 saying so in gh's words" "known GitHub host" "$out"
fresh
echo '[]' > "$ST/stacked"
judge "GH_REPO=acme/widget gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/feat/x" "$FORK"
check_eq "#1758 control: GH_REPO still names the repository" "0" "$rc"
check "#1758 control: listed there" "pr list --repo acme/widget --base feat/x" "$calls"
check_not "#1758 control: without asking gh to fill it" "api repos/{owner}/{repo}" "$calls"

# 16. --hostname sends gh api to another GitHub altogether. This gate lists pull requests on
# github.com only, so a delete there is refused, saying why, never listed against github.com
# (claude-config#1758, as GH_HOST is above).
for c in \
  "gh api --hostname ghe.example.com -X DELETE repos/acme/widget/git/refs/heads/feat/x" \
  "gh api --hostname=ghe.example.com -X DELETE repos/acme/widget/git/refs/heads/feat/x" \
  "gh api --hostname ghe.example.com graphql -f query='mutation { deleteRef(input: {refId: \"REF_kwDOfeat\"}) { clientMutationId } }'"; do
  fresh
  echo '[]' > "$ST/stacked"
  echo "$NODE_FEAT" > "$ST/node"
  judge "$c"
  check_eq "#1758 a delete on another GitHub host is refused: $c" "2" "$rc"
  check "#1758 naming that host: $c" "ghe.example.com" "$out"
  check_eq "#1758 and nothing is asked of github.com: $c" "" "$calls"
done
fresh
echo '[]' > "$ST/stacked"
judge "gh api --hostname GitHub.com -X DELETE repos/acme/widget/git/refs/heads/feat/x"
check_eq "#1758 control: --hostname github.com is judged as github.com" "0" "$rc"
check "#1758 control: listed there" "pr list --repo acme/widget --base feat/x" "$calls"
fresh
judge "gh api --hostname ghe.example.com repos/acme/widget/pulls"
check_eq "#1758 control: another host on a command deleting no branch passes, unasked" "0||" "$rc|$out|$calls"

# 17. Without its reader a command naming a deleteRef is refused too.
fresh
out="$(payload "gh api graphql -f query='mutation { deleteRef(input: {refId: \"R\"}) { clientMutationId } }'" | PATH="$STUB:$PATH" bash "$LONE/stacked-branch-delete-gate.sh" 2>&1)"; rc=$?
check_eq "#1758 with lib/shell-words.py missing a deleteRef is refused" "2" "$rc"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
