#!/usr/bin/env bash
# report-web-guidance-pin.sh: tell Dan when the pinned web guidance tool has fallen behind a release
# that has had two weeks to be caught by others, and say nothing while it has not (claude-config#3565).
#
# The tool is the npm package of Google Chrome's Modern Web Guidance. Sessions run the one version
# in payload/hooks/lib/<package>-version, read through payload/hooks/lib/web-guidance-pin.py, which
# also decides what "behind" means: a release newer than the pin, not a prerelease, published at
# least MIN_AGE_DAYS before now. A newer release younger than that is not reported yet, so a bad
# release has time to be found and pulled before anybody is asked to move to it.
#
# Run once a day by .github/workflows/web-guidance-pin.yml. Behind opens ONE issue naming both
# versions; while it is open, a later day comments on it instead of opening a second. It is found by
# a marker in its body, read from the list of open issues rather than from search, whose index lags.
# A current pin posts nothing.
#
# A registry that cannot be reached, or an answer that cannot be read, is never read as current: the
# run fails saying which, and a failed scheduled run is red in the Actions tab, where GitHub emails
# whoever last changed the workflow's schedule.
#
# Input, from the environment:
#   GH_REPO    owner/name to post in; gh reads it, with GH_TOKEN
#   RUN_URL    the workflow run, linked from what is posted
#   WGP_NOW    the time to judge age against, epoch seconds (the tests set it; default now)
#   WGP_REGISTRY_ANSWER   a file holding the registry's answer, read in place of asking npm (the
#              tests set it; default ask `npm view <package> time --json`)
# Exit 0 when nothing needed saying or it was posted; 1 when the pin, the registry or gh failed.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
LIB="$ROOT/payload/hooks/lib/web-guidance-pin.py"
NAME="modern-web-""guidance"
MIN_AGE_DAYS=14
MARKER="<!-- web-guidance-pin-behind -->"
say(){ echo "report-web-guidance-pin: $*" >&2; }

now="${WGP_NOW:-$(date +%s)}"
pin="$(python3 "$LIB" pin 2>&1)" || { say "the pin could not be read ($pin), so nothing was compared."; exit 1; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/web-guidance-pin.XXXXXX")" || { say "could not make a scratch folder."; exit 1; }
trap 'rm -rf "$scratch"' EXIT

answer="${WGP_REGISTRY_ANSWER:-}"
if [ -z "$answer" ]; then
  answer="$scratch/time.json"
  npm view "$NAME" time --json > "$answer" 2> "$scratch/npm.err" || {
    say "could not reach the npm registry, so whether the pin ($pin) is behind is unknown: $(tail -n 3 "$scratch/npm.err" | tr '\n' ' ')"
    exit 1
  }
fi

newer="$(python3 "$LIB" behind "$answer" "$now" "$MIN_AGE_DAYS" 2>&1)"; rc=$?
case "$rc" in
  10) say "the pin, $pin, is current: no newer release is $MIN_AGE_DAYS days old yet, so nothing was posted."; exit 0 ;;
  0) ;;
  *) say "the registry's answer could not be read ($newer), so whether the pin ($pin) is behind is unknown."; exit 1 ;;
esac
version="${newer%% *}"; published="${newer#* }"
today="$(date -u -r "$now" +%Y-%m-%d 2>/dev/null || date -u -d "@$now" +%Y-%m-%d)"

details="- Pinned: $pin, in \`payload/hooks/lib/$NAME-version\`
- Newest release at least $MIN_AGE_DAYS days old: $version, published $published
- Run: ${RUN_URL:-not given}"

body_file="$scratch/body.md"
open="$(gh issue list --state open --label security --limit 200 --json number,body \
  --jq "[.[] | select(.body | contains(\"$MARKER\"))][0].number // empty")" || {
  say "gh could not list the open issues, so whether one is already open is unknown and nothing was posted."
  exit 1
}

if [ -n "$open" ]; then
  printf 'Still behind on %s.\n\n%s\n' "$today" "$details" > "$body_file"
  gh issue comment "$open" --body-file "$body_file" >/dev/null || { say "gh could not comment on issue #$open."; exit 1; }
  say "the pin, $pin, is still behind $version; said on issue #$open."
  exit 0
fi

cat > "$body_file" <<EOF
$MARKER
Sessions run the web guidance tool at the pinned version $pin, and a release newer than it has now been out for at least $MIN_AGE_DAYS days (checked $today).

$details

## Moving the pin

1. Read what changed: \`npm diff --diff=$NAME@$pin --diff=$NAME@$version\`.
2. If nothing in it should not run on Dan's Mac, one pull request changes the version line in \`payload/hooks/lib/$NAME-version\` and the version in the rule file's command in \`payload/CLAUDE.md\` together. \`tests/test-web-guidance-pin.sh\` fails while the two differ.

While this issue is open, each later day it is still behind adds a comment here instead of a new issue. A current pin posts nothing.

## Open questions

- Does anything in the diff between $pin and $version need a closer look before it runs on Dan's Mac?
EOF
url="$(gh issue create --title "The web guidance tool's pin, $pin, is behind $version" \
  --label priority-p2 --label security --label tooling --milestone Ungrouped --body-file "$body_file")" || {
  say "gh could not open the issue."
  exit 1
}
say "the pin, $pin, is behind $version; opened $url"
