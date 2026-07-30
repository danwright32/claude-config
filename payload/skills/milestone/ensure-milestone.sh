#!/usr/bin/env bash
# ensure-milestone.sh: resolve a milestone title to a real GitHub milestone,
# reusing an existing one wherever possible and refusing to invent a twin.
#
# Every path that files an issue funnels through here, so "an issue always belongs
# to a milestone" is one implementation rather than a rule each caller remembers.
#
# Usage:
#   ensure-milestone.sh <owner/name> <title> [options]
#
# Options:
#   --create-approved        permit creating the milestone when nothing matches.
#                            Without it this script NEVER creates, so the decision
#                            to open a new milestone cannot happen by momentum.
#   --description <text>     milestone description (only used when creating)
#   --due <iso8601>          milestone due date (only used when creating)
#
# Env:
#   DRY_RUN=1                read and classify, but write nothing
#
# Output (first token is the verdict, so callers can branch on it):
#   MILESTONE-EXISTS  <number> <title> <url>     reused an open milestone
#   MILESTONE-CREATED <number> <title> <url>     created it
#   WOULD-CREATE-MILESTONE repo=<r> title=<t>    dry run
#   CLOSED-MATCH / NEAR-DUPLICATE / NO-MATCH     needs a human decision
#
# Exit codes:
#   0  reused or created
#   2  usage error
#   3  a milestone with this title exists but is CLOSED
#   4  a near duplicate open milestone exists
#   5  nothing matched and creating was not approved
#   6  the milestone list could not be read (fails loud, never creates blind)

set -uo pipefail

repo="${1:-}"
title="${2:-}"
if [[ -z "$repo" || -z "$title" || "$repo" == --* ]]; then
  echo "Usage: ensure-milestone.sh <owner/name> <title> [--create-approved] [--description <text>] [--due <iso8601>]" >&2
  exit 2
fi
shift 2

create_approved=""
description=""
due_on=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-approved) create_approved=1; shift ;;
    --description) description="${2:-}"; shift 2 ;;
    --due) due_on="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "Cannot resolve a milestone: gh is not on PATH. Refusing to file an issue without one." >&2
  exit 6
fi

# --- read every milestone, both states, all pages -------------------------
# GitHub pages this endpoint at 30 by default, so a repo with a long milestone
# history would silently look like it has no match and a duplicate would be born.
# stdout and stderr are kept apart: merging them lets any gh warning land in the
# middle of the JSON, which reads as an unparseable list and blocks filing.
gh_err="$(mktemp)"
trap 'rm -f "$gh_err"' EXIT
raw="$(gh api --paginate "repos/$repo/milestones?state=all&per_page=100" 2>"$gh_err")"
if [[ $? -ne 0 ]]; then
  echo "Could not read the milestone list for $repo: $(tr '\n' ' ' <"$gh_err")" >&2
  exit 6
fi

# --- classify -------------------------------------------------------------
verdict="$(printf '%s' "$raw" | python3 -c '
import sys, json, re
from difflib import SequenceMatcher

RATIO = 0.72          # tuned so "Q3 hardening" vs "Q4 hardening" stops to ask
                      # but "Milestone: Auth" vs "Milestone: Billing" does not.
SUBSTR_MIN = 4        # ignore substring hits on very short titles

def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())

def load(text):
    # gh --paginate concatenates one JSON array per page, and --slurp would nest
    # them, so decode consecutive values and flatten one level either way.
    dec, out, i, n = json.JSONDecoder(), [], 0, len(text)
    while i < n:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        val, i = dec.raw_decode(text, i)
        out.append(val)
    flat = []
    for v in out:
        if isinstance(v, list):
            for item in v:
                if isinstance(item, list):
                    flat.extend(item)
                else:
                    flat.append(item)
        else:
            flat.append(v)
    return [m for m in flat if isinstance(m, dict) and m.get("title")]

want = sys.argv[1]
try:
    milestones = load(sys.stdin.read())
except Exception:
    print("PARSE-ERROR")
    sys.exit(0)

wn = norm(want)
if not wn:
    print("PARSE-ERROR")
    sys.exit(0)

opens = [m for m in milestones if m.get("state") == "open"]
closed = [m for m in milestones if m.get("state") != "open"]

def emit(*fields):
    print("\t".join(str(f) for f in fields))

for m in opens:
    if norm(m["title"]) == wn:
        emit("EXISTS", m.get("number", ""), m["title"], m.get("html_url", ""))
        sys.exit(0)

for m in closed:
    if norm(m["title"]) == wn:
        emit("CLOSED", m.get("number", ""), m["title"], m.get("html_url", ""))
        sys.exit(0)

# Near duplicates are judged against OPEN milestones only: a new milestone that
# resembles a finished one is usually legitimate follow-on work.
near = []
for m in opens:
    mn = norm(m["title"])
    if not mn:
        continue
    shorter, longer = sorted((wn, mn), key=len)
    if len(shorter) >= SUBSTR_MIN and shorter in longer:
        near.append(m)
        continue
    if SequenceMatcher(None, wn, mn).ratio() >= RATIO:
        near.append(m)

if near:
    emit("NEAR", "; ".join("#%s %s" % (m.get("number", "?"), m["title"]) for m in near))
    sys.exit(0)

emit("NONE", "; ".join("#%s %s" % (m.get("number", "?"), m["title"]) for m in opens) or "(none open)")
' "$title")"

kind="$(printf '%s' "$verdict" | cut -f1)"
f2="$(printf '%s' "$verdict" | cut -f2)"
f3="$(printf '%s' "$verdict" | cut -f3)"
f4="$(printf '%s' "$verdict" | cut -f4)"

case "$kind" in
  EXISTS)
    echo "MILESTONE-EXISTS $f2 $f3 $f4"
    # gh issue create matches a milestone BY NAME, not by number, so callers need
    # the milestone's own exact title. The title asked for may differ in case or
    # punctuation, and passing that variant to gh fails to find the milestone.
    echo "MILESTONE-TITLE $f3"
    exit 0
    ;;
  CLOSED)
    echo "CLOSED-MATCH #$f2 \"$f3\" already exists in $repo but is closed ($f4)."
    echo "Ask before proceeding: reopen that milestone, attach the issue to a different open one, or pick a new distinct title."
    exit 3
    ;;
  NEAR)
    echo "NEAR-DUPLICATE \"$title\" closely resembles an open milestone in $repo: $f2"
    echo "Do not create a second one. Either attach the issue to that milestone, or confirm with the user that a genuinely separate milestone is wanted."
    exit 4
    ;;
  NONE)
    if [[ -z "$create_approved" ]]; then
      echo "NO-MATCH \"$title\" matches no open milestone in $repo."
      echo "Open milestones: $f2"
      echo "Creating a milestone needs the user's approval. Offer the fitting one from that list, or ask before creating \"$title\"."
      exit 5
    fi
    ;;
  *)
    echo "Could not read the milestone list for $repo (unexpected response)." >&2
    exit 6
    ;;
esac

# --- a NEW title names the feature, not a narrative sentence ---------------
# A milestone is the overarching feature, and its issues are what has to be finished
# for that feature to ship. So the title is a short noun phrase naming the thing
# being built, and the narrative goes in the description.
#
# Only ever checked here, on the path that CREATES. A title that already names a
# real milestone is reused above and never reaches this point, which matters
# because Dan kept the narrative milestones he already had: applying the shape rule
# to a lookup would orphan every issue that belongs to one of them.
#
# This is a shape check, not a vocabulary check. Dan deliberately chose not to
# freeze a list of allowed names, so anything that READS as a feature name passes.
shape="$(python3 -c '
import re
import sys

title = sys.argv[1]

# A sentence needs punctuation to hold its clauses together. The name of a feature
# does not have clauses.
PUNCT = ",;:.!?"

# Words that only turn up when a title is describing rather than naming: pronouns,
# copulas and modals, relative pronouns. Plus the one proper noun that kept showing
# up in the titles Dan objected to.
STOP = {
    "i", "me", "my", "mine", "you", "your", "yours", "he", "him", "his", "she",
    "her", "hers", "we", "us", "our", "ours", "they", "them", "their", "theirs",
    "it", "its",
    "am", "is", "are", "was", "were", "be", "been", "being",
    "can", "will", "would", "should", "must", "may", "might", "shall",
    "do", "does", "did", "done", "has", "have", "had",
    "where", "when", "that", "which", "who", "whose", "whom", "why", "how", "what",
    "dan",
}

# Six words fits a real feature name ("Node test coloring in edit mode") while still
# refusing every title Dan objected to: those ran 7 to 11 words, or carried a comma
# or a colon.
MAX_WORDS = 6
MAX_CHARS = 48

words = title.split()

if len(words) > MAX_WORDS:
    print("it is %d words long, and a feature name is at most %d" % (len(words), MAX_WORDS))
    sys.exit(0)

if len(title) > MAX_CHARS:
    print("it is %d characters long, and a feature name is at most %d" % (len(title), MAX_CHARS))
    sys.exit(0)

found = [c for c in PUNCT if c in title]
if found:
    print("it reads as a sentence: a feature name has no %s" % " or ".join(repr(c) for c in found))
    sys.exit(0)

hits = [w for w in words if re.sub(r"[^a-z]", "", w.lower()) in STOP]
if hits:
    print("it describes rather than names, because of: %s" % ", ".join(hits))
    sys.exit(0)

print("OK")
' "$title")"

if [[ "$shape" != "OK" ]]; then
  if [[ -z "${ALLOW_ANY_MILESTONE_TITLE:-}" ]]; then
    echo "TITLE-NOT-A-CATEGORY \"$title\" is not shaped like a milestone: $shape."
    echo "A milestone groups a CATEGORY of work, so its title is a short noun phrase that stays true for months: Accessibility, UI/UX, Monitoring and alerting, Analytics, Tech debt and CI hygiene, Data integrity, Security and privacy."
    echo "Pick the category this work belongs to and use that as the title. Put the narrative (what is wrong, why it matters) in the milestone DESCRIPTION, where it belongs."
    echo "The full rule, with the examples this check came from, is in ~/.claude/skills/milestone/NAMING.md."
    echo "If a non category title is genuinely right here, say why first, then re-run with the visible override: ALLOW_ANY_MILESTONE_TITLE=1"
    exit 8
  fi
  echo "TITLE-SHAPE-OVERRIDDEN \"$title\" ($shape), allowed by ALLOW_ANY_MILESTONE_TITLE."
fi

# --- create, only ever on the approved NONE path --------------------------
if [[ -n "${DRY_RUN:-}" ]]; then
  echo "WOULD-CREATE-MILESTONE repo=$repo title=$title"
  exit 0
fi

args=(api "repos/$repo/milestones" -f "title=$title" -f "description=$description")
[[ -n "$due_on" ]] && args+=(-f "due_on=$due_on")

created="$(gh "${args[@]}" 2>"$gh_err")"
if [[ $? -ne 0 ]]; then
  echo "Failed to create milestone \"$title\" in $repo: $(tr '\n' ' ' <"$gh_err")" >&2
  exit 6
fi

read -r num url <<<"$(printf '%s' "$created" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get("number", ""), d.get("html_url", ""))
except Exception:
    print("", "")
')"
if [[ -z "$num" ]]; then
  echo "Created a milestone in $repo but could not read it back. Verify on GitHub before filing issues." >&2
  exit 6
fi
echo "MILESTONE-CREATED $num $title $url"
echo "MILESTONE-TITLE $title"
exit 0
