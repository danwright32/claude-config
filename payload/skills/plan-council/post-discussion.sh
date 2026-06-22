#!/usr/bin/env bash
#
# post-discussion.sh — robustly publish a plan-council result, with fallbacks.
# Usage: post-discussion.sh <owner/repo> <title> <body-file>
#
# Tries, in order:
#   1. a GitHub Discussion (needs Discussions enabled + a category)
#   2. a tracking GitHub issue
#   3. a local PLAN-<slug>.md file
# Prints one line describing what happened: "DISCUSSION <url>", "ISSUE <url>",
# or "FILE <path>", so the caller can tell the user exactly where the plan went.

set -uo pipefail
repo="${1:?usage: post-discussion.sh owner/repo title body-file}"
title="${2:?missing title}"
bodyfile="${3:?missing body file}"
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
  url="$(gh issue create --repo "$repo" --title "$title" --body "$body" 2>/dev/null)"
  if [ -n "$url" ]; then echo "ISSUE $url"; exit 0; fi
fi

# 3. Local file ------------------------------------------------------------
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
out="PLAN-${slug:-feature}.md"
printf '%s\n' "$body" > "$out"
echo "FILE $out"
