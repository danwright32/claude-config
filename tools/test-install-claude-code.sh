#!/usr/bin/env bash
# The mods' tests on Claude Code in CI (claude-config#3297): tools/install-claude-code.sh, the one
# reader of .github/claude-code-version; tools/report-mods-on-newest-claude-code.sh, which tells Dan
# when the daily run on the newest release fails; and the two workflows that use them.
#
# npm and gh are fakes that log what they were asked, so nothing is downloaded and nothing is posted.
# Every refusal is reached on purpose, and each workflow rule is read from the real files with their
# comments stripped, so the prose explaining a rule can never be what satisfies it (L135).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
INSTALL="$DIR/install-claude-code.sh"
REPORT="$DIR/report-mods-on-newest-claude-code.sh"
TESTS_WF="$ROOT/.github/workflows/tests.yml"
DAILY_WF="$ROOT/.github/workflows/mods-on-newest-claude-code.yml"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-install-claude-code.XXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "FAIL: refusing to run: the throwaway directory came back as '$TMPROOT'."; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# The installer, against a fake npm.
# ---------------------------------------------------------------------------
NPM="$TMPROOT/npm"; NPM_LOG="$TMPROOT/npm.log"
cat > "$NPM" <<'STUB'
#!/bin/bash
echo "$*" >> "$NPM_LOG"
if [ "$1" = view ]; then
  [ -n "${STUB_VIEW_FAIL:-}" ] && { echo "npm error network" >&2; exit 1; }
  echo "${STUB_NEWEST:-2.1.999}"; exit 0
fi
if [ "$1" = install ]; then
  [ -n "${STUB_INSTALL_FAIL:-}" ] && { echo "npm error 404 Not Found" >&2; exit 1; }
  prefix=""; spec=""
  while [ $# -gt 0 ]; do case "$1" in --prefix) prefix="$2"; shift 2 ;; @*) spec="$1"; shift ;; *) shift ;; esac; done
  mkdir -p "$prefix/node_modules/.bin"
  built="${STUB_BUILT_VERSION:-${spec##*@}}"
  printf '#!/bin/bash\necho "%s (Claude Code)"\n' "$built" > "$prefix/node_modules/.bin/claude"
  chmod +x "$prefix/node_modules/.bin/claude"
  exit 0
fi
exit 3
STUB
chmod +x "$NPM"
VF="$TMPROOT/claude-code-version"
inst(){   # the whole command, env words first -> out (stdout), err, code
  : > "$NPM_LOG"
  out="$("$@" 2>"$TMPROOT/inst.err")"; code=$?; err="$(cat "$TMPROOT/inst.err")"
}
run_install(){ inst env NPM_BIN="$NPM" NPM_LOG="$NPM_LOG" CLAUDE_CODE_VERSION_FILE="$VF" "$@"; }

printf '# a comment\n\n2.1.300\n' > "$VF"
run_install bash "$INSTALL" "$TMPROOT/cc1"
[ "$code" -eq 0 ] && [ "$out" = "$TMPROOT/cc1/node_modules/.bin/claude" ] && grep -q -- "--prefix $TMPROOT/cc1 .*@anthropic-ai/claude-code@2.1.300$" "$NPM_LOG" \
  && check "#3297 with no version given it installs the one in the file, exactly, and prints only the command's path" ok \
  || check "#3297 with no version given it installs the one in the file, exactly, and prints only the command's path" "exit=$code out=$out err=$err npm: $(cat "$NPM_LOG")"
run_install bash "$INSTALL" "$TMPROOT/cc1"
[ "$code" -eq 0 ] && [ ! -s "$NPM_LOG" ] && grep -q 'already in' <<< "$err" \
  && check "#3297 a folder already holding that version is used without asking npm" ok \
  || check "#3297 a folder already holding that version is used without asking npm" "exit=$code err=$err npm: $(cat "$NPM_LOG")"
printf '2.1.301\n' > "$VF"
run_install bash "$INSTALL" "$TMPROOT/cc1"
[ "$code" -eq 0 ] && grep -q '@anthropic-ai/claude-code@2.1.301$' "$NPM_LOG" \
  && check "#3297 a folder holding another version is installed over" ok \
  || check "#3297 a folder holding another version is installed over" "exit=$code err=$err npm: $(cat "$NPM_LOG")"
run_install bash "$INSTALL" "$TMPROOT/cc2" latest
[ "$code" -eq 2 ] && [ ! -s "$NPM_LOG" ] && [ -z "$out" ] \
  && check "#3297 a version given on the command line, latest included, is refused before npm is asked" ok \
  || check "#3297 a version given on the command line, latest included, is refused before npm is asked" "exit=$code out=$out npm: $(cat "$NPM_LOG")"
refused_all=ok
for bad in 'latest' '^2.1.300' '2.1' '2.1.300
2.1.301' ''; do
  printf '%s\n' "$bad" > "$VF"
  run_install bash "$INSTALL" "$TMPROOT/cc3"
  if [ "$code" -ne 2 ] || [ -s "$NPM_LOG" ] || [ -n "$out" ]; then
    refused_all="file '$(printf '%s' "$bad" | tr '\n' ' ')': exit=$code out=$out"; break
  fi
done
check "#3297 a version file not holding exactly one exact version is refused before npm is asked" "$refused_all"
rm -f "$VF"
run_install bash "$INSTALL" "$TMPROOT/cc3"
[ "$code" -eq 2 ] && grep -q 'is missing' <<< "$err" \
  && check "#3297 a missing version file is refused, saying so" ok || check "#3297 a missing version file is refused, saying so" "exit=$code err=$err"
printf '2.1.302\n' > "$VF"
run_install STUB_INSTALL_FAIL=1 bash "$INSTALL" "$TMPROOT/cc4"
[ "$code" -eq 1 ] && [ -z "$out" ] && grep -q '404 Not Found' <<< "$err" \
  && check "#3297 an npm failure fails with npm's words and prints no path" ok \
  || check "#3297 an npm failure fails with npm's words and prints no path" "exit=$code out=$out err=$err"
run_install STUB_BUILT_VERSION=2.1.250 bash "$INSTALL" "$TMPROOT/cc5"
[ "$code" -eq 1 ] && [ -z "$out" ] && grep -q 'not the build asked for' <<< "$err" \
  && check "#3297 a command answering another version than asked fails" ok \
  || check "#3297 a command answering another version than asked fails" "exit=$code out=$out err=$err"
run_install STUB_NEWEST=2.1.333 bash "$INSTALL" "$TMPROOT/cc6" --newest
[ "$code" -eq 0 ] && grep -q '^view @anthropic-ai/claude-code dist-tags.latest' "$NPM_LOG" && grep -q '@anthropic-ai/claude-code@2.1.333$' "$NPM_LOG" \
  && grep -q 'newest release of @anthropic-ai/claude-code is 2.1.333' <<< "$err" \
  && check "#3297 --newest installs the exact version npm names newest, and says which" ok \
  || check "#3297 --newest installs the exact version npm names newest, and says which" "exit=$code err=$err npm: $(cat "$NPM_LOG")"
run_install STUB_VIEW_FAIL=1 bash "$INSTALL" "$TMPROOT/cc7" --newest
[ "$code" -eq 1 ] && ! grep -q '^install' "$NPM_LOG" && [ -z "$out" ] \
  && check "#3297 --newest with npm not answering installs nothing and fails" ok \
  || check "#3297 --newest with npm not answering installs nothing and fails" "exit=$code out=$out npm: $(cat "$NPM_LOG")"
# The real file, read by the real parser: one exact version.
inst env NPM_BIN="$NPM" NPM_LOG="$NPM_LOG" bash "$INSTALL" "$TMPROOT/cc8"
real_version="$(sed -nE 's/.*@anthropic-ai\/claude-code@([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$NPM_LOG")"
[ "$code" -eq 0 ] && [ -n "$real_version" ] \
  && check "#3297 the real .github/claude-code-version holds one exact version ($real_version)" ok \
  || check "#3297 the real .github/claude-code-version holds one exact version" "exit=$code err=$err"

# ---------------------------------------------------------------------------
# The report, against a fake gh.
# ---------------------------------------------------------------------------
GHD="$TMPROOT/gh-bin"; mkdir -p "$GHD"; GH_LOG="$TMPROOT/gh.log"
cat > "$GHD/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue list")
    [ "${STUB_GH_FAIL:-}" = list ] && exit 1
    jqx=""; while [ $# -gt 0 ]; do [ "$1" = --jq ] && jqx="$2"; shift; done
    printf '%s' "${STUB_LIST_JSON:-[]}" | jq -r "$jqx" ;;
  "issue comment")
    [ "${STUB_GH_FAIL:-}" = comment ] && exit 1
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$GH_LOG.comment"; shift; done ;;
  "issue create")
    [ "${STUB_GH_FAIL:-}" = create ] && exit 1
    while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$GH_LOG.body"; shift; done
    echo "https://github.com/o/r/issues/77" ;;
  *) exit 4 ;;
esac
STUB
chmod +x "$GHD/gh"
LOGS="$TMPROOT/logs"; mkdir -p "$LOGS"
printf '2.1.340\n' > "$LOGS/version"
cat > "$LOGS/test-mods.log" <<'LOG'
SUITE-NOTE Claude Code changed since the mods last passed on this Mac: they passed on Claude Code 2.1.328, and 2.1.340 is installed now.
FAIL: every mod in payload/mods passes Claude Code's own checks: exit=1 out=check-mods: 23 of 23 mods type checked
check-mods: secret-guard failed claude plugin test: 2 fail (load average 1.2)
check-mods: mod-kit refused by claude plugin validate: bad event (load average 1.2)
check-mods: goal-box ok (types checked)
SUITE-RESULT passed=500 failed=1
LOG
cat > "$LOGS/load-engine.log" <<'LOG'
FAIL: all: every mod given was seen loading (the control) (never seen loading: picker-manners)
SUITE-RESULT passed=3 failed=1
LOG
report(){   # env words -> out, code; what gh was asked in GH_LOG, what it was given in GH_LOG.body or .comment
  : > "$GH_LOG"; rm -f "$GH_LOG.body" "$GH_LOG.comment"
  out="$(env PATH="$GHD:$PATH" GH_LOG="$GH_LOG" GH_REPO=o/r RUN_URL=https://example.invalid/run/1 "$@" bash "$REPORT" "$LOGS" 2>&1)"; code=$?
}
report RESULT=success
[ "$code" -eq 0 ] && [ ! -s "$GH_LOG" ] \
  && check "#3297 a passing day asks GitHub nothing and posts nothing" ok || check "#3297 a passing day asks GitHub nothing and posts nothing" "exit=$code gh: $(cat "$GH_LOG")"
report RESULT=success STUB_LIST_JSON='[{"number":5,"body":"<!-- mods-on-newest-claude-code -->"}]'
[ "$code" -eq 0 ] && [ ! -s "$GH_LOG" ] \
  && check "#3297 and so does one with the issue still open" ok || check "#3297 and so does one with the issue still open" "exit=$code gh: $(cat "$GH_LOG")"
report RESULT=failure STUB_LIST_JSON='[{"number":9,"body":"something else"}]'
body="$(cat "$GH_LOG.body" 2>/dev/null)"; create="$(grep '^issue create' "$GH_LOG")"
[ "$code" -eq 0 ] && [ -n "$create" ] && ! grep -q '^issue comment' "$GH_LOG" \
  && check "#3297 a failing day with no report open opens one issue" ok || check "#3297 a failing day with no report open opens one issue" "exit=$code out=$out gh: $(cat "$GH_LOG")"
miss=""
for want in '--label priority-p1' '--label bug' '--label mods' '--milestone Ungrouped' '2.1.340'; do
  case "$create" in *"$want"*) ;; *) miss="$miss [$want]" ;; esac
done
[ -z "$miss" ] && check "#3297 labelled priority-p1, bug and mods, in Ungrouped, its title naming the version" ok \
  || check "#3297 labelled priority-p1, bug and mods, in Ungrouped, its title naming the version" "missing$miss in: $create"
miss=""
for want in '<!-- mods-on-newest-claude-code -->' '## Open questions' 'Claude Code: 2.1.340' 'Mods failing: mod-kit, picker-manners, secret-guard' 'https://example.invalid/run/1' 'secret-guard failed claude plugin test'; do
  case "$body" in *"$want"*) ;; *) miss="$miss [$want]" ;; esac
done
case "$body" in *goal-box*) miss="$miss [names goal-box, which passed]" ;; esac
[ -z "$miss" ] && check "#3297 its body names the version, each failing mod once, the run and what failed, and has its open questions" ok \
  || check "#3297 its body names the version, each failing mod once, the run and what failed, and has its open questions" "missing$miss in: $body"
case "$body" in *$'\u2014'*|*$'\u2013'*) check "#3297 the issue body uses no dash as punctuation" "$body" ;; *) check "#3297 the issue body uses no dash as punctuation" ok ;; esac
report RESULT=failure STUB_LIST_JSON='[{"number":9,"body":"x"},{"number":12,"body":"intro\n<!-- mods-on-newest-claude-code -->\nmore"}]'
[ "$code" -eq 0 ] && grep -q '^issue comment 12 ' "$GH_LOG" && ! grep -q '^issue create' "$GH_LOG" \
  && grep -q 'Claude Code: 2.1.340' "$GH_LOG.comment" 2>/dev/null \
  && check "#3297 a failing day with the report open comments on it, naming the version, and opens no second" ok \
  || check "#3297 a failing day with the report open comments on it, naming the version, and opens no second" "exit=$code gh: $(cat "$GH_LOG")"
report RESULT=failure STUB_GH_FAIL=list
[ "$code" -ne 0 ] && ! grep -qE '^issue (create|comment)' "$GH_LOG" \
  && check "#3297 when the open issues cannot be listed it posts nothing and fails, rather than opening a second" ok \
  || check "#3297 when the open issues cannot be listed it posts nothing and fails, rather than opening a second" "exit=$code gh: $(cat "$GH_LOG")"
report RESULT=failure STUB_GH_FAIL=create
[ "$code" -ne 0 ] && check "#3297 an issue that cannot be opened fails the run, so GitHub's own failure email goes out" ok \
  || check "#3297 an issue that cannot be opened fails the run, so GitHub's own failure email goes out" "exit=$code out=$out"
rm -f "$LOGS/version" "$LOGS/test-mods.log" "$LOGS/load-engine.log"
report RESULT=failure
body="$(cat "$GH_LOG.body" 2>/dev/null)"
case "$body" in *"unknown, because the install did not finish"*"test-mods.log: not written"*)
  check "#3297 a run that died before the tests is still reported, saying the install did not finish" ok ;;
  *) check "#3297 a run that died before the tests is still reported, saying the install did not finish" "exit=$code body: $body" ;; esac

# ---------------------------------------------------------------------------
# The workflows.
# ---------------------------------------------------------------------------
code_of(){ sed 's/[[:space:]]#.*$//; s/^#.*$//' "$1"; }
job_of(){   # $1 = workflow  $2 = job id -> that job's code lines
  code_of "$1" | awk -v j="  $2:" '$0 == j { on = 1; next } on && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { on = 0 } on'
}
tw="$(code_of "$TESTS_WF")"; dw="$(code_of "$DAILY_WF")"; parts="$(job_of "$TESTS_WF" parts)"
grep -qE 'bash tools/install-claude-code\.sh "\$HOME/claude-code-for-mods"\)"$' <<< "$parts" \
  && grep -q 'MODS_CLAUDE=' <<< "$parts" \
  && check "#3297 every part installs the version in the file, with no version or --newest given, and names it in MODS_CLAUDE" ok \
  || check "#3297 every part installs the version in the file, with no version or --newest given, and names it in MODS_CLAUDE" "not found in the parts job"
grep -qF "hashFiles('.github/claude-code-version')" <<< "$parts" \
  && check "#3297 the parts' Claude Code is cached on the version file" ok || check "#3297 the parts' Claude Code is cached on the version file" "no cache key on it"
grep -q 'GITHUB_PATH' <<< "$tw" \
  && check "#3297 the checks' Claude Code is kept off every suite's PATH" "tests.yml writes GITHUB_PATH" \
  || check "#3297 the checks' Claude Code is kept off every suite's PATH" ok
# The version is written once: no workflow installs the package itself, or names the pinned version.
bad=""
for wf in "$TESTS_WF" "$DAILY_WF"; do
  wcode="$(code_of "$wf")"
  grep -qE '@anthropic-ai/claude-code|claude-code@|npm (install|i) .*claude' <<< "$wcode" && bad="$bad ${wf##*/} installs the package itself;"
  [ -n "$real_version" ] && grep -qF "$real_version" <<< "$wcode" && bad="$bad ${wf##*/} names $real_version;"
done
[ -z "$bad" ] && check "#3297 neither workflow installs Claude Code but through the installer, or writes its version" ok \
  || check "#3297 neither workflow installs Claude Code but through the installer, or writes its version" "$bad"
# And the file is read by one place: every other code line naming it is a cache key, or the report's
# text to a reader.
other_readers(){   # $1 = a checkout -> every file there naming the version file outside a cache key or the report's text
  # Every text file in the working tree, staged or not and of any type, in one process (#3325): a
  # listing of tracked files of a few types missed a reader not yet added and a script with no
  # extension. Markdown alone is left out, as prose that names the file without reading it. The
  # installer is always among what it lists, so a listing that read nothing is refused, not passed.
  local listed named f bad=""
  listed="$(cd "$1" && git grep --untracked -I -l -F 'claude-code-version' -- ':!*.md' 2>/dev/null)"
  grep -qx 'tools/install-claude-code\.sh' <<< "$listed" \
    || { printf ' (nothing: the listing did not find tools/install-claude-code.sh itself, so it read nothing)'; return; }
  named="$(grep -v -e '^tools/test-install-claude-code\.sh$' -e '^tools/install-claude-code\.sh$' -e '^tools/report-mods-on-newest-claude-code\.sh$' <<< "$listed")"
  for f in $named; do
    case "$f" in
      .github/workflows/*) [ -n "$(code_of "$1/$f" | grep -F 'claude-code-version' | grep -vF "hashFiles('.github/claude-code-version')")" ] && bad="$bad $f" ;;
      *) bad="$bad $f" ;;
    esac
  done
  [ -n "$(grep -v '^[[:space:]]*#' "$1/tools/report-mods-on-newest-claude-code.sh" | grep -F 'claude-code-version' | grep -v '`')" ] && bad="$bad tools/report-mods-on-newest-claude-code.sh (outside its text)"
  printf '%s' "$bad"
}
# A copy git cannot read (a worktree copied without its repository, or one owned by another user) is
# said to be unmeasured rather than failed or passed: it is the machine, not the tree.
if git -C "$ROOT" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  bad="$(other_readers "$ROOT")"
  [ -z "$bad" ] && check "#3297 .github/claude-code-version is read by tools/install-claude-code.sh alone" ok \
    || check "#3297 .github/claude-code-version is read by tools/install-claude-code.sh alone" "also named, outside a cache key, in:$bad"
else
  echo "SUITE-PART-UNMEASURED that .github/claude-code-version has one reader: git cannot read $ROOT as a checkout here, so its files cannot be listed"
fi
# The guard seen to fail (#3325), on a checkout holding the real readers, a cache key, prose naming the
# file, and then one second reader at a time: one not yet staged, and ones of file types a listing by
# type would skip (a script with no extension, as claude-sync itself is, and a JavaScript file).
OR="$TMPROOT/one-reader"
mkdir -p "$OR/tools" "$OR/.github/workflows"
for f in install-claude-code.sh report-mods-on-newest-claude-code.sh test-install-claude-code.sh; do cp "$DIR/$f" "$OR/tools/$f"; done
printf 'jobs:\n  a:\n    steps:\n      - with:\n          key: cc-${{ hashFiles('"'"'.github/claude-code-version'"'"') }}\n' > "$OR/.github/workflows/w.yml"
printf 'The version is in .github/claude-code-version.\n' > "$OR/README.md"
git -C "$OR" init -q && git -C "$OR" add -A && git -C "$OR" -c user.email=t@t -c user.name=t commit -q -m base
bad="$(other_readers "$OR")"
[ -z "$bad" ] && check "#3325 a checkout whose only reader is the installer passes, prose and a cache key included" ok \
  || check "#3325 a checkout whose only reader is the installer passes, prose and a cache key included" "named:$bad"
second_reader(){   # $1 = path in the fixture  $2 = staged or untracked -> did the guard name it
  printf 'v=$(cat .github/claude-code-version)\n' > "$OR/$1"
  [ "$2" = staged ] && git -C "$OR" add -- "$1"
  bad="$(other_readers "$OR")"
  case " $bad " in *" $1 "*) check "#3325 a second reader, $2, in $1, is named" ok ;;
    *) check "#3325 a second reader, $2, in $1, is named" "named:${bad:- nothing}" ;; esac
  git -C "$OR" rm -q --cached --ignore-unmatch -- "$1" > /dev/null; rm -f "$OR/$1"
}
second_reader tools/second-reader.py staged
second_reader tools/second-reader.sh untracked
second_reader tools/second-reader staged
second_reader tools/second-reader.js staged
# A folder that is no checkout at all lists nothing, which must never read as no second reader.
mkdir -p "$TMPROOT/not-a-checkout/tools"
cp "$DIR/install-claude-code.sh" "$DIR/report-mods-on-newest-claude-code.sh" "$TMPROOT/not-a-checkout/tools/"
case "$(other_readers "$TMPROOT/not-a-checkout")" in
  *"read nothing"*) check "#3325 a listing that read nothing is refused, not passed" ok ;;
  *) check "#3325 a listing that read nothing is refused, not passed" "it passed or named something else" ;;
esac
# The daily run: on a schedule and by hand only, the newest release, and only the job running no
# Claude Code may write.
on="$(printf '%s\n' "$dw" | awk '/^on:/ { on = 1; next } on && /^[A-Za-z]/ { on = 0 } on')"
# Its triggers are exactly these two, so any other (a push, a pull request, another workflow) fails.
triggers="$(sed -n 's/^  \([a-z_]*\):.*$/\1/p' <<< "$on" | LC_ALL=C sort | paste -sd' ' -)"
[ "$triggers" = "schedule workflow_dispatch" ] \
  && check "#3297 the daily run is on a schedule and never on a push or a pull request, so it cannot turn one red" ok \
  || check "#3297 the daily run is on a schedule and never on a push or a pull request, so it cannot turn one red" "on: $(printf '%s' "$on" | tr '\n' ' ')"
dtests="$(job_of "$DAILY_WF" tests)"; dreport="$(job_of "$DAILY_WF" report)"
grep -q 'bash tools/install-claude-code\.sh .* --newest)"$' <<< "$dtests" && grep -q 'bash tests/test-mods\.sh' <<< "$dtests" \
  && grep -q 'bash tests/test-mods-load-engine\.sh' <<< "$dtests" \
  && check "#3297 the daily run installs the newest release and runs both mods suites on it" ok \
  || check "#3297 the daily run installs the newest release and runs both mods suites on it" "not found in its tests job"
top_perm="$(printf '%s\n' "$dw" | awk '/^permissions:/ { on = 1; next } on && /^[A-Za-z]/ { on = 0 } on')"
! grep -qE ':[[:space:]]*write' <<< "$top_perm
$dtests" &&grep -qE '^      issues:[[:space:]]*write' <<< "$dreport" \
  && ! grep -qE 'install-claude-code|tests/test-' <<< "$dreport" \
  && check "#3297 only the report job may write, and it runs no Claude Code and no suite" ok \
  || check "#3297 only the report job may write, and it runs no Claude Code and no suite" "permissions or steps are not split that way"
grep -q 'needs: tests' <<< "$dreport" && grep -q 'if: always()' <<< "$dreport" \
  && grep -qF 'RESULT: ${{ needs.tests.result }}' <<< "$dreport" \
  && check "#3297 the report runs whatever the tests did, and is handed their result" ok \
  || check "#3297 the report runs whatever the tests did, and is handed their result" "needs, always() or RESULT missing"
missing=""
for j in tests report; do grep -qE '^    timeout-minutes: [0-9]+$' <<< "$(job_of "$DAILY_WF" "$j")" || missing="$missing $j"; done
[ -z "$missing" ] && check "#3297 every job of the daily run has a timeout" ok || check "#3297 every job of the daily run has a timeout" "none on:$missing"
grep -q '^  cancel-in-progress: false' <<< "$dw" \
  && check "#3297 two daily runs never overlap or cancel each other, so one failure is one issue" ok \
  || check "#3297 two daily runs never overlap or cancel each other, so one failure is one issue" "no uncancelled concurrency group"

for t in "$INSTALL" "$REPORT"; do
  [ -x "$t" ] && check "${t#"$ROOT"/} is executable" ok || check "${t#"$ROOT"/} is executable" "not executable"
done

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
