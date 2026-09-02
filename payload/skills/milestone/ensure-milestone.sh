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
#   --for-issues <n>         how many issues will go into it. REQUIRED to create
#                            anything but the catch-all, and refused below 2. The
#                            count is stated by the caller, not verified here.
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
#   8  a new title is not shaped like a feature name
#  10  a new milestone was asked for without a count, or for fewer than 2 issues

set -uo pipefail

repo="${1:-}"
title="${2:-}"
if [[ -z "$repo" || -z "$title" || "$repo" == --* ]]; then
  echo "Usage: ensure-milestone.sh <owner/name> <title> [--create-approved] [--description <text>] [--due <iso8601>]" >&2
  exit 2
fi
shift 2

# The one designated holding pen per repo, plus the exact-match test for it, both
# from catch-all.sh. They live there rather than here because milestone-candidates.sh
# needs the same name: a second copy would let the two scripts look in differently
# spelled pens while both read as correct, and the reader would report "no siblings"
# with dozens of them sitting in the pen this script writes to (L41).
#
# Resolved from this script's own location at run time, so the same copy is right on
# both Macs. A missing file is reported as missing rather than defaulted around.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$HERE/catch-all.sh" ]]; then
  echo "Cannot resolve the holding pen's name: $HERE/catch-all.sh is missing. Refusing to guess it." >&2
  exit 6
fi
# shellcheck source=catch-all.sh
source "$HERE/catch-all.sh"

create_approved=""
distinct_approved=""
for_issues=""
for_issues_given=""
description=""
due_on=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --create-approved) create_approved=1; shift ;;
    # The near duplicate refusal tells the caller to confirm with the user that a genuinely
    # separate milestone is wanted, and there was no way to say they had, so the only route left
    # was `gh api` directly, which skips the title check this script exists to run (claude-config#255).
    # It waives the DUPLICATE question and nothing else: the shape check and the two issue
    # threshold both still run below, because one override must never quietly waive three rules.
    --distinct-approved) distinct_approved=1; shift ;;
    # The flag being GIVEN is tracked separately from its value, because
    # `--for-issues "$count"` with an unset variable leaves the same empty string as
    # not passing the flag at all. Without this the caller is told they forgot to
    # state a count, which sends them to think about the threshold when the real
    # fault is an empty variable at the call site (L11).
    --for-issues) for_issues="${2:-}"; for_issues_given=1; shift 2 ;;
    --description) description="${2:-}"; shift 2 ;;
    --due) due_on="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# A count that is not a plain positive integer is a USAGE error, never quietly read
# as zero or as good enough. A caller passing an empty variable would otherwise be
# refused with a message about the threshold, which points at the wrong thing (L11).
# Checked here, before anything branches on it, and NOT waived by the threshold
# override below: one override must never quietly waive two rules.
if [[ -n "$for_issues_given" && ! "$for_issues" =~ ^[0-9]+$ ]]; then
  echo "Usage: --for-issues takes a plain count of how many issues will go into this milestone, got \"$for_issues\"." >&2
  exit 2
fi

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

# Words that name a KIND of feature rather than which feature it is. A title pair sharing only one
# of these is not a duplicate, it is two features of the same kind, and any repo with more than one
# integration, sync, page or dashboard trips the comparison below on every second one: "Regal
# integration" was refused as a twin of "PET integration" on 2026-09-01 (claude-config#255).
#
# Dropped only when BOTH titles carry the word, so a single title using one is compared whole, and
# only when something distinctive is left on both sides afterwards: comparing an empty string
# against a real title matches everything (L214).
GENERIC = {
    "integration", "integrations", "sync", "syncs", "page", "pages",
    "dashboard", "dashboards", "cleanup", "cleanups", "migration", "migrations",
}

def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())

def words(s):
    return [w for w in re.split(r"[^a-z0-9]+", (s or "").lower()) if w]

def distinctive(a, b):
    """The two titles with any GENERIC word they SHARE removed, or None when that leaves nothing."""
    aw, bw = words(a), words(b)
    shared = (set(aw) & set(bw)) & GENERIC
    if not shared:
        return None
    da, db = [w for w in aw if w not in shared], [w for w in bw if w not in shared]
    if not da or not db:
        return None
    return "".join(da), "".join(db)

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
    pair = distinctive(want, m["title"])
    a, b = pair if pair else (wn, mn)
    shorter, longer = sorted((a, b), key=len)
    if len(shorter) >= SUBSTR_MIN and shorter in longer:
        near.append(m)
        continue
    if SequenceMatcher(None, a, b).ratio() >= RATIO:
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
    if [[ -z "$distinct_approved" ]]; then
      echo "NEAR-DUPLICATE \"$title\" closely resembles an open milestone in $repo: $f2"
      echo "Do not create a second one. Either attach the issue to that milestone, or confirm with the user that a genuinely separate milestone is wanted and re-run with --distinct-approved."
      exit 4
    fi
    # SAID, not silent. The resemblance is real and somebody decided it was two features rather
    # than one, so the line records that decision where the creation is reported (L11).
    echo "DISTINCT-APPROVED \"$title\" resembles an open milestone in $repo ($f2), and was confirmed as a separate feature."
    ;;
  NONE)
    if is_catch_all "$title"; then
      # The catch-all needs no approval, and it is described here rather than by the
      # caller so every repo's holding pen reads the same.
      create_approved=1
      [[ -z "$description" ]] && description="$CATCH_ALL_DESCRIPTION"
      echo "CATCH-ALL-MILESTONE creating the standalone holding pen \"$CATCH_ALL\" in $repo, which needs no approval."
    elif [[ -z "$create_approved" ]]; then
      echo "NO-MATCH \"$title\" matches no open milestone in $repo."
      echo "Open milestones: $f2"
      echo "You almost certainly do not want to create one. A new milestone is a PLANNING decision, made when a feature is planned through /plan-council, /plan-lite or /milestone. It never makes sense to open a milestone for a one-off issue."
      echo "So pick one of these two instead:"
      echo "  1. An existing open milestone from the list above, if the work ships with that feature."
      echo "  2. The catch-all milestone \"$CATCH_ALL\", which needs no approval. This is a REAL milestone that holds the standalone issues, not the absence of one:"
      echo "     bash ~/.claude/skills/milestone/ensure-milestone.sh \"$repo\" \"$CATCH_ALL\""
      echo "Only if this genuinely is a feature being planned right now, ask the user first, then re-run with --create-approved."
      exit 5
    fi
    ;;
  *)
    echo "Could not read the milestone list for $repo (unexpected response)." >&2
    exit 6
    ;;
esac

# --- a NEW milestone is for 2 OR MORE issues -------------------------------
# A milestone holding a single issue is not a feature, it is a label with extra
# steps. That rule used to live only in the instruction text, which is to say it was
# a hope (L27): nothing stopped a session opening one for a lone issue, and doing so
# is what produced the essay titled milestones this file exists to prevent.
#
# The count is STATED, not verified, and the comment says so plainly because a
# checked number and an asserted one are different things. The caller usually holds
# issues that do not exist yet, so nothing here could confirm it. What the flag
# removes is creation by MOMENTUM: passing --create-approved is no longer enough on
# its own, and a caller now has to say how many issues this milestone is for.
#
# Reached only on the approved NONE path, so it never touches a reuse. The catch-all
# has already set create_approved itself above and is exempt on purpose: it is a
# holding pen rather than a feature, and applying the threshold to it would make the
# pen uncreatable and leave every standalone issue with nowhere to go, which is the
# deadlock a too broad rule produces (L362).
if [[ -n "$create_approved" ]] && ! is_catch_all "$title"; then
  if [[ -z "$for_issues" ]]; then
    echo "NO-ISSUE-COUNT creating a milestone needs --for-issues <n>, saying how many issues will go into it."
    echo "A new milestone is for 2 or more issues. Count the issues being filed together plus any existing ones you would move into it."
    echo "One issue with no siblings is not a feature: it goes in the catch-all \"$CATCH_ALL\" instead."
    echo "  bash ~/.claude/skills/milestone/ensure-milestone.sh \"$repo\" \"$CATCH_ALL\""
    echo "Read what the repo already holds first, so the count is real rather than guessed:"
    echo "  bash ~/.claude/skills/milestone/milestone-candidates.sh \"$repo\" --like \"<the issue title>\""
    exit 10
  fi
  # ZERO is a different act from ONE, and only one of them is the failure mode.
  # `milestone/SKILL.md` documents an empty "issues" array as a way to create the
  # container deliberately, before its issues exist, so refusing 0 would break a
  # documented flow. It is announced rather than passed over, so an empty milestone
  # can never appear without something having said so.
  if [[ "$for_issues" -eq 0 ]]; then
    echo "EMPTY-MILESTONE \"$title\" is being created with no issues yet, which is only right when its issues are coming next."
  fi
  if [[ "$for_issues" -eq 1 ]]; then
    if [[ -z "${ALLOW_SINGLE_ISSUE_MILESTONE:-}" ]]; then
      echo "SINGLE-ISSUE-MILESTONE \"$title\" would hold $for_issues issue, and a new milestone is for 2 or more."
      echo "A milestone with one issue in it is not a feature, it is a label with extra steps."
      echo "Put it in the catch-all \"$CATCH_ALL\" instead, or find its siblings first:"
      echo "  bash ~/.claude/skills/milestone/milestone-candidates.sh \"$repo\" --like \"<the issue title>\""
      echo "If a single issue milestone is genuinely right here, say why first, then re-run with the visible override: ALLOW_SINGLE_ISSUE_MILESTONE=1"
      exit 10
    fi
    echo "SINGLE-ISSUE-MILESTONE-OVERRIDDEN \"$title\" holds $for_issues issue, allowed by ALLOW_SINGLE_ISSUE_MILESTONE."
  fi
fi

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

# Eight words and sixty characters fit a real feature name ("Bulk contact enrichment
# for scouted shows", "Organisation contact ledger for scouted show venues"), which a
# six word cap refused. The length rules are only a backstop against a title that is
# obviously a paragraph: the punctuation and stop-word rules below do the real work,
# and they still refuse every title Dan objected to.
MAX_WORDS = 8
MAX_CHARS = 60

words = title.split()

found = [c for c in PUNCT if c in title]
if found:
    print("it reads as a sentence: a feature name has no %s" % " or ".join(repr(c) for c in found))
    sys.exit(0)

if len(words) > MAX_WORDS:
    print("it is %d words long, and a feature name is at most %d" % (len(words), MAX_WORDS))
    sys.exit(0)

if len(title) > MAX_CHARS:
    print("it is %d characters long, and a feature name is at most %d" % (len(title), MAX_CHARS))
    sys.exit(0)

hits = [w for w in words if re.sub(r"[^a-z]", "", w.lower()) in STOP]
if hits:
    print("it describes rather than names, because of: %s" % ", ".join(hits))
    sys.exit(0)

print("OK")
' "$title")"

if [[ "$shape" != "OK" ]]; then
  if [[ -z "${ALLOW_ANY_MILESTONE_TITLE:-}" ]]; then
    echo "TITLE-NOT-A-FEATURE \"$title\" is not shaped like a milestone: $shape."
    echo "A milestone is the overarching FEATURE, and its issues are what has to be finished for that feature to ship. So the title is a short noun phrase naming the thing being built: Saved views, Salesforce sync v2, Bulk contact enrichment, Queue windowing."
    echo "Name the feature and use that as the title. Put the narrative (what is wrong, why it matters, what counts as done) in the milestone DESCRIPTION, where GitHub actually shows it."
    echo "If this work is a standalone bug or chore belonging to no feature, it goes in the catch-all milestone instead: \"$CATCH_ALL\"."
    echo "The full rule, with the examples this check came from, is in ~/.claude/skills/milestone/NAMING.md."
    echo "If a non feature title is genuinely right here, say why first, then re-run with the visible override: ALLOW_ANY_MILESTONE_TITLE=1"
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
