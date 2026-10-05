#!/usr/bin/env bash
# Holds three decisions in .github/workflows/tests.yml that the September 2026 CI review made
# (claude-config#598), each of which a later edit could quietly undo:
#
#   #594 a run on main is never cancelled by the next push. 207 of 602 runs on main that month were
#        cancelled, and those were exactly the runs that would have said which commit turned main red.
#
#   #597 every action is pinned to a full commit hash on a runtime GitHub still supports, so the code
#        that runs cannot change under the same tag and a deprecated runtime cannot fail every run at
#        once on the day it is switched off.
#
#   #597 the runner image is named, never ubuntu-latest, so the image moving underneath (to Ubuntu 26
#        on 2026-10-19) cannot turn main red with no commit to blame. Moving to a new image is then a
#        commit somebody makes and CI judges, rather than a date.
#
# Each rule is a function over a workflow FILE, and each is run against a fixture that breaks it
# before it is believed about the real file. A check never seen to fail could be passing because it
# reads nothing (L1, L159).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOWS="$DIR/../.github/workflows"
REAL="$WORKFLOWS/tests.yml"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

[ -f "$REAL" ] || { echo "test-ci-workflow: no workflow at $REAL, so nothing was checked." >&2; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.ciworkflow.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-ci-workflow: refusing to run: the throwaway directory came back as '$TMPROOT'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# Comments are stripped before anything is read, so the prose explaining a rule can never be what
# satisfies it (L135).
code_of(){ sed 's/[[:space:]]#.*$//; s/^#.*$//' "$1"; }

# ---------------------------------------------------------------------------
# #594: main is never cancelled.
# ---------------------------------------------------------------------------
# Answers "ok" or why not. Cancelling is still wanted on pull request branches, where a newer push
# really does supersede the old one, so what is required is a condition that is false on main, not
# the removal of cancelling altogether.
main_not_cancelled(){ # main_not_cancelled <workflow>
  local v
  v="$(code_of "$1" | sed -n 's/^[[:space:]]*cancel-in-progress:[[:space:]]*//p')"
  case "$v" in
    '') echo ok ;;
    true) echo "cancel-in-progress is plain true, so every run on main is cancelled by the next push" ;;
    false) echo ok ;;
    *"github.ref != 'refs/heads/main'"*) echo ok ;;
    *) echo "cancel-in-progress is '$v', which does not visibly exclude main" ;;
  esac
}
printf 'concurrency:\n  group: tests-${{ github.ref }}\n  cancel-in-progress: true # superseded\n' > "$TMPROOT/cancels.yml"
r="$(main_not_cancelled "$TMPROOT/cancels.yml")"
[ "$r" != ok ] \
  && check "#594 a workflow that cancels every superseded run is refused" ok \
  || check "#594 a workflow that cancels every superseded run is refused" "it passed"
printf 'concurrency:\n  # cancel-in-progress: ${{ github.ref != '"'"'refs/heads/main'"'"' }}\n  cancel-in-progress: true\n' > "$TMPROOT/comment-only.yml"
r="$(main_not_cancelled "$TMPROOT/comment-only.yml")"
[ "$r" != ok ] \
  && check "#594 and a comment holding the right expression does not satisfy it" ok \
  || check "#594 and a comment holding the right expression does not satisfy it" "it passed"
r="$(main_not_cancelled "$REAL")"
[ "$r" = ok ] \
  && check "#594 the real workflow never cancels a run on main" ok \
  || check "#594 the real workflow never cancels a run on main" "$r"
# Still cancelling on pull requests, which is the half that saves minutes for nothing lost.
grep -qE "^[[:space:]]*cancel-in-progress:[[:space:]]*\\$\\{\\{ github.ref != 'refs/heads/main' \\}\\}" "$REAL" \
  && check "#594 and still cancels a superseded run on a pull request branch" ok \
  || check "#594 and still cancels a superseded run on a pull request branch" "cancel-in-progress is no longer the main excluding expression"

# Turning cancel-in-progress off is NOT enough on its own. A concurrency group holds at most one
# running and one PENDING run, and a newer run queuing into the group cancels the pending one
# whatever cancel-in-progress says. So with one group per branch, three commits landing on main
# together still lost the middle verdict. On main the group must be one per commit.
group_per_commit_on_main(){ # group_per_commit_on_main <workflow>
  local g
  g="$(code_of "$1" | sed -n 's/^[[:space:]]*group:[[:space:]]*//p')"
  case "$g" in
    '') echo "no concurrency group, so nothing is ever cancelled" ;;
    *"github.ref == 'refs/heads/main' && github.sha"*) echo ok ;;
    *) echo "the group is '$g', which is shared by every commit on main, so a pending run there is cancelled by the next one queuing" ;;
  esac
}
printf 'concurrency:\n  group: tests-${{ github.ref }}\n  cancel-in-progress: false\n' > "$TMPROOT/shared-group.yml"
r="$(group_per_commit_on_main "$TMPROOT/shared-group.yml")"
[ "$r" != ok ] \
  && check "#594 a group shared by every commit on main is refused, even with cancelling off" ok \
  || check "#594 a group shared by every commit on main is refused, even with cancelling off" "it passed"
printf 'jobs:\n  suite:\n    runs-on: ubuntu-26.04\n' > "$TMPROOT/no-group.yml"
r="$(group_per_commit_on_main "$TMPROOT/no-group.yml")"
[ "$r" != ok ] \
  && check "#594 a workflow with no concurrency group at all is refused too" ok \
  || check "#594 a workflow with no concurrency group at all is refused too" "it passed"
# Strict about the real file: a deleted group would also stop pull requests cancelling a superseded
# run, which is the half of #594 that saves minutes, so it is refused rather than waved through.
r="$(group_per_commit_on_main "$REAL")"
[ "$r" = ok ] \
  && check "#594 on main each commit has its own group, so no pending run is displaced" ok \
  || check "#594 on main each commit has its own group, so no pending run is displaced" "$r"

# ---------------------------------------------------------------------------
# #597: every action is pinned to a commit, on a supported runtime.
# ---------------------------------------------------------------------------
# The oldest major of each action that runs on Node 24 rather than the deprecated Node 20, read off
# each action's action.yml (`runs.using`) on 2026-10-05. An action not listed here is refused rather
# than waved through, so adding one means checking its runtime and writing it down (L96).
min_major_for(){
  case "$1" in
    actions/checkout) echo 5 ;;
    actions/cache) echo 5 ;;
    *) echo "" ;;
  esac
}
actions_pinned(){ # actions_pinned <workflow> -> ok, or one line per offending step
  local out="" line ref action sha ver major min n=0
  while IFS= read -r line; do
    n=$((n + 1))
    ref="$(printf '%s\n' "$line" | sed -n 's/^[[:space:]-]*uses:[[:space:]]*\([^[:space:]]*\).*/\1/p')"
    action="${ref%@*}"; sha="${ref#*@}"
    ver="$(printf '%s\n' "$line" | sed -n 's/.*#[[:space:]]*\(v[0-9][0-9.]*\).*/\1/p')"
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      out="$out$action is referenced as '$sha', not a full commit hash
"
      continue
    fi
    if [ -z "$ver" ]; then
      out="$out$action is pinned with no version comment, so nobody can tell what it is
"
      continue
    fi
    major="${ver#v}"; major="${major%%.*}"
    min="$(min_major_for "$action")"
    if [ -z "$min" ]; then
      out="$out$action has no recorded runtime here, so whether it runs on a supported Node is unknown
"
    elif [ "$major" -lt "$min" ]; then
      out="$out$action $ver runs on the deprecated Node 20; v$min or later is needed
"
    fi
  done <<EOF
$(grep -E '^[[:space:]-]*uses:' "$1")
EOF
  if [ "$n" -eq 0 ] || [ -z "$(grep -E '^[[:space:]-]*uses:' "$1")" ]; then
    echo "no uses: line was found, so nothing was checked"
  elif [ -z "$out" ]; then
    echo ok
  else
    printf '%s' "$out"
  fi
}
printf 'steps:\n  - uses: actions/checkout@v4\n' > "$TMPROOT/tag.yml"
r="$(actions_pinned "$TMPROOT/tag.yml")"
grep -q 'not a full commit hash' <<< "$r" \
  && check "#597 an action referenced by tag is refused" ok \
  || check "#597 an action referenced by tag is refused" "got: $r"
printf 'steps:\n  - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2\n' > "$TMPROOT/node20.yml"
r="$(actions_pinned "$TMPROOT/node20.yml")"
grep -q 'deprecated Node 20' <<< "$r" \
  && check "#597 a pinned action still on Node 20 is refused" ok \
  || check "#597 a pinned action still on Node 20 is refused" "got: $r"
printf 'steps:\n  - uses: someone/else@3d3c42e5aac5ba805825da76410c181273ba90b1 # v9.0.0\n' > "$TMPROOT/unknown.yml"
r="$(actions_pinned "$TMPROOT/unknown.yml")"
grep -q 'no recorded runtime' <<< "$r" \
  && check "#597 an action whose runtime nobody recorded is refused" ok \
  || check "#597 an action whose runtime nobody recorded is refused" "got: $r"
printf 'steps:\n  - run: true\n' > "$TMPROOT/none.yml"
r="$(actions_pinned "$TMPROOT/none.yml")"
[ "$r" != ok ] \
  && check "#597 a file with no action in it reports that nothing was checked" ok \
  || check "#597 a file with no action in it reports that nothing was checked" "it passed"
r="$(actions_pinned "$REAL")"
[ "$r" = ok ] \
  && check "#597 every action in the real workflow is pinned to a commit on a supported runtime" ok \
  || check "#597 every action in the real workflow is pinned to a commit on a supported runtime" "$r"

# ---------------------------------------------------------------------------
# #597: the runner image is named.
# ---------------------------------------------------------------------------
image_named(){ # image_named <workflow>
  local r
  r="$(code_of "$1" | sed -n 's/^[[:space:]]*runs-on:[[:space:]]*//p')"
  if [ -z "$r" ]; then echo "no runs-on line was found"; return; fi
  case "$r" in
    *-latest*) echo "runs on '$r', which GitHub moves to a new image on a date of its choosing" ;;
    ubuntu-[0-9][0-9].[0-9][0-9]) echo ok ;;
    *) echo "runs on '$r', which is not a named Ubuntu image" ;;
  esac
}
printf 'jobs:\n  suite:\n    runs-on: ubuntu-latest\n' > "$TMPROOT/latest.yml"
r="$(image_named "$TMPROOT/latest.yml")"
[ "$r" != ok ] \
  && check "#597 a job on ubuntu-latest is refused" ok \
  || check "#597 a job on ubuntu-latest is refused" "it passed"
r="$(image_named "$REAL")"
[ "$r" = ok ] \
  && check "#597 the real workflow names its runner image" ok \
  || check "#597 the real workflow names its runner image" "$r"
# The container that reproduces CI on a Mac derives its image from this same line and refuses one it
# has no mapping for. Asked directly, so a move to a new image cannot leave it refusing unnoticed.
runner="$(code_of "$REAL" | sed -n 's/^[[:space:]]*runs-on:[[:space:]]*//p')"
grep -qE "^[[:space:]]*(.*\\|)?$runner(\\|.*)?\\)[[:space:]]+IMAGE=" "$DIR/run-on-linux.sh" \
  && check "#597 run-on-linux.sh has an image for '$runner'" ok \
  || check "#597 run-on-linux.sh has an image for '$runner'" "no case arm names it"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
