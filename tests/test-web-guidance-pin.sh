#!/usr/bin/env bash
# The web guidance tool runs one pinned version, and a newer one reaches Dan as one issue
# (claude-config#3565).
#
# The tool is the npm package of Google Chrome's Modern Web Guidance, which the rule file tells
# every session to run with npx before designing for the web. Its version has one home,
# payload/hooks/lib/<package>-version, read through payload/hooks/lib/web-guidance-pin.py. This
# suite holds:
#
#   1. The scan: no file in the repository names the package with @latest, with no version on a
#      command that runs it, or with any version but the pin. Seen to fail on each of those first,
#      and to pass the prose that only names the plugin, the source repository or the pin file.
#   2. The repository itself, by that scan, with ONE held line: the rule file's sentence telling
#      sessions to run @latest is lasting memory, changed only by Dan. While that line is exactly
#      the text it was on 2026-11-25, this says so as SUITE-PART-UNMEASURED and judges the rest;
#      any other wording of it is judged like every other line, and once it is gone the rule file
#      must name the pinned command.
#   3. tools/report-web-guidance-pin.sh, the daily freshness report, against a fixed clock, a
#      registry answer from a file and a fake gh: silent on a current pin, one issue when a newer
#      release is two weeks old, a comment when that issue is open, and a failure, never silence,
#      when the registry cannot be read.
#   4. .github/workflows/web-guidance-pin.yml runs it on a schedule only, bounded.
#
# The package is named in two halves here, so this file is not itself a finding.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
NAME="modern-web-""guidance"
LIB="$ROOT/payload/hooks/lib/web-guidance-pin.py"
PINFILE="$ROOT/payload/hooks/lib/$NAME-version"
REPORT="$ROOT/tools/report-web-guidance-pin.sh"
WF="$ROOT/.github/workflows/web-guidance-pin.yml"
# The rule file line held for Dan: sha256 of payload/CLAUDE.md line 79 on main on 2026-11-25.
HELD_SHA="5c42bd87191925503b1f22f07a4084f42dd27b19cb6672a1eb69957742b7b511"

pass=0; fail=0
check(){ if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-web-guidance-pin.XXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "FAIL: refusing to run: the throwaway directory came back as '$TMPROOT'."; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

for f in "$LIB" "$PINFILE" "$REPORT" "$WF"; do
  [ -f "$f" ] && check "${f#"$ROOT"/} exists" ok || check "${f#"$ROOT"/} exists" "missing"
done
if [ ! -f "$LIB" ] || [ ! -f "$PINFILE" ]; then
  printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"; exit 1
fi

# ---------------------------------------------------------------------------
# The pin.
# ---------------------------------------------------------------------------
PIN="$(python3 "$LIB" pin 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [[ "$PIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && check "the pin reads as one version" ok \
  || check "the pin reads as one version" "exit $rc: $PIN"

python3 -B "$ROOT/payload/hooks/lib/install-hook-libs.py" "$ROOT/payload/hooks/lib" "$TMPROOT/badlib" web-guidance-pin.py \
  || check "lib/install-hook-libs.py installs web-guidance-pin.py" "it could not"
printf '# a comment\n%s\n' "latest" > "$TMPROOT/badlib/$NAME-version"
out="$(python3 "$TMPROOT/badlib/web-guidance-pin.py" pin 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"exactly one version line"* ]] && check "a pin of latest is refused" ok \
  || check "a pin of latest is refused" "exit $rc: $out"
rm -f "$TMPROOT/badlib/$NAME-version"
out="$(python3 "$TMPROOT/badlib/web-guidance-pin.py" pin 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"could not be read"* ]] && check "a missing pin file is refused" ok \
  || check "a missing pin file is refused" "exit $rc: $out"

# ---------------------------------------------------------------------------
# 1. The scan, on fixture trees.
# ---------------------------------------------------------------------------
fixture(){   # $1 = name, then lines for a file a.md in a fresh repository
  local d="$TMPROOT/tree-$1"; shift
  mkdir -p "$d"; git -C "$d" init -q
  printf '%s\n' "$@" > "$d/a.md"
  printf '%s\n' "$d"
}
d="$(fixture latest "Run DISABLE_TELEMETRY=1 npx -y $NAME@""latest search \"x\"")"
out="$(python3 "$LIB" scan "$d")"; rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == "a.md:1: names @latest"* ]] && check "scan: @latest is a finding" ok \
  || check "scan: @latest is a finding" "exit $rc: $out"

d="$(fixture other "npx -y $NAME@0.0.9 retrieve \"id\"")"
out="$(python3 "$LIB" scan "$d")"; rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"names version '0.0.9', and the pin is $PIN"* ]] && check "scan: another version is a finding" ok \
  || check "scan: another version is a finding" "exit $rc: $out"

d="$(fixture bare "first line" "then \`npx -y $NAME search \"x\"\`")"
out="$(python3 "$LIB" scan "$d")"; rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == "a.md:2: runs it with no version"* ]] && check "scan: a run with no version is a finding" ok \
  || check "scan: a run with no version is a finding" "exit $rc: $out"

d="$(fixture flags "npm --yes exec $NAME -- search x" "npm -g install $NAME" "pnpm add -g $NAME")"
out="$(python3 "$LIB" scan "$d")"; rc=$?
[ "$rc" -eq 1 ] && [ "$(grep -c 'runs it with no version' <<< "$out")" -eq 3 ] && check "scan: a run with flags before the subcommand, by any runner, is a finding" ok \
  || check "scan: a run with flags before the subcommand, by any runner, is a finding" "exit $rc: $out"

d="$(fixture prose"Run DISABLE_TELEMETRY=1 npx -y $NAME@$PIN search \"x\"" \
  "published as the \`$NAME\` plugin, source \`GoogleChrome/$NAME-src\`" \
  "the skill $NAME:$NAME in ~/.claude/plugins/cache/googlechrome/$NAME/1.0.2/skills" \
  "the pin lives in payload/hooks/lib/$NAME-version")"
out="$(python3 "$LIB" scan "$d")"; rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && check "scan: the pin and plain mentions pass" ok \
  || check "scan: the pin and plain mentions pass" "exit $rc: $out"

# An untracked file counts (a new file before it is added); an ignored one does not.
d="$(fixture untracked "nothing here")"
printf 'npx %s@%s\n' "$NAME" "latest" > "$d/new.txt"
printf 'ignored.txt\n' > "$d/.gitignore"; printf 'npx %s@%s\n' "$NAME" "latest" > "$d/ignored.txt"
out="$(python3 "$LIB" scan "$d")"; rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == "new.txt:1:"* ]] && [[ "$out" != *ignored.txt* ]] && check "scan: an untracked file is read, an ignored one is not" ok \
  || check "scan: an untracked file is read, an ignored one is not" "exit $rc: $out"

out="$(python3 "$LIB" scan "$TMPROOT/not-a-repository" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && check "scan: a folder git cannot list is an error, never a clean scan" ok \
  || check "scan: a folder git cannot list is an error, never a clean scan" "exit $rc: $out"

# ---------------------------------------------------------------------------
# 2. The repository, with the one held rule file line.
# ---------------------------------------------------------------------------
found="$(python3 "$LIB" scan "$ROOT")"; rc=$?
[ "$rc" -le 1 ] && check "scan: the repository was listed and read" ok || check "scan: the repository was listed and read" "exit $rc"
held=0; rest=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in
    payload/CLAUDE.md:*)
      n="${line#payload/CLAUDE.md:}"; n="${n%%:*}"
      sha="$(sed -n "${n}p" "$ROOT/payload/CLAUDE.md" | shasum -a 256 | awk '{print $1}')"
      if [ "$sha" = "$HELD_SHA" ]; then held=1; continue; fi ;;
  esac
  rest="$rest$line; "
done <<< "$found"
[ -z "$rest" ] && check "scan: nothing in the repository runs the tool unpinned" ok \
  || check "scan: nothing in the repository runs the tool unpinned" "$rest"
if [ "$held" -eq 1 ]; then
  echo "SUITE-PART-UNMEASURED the rule file's web guidance line: payload/CLAUDE.md still tells sessions to run the tool at @latest, in the exact words it had on 2026-11-25, and that line is lasting memory that only Dan changes (claude-config#3565), so whether the rule file names the pinned command is not judged until he replaces it"
else
  grep -q -F "npx -y $NAME@$PIN search" "$ROOT/payload/CLAUDE.md" \
    && check "the rule file names the pinned search command" ok \
    || check "the rule file names the pinned search command" "payload/CLAUDE.md has no 'npx -y $NAME@$PIN search'"
fi

# ---------------------------------------------------------------------------
# The registry answer.
# ---------------------------------------------------------------------------
NOW=1795000000   # 2026-11-18 11:06:40 UTC
DAY=86400
iso(){ python3 -c 'import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"; }
answer(){   # $1 = file, then version=age-in-days pairs
  local f="$1"; shift
  { printf '{"created": "%s", "modified": "%s"' "$(iso $((NOW - 400 * DAY)))" "$(iso $((NOW - DAY)))"
    for p in "$@"; do printf ', "%s": "%s"' "${p%%=*}" "$(iso $((NOW - ${p#*=} * DAY)))"; done
    printf '}\n'; } > "$f"
}
A="$TMPROOT/answers"; mkdir -p "$A"
answer "$A/current.json" "0.0.1=200" "$PIN=40" "99.0.0=13" "99.0.1-beta.1=30"
out="$(python3 "$LIB" behind "$A/current.json" "$NOW" 14 2>&1)"; rc=$?
[ "$rc" -eq 10 ] && [ -z "$out" ] && check "behind: a newer release under two weeks old, and a prerelease, are not yet behind" ok \
  || check "behind: a newer release under two weeks old, and a prerelease, are not yet behind" "exit $rc: $out"
answer "$A/behind.json" "$PIN=40" "98.0.0=20" "98.1.0=15" "99.0.0=2"
out="$(python3 "$LIB" behind "$A/behind.json" "$NOW" 14 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [[ "$out" == "98.1.0 "* ]] && check "behind: the newest release two weeks old is named" ok \
  || check "behind: the newest release two weeks old is named" "exit $rc: $out"
answer "$A/nopin.json" "98.1.0=15"
out="$(python3 "$LIB" behind "$A/nopin.json" "$NOW" 14 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"does not list the pinned version"* ]] && check "behind: an answer without the pin is unread, never current" ok \
  || check "behind: an answer without the pin is unread, never current" "exit $rc: $out"
printf 'npm ERR! code E404\n' > "$A/notjson.json"
out="$(python3 "$LIB" behind "$A/notjson.json" "$NOW" 14 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && [[ "$out" == *"could not be read as JSON"* ]] && check "behind: an answer that is not JSON is unread, never current" ok \
  || check "behind: an answer that is not JSON is unread, never current" "exit $rc: $out"

# ---------------------------------------------------------------------------
# 3. The report, with a fake npm and gh.
# ---------------------------------------------------------------------------
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
GH_LOG="$TMPROOT/gh.log"; NPM_LOG="$TMPROOT/npm.log"
cat > "$BIN/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue list") [ -n "${FAKE_GH_LIST_FAILS:-}" ] && exit 1; printf '%s\n' "${FAKE_OPEN_ISSUE:-}" ;;
  "issue create") while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$GH_LOG.body"; shift; done
                  echo "https://github.com/o/r/issues/7" ;;
  "issue comment") while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$GH_LOG.body"; shift; done ;;
esac
STUB
cat > "$BIN/npm" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_LOG"
[ -n "${FAKE_NPM_FAILS:-}" ] && { echo "npm error code ENOTFOUND" >&2; exit 1; }
cat "$FAKE_NPM_ANSWER"
STUB
chmod +x "$BIN/gh" "$BIN/npm"
run_report(){   # env assignments are passed in front by the caller
  rm -f "$GH_LOG" "$GH_LOG.body" "$NPM_LOG"
  env PATH="$BIN:$PATH" GH_LOG="$GH_LOG" NPM_LOG="$NPM_LOG" GH_REPO=o/r RUN_URL=https://example.invalid/run \
    WGP_NOW="$NOW" "$@" bash "$REPORT" 2>&1
}
if [ -f "$REPORT" ]; then
  out="$(run_report FAKE_NPM_ANSWER="$A/current.json")"; rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$GH_LOG" ] && [[ "$out" == *"nothing was posted"* ]] && check "report: a current pin posts nothing" ok \
    || check "report: a current pin posts nothing" "exit $rc, gh: $(cat "$GH_LOG" 2>/dev/null), out: $out"
  grep -q -x "view $NAME time --json" "$NPM_LOG" 2>/dev/null && check "report: the registry is asked for every release's publish time" ok \
    || check "report: the registry is asked for every release's publish time" "npm was asked: $(cat "$NPM_LOG" 2>/dev/null)"

  out="$(run_report FAKE_NPM_ANSWER="$A/behind.json")"; rc=$?
  body="$(cat "$GH_LOG.body" 2>/dev/null)"
  if [ "$rc" -eq 0 ] && grep -q '^issue create' "$GH_LOG" && grep -q "98.1.0" "$GH_LOG" && grep -q -- "$PIN" "$GH_LOG" \
     && [[ "$body" == *"<!-- web-guidance-pin-behind -->"* ]] && [[ "$body" == *"## Open questions"* ]] && [[ "$body" == *"npm diff"* ]]; then
    check "report: a pin behind a two week old release opens one issue naming both versions" ok
  else
    check "report: a pin behind a two week old release opens one issue naming both versions" "exit $rc, gh: $(cat "$GH_LOG" 2>/dev/null), out: $out"
  fi
  grep -q -- '--milestone' "$GH_LOG" && grep -q -- '--label priority-' "$GH_LOG" \
    && check "report: the issue carries a priority and a milestone" ok \
    || check "report: the issue carries a priority and a milestone" "$(grep create "$GH_LOG")"

  out="$(run_report FAKE_NPM_ANSWER="$A/behind.json" FAKE_OPEN_ISSUE=41)"; rc=$?
  [ "$rc" -eq 0 ] && grep -q '^issue comment 41' "$GH_LOG" && ! grep -q '^issue create' "$GH_LOG" \
    && check "report: with that issue open, a later day comments on it instead" ok \
    || check "report: with that issue open, a later day comments on it instead" "exit $rc, gh: $(cat "$GH_LOG" 2>/dev/null)"

  out="$(run_report FAKE_NPM_FAILS=1 FAKE_NPM_ANSWER=/dev/null)"; rc=$?
  [ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ] && [[ "$out" == *"could not reach the npm registry"* ]] && [[ "$out" == *ENOTFOUND* ]] \
    && check "report: an unreachable registry fails the run saying so, never reads as current" ok \
    || check "report: an unreachable registry fails the run saying so, never reads as current" "exit $rc: $out"

  out="$(run_report FAKE_NPM_ANSWER="$A/nopin.json")"; rc=$?
  [ "$rc" -eq 1 ] && [ ! -s "$GH_LOG" ] && [[ "$out" == *"unknown"* ]] \
    && check "report: an answer it cannot read fails the run" ok \
    || check "report: an answer it cannot read fails the run" "exit $rc: $out"

  out="$(run_report FAKE_NPM_ANSWER="$A/behind.json" FAKE_GH_LIST_FAILS=1)"; rc=$?
  [ "$rc" -eq 1 ] && ! grep -q '^issue create' "$GH_LOG" \
    && check "report: when the open issues cannot be listed nothing is posted and the run fails" ok \
    || check "report: when the open issues cannot be listed nothing is posted and the run fails" "exit $rc: $out"
fi

# ---------------------------------------------------------------------------
# 4. The workflow: a schedule and a run by hand, never a push or a pull request, bounded.
# ---------------------------------------------------------------------------
if [ -f "$WF" ]; then
  code="$(sed 's/[[:space:]]#.*$//; /^[[:space:]]*#/d' "$WF")"
  triggers="$(awk '/^on:/ { on = 1; next } on && /^[^[:space:]]/ { exit } on && /^  [a-z_]+:/ { sub(/:.*/, ""); sub(/^ +/, ""); print }' <<< "$code" | paste -sd, -)"
  [ "$triggers" = "schedule,workflow_dispatch" ] && check "workflow: runs on a schedule and by hand only" ok \
    || check "workflow: runs on a schedule and by hand only" "its triggers are '$triggers'"
  grep -q 'timeout-minutes:' <<< "$code" && check "workflow: its job is bounded" ok || check "workflow: its job is bounded" "no timeout-minutes"
  grep -q 'bash tools/report-web-guidance-pin.sh' <<< "$code" && check "workflow: it runs the report" ok \
    || check "workflow: it runs the report" "tools/report-web-guidance-pin.sh is not run"
  grep -q 'issues: write' <<< "$code" && check "workflow: it may write issues" ok || check "workflow: it may write issues" "no issues: write"
fi

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
