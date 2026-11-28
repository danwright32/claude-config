#!/usr/bin/env bash
# tools/ci-cold-cost-streak.sh turns main red when the drafts gate's cold cost case was unmeasured
# on each of main's last STREAK trees, says green when one of them measured it, and says unmeasured,
# never green, when it cannot read enough of main's history (claude-config#3406).
#
# Driven against a fake gh that serves fixtures: one commit per letter of a case's spec, each with
# its tree's green record, its run's jobs, and that run's records of unmeasured parts.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/ci-cold-cost-streak.sh"
GATE_SUITE="$DIR/../payload/hooks/test-slack-drafts-only-gate.sh"
RUNNER="$DIR/../payload/hooks/run-all-tests.sh"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

command -v jq > /dev/null 2>&1 || {
  echo "SUITE-NOT-RUN jq is not installed, so the tool's API reading cannot be exercised"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.coldstreak.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-ci-cold-cost-streak: refusing to run: the throwaway directory came back as '$TMPROOT'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

STREAK="$(sed -n 's/^STREAK=\([0-9][0-9]*\)$/\1/p' "$TOOL")"
LINE_COLD="#3406: bash tests/test-claude-sync.sh is judged within 17.8 percent of the line by the runner's speed, 2.25 s and 53.5 units of the yardstick's median sample, on Linux (#2918, #3167): every judgement of this case ran out of the gate's seconds on this machine"
LINE_WARM="#3170: judged a second time, bash tests/test-claude-sync.sh takes at most 6 units of the yardstick, from the cache (#2918): the cache this case was handed was never filled"
TAB="$(printf '\t')"

# The fake gh. Every response is a file in the case's directory, and a missing file is the API
# failing, as gh does: a message on stderr and a non zero exit.
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE/calls"
serve(){ if [ -f "$FAKE/$1" ]; then cat "$FAKE/$1"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi; }
case "$1 $2" in
  "api repos/owner/repo/commits?sha=main&per_page="*) serve commits.json ;;
  "api repos/owner/repo/actions/artifacts?name=green-tree-"*) t="${2#*green-tree-}"; serve "art-${t%%&*}.json" ;;
  "api repos/owner/repo/actions/runs/"*"/jobs?"*) r="${2#repos/owner/repo/actions/runs/}"; serve "jobs-${r%%/*}.json" ;;
  "api repos/owner/repo/actions/runs/"*"/artifacts?"*) r="${2#repos/owner/repo/actions/runs/}"; serve "runart-${r%%/*}.json" ;;
  "run download")
    id="$3"; shift 3; dir=""
    while [ $# -gt 0 ]; do case "$1" in -D|--dir) dir="$2"; shift 2 ;; *) shift ;; esac; done
    [ -d "$FAKE/dl-$id" ] || { echo "no artifact" >&2; exit 1; }
    mkdir -p "$dir" && cp -R "$FAKE/dl-$id/." "$dir/" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 3 ;;
esac
GH
chmod +x "$TMPROOT/bin/gh"

# make_case <name> <spec>: one commit per letter, newest first, two parts per run.
#   U  the cold case was unmeasured      M  it was measured (no line for it)
#   W  only the cached twin's line       O  the cold case's words, under another suite
#   N  no live green record of the tree  I  one record of unmeasured parts for two parts
make_case(){
  local c="$TMPROOT/$1" spec="$2" i=0 letter sha tree run first=1
  mkdir -p "$c"
  printf '[' > "$c/commits.json"
  while [ -n "$spec" ]; do
    letter="${spec:0:1}"; spec="${spec:1}"; i=$((i + 1))
    sha="$(printf 'c%09d%030d' "$i" 0)"; tree="$(printf 't%039d' "$i")"; run=$((1000 + i))
    [ "$first" = 1 ] || printf ',' >> "$c/commits.json"; first=0
    printf '{"sha": "%s", "commit": {"tree": {"sha": "%s"}}}' "$sha" "$tree" >> "$c/commits.json"
    [ "$letter" = N ] && continue
    printf '{"artifacts": [{"name": "green-tree-%s", "expired": false, "created_at": "2026-11-26T10:00:00Z", "workflow_run": {"id": %s}}]}' "$tree" "$run" > "$c/art-$tree.json"
    printf '{"jobs": [{"name": "deal"}, {"name": "suites part 1"}, {"name": "suites part 2"}, {"name": "suite"}]}' > "$c/jobs-$run.json"
    mkdir -p "$c/dl-$run/part-unmeasured-1" "$c/dl-$run/part-unmeasured-2"
    : > "$c/dl-$run/part-unmeasured-1/unmeasured.tsv"
    printf 'test-pinned-compiler.sh%sno npm on PATH\n' "$TAB" > "$c/dl-$run/part-unmeasured-2/unmeasured.tsv"
    case "$letter" in
      U) printf 'test-slack-drafts-only-gate.sh%s%s\n' "$TAB" "$LINE_COLD" >> "$c/dl-$run/part-unmeasured-1/unmeasured.tsv" ;;
      W) printf 'test-slack-drafts-only-gate.sh%s%s\n' "$TAB" "$LINE_WARM" >> "$c/dl-$run/part-unmeasured-1/unmeasured.tsv" ;;
      O) printf 'test-other.sh%s%s\n' "$TAB" "$LINE_COLD" >> "$c/dl-$run/part-unmeasured-1/unmeasured.tsv" ;;
    esac
    if [ "$letter" = I ]; then
      printf 'test-slack-drafts-only-gate.sh%s%s\n' "$TAB" "$LINE_COLD" > "$c/dl-$run/part-unmeasured-1/unmeasured.tsv"
      rm -rf "$c/dl-$run/part-unmeasured-2"
      printf '{"artifacts": [{"name": "part-unmeasured-1", "expired": false}]}' > "$c/runart-$run.json"
    else
      printf '{"artifacts": [{"name": "part-unmeasured-1", "expired": false}, {"name": "part-unmeasured-2", "expired": false}, {"name": "part-timings-1", "expired": false}]}' > "$c/runart-$run.json"
    fi
  done
  printf ']' >> "$c/commits.json"
}
# run_case <name> [repo]: the tool's stdout, then "exit <code>".
run_case(){
  local out rc
  out="$(FAKE="$TMPROOT/$1" STREAK_GH="$TMPROOT/bin/gh" STREAK_REPO="${2-owner/repo}" RUNNER_TEMP="$TMPROOT" bash "$TOOL" 2> "$TMPROOT/$1.err")"; rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}
answered(){ # answered <check name> <answer> <a pattern the why must match> <case> [repo]
  local got
  got="$(run_case "$4" "${5-owner/repo}")"
  # shellcheck disable=SC2254
  case "$got" in
    "cold-streak=$2"$'\n'"cold-streak-why="$3$'\n'"exit 0") check "$1" ok ;;
    *) check "$1" "answered: $(tr '\n' '|' <<< "$got") stderr: $(tr '\n' '|' < "$TMPROOT/$4.err" | cut -c1-600)" ;;
  esac
}
rep(){ local s="" k=0; while [ "$k" -lt "$2" ]; do s="$s$1"; k=$((k + 1)); done; printf '%s' "$s"; }

[[ "$STREAK" =~ ^[0-9]+$ ]] && [ "$STREAK" -ge 2 ] \
  && check "#3406 the tool holds one numbered STREAK setting" ok \
  || check "#3406 the tool holds one numbered STREAK setting" "read '$STREAK' from $TOOL"
[ -n "$STREAK" ] || STREAK=5

make_case red "$(rep U "$STREAK")"
answered "#3406 main's last $STREAK readable trees all unmeasured is red, naming each" red "it was unmeasured on each of main's last $STREAK readable trees:*c000000001 (run 1001)*(run 100$STREAK)*" "red"

make_case one-measured "UU$(rep M 1)$(rep U "$STREAK")"
answered "#3406 one measured tree among them is green, naming it" green "main's commit c000000003, run 1003, measured it, with 2 unmeasured tree(s) newer than it*" "one-measured"

make_case newest-measured "M$(rep U "$STREAK")"
answered "#3406 the newest tree measured is green at once" green "main's commit c000000001, run 1001, measured it, with 0 unmeasured tree(s) newer than it." "newest-measured"

make_case skip-unrecorded "NN$(rep U "$STREAK")"
answered "#3406 a tree with no green record is skipped, never read as measured, and the streak still turns red" red "*(run 1003)*" "skip-unrecorded"

make_case too-few "$(rep U $((STREAK - 1)))N"
answered "#3406 fewer than $STREAK readable trees is unmeasured, not green" unmeasured "only $((STREAK - 1)) of main's newest * commits had a readable record (1 skipped)*" "too-few"

make_case incomplete "I$(rep U $((STREAK - 1)))"
answered "#3406 a run with fewer records than parts is skipped, so the streak is unmeasured" unmeasured "only $((STREAK - 1)) of main's newest * commits had a readable record (1 skipped)*" "incomplete"

make_case same-tree "$(rep U "$STREAK")"
sed -i.bak "s/$(printf 't%039d' 2)/$(printf 't%039d' 1)/" "$TMPROOT/same-tree/commits.json"
answered "#3406 two commits holding one tree are one tree, counted once" unmeasured "only $((STREAK - 1)) of main's newest * commits had a readable record (1 skipped)*" "same-tree"

make_case warm-only "$(rep W "$STREAK")"
answered "#3406 the cached twin's unmeasured line is not this case, so it is green" green "main's commit c000000001, run 1001, measured it*" "warm-only"

make_case other-suite "$(rep O "$STREAK")"
answered "#3406 the case's words under another suite are not this case, so it is green" green "main's commit c000000001, run 1001, measured it*" "other-suite"

mkdir -p "$TMPROOT/no-commits"
answered "#3406 main's commits that cannot be listed are unmeasured, not green" unmeasured "could not list main's commits*" "no-commits"

make_case no-repo "$(rep U "$STREAK")"
answered "#3406 no repository named is unmeasured" unmeasured "no repository was named*" "no-repo" ""

# The words it finds the case by are the words the suite prints and run-all-tests records (L100):
# cost_case prints "SUITE-PART-UNMEASURED <issue>: <check name>: ...", the cold case passes #3406 and
# a name starting "bash tests/test-claude-sync.sh is judged within", and run-all-tests records the
# line after "SUITE-PART-UNMEASURED " under the suite's own file name.
marker="$(sed -n 's/^MARKER="\(.*\)"$/\1/p' "$TOOL")"
suite_name="$(sed -n 's/^SUITE="\(.*\)"$/\1/p' "$TOOL")"
miss=""
[ "$marker" = "#3406: bash tests/test-claude-sync.sh is judged within" ] || miss="$miss the tool's MARKER is '$marker';"
[ "$suite_name" = "$(basename "$GATE_SUITE")" ] || miss="$miss the tool's SUITE is '$suite_name';"
cold_call="$(grep -F 'cost_case "bash tests/test-claude-sync.sh is judged within $cold_within on' "$GATE_SUITE" || true)"
grep -qF '"$cost" "#3406"' <<< "$cold_call" \
  || miss="$miss the drafts suite's cold case is not reported through cost_case under #3406;"
# shellcheck disable=SC2016
grep -qF '"unmeasured: "*) echo "SUITE-PART-UNMEASURED ${3:-#3170}: $1: ${2#unmeasured: }"' "$GATE_SUITE" \
  || miss="$miss cost_case does not print SUITE-PART-UNMEASURED <issue>: <name>: <why>;"
grep -qF "sed -n 's/^SUITE-PART-UNMEASURED //p'" "$RUNNER" \
  || miss="$miss run-all-tests no longer records the line after SUITE-PART-UNMEASURED;"
[ -z "$miss" ] && check "#3406 the tool finds the case by the words the drafts suite prints and run-all-tests records" ok \
  || check "#3406 the tool finds the case by the words the drafts suite prints and run-all-tests records" "${miss# }"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
