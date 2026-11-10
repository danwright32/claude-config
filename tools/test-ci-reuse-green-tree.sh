#!/usr/bin/env bash
# tools/ci-reuse-green-tree.sh decides whether a pull request run may stand on an earlier green run
# of EXACTLY the same tree instead of running the suites again (claude-config#2690). It may only say
# yes on proof (L312): an index artifact named for the tree, a completed green run of this
# repository's own tests.yml that is not a fork's, and the commit that run tested, read by its own
# sha from GitHub, holding exactly this tree and belonging to that run. Every other answer, an API
# that fails included, is the full suite.
#
# Driven against a fake gh that serves fixtures, so every refusal is reached on purpose. Each case
# asserts the helper's exit code and its stdout, which the workflow appends to GITHUB_OUTPUT: a
# reuse is the reused-run line, and a full suite is no such line at all.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$DIR/ci-reuse-green-tree.sh"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

command -v jq > /dev/null 2>&1 || {
  echo "SUITE-NOT-RUN jq is not installed, so the helper's API reading cannot be exercised"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.reusetree.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-ci-reuse-green-tree: refusing to run: the throwaway directory came back as '$TMPROOT'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

REPO="owner/repo"
T="1111111111111111111111111111111111111111"     # the tree this run tests
OTHER_T="2222222222222222222222222222222222222222"
S="aaaa000000000000000000000000000000000001"     # the commit the earlier run tested
HEAD="bbbb000000000000000000000000000000000002"  # that run's pull request head
BASE="cccc000000000000000000000000000000000003"
RUN=900
ME=901
ART=77

# The fake gh. Every response is a file in the case's directory, and a missing file is the API
# failing, as gh does: a message on stderr and a non zero exit. Each call is logged.
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
serve(){ if [ -f "$FAKE/$1" ]; then cat "$FAKE/$1"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi; }
case "$1 $2" in
  "api repos/owner/repo/actions/artifacts?name="*) serve artifacts.json ;;
  "api repos/owner/repo/actions/runs/"*) serve "run-${2##*/}.json" ;;
  "api repos/owner/repo/git/commits/"*) serve "commit-${2##*/}.json" ;;
  "run download")
    id="$3"; shift 3; dir=""
    while [ $# -gt 0 ]; do case "$1" in -D|--dir) dir="$2"; shift 2 ;; *) shift ;; esac; done
    [ -f "$FAKE/artifact-$id.txt" ] || { echo "no artifact" >&2; exit 1; }
    mkdir -p "$dir" && cp "$FAKE/artifact-$id.txt" "$dir/tested.txt" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 3 ;;
esac
GH
chmod +x "$TMPROOT/bin/gh"

# One case directory, holding the green, matching proof; each case then breaks one part of it.
n=0
fresh(){ # fresh -> sets C to a new case directory holding a valid proof for a push run
  n=$((n + 1)); C="$TMPROOT/case$n"; mkdir -p "$C"
  cat > "$C/artifacts.json" <<JSON
{"total_count":1,"artifacts":[{"id":$ART,"name":"green-tree-$T","expired":false,"created_at":"2026-11-10T20:00:00Z","workflow_run":{"id":$RUN,"repository_id":5,"head_repository_id":5,"head_branch":"x","head_sha":"$S"}}]}
JSON
  run_json push "$S" success completed "$REPO" ".github/workflows/tests.yml" > "$C/run-$RUN.json"
  commit_json "$S" "$T" "$BASE" > "$C/commit-$S.json"
  printf 'sha=%s\ntree=%s\nrun=%s\n' "$S" "$T" "$RUN" > "$C/artifact-$RUN.txt"
}
run_json(){ # run_json <event> <head sha> <conclusion> <status> <head repo> <path>
  printf '{"id":%s,"event":"%s","head_sha":"%s","conclusion":"%s","status":"%s","path":"%s","html_url":"https://github.com/%s/actions/runs/%s","repository":{"full_name":"%s"},"head_repository":{"full_name":"%s"}}\n' \
    "$RUN" "$1" "$2" "$3" "$4" "$6" "$REPO" "$RUN" "$REPO" "$5"
}
commit_json(){ # commit_json <sha> <tree> <parent>...
  local sha="$1" tree="$2" p parents=""; shift 2
  for p in "$@"; do parents="$parents${parents:+,}{\"sha\":\"$p\"}"; done
  printf '{"sha":"%s","tree":{"sha":"%s"},"parents":[%s]}\n' "$sha" "$tree" "$parents"
}
decide(){ # decide [event] [tree] -> sets out, err, rc for the helper run against case $C
  : > "$C/calls"
  out="$(FAKE="$C" REUSE_GH="$TMPROOT/bin/gh" REUSE_REPO="$REPO" REUSE_TREE="${2:-$T}" REUSE_EVENT="${1:-pull_request}" REUSE_RUN_ID="$ME" \
    bash "$HELPER" 2> "$C/err")"; rc=$?
  err="$(cat "$C/err")"
}
# A full suite: exit 0, no reuse line, and a log line saying the full suite runs and why.
full_because(){ # full_because <label> <word the reason must hold>
  if [ "$rc" -ne 0 ]; then check "$1" "exit $rc: $(tail -2 <<< "$err" | tr '\n' ' ')"
  elif grep -q '^reused-run=' <<< "$out"; then check "$1" "it reused: $out"
  elif ! grep -qi 'full suite' <<< "$err"; then check "$1" "the log does not say the full suite runs: $err"
  elif ! grep -qi -- "$2" <<< "$err"; then check "$1" "the reason does not mention '$2': $err"
  else check "$1" ok; fi
}

# 1. The proof holds: the run is named in the output, and the log says which run and commit.
fresh; decide
if [ "$rc" -eq 0 ] && grep -qx "reused-run=$RUN" <<< "$out" && grep -qx "reused-sha=$S" <<< "$out" \
  && grep -qx "reused-url=https://github.com/$REPO/actions/runs/$RUN" <<< "$out" \
  && grep -q "$RUN" <<< "$err" && grep -q "$S" <<< "$err"; then
  check "#2690 a green run of this exact tree is reused, and the run and commit it reused are named" ok
else
  check "#2690 a green run of this exact tree is reused, and the run and commit it reused are named" "rc=$rc out=[$(tr '\n' ' ' <<< "$out")] err=[$(tr '\n' ' ' <<< "$err")]"
fi

# 2. The earlier run was a pull request's, which tests GitHub's merge commit: the commit it recorded
# is a merge whose parents include that run's head, so it is tied to the run.
fresh
run_json pull_request "$HEAD" success completed "$REPO" ".github/workflows/tests.yml" > "$C/run-$RUN.json"
sed -i.bak "s/\"head_sha\":\"$S\"/\"head_sha\":\"$HEAD\"/" "$C/artifacts.json"
commit_json "$S" "$T" "$BASE" "$HEAD" > "$C/commit-$S.json"
decide
grep -qx "reused-run=$RUN" <<< "$out" && [ "$rc" -eq 0 ] \
  && check "#2690 a pull request run's merge commit with this exact tree is reused" ok \
  || check "#2690 a pull request run's merge commit with this exact tree is reused" "rc=$rc out=[$out] err=[$err]"

# 3. A different tree.
fresh; commit_json "$S" "$OTHER_T" "$BASE" > "$C/commit-$S.json"; decide
full_because "#2690 a run whose commit holds a different tree runs the full suite" "tree"

# 4. A red run, and one still running.
fresh; run_json push "$S" failure completed "$REPO" ".github/workflows/tests.yml" > "$C/run-$RUN.json"; decide
full_because "#2690 a red run runs the full suite" "failure"
fresh; run_json push "$S" "" in_progress "$REPO" ".github/workflows/tests.yml" > "$C/run-$RUN.json"; decide
full_because "#2690 a run not yet finished runs the full suite" "in_progress"

# 5. No earlier run of this tree at all, and only an expired one.
fresh; printf '{"total_count":0,"artifacts":[]}\n' > "$C/artifacts.json"; decide
full_because "#2690 a tree with no earlier green run runs the full suite" "no "
fresh; sed -i.bak 's/"expired":false/"expired":true/' "$C/artifacts.json"; decide
full_because "#2690 a tree whose only record has expired runs the full suite" "no "

# 6. The API failing at each read.
fresh; rm "$C/artifacts.json"; decide
full_because "#2690 the artifact search failing runs the full suite" "could not"
fresh; rm "$C/run-$RUN.json"; decide
full_because "#2690 the run read failing runs the full suite" "could not"
fresh; rm "$C/commit-$S.json"; decide
full_because "#2690 the commit read failing runs the full suite" "could not"
fresh; rm "$C/artifact-$RUN.txt"; decide
full_because "#2690 the record download failing runs the full suite" "could not"
fresh; printf 'not json at all\n' > "$C/artifacts.json"; decide
full_because "#2690 an answer that is not JSON runs the full suite" "could not"

# 7. A run that is not this repository's own tests.yml.
fresh; run_json push "$S" success completed "someone/fork" ".github/workflows/tests.yml" > "$C/run-$RUN.json"; decide
full_because "#2690 a fork's run runs the full suite" "fork"
fresh; run_json push "$S" success completed "$REPO" ".github/workflows/other.yml" > "$C/run-$RUN.json"; decide
full_because "#2690 a run of another workflow runs the full suite" "workflow"

# 8. The recorded commit not belonging to the run.
fresh; run_json push "$HEAD" success completed "$REPO" ".github/workflows/tests.yml" > "$C/run-$RUN.json"
sed -i.bak "s/\"head_sha\":\"$S\"/\"head_sha\":\"$HEAD\"/" "$C/artifacts.json"; decide
full_because "#2690 a push run whose recorded commit is not its own runs the full suite" "belong"
fresh; run_json pull_request "$HEAD" success completed "$REPO" ".github/workflows/tests.yml" > "$C/run-$RUN.json"
sed -i.bak "s/\"head_sha\":\"$S\"/\"head_sha\":\"$HEAD\"/" "$C/artifacts.json"
commit_json "$S" "$T" "$BASE" "$OTHER_T" > "$C/commit-$S.json"; decide
full_because "#2690 a pull request run whose recorded merge commit has another head runs the full suite" "belong"
fresh; printf 'sha=%s\ntree=%s\nrun=%s\n' "$S" "$T" 12345 > "$C/artifact-$RUN.txt"; decide
full_because "#2690 a record naming a different run runs the full suite" "run"
fresh; printf 'tree=%s\n' "$T" > "$C/artifact-$RUN.txt"; decide
full_because "#2690 a record naming no commit runs the full suite" "commit"
fresh; sed -i.bak 's/"head_sha":"[0-9a-f]*"/"head_sha":"ffff000000000000000000000000000000000009"/' "$C/artifacts.json"; decide
full_because "#2690 an index whose run head differs from the run's own runs the full suite" "head"

# 9. This run's own record (a re-run of the same run) is never its own proof.
fresh; sed -i.bak "s/\"id\":$RUN,\"repository_id\"/\"id\":$ME,\"repository_id\"/" "$C/artifacts.json"; decide
full_because "#2690 a run never stands on its own record" "this run"

# 10. Only a pull request run reuses: pushes to main and runs by hand always run in full, and ask
# GitHub nothing.
for ev in push workflow_dispatch; do
  fresh; decide "$ev"
  full_because "#2690 a $ev run runs the full suite" "pull request"
  [ ! -s "$C/calls" ] \
    && check "#2690 and a $ev run makes no API call" ok \
    || check "#2690 and a $ev run makes no API call" "called: $(tr '\n' ' ' < "$C/calls")"
done

# 11. A tree that is not a full hash is refused before anything is asked.
fresh; decide pull_request "abc"; full_because "#2690 a tree that is not a full hash runs the full suite" "tree"

# 12. gh itself missing is the API failing, not a crash.
fresh; : > "$C/calls"
out="$(FAKE="$C" REUSE_GH="$TMPROOT/bin/no-such-gh" REUSE_REPO="$REPO" REUSE_TREE="$T" REUSE_EVENT=pull_request REUSE_RUN_ID="$ME" bash "$HELPER" 2> "$C/err")"; rc=$?
err="$(cat "$C/err")"
full_because "#2690 no gh on the runner runs the full suite" "could not"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
