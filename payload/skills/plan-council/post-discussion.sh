#!/usr/bin/env bash
#
# post-discussion.sh: robustly publish a plan-council result, with fallbacks.
# Usage: post-discussion.sh <owner/repo> <title> <body-file> [milestone-title]
#
# Tries, in order:
#   1. a GitHub Discussion (needs Discussions enabled + a category)
#   2. a tracking GitHub issue
#   3. a local PLAN-<slug>.md file
# Prints one line describing what happened: "DISCUSSION <url>", "ISSUE <url>",
# or "FILE <path>", so the caller can tell the user exactly where the plan went.
# Exits non-zero, naming why on stderr, when the plan landed nowhere.
#
# The issue carries every field the issue field gate requires, because that gate only
# sees commands typed in a session and never this script's own (claude-config#677):
#   - a priority (priority-p2) and a category (planning), each created in the repo first
#     when missing;
#   - a milestone. This runs before the plan is approved, so the plan's own milestone
#     usually does not exist yet (creating it here would create milestones for plans that
#     get rejected). So an EXISTING match is reused, and otherwise the issue waits in the
#     repo's catch-all milestone, Ungrouped, and a MILESTONE-PENDING line names the move
#     to make once the plan's milestone exists. It never invents a feature milestone.
# When any of those cannot be had, no bare issue is filed: the plan goes to the file.
#
# The file is written at the root of the project the script runs in, never into
# whatever folder it happened to start from, and a write that fails is a failure.

set -uo pipefail
repo="${1:?usage: post-discussion.sh owner/repo title body-file [milestone-title]}"
title="${2:?missing title}"
bodyfile="${3:?missing body file}"
milestone="${4:-}"
[ -f "$bodyfile" ] || { echo "ERROR: body file not found: $bodyfile" >&2; exit 1; }
body="$(cat "$bodyfile")"
owner="${repo%%/*}"; name="${repo##*/}"

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not installed" >&2; }

errf="$(mktemp "${TMPDIR:-/tmp}/post-discussion.XXXXXX")" || { echo "ERROR: could not make a scratch file" >&2; exit 1; }
trap 'rm -f "$errf"' EXIT
CATEGORY="planning"
MILESTONE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../milestone" 2>/dev/null && pwd)"

# Settles the issue's milestone and labels, or says why it cannot (why_no_issue) and returns 1, so
# that an issue is never filed without them. Sets ms_title, and pending when the issue will wait in
# the catch-all for a plan milestone that does not exist yet.
why_no_issue=""
ms_title=""
pending=""
issue_fields(){
  local ensure="$MILESTONE_DIR/ensure-milestone.sh" ms_out rc raw
  if [ ! -f "$ensure" ] || [ ! -f "$MILESTONE_DIR/catch-all.sh" ] || [ ! -f "$MILESTONE_DIR/ensure-priority-labels.sh" ]; then
    why_no_issue="the milestone helpers are missing from $MILESTONE_DIR, so the issue could not be given its milestone and labels."
    return 1
  fi
  if [ -n "$milestone" ]; then
    ms_out="$(bash "$ensure" "$repo" "$milestone" 2>"$errf")"; rc=$?
    if [ "$rc" -eq 6 ]; then
      why_no_issue="the milestones could not be read: $(tr '\n' ' ' < "$errf")"
      return 1
    fi
    [ "$rc" -eq 0 ] && ms_title="$(sed -n 's/^MILESTONE-TITLE //p' <<< "$ms_out" | awk 'NR <= 1')"
  fi
  if [ -z "$ms_title" ]; then
    # shellcheck source=../milestone/catch-all.sh
    . "$MILESTONE_DIR/catch-all.sh"
    ms_out="$(bash "$ensure" "$repo" "$CATCH_ALL" 2>"$errf")"; rc=$?
    ms_title="$(sed -n 's/^MILESTONE-TITLE //p' <<< "$ms_out" | awk 'NR <= 1')"
    if [ "$rc" -ne 0 ] || [ -z "$ms_title" ]; then
      why_no_issue="neither the plan's milestone nor the catch-all \"$CATCH_ALL\" could be had: $(tr '\n' ' ' < "$errf") $ms_out"
      return 1
    fi
    [ -n "$milestone" ] && pending=1
  fi
  if ! bash "$MILESTONE_DIR/ensure-priority-labels.sh" "$repo" >/dev/null 2>"$errf"; then
    why_no_issue="the priority labels could not be made sure of: $(tr '\n' ' ' < "$errf")"
    return 1
  fi
  if ! raw="$(gh label list --repo "$repo" --limit 500 --json name 2>"$errf")"; then
    why_no_issue="the labels could not be read: $(tr '\n' ' ' < "$errf")"
    return 1
  fi
  if ! python3 -c 'import json,sys; sys.exit(0 if any(l.get("name") == sys.argv[1] for l in json.loads(sys.argv[2])) else 1)' "$CATEGORY" "$raw" 2>/dev/null; then
    if ! gh label create "$CATEGORY" --repo "$repo" --color 5319e7 --description "A plan and its record" >/dev/null 2>"$errf"; then
      why_no_issue="the $CATEGORY label is missing and could not be created: $(tr '\n' ' ' < "$errf")"
      return 1
    fi
  fi
  return 0
}

# 1. GitHub Discussion -----------------------------------------------------
if command -v gh >/dev/null 2>&1; then
  meta="$(gh api graphql -f query='query($o:String!,$n:String!){repository(owner:$o,name:$n){id hasDiscussionsEnabled discussionCategories(first:20){nodes{id name}}}}' -F o="$owner" -F n="$name" 2>/dev/null)"
  if [ -n "$meta" ]; then
    rid="$(printf '%s' "$meta" | python3 -c 'import sys,json
try:
 d=json.load(sys.stdin)["data"]["repository"]
 print(d["id"] if d.get("hasDiscussionsEnabled") else "")
except Exception: print("")' 2>/dev/null)"
    cat="$(printf '%s' "$meta" | python3 -c 'import sys,json
try:
 ns=json.load(sys.stdin)["data"]["repository"]["discussionCategories"]["nodes"]
 pref=[n for n in ns if n["name"].lower() in ("ideas","general","planning")]
 print((pref or ns)[0]["id"] if ns else "")
except Exception: print("")' 2>/dev/null)"
    if [ -n "$rid" ] && [ -n "$cat" ]; then
      url="$(gh api graphql -f query='mutation($r:ID!,$c:ID!,$t:String!,$b:String!){createDiscussion(input:{repositoryId:$r,categoryId:$c,title:$t,body:$b}){discussion{url}}}' -F r="$rid" -F c="$cat" -F t="$title" -F b="$body" 2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["data"]["createDiscussion"]["discussion"]["url"])
except Exception: print("")' 2>/dev/null)"
      if [ -n "$url" ]; then echo "DISCUSSION $url"; exit 0; fi
    fi
  fi

  # 2. Tracking issue ------------------------------------------------------
  issue_url=""
  if issue_fields; then
    # The issue names the session that filed it, from the one shared line maker (claude-config#536).
    sess_line="$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" 2>/dev/null && pwd)/claude-session-line.sh" 2>/dev/null)" || sess_line=""
    issue_body="$body"
    [ -n "$sess_line" ] && issue_body="$body"$'\n\n'"$sess_line"
    if issue_url="$(gh issue create --repo "$repo" --title "$title" --body "$issue_body" \
        --milestone "$ms_title" --label priority-p2 --label "$CATEGORY" 2>"$errf")" && [ -n "$issue_url" ]; then
      echo "ISSUE $issue_url"
      if [ -n "$pending" ]; then
        echo "MILESTONE-PENDING $issue_url is in \"$ms_title\" until the plan's milestone exists. Move it once it does: gh issue edit $issue_url --milestone \"$milestone\""
      fi
      exit 0
    fi
    why_no_issue="gh issue create failed: $(tr '\n' ' ' < "$errf")"
  fi
  echo "NOTE: no tracking issue was filed, so the plan goes to a file. $why_no_issue" >&2
fi

# 3. Local file ------------------------------------------------------------
# At the project's root, never wherever this happened to be started from.
root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
if [ -z "$root" ]; then
  echo "ERROR: $(pwd) is not inside a git checkout, so there is no project root to write the plan file to. The plan is still in $bodyfile." >&2
  exit 1
fi
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
out="$root/PLAN-${slug:-feature}.md"
if ! { printf '%s\n' "$body" > "$out"; } 2>"$errf"; then
  echo "ERROR: could not write $out: $(tr '\n' ' ' < "$errf"). The plan is still in $bodyfile." >&2
  exit 1
fi
echo "FILE $out"
