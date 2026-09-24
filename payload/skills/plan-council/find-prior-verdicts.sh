#!/usr/bin/env bash
#
# find-prior-verdicts.sh: before a planning skill asks its first grilling question, find any
# earlier verdict on the approach being planned (claude-config#559).
#
# On 2026-09-24 a /plan-lite run grilled Dan and drafted a plan that DESIGN.md and #541 already
# recorded as planned and REJECTED the day before. Only the red team found it, after a full
# grilling round, and Dan's answers had been given on a false premise (L61). Both planning
# skills run this first and quote what it prints, with its date, before grilling.
#
# Searches, case insensitively and for each term separately:
#   - the repository's decision records: every TRACKED markdown file named DESIGN, README,
#     CLAUDE, AGENTS, DECISIONS or ADR*, or sitting under a docs, doc or adr directory. Source
#     code is not searched: a term matching a variable name is not a verdict.
#   - every issue in the GitHub repository, open AND closed, through `gh issue list --search`.
#
# Each document hit prints its file, line, the date that line was committed (from git blame)
# and the line itself. Each issue prints its number, state, date and title.
#
# Usage: find-prior-verdicts.sh [--dir <repo dir>] [--repo <owner/name>] <term> [<term> ...]
#   --dir defaults to the current directory; --repo defaults to what `gh repo view` names there.
#
# Exit: 0 the search ran (it prints NONE FOUND when nothing matched),
#       2 some part could not be searched (it prints COULD NOT SEARCH and what it could),
#       64 usage error.
# An unsearched source is never reported as an empty one (L98): a failed issue search says so
# and exits 2, so NONE FOUND always means everything named was really searched.

set -uo pipefail

MAX_DOC_HITS=20
MAX_ISSUES=15

dir="."
repo=""
terms=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0"; exit 0 ;;
    *) terms+=("$1"); shift ;;
  esac
done

if [ "${#terms[@]}" -eq 0 ]; then
  echo "find-prior-verdicts: no search terms given. Pass the approach's distinctive words, for example: find-prior-verdicts.sh \"path scoped\" \"rules paths\"" >&2
  exit 64
fi

could_not=0
if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "COULD NOT SEARCH decision records: $dir is not inside a git repository, so there is no tracked decision record to read."
  exit 2
fi
top="$(git -C "$dir" rev-parse --show-toplevel)"

# The decision records: tracked markdown, chosen by name or by directory.
records=()
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  upper="$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')"
  case "$upper" in
    DESIGN*.MD|README*.MD|CLAUDE.MD|AGENTS.MD|DECISIONS*.MD|ADR*.MD) records+=("$f"); continue ;;
  esac
  case "/$f" in
    */docs/*.md|*/doc/*.md|*/adr/*.md|*/docs/*.MD|*/doc/*.MD|*/adr/*.MD) records+=("$f") ;;
  esac
done < <(git -C "$top" ls-files -z -- '*.md' '*.MD')

line_date() { # line_date <file> <line>: the date the line was committed, or "uncommitted"
  local sha
  sha="$(git -C "$top" blame -L "$2,$2" --porcelain -- "$1" 2>/dev/null | head -1 | cut -d' ' -f1)"
  case "$sha" in
    ''|0000000*) echo "uncommitted" ;;
    *) git -C "$top" show -s --format=%as "$sha" 2>/dev/null || echo "undated" ;;
  esac
}

if [ -z "$repo" ]; then
  repo="$(cd "$top" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || repo=""
fi

found=0
for term in "${terms[@]}"; do
  echo "== \"$term\""
  hits=0
  if [ "${#records[@]}" -gt 0 ]; then
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      hits=$((hits + 1))
      if [ "$hits" -le "$MAX_DOC_HITS" ]; then
        file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
        printf '  %s:%s (%s) %s\n' "$file" "$line" "$(line_date "$file" "$line")" "$(printf '%s' "$text" | cut -c1-240)"
      fi
    done < <(cd "$top" && grep -n -i -F -H -- "$term" "${records[@]}" 2>/dev/null)
  fi
  [ "$hits" -gt "$MAX_DOC_HITS" ] && echo "  ... and $((hits - MAX_DOC_HITS)) more document lines"
  found=$((found + hits))

  if [ -z "$repo" ]; then
    echo "  COULD NOT SEARCH issues: no GitHub repository could be named for $top (pass --repo owner/name)."
    could_not=1
    continue
  fi
  if issues="$(gh issue list --repo "$repo" --state all --search "$term" --limit "$MAX_ISSUES" \
      --json number,state,closedAt,updatedAt,title \
      --jq '.[] | "\(.number)\t\(.state)\t\((.closedAt // .updatedAt)[0:10])\t\(.title)"' 2>&1)"; then
    while IFS=$'\t' read -r num state date title; do
      [ -n "$num" ] || continue
      printf '  #%s %s %s %s\n' "$num" "$state" "$date" "$title"
      found=$((found + 1))
    done <<<"$issues"
  else
    echo "  COULD NOT SEARCH issues in $repo: $(printf '%s' "$issues" | head -1)"
    could_not=1
  fi
done

echo
if [ "$could_not" -eq 1 ]; then
  echo "COULD NOT SEARCH everything: the lines above say which source failed. Say so to Dan; an unsearched source is not an empty one."
  exit 2
fi
if [ "$found" -eq 0 ]; then
  echo "NONE FOUND: no earlier verdict matched in ${#records[@]} decision records (${records[*]:-none tracked}) or in the issues of $repo."
fi
exit 0
