#!/usr/bin/env bash
# ci-reuse-green-tree.sh: may this pull request run stand on an earlier green run of EXACTLY the
# same tree, rather than running every suite again? (claude-config#2690)
#
# Dan's choice, 2026-11-10: keep the merge gate that refuses a head behind main (#766) exactly as it
# is, and make the run that follows `gh pr update-branch` cheap instead, when the tree it produces has
# already passed. L312: skip only on PROOF of an identical tree, never on a path or a trigger.
#
# The proof, every part read from GitHub at the moment of deciding:
#   1. an index artifact named green-tree-<tree>, which tests.yml's `suite` job uploads only at the
#      end of a FULL run whose deal and every part passed (never from a run that itself reused);
#   2. the run that uploaded it, read by its id: completed, conclusion success, this repository's
#      own .github/workflows/tests.yml, and its head repository this one, never a fork's; not this
#      run itself; and the same head the index names;
#   3. the commit that run tested, recorded in the artifact and then read from GitHub BY ITS SHA
#      (L179): it must hold exactly this tree, and it must belong to that run, which is the run's
#      own head for a push or a run by hand, and for a pull request the merge commit GitHub tested,
#      whose parents include that run's head.
# Anything else, including any API call failing or an answer that will not parse, is the full suite.
#
# Only a pull request run consumes a proof. A push to main always runs in full: every run on main is
# kept on purpose so a red main names its commit (claude-config#594), and dropping that run is a
# separate decision (pricing for #2690, section D). A run by hand always runs in full too.
#
# Input, from the environment:
#   REUSE_REPO    owner/name the run belongs to (github.repository)
#   REUSE_TREE    the tree this run would test (git rev-parse HEAD^{tree} of its checkout)
#   REUSE_EVENT   github.event_name
#   REUSE_RUN_ID  github.run_id, so a run never stands on its own record
#   REUSE_GH      the gh to call (default gh); the tests point it at a fake
# Output: on a reuse ONLY, three lines on stdout for GITHUB_OUTPUT, reused-run=, reused-sha= and
# reused-url=. Every decision, either way, is explained on stderr, which is the job's log.
# Exit 0 for both decisions; the workflow treats any other exit as the full suite as well.
set -uo pipefail

gh="${REUSE_GH:-gh}"
repo="${REUSE_REPO:-}"
tree="${REUSE_TREE:-}"
event="${REUSE_EVENT:-}"
me="${REUSE_RUN_ID:-}"
workflow_path=".github/workflows/tests.yml"

full(){ echo "Running the full suite: $*" >&2; exit 0; }
is_sha(){ [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

[ "$event" = pull_request ] || full "only a pull request run reuses an earlier green run, and this is a '$event' run."
is_sha "$tree" || full "the tree to test came through as '$tree', which is not a full hash."
[ -n "$repo" ] || full "no repository was named."
command -v jq > /dev/null 2>&1 || full "could not read GitHub's answers: jq is not installed."

name="green-tree-$tree"

# 1. The index. Newest first; only the newest live record is considered, so an odd one is a full
# suite rather than a hunt for one that passes.
arts="$("$gh" api "repos/$repo/actions/artifacts?name=$name&per_page=20" 2> /dev/null)" \
  || full "could not search for a record of tree $tree (the artifacts API call failed)."
art="$(jq -c '[.artifacts[] | select(.expired == false)] | sort_by(.created_at) | reverse | .[0] // empty' <<< "$arts" 2> /dev/null)" \
  || full "could not read the artifacts API's answer for tree $tree."
[ -n "$art" ] || full "no earlier green run of tree $tree is on record (no live $name artifact)."
run_id="$(jq -r '.workflow_run.id // empty' <<< "$art")"
index_head="$(jq -r '.workflow_run.head_sha // empty' <<< "$art")"
[[ "$run_id" =~ ^[0-9]+$ ]] || full "the record of tree $tree names no run."
[ "$run_id" != "$me" ] || full "the only record of tree $tree is this run's own."

# 2. The run, read by its id.
run="$("$gh" api "repos/$repo/actions/runs/$run_id" 2> /dev/null)" \
  || full "could not read run $run_id, which recorded tree $tree."
fields="$(jq -r '[.status, (.conclusion // ""), .path, .repository.full_name, (.head_repository.full_name // ""), .head_sha, .event, .html_url] | map(tostring) | join("\t")' <<< "$run" 2> /dev/null)" \
  || full "could not read the answer for run $run_id."
IFS=$'\t' read -r status conclusion path run_repo head_repo run_head run_event url <<< "$fields"
[ "$status" = completed ] || full "run $run_id, which recorded tree $tree, is $status, not completed."
[ "$conclusion" = success ] || full "run $run_id, which recorded tree $tree, ended in ${conclusion:-no conclusion}, not success."
[ "$path" = "$workflow_path" ] || full "run $run_id is of workflow $path, not $workflow_path."
[ "$run_repo" = "$repo" ] || full "run $run_id belongs to $run_repo, not $repo."
[ "$head_repo" = "$repo" ] || full "run $run_id tested a fork's head ($head_repo), and a fork's run is never proof here."
is_sha "$run_head" || full "run $run_id has no head commit."
[ "$run_head" = "$index_head" ] || full "run $run_id's head is $run_head but its record names head $index_head."

# 3. The commit it tested, from the record, then read from GitHub by that sha.
dl="$(mktemp -d "${TMPDIR:-/tmp}/reuse-green-tree.XXXXXXXX")" || full "could not make a directory to download the record into."
trap 'rm -rf "$dl"' EXIT
"$gh" run download "$run_id" -R "$repo" -n "$name" -D "$dl" > /dev/null 2>&1 \
  || full "could not download the record $name from run $run_id."
[ -f "$dl/tested.txt" ] || full "could not find tested.txt in the record from run $run_id."
tested="$(sed -n '/^sha=/{s/^sha=//p;q;}' "$dl/tested.txt")"
recorded_run="$(sed -n '/^run=/{s/^run=//p;q;}' "$dl/tested.txt")"
is_sha "$tested" || full "the record from run $run_id names no tested commit."
[ "$recorded_run" = "$run_id" ] || full "the record names run '$recorded_run', but it was uploaded by run $run_id."
commit="$("$gh" api "repos/$repo/git/commits/$tested" 2> /dev/null)" \
  || full "could not read commit $tested, which run $run_id tested."
commit_tree="$(jq -r '.tree.sha // empty' <<< "$commit" 2> /dev/null)" \
  || full "could not read the answer for commit $tested."
[ "$commit_tree" = "$tree" ] || full "commit $tested, which run $run_id tested, holds tree ${commit_tree:-none}, not $tree."
if [ "$tested" != "$run_head" ]; then
  [ "$run_event" = pull_request ] \
    || full "commit $tested does not belong to run $run_id, a $run_event run whose own commit is $run_head."
  jq -e --arg h "$run_head" '[.parents[].sha] | index($h)' <<< "$commit" > /dev/null 2>&1 \
    || full "commit $tested does not belong to run $run_id: it is not a merge of that run's head $run_head."
fi

echo "Reusing run $run_id ($url): it passed on commit $tested, whose tree is exactly this run's tree $tree. The suites are NOT run again in this run." >&2
printf 'reused-run=%s\nreused-sha=%s\nreused-url=%s\n' "$run_id" "$tested" "$url"
