#!/usr/bin/env bash
# ci-cold-cost-streak.sh: say whether the drafts gate's cold cost case went unmeasured on main's
# last trees, every one of them (claude-config#3406).
#
#   STREAK_REPO=<owner/name> bash tools/ci-cold-cost-streak.sh
#
# The case is `bash tests/test-claude-sync.sh is judged within <limit> units of the yardstick` in
# payload/hooks/test-slack-drafts-only-gate.sh. Where every sample of it ran out of the gate's 11
# seconds on the runner it reports unmeasured rather than failing (Dan's decision of 2026-11-26,
# "3.60.1 Read it as unmeasured"), and an unmeasured part passes. So a real slowdown that made every
# judgement run out would read as green for ever (L557, L98). This reads, for each of main's newest
# commits, the run that proved its tree (the green-tree-<tree> record every full green run leaves,
# the same record tools/ci-reuse-green-tree.sh stands a reuse on, so a main push that reused a pull
# request run is read through that run), and that run's record of unmeasured parts (the
# part-unmeasured-<n> artifacts, one per part). It answers:
#
#   red         the newest STREAK readable trees all had the case unmeasured
#   green       at least one of them measured it (passed, as a red run leaves no green record)
#   unmeasured  fewer than STREAK trees in the newest LOOKBACK commits could be read
#
# Output: two lines on stdout for GITHUB_OUTPUT, cold-streak=<answer> and cold-streak-why=<one
# line naming the commits and runs it read>. Every step is explained on stderr, the job's log. Exit
# 0 for every answer; the workflow reads any other exit as unmeasured. It never judges a run by its
# conclusion alone: a tree is read only when its run handed back a record for every one of its parts.
#
# Input, from the environment:
#   STREAK_REPO   owner/name (github.repository)
#   STREAK_GH     the gh to call (default gh); the tests point it at a fake
set -uo pipefail

# THE ONE SETTING (#3406). How many of main's trees in a row must have the case unmeasured before
# main goes red. Measured on 2026-11-26 from about 50 pull request runs: a first judgement ran out
# of the seconds on 11 of them (0.22), and every sample ran out on 2 of the 8 whose logs were read.
# Taking 0.22 as the chance for any one tree, and the trees as independent, five in a row by bad
# luck alone is 0.22^5 = 0.0005, about one main push in 1,900; four is 0.0023 and six 0.0001. Slow
# runners come in spells, so the trees are not truly independent, which is why it is five and not
# three. A real slowdown that makes every judgement run out turns main red within five trees.
STREAK=5
# How far back it looks for STREAK readable trees: a red run leaves no green record, and an
# expired or incomplete one is skipped, never read as measured.
LOOKBACK=$((STREAK * 4))
# How the suite's line for this case starts, after run-all-tests takes the SUITE-PART-UNMEASURED
# off it, and the suite it is recorded under. tools/test-ci-cold-cost-streak.sh holds both equal to
# what payload/hooks/test-slack-drafts-only-gate.sh prints.
SUITE="test-slack-drafts-only-gate.sh"
MARKER="#3406: bash tests/test-claude-sync.sh is judged within"

gh="${STREAK_GH:-gh}"
repo="${STREAK_REPO:-}"

answer(){ # answer <red|green|unmeasured> <why>
  echo "Cold cost case on main: $1. $2" >&2
  printf 'cold-streak=%s\ncold-streak-why=%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ')"
  exit 0
}
[ -n "$repo" ] || answer unmeasured "no repository was named, so main's history was not read."
command -v jq > /dev/null 2>&1 || answer unmeasured "jq is not installed, so GitHub's answers could not be read."

commits="$("$gh" api "repos/$repo/commits?sha=main&per_page=$LOOKBACK" 2> /dev/null)" \
  || answer unmeasured "could not list main's commits (the commits API call failed)."
pairs="$(jq -r '.[] | "\(.sha) \(.commit.tree.sha)"' <<< "$commits" 2> /dev/null)" \
  || answer unmeasured "could not read the commits API's answer."
[ -n "$pairs" ] || answer unmeasured "the commits API listed no commit on main."

dl_root="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cold-streak.XXXXXXXX")" || answer unmeasured "could not make a folder to download records into."
trap 'rm -rf "$dl_root"' EXIT

read_n=0; skipped=0; seen=""
while read -r sha tree; do
  [ -n "$sha" ] || continue
  short="${sha:0:10}"
  arts="$("$gh" api "repos/$repo/actions/artifacts?name=green-tree-$tree&per_page=20" 2> /dev/null)" \
    || { echo "  $short: skipped, the search for its tree's green record failed." >&2; skipped=$((skipped + 1)); continue; }
  run_id="$(jq -r '[.artifacts[] | select(.expired == false)] | sort_by(.created_at) | reverse | .[0].workflow_run.id // empty' <<< "$arts" 2> /dev/null)"
  [[ "$run_id" =~ ^[0-9]+$ ]] \
    || { echo "  $short: skipped, no live green record of its tree (its run failed, is still running, or the record expired)." >&2; skipped=$((skipped + 1)); continue; }
  parts="$("$gh" api "repos/$repo/actions/runs/$run_id/jobs?per_page=100" 2> /dev/null | jq -r '[.jobs[] | select(.name | startswith("suites part"))] | length' 2> /dev/null)"
  recs="$("$gh" api "repos/$repo/actions/runs/$run_id/artifacts?per_page=100" 2> /dev/null | jq -r '[.artifacts[] | select(.expired == false) | select(.name | startswith("part-unmeasured-")) | .name] | unique | length' 2> /dev/null)"
  if ! [[ "$parts" =~ ^[0-9]+$ ]] || ! [[ "$recs" =~ ^[0-9]+$ ]] || [ "$parts" -eq 0 ] || [ "$recs" -ne "$parts" ]; then
    echo "  $short: skipped, run $run_id handed back ${recs:-no} record(s) of unmeasured parts for ${parts:-an unknown number of} part(s)." >&2
    skipped=$((skipped + 1)); continue
  fi
  d="$dl_root/$run_id"
  mkdir -p "$d"
  "$gh" run download "$run_id" -R "$repo" -p 'part-unmeasured-*' -D "$d" > /dev/null 2>&1 \
    || { echo "  $short: skipped, run $run_id's records of unmeasured parts could not be downloaded." >&2; skipped=$((skipped + 1)); continue; }
  got="$(find "$d" -name unmeasured.tsv -type f | grep -c . || true)"
  [ "${got:-0}" -eq "$parts" ] \
    || { echo "  $short: skipped, run $run_id's download held ${got:-0} record(s) for $parts part(s)." >&2; skipped=$((skipped + 1)); continue; }
  read_n=$((read_n + 1))
  if find "$d" -name unmeasured.tsv -type f -exec cat {} + | awk -F'\t' -v s="$SUITE" -v m="$MARKER" \
      '$1 == s && index(substr($0, length($1) + 2), m) == 1 { f = 1 } END { exit !f }'; then
    echo "  $short: unmeasured in run $run_id." >&2
    seen="$seen $short (run $run_id)"
  else
    answer green "main's commit $short, run $run_id, measured it, with $((read_n - 1)) unmeasured tree(s) newer than it${seen:+:$seen}."
  fi
  [ "$read_n" -lt "$STREAK" ] || break
done <<< "$pairs"

if [ "$read_n" -ge "$STREAK" ]; then
  answer red "it was unmeasured on each of main's last $STREAK readable trees:$seen. Every sample ran out of the gate's seconds on each, so whether the gate has grown past its limit is not known; read its step clock readings in those runs' logs (#3406)."
fi
answer unmeasured "only $read_n of main's newest $LOOKBACK commits had a readable record ($skipped skipped), fewer than the $STREAK it needs, so whether it has gone unmeasured $STREAK times in a row is not known."
