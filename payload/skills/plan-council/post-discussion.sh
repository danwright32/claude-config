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
#
# Milestones: every issue belongs to one. This runs before the plan is approved, so
# the plan's own milestone usually does not exist yet (creating it here would create
# milestones for plans that get rejected). So it attaches an EXISTING milestone when
# one matches, and otherwise prints a NO-MILESTONE warning naming the gap, which the
# milestone step then closes by adopting this issue. It never invents a milestone,
# and it never files an orphan silently.

set -uo pipefail
repo="${1:?usage: post-discussion.sh owner/repo title body-file [milestone-title]}"
title="${2:?missing title}"
bodyfile="${3:?missing body file}"
milestone="${4:-}"
[ -f "$bodyfile" ] || { echo "ERROR: body file not found: $bodyfile" >&2; exit 1; }
body="$(cat "$bodyfile")"
owner="${repo%%/*}"; name="${repo##*/}"

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh CLI not installed" >&2; }

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
  # Resolve a milestone WITHOUT creating one. An exact or case variant match is
  # reused; anything else leaves the issue unmilestoned and says so out loud.
  ensure="$(cd "$(dirname "${BASH_SOURCE[0]}")/../milestone" && pwd)/ensure-milestone.sh"
  ms_title=""
  if [ -n "$milestone" ] && [ -f "$ensure" ]; then
    ms_out="$(bash "$ensure" "$repo" "$milestone" 2>/dev/null)"
    ms_title="$(printf '%s\n' "$ms_out" | sed -n 's/^MILESTONE-TITLE //p' | awk 'NR <= 1')"
  fi

  # The issue names the session that filed it, from the one shared line maker (claude-config#536).
  sess_line="$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../hooks/lib" 2>/dev/null && pwd)/claude-session-line.sh" 2>/dev/null)" || sess_line=""
  [ -n "$sess_line" ] && body="$body"$'\n\n'"$sess_line"

  if [ -n "$ms_title" ]; then
    url="$(gh issue create --repo "$repo" --title "$title" --body "$body" --milestone "$ms_title" 2>/dev/null)"
  else
    url="$(gh issue create --repo "$repo" --title "$title" --body "$body" 2>/dev/null)"
  fi
  if [ -n "$url" ]; then
    echo "ISSUE $url"
    if [ -z "$ms_title" ]; then
      echo "NO-MILESTONE $url has no milestone yet. Attach it when the plan's milestone is created: gh issue edit $url --milestone \"<title>\""
    fi
    exit 0
  fi
fi

# 3. Local file ------------------------------------------------------------
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
out="PLAN-${slug:-feature}.md"
printf '%s\n' "$body" > "$out"
echo "FILE $out"
