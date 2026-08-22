#!/usr/bin/env bash
# ensure-priority-labels.sh: make sure a repo has the five priority labels, so an
# issue can always be filed with one.
#
# Every issue carries a priority (see NAMING.md for the scale and for who picks the
# level). A repo that has never been labelled would make that rule impossible to
# follow, and `gh issue create --label priority-p2` fails outright when the label
# does not exist, so this runs first.
#
# Each label carries its meaning in its description, which puts the scale on GitHub
# itself rather than only in this config: Dan reads the backlog in the browser.
#
# Usage:
#   ensure-priority-labels.sh <owner/name>
#
# Env:
#   DRY_RUN=1   report what is missing, write nothing
#
# Output (first token is the verdict, so callers can branch on it):
#   PRIORITY-LABEL-EXISTS  <name>            already there, left untouched
#   PRIORITY-LABEL-CREATED <name>            created
#   WOULD-CREATE-LABEL     <name>            dry run
#   SEVERITY-LABELS-FOUND  <names>           rival scales that priority replaces
#   PRIORITY-LABELS-READY  <repo>            all five present (only ever printed then)
#
# Exit codes:
#   0  all five levels are present
#   2  usage error
#   6  the label list could not be read (fails loud, never creates blind)
#   7  a label could not be created

set -uo pipefail

repo="${1:-}"
if [[ -z "$repo" || "$repo" != */* || "$repo" == --* ]]; then
  echo "Usage: ensure-priority-labels.sh <owner/name>" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Cannot ensure the priority labels: gh is not on PATH." >&2
  exit 6
fi

# The scale, in one place. Colour runs hot to cold so the level reads at a glance
# in the issue list, which is where Dan actually triages.
LEVELS=(
  "priority-p0|b60205|Broken now, drop everything"
  "priority-p1|d93f0b|Important, do next"
  "priority-p2|fbca04|Normal, the default for real work"
  "priority-p3|0e8a16|Nice to have"
  "priority-p4|c5def5|Someday, maybe never"
)

# --- read the existing labels ---------------------------------------------
# Reading this list is what decides which labels are missing. If the read fails,
# creating anyway would fire five doomed calls and then report success, so this
# fails loud instead. stdout and stderr are kept apart so a gh warning cannot land
# in the middle of the JSON and read as an empty repo.
gh_err="$(mktemp)"
trap 'rm -f "$gh_err"' EXIT
raw="$(gh label list --repo "$repo" --limit 500 --json name 2>"$gh_err")"
if [[ $? -ne 0 ]]; then
  echo "Could not read the label list for $repo: $(tr '\n' ' ' <"$gh_err")" >&2
  exit 6
fi

existing="$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("PARSE-ERROR")
    sys.exit(0)
if not isinstance(data, list):
    print("PARSE-ERROR")
    sys.exit(0)
# Lowercased: GitHub treats label names case insensitively for uniqueness, so
# creating priority-p2 next to an existing PRIORITY-P2 fails.
for item in data:
    name = (item or {}).get("name") if isinstance(item, dict) else None
    if name:
        print(name.lower())
')"

if [[ "$existing" == "PARSE-ERROR" ]]; then
  echo "Could not read the label list for $repo (unexpected response)." >&2
  exit 6
fi

has_label() { # has_label <lowercased name>
  # `case` over the list rather than `printf ... | grep -qxF` (claude-config#162). `grep -q` leaves
  # on its first match, its producer is killed by SIGPIPE, and under `pipefail` the pipeline's
  # status becomes that death, so a label that IS present reads as missing and this tries to create
  # it again. Whether it bites depends on how long the label list is and where in it the match
  # falls, which is a size threshold nobody watches: a repo with many labels is the one that breaks
  # (L183). The newlines on both sides are what makes this a whole-line match, exactly as -x was,
  # and the name is quoted inside the pattern so a label carrying a glob character stays literal.
  case "
$existing
" in *"
$1
"*) return 0 ;; esac
  return 1
}

# --- create whatever is missing -------------------------------------------
failed=0
for spec in "${LEVELS[@]}"; do
  IFS='|' read -r name color desc <<<"$spec"

  if has_label "$name"; then
    echo "PRIORITY-LABEL-EXISTS $name"
    continue
  fi

  if [[ -n "${DRY_RUN:-}" ]]; then
    echo "WOULD-CREATE-LABEL $name"
    continue
  fi

  if gh label create "$name" --repo "$repo" --color "$color" --description "$desc" >/dev/null 2>"$gh_err"; then
    echo "PRIORITY-LABEL-CREATED $name"
    continue
  fi

  # A 422 here means the label already exists: another run of this script, or a
  # person in the GitHub UI, got there between the list read and this create. That
  # is the idempotent outcome, not a failure, so it must not fail the run.
  if grep -qiE 'already exists|422' "$gh_err"; then
    echo "PRIORITY-LABEL-EXISTS $name"
    continue
  fi

  echo "LABEL-FAILED $name: $(tr '\n' ' ' <"$gh_err")" >&2
  failed=$((failed + 1))
done

# --- report the rival scales, never delete them ---------------------------
# Priority is the only urgency scale now, but deleting a label strips it from every
# issue carrying it. That is Dan's decision, so this only ever names them.
rivals="$(printf '%s\n' "$existing" | grep -E '^(sev-|severity:)' | tr '\n' ' ' | sed 's/ *$//')"
if [[ -n "$rivals" ]]; then
  echo "SEVERITY-LABELS-FOUND $rivals"
  echo "These are the old urgency scales that priority replaces. Nothing was deleted: removing a label strips it from every issue that carries it, so ask Dan before cleaning them up. Stop applying them to new issues."
fi

if [[ "$failed" -gt 0 ]]; then
  echo "$failed of ${#LEVELS[@]} priority labels could not be created in $repo. Re-running is safe: the ones that exist are left alone." >&2
  exit 7
fi

if [[ -n "${DRY_RUN:-}" ]]; then
  exit 0
fi

echo "PRIORITY-LABELS-READY $repo"
exit 0
