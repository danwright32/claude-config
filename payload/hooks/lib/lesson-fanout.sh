#!/usr/bin/env bash
#
# lesson-fanout.sh
# For each lesson named, file one "sweep this project for that defect" issue in every repo the
# repo-digest reports cover, except the repo the lesson was learned in. A lesson recorded from one
# project is evidence the same defect may be sitting in the others (L195), and nothing else ever
# goes and looks.
#
#   lesson-fanout.sh L739 [L740 ...]
#
# Run by hand or when lesson-fanout-notice.sh asks for it. Safe to run any number of times, from
# either Mac: before filing, each repo's existing lesson-sweep issues are read, and a lesson counts
# as already filed there when an issue's title names its NUMBER or its body carries its stable ID.
# The number survives a reworded rule and the id survives a renumber, so neither files a twin.
#
# THE REPO LIST is read live from dwright-pennie/repo-digest (repos.json and repos-weekly.json),
# never copied here, so a repo added to the digest with its button is covered from the next run
# (L41). Either list unreadable refuses the whole run: a partial list would quietly skip repos.
#
# THE ACCOUNT is chosen per repo: the first signed in gh account, active one first, that can push
# to it, passed as GH_TOKEN for that repo's calls only. The active account is never switched,
# because other sessions on this Mac depend on it.
#
# WHAT THE ISSUE CARRIES is the rule sentence and the lesson's id, never the evidence paragraph or
# the repo it came from: four of the digest repos are public, and evidence names private systems.
#
# THE LEDGER ($CLAUDE_HOME/state/lesson-fanout.done, one "Lnnn id" line per lesson) is written only
# once every target repo has the issue, so a lesson that failed anywhere is offered again by the
# notice hook and a rerun fills only the gaps (L368).
#
# Exit codes: 0 every repo covered; 1 something was not covered (each named with its reason);
# 2 usage.
#
# Seams (tests set all of them):
#   LESSON_FANOUT_SYNC_TOOL    claude-sync, for `lesson Lnnn` (default ~/claude-config-sync/claude-sync)
#   LESSON_FANOUT_HELPERS_DIR  where ensure-priority-labels.sh and ensure-milestone.sh live
#   CLAUDE_HOME                where the ledger lives
#   gh on PATH

set -uo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SYNC_TOOL="${LESSON_FANOUT_SYNC_TOOL:-$HOME/claude-config-sync/claude-sync}"
HELPERS="${LESSON_FANOUT_HELPERS_DIR:-$CLAUDE_HOME/skills/milestone}"
LEDGER="$CLAUDE_HOME/state/lesson-fanout.done"
DIGEST_REPO="dwright-pennie/repo-digest"
DIGEST_LISTS="repos.json repos-weekly.json"
LABEL="lesson-sweep"
PRIORITY="priority-p3"
MILESTONE="Ungrouped"

usage(){ echo "Usage: lesson-fanout.sh L739 [L740 ...]" >&2; exit 2; }
[ "$#" -gt 0 ] || usage
for a in "$@"; do [[ "$a" =~ ^L[0-9]+$ ]] || usage; done

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "REFUSED: $tool is not installed, so nothing was filed." >&2; exit 1; }
done

# ---- accounts ----
accounts="$(gh auth status --json hosts 2>/dev/null \
  | jq -r '.hosts["github.com"] // [] | sort_by(if .active then 0 else 1 end) | .[] | select(.state == "success") | .login' 2>/dev/null)"
if [ -z "$accounts" ]; then
  echo "REFUSED: no GitHub account is signed in to gh on this Mac, so nothing was filed." >&2
  exit 1
fi
tokens=""
for login in $accounts; do
  tok="$(gh auth token --hostname github.com -u "$login" 2>/dev/null)" || continue
  [ -n "$tok" ] && tokens="$tokens$login $tok"$'\n'
done

# ---- repo list ----
repos=""
for list in $DIGEST_LISTS; do
  # An unreadable list refuses the run now, because a run over half the repos reads like a run over
  # all of them. A readable but empty one is allowed here and judged with the other list below.
  got="" found=0
  while IFS=' ' read -r login tok; do
    [ -n "$tok" ] || continue
    raw="$(GH_TOKEN="$tok" gh api -H "Accept: application/vnd.github.raw" "repos/$DIGEST_REPO/contents/$list" 2>/dev/null)" || continue
    printf '%s' "$raw" | jq -e '.repos | type == "array"' >/dev/null 2>&1 || continue
    got="$(printf '%s' "$raw" | jq -r '.repos[] | "\(.owner)/\(.name)"')" found=1
    break
  done <<<"$tokens"
  if [ "$found" -eq 0 ]; then
    echo "REFUSED: could not read $list from $DIGEST_REPO with any signed in account, so nothing was filed." >&2
    exit 1
  fi
  repos="$repos$got"$'\n'
done
repos="$(printf '%s' "$repos" | sed '/^$/d' | sort -uf)"
if [ -z "$repos" ]; then
  echo "REFUSED: $DIGEST_REPO lists no repos in $DIGEST_LISTS, so there is nowhere to file." >&2
  exit 1
fi

# ---- per repo account, resolved once for every lesson in the run ----
token_for(){   # $1 = owner/name -> the token of the first account that can push, or nothing
  local login tok
  while IFS=' ' read -r login tok; do
    [ -n "$tok" ] || continue
    if [ "$(GH_TOKEN="$tok" gh api "repos/$1" 2>/dev/null | jq -r '.permissions.push // false' 2>/dev/null)" = "true" ]; then
      printf '%s' "$tok"; return 0
    fi
  done <<<"$tokens"
  return 1
}
repo_tokens=""
for r in $repos; do
  t="$(token_for "$r")" || t="-"
  repo_tokens="$repo_tokens$r $t"$'\n'
done

# ---- one lesson ----
overall=0
fan_out(){   # $1 = Lnnn
  local num="$1" entry id rule short title body_file source_names r tok existing hit url err ok=0
  if ! entry="$("$SYNC_TOOL" lesson "$num" 2>&1)"; then
    echo "REFUSED $num: could not read it: $entry"
    return 1
  fi
  id="$(printf '%s\n' "$entry" | sed -n '1s/^id: \([0-9a-f]*\).*/\1/p')"
  rule="$(printf '%s\n' "$entry" | sed '1d' | tr -s '[:space:]' ' ' \
    | sed -n "s/^ *- \*\*$num\. \([^*]*\)\*\*.*/\1/p" | sed 's/ *$//')"
  if [ -z "$id" ] || [ -z "$rule" ]; then
    echo "REFUSED $num: could not find its id and rule sentence in what claude-sync printed."
    return 1
  fi
  short="$(printf '%s\n' "$entry" | sed -n 's/^[[:space:]]*SHORT:[[:space:]]*//p' | head -1)"
  title="Lesson $num sweep: ${short:-$rule}"
  # Any digest repo the entry cites as name#N is where the lesson came from.
  source_names="$(printf '%s\n' "$entry" | grep -oE '[A-Za-z0-9_.-]+#[0-9]+' | sed 's/#.*//' | tr '[:upper:]' '[:lower:]' | sort -u)"

  body_file="$(mktemp)"
  cat >"$body_file" <<BODY
A new lesson was recorded in another project. Check whether this project has the same defect.

**$num.** $rule

What to do: look for code in this project that matches the situation the rule describes, fix any instance found, and close this issue saying where you looked. If nothing here can hit it, close it with that reason. The full lesson, with its evidence, is \`claude-sync lesson $id\` on Dan's Macs.

<!-- lesson-id: $id -->
BODY

  while IFS=' ' read -r r tok; do
    [ -n "$r" ] || continue
    if printf '%s\n' "$source_names" | grep -qixF "${r#*/}"; then
      echo "SKIPPED $num $r: the lesson came from here"; continue
    fi
    if [ "$tok" = "-" ]; then
      echo "FAILED $num $r: no signed in account can write to it"; ok=1; continue
    fi
    if ! existing="$(GH_TOKEN="$tok" gh issue list --repo "$r" --label "$LABEL" --state all --limit 1000 \
        --json number,title,body 2>&1)"; then
      echo "FAILED $num $r: could not read its existing issues, so nothing was filed blind: $existing"; ok=1; continue
    fi
    hit="$(printf '%s' "$existing" | jq -r --arg t "Lesson $num sweep" --arg m "lesson-id: $id" \
      '[.[] | select((.title | startswith($t)) or ((.body // "") | contains($m)))][0].number // empty' 2>/dev/null)"
    if [ -n "$hit" ]; then
      echo "EXISTS $num $r#$hit"; continue
    fi
    if ! err="$(GH_TOKEN="$tok" bash "$HELPERS/ensure-priority-labels.sh" "$r" 2>&1)"; then
      echo "FAILED $num $r: could not make sure the priority labels exist: $err"; ok=1; continue
    fi
    if ! err="$(GH_TOKEN="$tok" gh label create "$LABEL" --repo "$r" --color C5DEF5 \
        --description "Check this project for a defect a lesson recorded elsewhere" --force 2>&1)"; then
      echo "FAILED $num $r: could not make sure the $LABEL label exists: $err"; ok=1; continue
    fi
    if ! err="$(GH_TOKEN="$tok" bash "$HELPERS/ensure-milestone.sh" "$r" "$MILESTONE" 2>&1)"; then
      echo "FAILED $num $r: could not resolve the $MILESTONE milestone: $err"; ok=1; continue
    fi
    if ! url="$(GH_TOKEN="$tok" gh issue create --repo "$r" --title "$title" --body-file "$body_file" \
        --label "$PRIORITY,$LABEL" --milestone "$MILESTONE" 2>&1)"; then
      echo "FAILED $num $r: the create was refused: $url"; ok=1; continue
    fi
    echo "CREATED $num $r $(printf '%s' "$url" | tail -1)"
  done <<<"$repo_tokens"
  rm -f "$body_file"

  if [ "$ok" -eq 0 ]; then
    mkdir -p "$(dirname "$LEDGER")"
    grep -qxF "$num $id" "$LEDGER" 2>/dev/null || printf '%s %s\n' "$num" "$id" >>"$LEDGER"
  fi
  return "$ok"
}

for num in "$@"; do
  fan_out "$num" || overall=1
done
if [ "$overall" -ne 0 ]; then
  echo "NOT COMPLETE: the lines marked FAILED or REFUSED above were not filed. Rerunning files only those."
fi
exit "$overall"
