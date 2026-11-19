#!/usr/bin/env bash
# report-mods-on-newest-claude-code.sh <logs folder>: tell Dan when the daily run of the mods' tests on
# the newest Claude Code failed, and say nothing when it passed (claude-config#3297).
#
# Run by the report job of .github/workflows/mods-on-newest-claude-code.yml, after the job that
# installs the newest release and runs tests/test-mods.sh and tests/test-mods-load-engine.sh. That job
# leaves in the logs folder: version (the release it installed), test-mods.log and load-engine.log.
# Any of them can be missing, when the install itself failed, and that is reported too.
#
# A failure opens ONE issue, labelled priority-p1, bug and mods, in the Ungrouped milestone, naming the
# version and the failing mods. While that issue is open, a later failing day comments on it instead
# of opening a second. It is found by a marker in its body, read from the list of open issues rather
# than from search, whose index lags. A passing day posts nothing, even with the issue open: whether
# it can be closed is Dan's call.
#
# Input, from the environment:
#   RESULT   the tests job's result (success, failure, cancelled, skipped)
#   RUN_URL  the workflow run, linked from what is posted
#   GH_REPO  owner/name to post in; gh reads it, with GH_TOKEN
# Exit 0 when nothing needed saying or it was posted; 1 when posting failed, which turns the run red,
# and GitHub then emails whoever last changed the workflow's schedule.
set -uo pipefail

LOGS="${1:-}"
MARKER="<!-- mods-on-newest-claude-code -->"
say(){ echo "report-mods-on-newest-claude-code: $*" >&2; }

if [ -z "$LOGS" ] || [ -z "${RESULT:-}" ] || [ -z "${GH_REPO:-}" ]; then
  say "usage: RESULT=<result> GH_REPO=<owner/name> RUN_URL=<url> report-mods-on-newest-claude-code.sh <logs folder>"
  exit 2
fi
if [ "$RESULT" = success ]; then
  say "the mods passed on the newest Claude Code ($(cat "$LOGS/version" 2>/dev/null || echo 'version not recorded')), so nothing was posted."
  exit 0
fi

version="$(tr -d '[:space:]' < "$LOGS/version" 2>/dev/null)"
[ -n "$version" ] || version="unknown, because the install did not finish"
today="$(date -u +%Y-%m-%d)"

# The mods named failing by check-mods, inside test-mods.sh's real tree case, and the load test's
# mods never seen loading. Sorted and said once each.
mods="$( { sed -nE 's/^(FAIL: .* out=)?check-mods: ([A-Za-z0-9._-]+) (refused by claude plugin validate|failed claude plugin test|draws side panes).*/\2/p' "$LOGS/test-mods.log" 2>/dev/null
  sed -nE 's/.*never seen loading:(.*)\).*/\1/p' "$LOGS/load-engine.log" 2>/dev/null | tr ' ' '\n'; } | grep . | LC_ALL=C sort -u | paste -sd, - | sed 's/,/, /g')"
[ -n "$mods" ] || mods="none named by a check; the lines below say what failed"

# What failed, in the suites' own words: each FAIL line's first line, each mod check-mods refused or
# failed with its reason, and each UNMEASURED part, cut to a length a reader can scan. Capped, saying
# so, because a flood would hide the first cause.
lines="$( { for f in test-mods load-engine; do
    [ -f "$LOGS/$f.log" ] || { echo "$f.log: not written, so that suite did not run"; continue; }
    grep -E '^(FAIL: |SUITE-PART-UNMEASURED |SUITE-RESULT |check-mods: [^ ]+ (refused by|failed claude plugin test|draws side panes)|check-mods: FAILED)' "$LOGS/$f.log" | sed "s|^|$f: |"
  done; } | cut -c1-500)"
n="$(printf '%s\n' "$lines" | grep -c .)"
if [ "$n" -gt 40 ]; then
  lines="$(printf '%s\n' "$lines" | awk 'NR <= 40')
...and $((n - 40)) more lines, in the run's own log"
fi

details="- Claude Code: $version
- Mods failing: $mods
- Run: ${RUN_URL:-not given}

\`\`\`
$lines
\`\`\`"

body_file="$(mktemp "${TMPDIR:-/tmp}/mods-newest-report.XXXXXX")" || { say "could not make a scratch file."; exit 1; }
trap 'rm -f "$body_file"' EXIT

open="$(gh issue list --state open --label mods --limit 200 --json number,body \
  --jq "[.[] | select(.body | contains(\"$MARKER\"))][0].number // empty")" || {
  say "gh could not list the open issues, so whether one is already open is unknown and nothing was posted."
  exit 1
}

if [ -n "$open" ]; then
  printf 'Still failing on %s.\n\n%s\n' "$today" "$details" > "$body_file"
  gh issue comment "$open" --body-file "$body_file" >/dev/null || { say "gh could not comment on issue #$open."; exit 1; }
  say "the mods failed on Claude Code $version again; said on issue #$open."
  exit 0
fi

cat > "$body_file" <<EOF
$MARKER
The daily run of the mods' own tests on the newest Claude Code failed on $today. Pull requests are not affected: their checks test the mods on the version written in \`.github/claude-code-version\`, and raising that file to this version is the pull request that would turn red the same way.

$details

While this issue is open, each later failing day adds a comment here instead of a new issue. A passing day posts nothing.

## Open questions

- Is this a change in Claude Code that the mods must follow, or a fault in Claude Code to report?
- Which mod changes make the tests pass on this version without breaking them on the one in \`.github/claude-code-version\`?
EOF
url="$(gh issue create --title "Mods fail their tests on the newest Claude Code, $version" \
  --label priority-p1 --label bug --label mods --milestone Ungrouped --body-file "$body_file")" || {
  say "gh could not open the issue."
  exit 1
}
say "the mods failed on Claude Code $version; opened $url"
