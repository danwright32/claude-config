#!/usr/bin/env bash
# milestone-candidates.sh: show what a filed issue could belong to, before it is filed.
#
# The end of turn issue review used to choose a milestone by comparing an idea
# against milestone TITLES. That cannot see two things, and both of them matter:
#
#   1. A feature whose title does not name the subject. "One store, one truth" says
#      nothing about spools; its DESCRIPTION does. So descriptions are printed.
#   2. Siblings the idea already has. Measured 2026-09-02, the holding pen held 98
#      issues in claude-config, 157 in bidspoke and 102 in new-agent-onboarding,
#      with obvious clusters inside it (about ten on the findings spool alone). The
#      eleventh sibling still read as a standalone chore, because nothing ever
#      looked at what was already in the pen.
#
# This script only ever READS. It reports; the caller decides. In particular it does
# NOT say whether a new milestone is warranted: the caller usually holds several new
# ideas at once and this only ever sees one of them, so an eligibility verdict here
# would be a claim it cannot measure (L11).
#
# Usage:
#   milestone-candidates.sh <owner/name> --like "<the idea's title>"
#
# Output (first token is the line's kind, so a reader can branch):
#   OPEN-MILESTONE #<num> <title>            an open milestone, the catch-all excluded
#       DESC <description on one line>       or "(none recorded)"
#   HOLDING-PEN <title> open=<n>             how full the pen is right now
#   CANDIDATE <score> #<num> <title>         a pen issue sharing a word, best first.
#                                            The score RANKS. It does not rule: read
#                                            the titles and decide what is related.
#                                            Shown as context, NOT counted as evidence.
#   CANDIDATE-TRUNCATED <shown> of <found>   only when more were found than printed
#   WEAK-TRUNCATED <shown> of <found>        likewise for the weak ones
#   CANDIDATE-COUNT <n> shown                how many are LISTED, never how many are
#                                            related: that count is the reader's
#   WEAK-COUNT <n>                           reported beside it, never folded into it
#   DUPLICATE-RISK <score> #<num> <title>    an open issue ANYWHERE that overlaps.
#                                            A warning that this may already be filed,
#                                            never a sibling, never in the count below.
#   READ-TRUNCATED <n> at the limit          the read hit its cap, so every count that
#                                            follows is about a subset of the backlog
#   DUPLICATE-COUNT <n>                      reported apart from the sibling count
#   NO-CANDIDATES <repo>                     read fine, nothing to report (exit 1)
#
# Exit codes:
#   0  read fine, and there is something to report
#   1  read fine, nothing to report
#   2  usage error
#   6  could not read. NEVER confused with 0 or 1: an unreadable backlog and an empty
#      one are different answers, and the empty one is the reassuring lie (L98).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolved from this script's own location, so the same copy is correct on both
# Macs. A missing shared file is reported as missing rather than defaulted around:
# guessing the pen's name is how the two scripts would come to look in different
# places while both reading as correct.
if [[ ! -f "$HERE/catch-all.sh" ]]; then
  echo "Cannot resolve the holding pen's name: $HERE/catch-all.sh is missing. Refusing to guess it." >&2
  exit 6
fi
# shellcheck source=catch-all.sh
source "$HERE/catch-all.sh"

repo="${1:-}"
if [[ -z "$repo" || "$repo" == --* ]]; then
  echo "Usage: milestone-candidates.sh <owner/name> --like \"<the idea's title>\"" >&2
  exit 2
fi
shift

like=""
# gh issue list defaults to 30 and returns exactly --limit with no indication that
# more exist. Measured 2026-09-02: bidspoke had 270 open issues, so a limit of 300 was
# 30 away from silently scanning a subset while still reporting "no duplicate found".
# Raised, and a read that comes back AT the limit is announced below rather than
# trusted (L24, L227).
limit=1000
show_max=12
while [[ $# -gt 0 ]]; do
  case "$1" in
    --like) like="${2:-}"; shift 2 ;;
    --limit) limit="${2:-}"; shift 2 ;;
    --show) show_max="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$like" ]]; then
  echo "Usage: milestone-candidates.sh <owner/name> --like \"<the idea's title>\"" >&2
  echo "--like is required: without the idea's own words there is nothing to match siblings against." >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "Cannot read $repo: gh is not on PATH. Reporting nothing rather than an empty backlog." >&2
  exit 6
fi

gh_err="$(mktemp)"
trap 'rm -f "$gh_err"' EXIT

# --- the open milestones --------------------------------------------------
# Paginated, because GitHub answers 30 by default and a repo with a long milestone
# history would look like it has nothing to match against.
milestones_raw="$(gh api --paginate "repos/$repo/milestones?state=open&per_page=100" 2>"$gh_err")"
if [[ $? -ne 0 ]]; then
  echo "Could not read the MILESTONE LIST for $repo: $(tr '\n' ' ' <"$gh_err")" >&2
  exit 6
fi

milestones_out="$(printf '%s' "$milestones_raw" | python3 -c '
import json, re, sys

def load(text):
    # gh --paginate concatenates one JSON array per page, so decode consecutive
    # values and flatten one level either way.
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

def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())

catch_all = sys.argv[1]
MAX_DESC = 300

try:
    milestones = load(sys.stdin.read())
except Exception as exc:
    sys.stderr.write("Could not read the MILESTONE LIST: the response did not parse (%s).\n" % exc)
    sys.exit(3)

# The query already asks for open ones, but the state is re-checked here rather
# than trusted: an idea cannot ship with a finished feature, and if the filter were
# ever dropped from the URL a closed milestone would silently become matchable with
# nothing reporting it.
wanted = [
    m for m in milestones
    if m.get("state") == "open" and norm(m["title"]) != norm(catch_all)
]
for m in wanted:
    print("OPEN-MILESTONE #%s %s" % (m.get("number", "?"), m["title"]))
    desc = re.sub(r"\s+", " ", (m.get("description") or "")).strip()
    if not desc:
        # A blank line here reads as a feature with nothing to say, which is
        # indistinguishable from one whose description failed to load.
        print("    DESC (none recorded)")
    elif len(desc) > MAX_DESC:
        print("    DESC %s [truncated]" % desc[:MAX_DESC].rstrip())
    else:
        print("    DESC %s" % desc)
print("MILESTONE-COUNT %d" % len(wanted))
' "$CATCH_ALL" 2>"$gh_err")"
mrc=$?
if [[ $mrc -ne 0 ]]; then
  echo "Could not read the MILESTONE LIST for $repo: $(tr '\n' ' ' <"$gh_err")" >&2
  exit 6
fi

# --- what is already in the holding pen -----------------------------------
# ONE read of every open issue, then partitioned locally, rather than one read of
# the pen. Two questions have to be answered and only one of them is about the pen:
#
#   "what should this be grouped with"  -> the pen, which is where loose work sits
#   "does this already exist"           -> ANYWHERE, which is the one that matters
#
# Reading only the pen answered the first and silently could not answer the second.
# On 2026-09-02 this helper was run before filing an idea, reported no siblings and
# seven weak matches, and the issue for the same work was in neither list because it
# sat in a real milestone. It was filed as a duplicate (#264) and closed the same
# hour. A duplicate is exactly what a pre-filing check exists to catch.
issues_raw="$(gh issue list --repo "$repo" --state open \
  --limit "$limit" --json number,title,milestone 2>"$gh_err")"
if [[ $? -ne 0 ]]; then
  # A repo with no pen yet is not a failure, it is a pen holding nothing. Anything
  # else is, and it says which half failed so the right one gets investigated.
  if grep -qi 'no milestone\|not found\|could not find' "$gh_err"; then
    issues_raw='[]'
  else
    echo "Could not read the HOLDING PEN \"$CATCH_ALL\" in $repo: $(tr '\n' ' ' <"$gh_err")" >&2
    exit 6
  fi
fi

siblings_out="$(printf '%s' "$issues_raw" | python3 -c '
import json, re, sys

like, catch_all, show_max = sys.argv[1], sys.argv[2], int(sys.argv[3])
limit = int(sys.argv[4])

# Words shorter than this carry no subject on their own.
MIN_WORD = 4


def stem(w):
    # Two cut down Porter steps, applied in this order and once each. Crude, but it
    # has to be right about the pairs that actually occur: "spool" against
    # "spooled", "finding" against "findings". An earlier version looped over the
    # suffixes and returned on the first hit, which made it order dependent, so
    # "findings" became "finding" while "finding" became "find" and two issues about
    # one subject scored zero against each other purely on grammar.
    if w.endswith("sses"):
        w = w[:-2]
    elif w.endswith("ies"):
        w = w[:-3] + "i"
    elif w.endswith("s") and not w.endswith("ss"):
        w = w[:-1]
    for suf in ("ing", "ed"):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            w = w[: -len(suf)]
            break
    return w


# Stop words are written naturally and stemmed with the same function, so the list
# says what it means and cannot drift from the stemmer. These turn up in almost
# every issue title here, and matching on them would make everything a sibling of
# everything, which reads exactly like the feature working (L104).
STOP = {
    stem(w)
    for w in (
        "give", "gives", "stop", "make", "makes", "report", "reports", "instead",
        "rather", "again", "still", "never", "always", "because", "before",
        "after", "when", "where", "which", "that", "this", "with", "from",
        "into", "them", "also", "than", "have", "should", "would", "every",
        "only", "some", "more", "most", "there", "their", "about", "other",
        "just", "then", "over", "past", "does", "done", "need", "needs",
        "take", "takes", "uses", "used", "once", "actually", "really", "thing",
        "things", "ways", "lets", "each", "both", "while", "being", "does",
        # Tracker vocabulary. Generic in EVERY repo, because everything here is an
        # issue that is open or closed and was filed at some point. Measured
        # 2026-09-02 on this repo: an idea about grouping the backlog drew two
        # siblings at two shared words and neither was about grouping, because they
        # shared "issue", "open" and "already". Raising the score threshold would
        # have discarded real matches, so the words go here instead.
        "issue", "issues", "open", "opened", "close", "closed", "already",
        "filed", "file", "backlog", "repo", "ticket", "item", "items",
        "against", "elsewhere", "twice", "anything",
    )
}


def words(text):
    out = set()
    for raw in re.split(r"[^a-z0-9]+", (text or "").lower()):
        if len(raw) < MIN_WORD:
            continue
        s = stem(raw)
        # A stem can be cut below the point where it still names anything ("uses"
        # to "us"), so fall back to the whole word rather than matching on a
        # fragment.
        if len(s) < 3:
            s = raw
        if s in STOP:
            continue
        out.add(s)
    return out

try:
    issues = json.loads(sys.stdin.read() or "[]")
    if not isinstance(issues, list):
        raise ValueError("expected a list of issues")
except Exception as exc:
    sys.stderr.write("the response did not parse (%s)\n" % exc)
    sys.exit(3)


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def milestone_of(it):
    ms = it.get("milestone")
    return (ms or {}).get("title") or ""


valid = [it for it in issues if isinstance(it, dict) and it.get("title")]
# An issue with NO milestone is treated as loose rather than as elsewhere. The gate
# requires one, so these are older issues predating it, and they belong with the pen
# for the grouping question.
pen = [it for it in valid if norm(milestone_of(it)) in ("", norm(catch_all))]
elsewhere = [it for it in valid if it not in pen]

target = words(like)
scored = []
for it in pen:
    shared = target & words(it["title"])
    if shared:
        scored.append((len(shared), it.get("number", 0), it["title"], sorted(shared)))

# The same overlap bar, asked of a different question. An issue already attached to a
# feature is not a sibling to group with, it is a warning that this work may already
# be filed, so it is reported and counted on its own line and never folded into the
# sibling count that the "2 or more" rule consumes.
dups = []
for it in elsewhere:
    shared = target & words(it["title"])
    if len(shared) >= 2:
        dups.append((len(shared), it.get("number", 0), it["title"],
                     milestone_of(it), sorted(shared)))
dups.sort(key=lambda r: (-r[0], -r[1]))

# Ranked by shared words, then by issue number descending so the newest of an equal
# pair comes first. A collection read from anywhere carries no order unless the read
# declares one (L343).
scored.sort(key=lambda r: (-r[0], -r[1]))

# The overlap RANKS and LIMITS. It does not rule (claude-config#265).
#
# It used to split the list into SIBLING and WEAK-MATCH at two shared words, and derive
# a SIBLING-COUNT that the "2 or more issues" rule then consumed. That number was wrong
# three times on the day it was written, always the same way, claiming a cluster that
# was not there: ten false siblings against bidspoke because "alert", "drop", "time"
# and "call" are generic in that vocabulary, then two more here on "issue", "open" and
# "already". Each fix excluded the words that exposed it, which is the tell: the next
# repo has its own generic words and nothing here can know them.
#
# Whatever reads this can judge relatedness far better than word counting can, because
# it can read the titles. So the score orders the shortlist and nothing else, and the
# count the threshold consumes has to be one a reader affirmed. This extends the
# refusal at the top of this file, which already declines to rule on eligibility, to
# relatedness itself.
# (No apostrophes anywhere below: this python is embedded in a single quoted shell
# string, so one would close the string and leave the file unparseable.)
candidates = scored

# Announced BEFORE anything derived from the read, so a reader who stops at the first
# line still learns the answer rests on a subset. A count landing exactly on the limit
# warns when nothing was actually lost, which is the safe direction: a needless warning
# costs a glance, a silent subset costs the answer.
if len(valid) >= limit:
    print("READ-TRUNCATED %d issues came back at the limit of %d, so this saw a SUBSET "
          "of the backlog and every count below is about that subset only. Re-run with "
          "--limit above %d." % (len(valid), limit, limit))
print("HOLDING-PEN %s open=%d" % (catch_all, len(pen)))
for score, num, title, shared in candidates[:show_max]:
    print("CANDIDATE %d #%s %s [shares: %s]" % (score, num, title, ", ".join(shared)))
if len(candidates) > show_max:
    print("CANDIDATE-TRUNCATED %d of %d shown" % (show_max, len(candidates)))
for score, num, title, ms, shared in dups[:show_max]:
    print("DUPLICATE-RISK %d #%s %s [in: %s] [shares: %s]"
          % (score, num, title, ms, ", ".join(shared)))
if len(dups) > show_max:
    print("DUPLICATE-TRUNCATED %d of %d shown" % (show_max, len(dups)))
# How many were SHOWN, which is not how many are related. Named so that nothing can
# read it as the second: the count the "2 or more issues" rule consumes is one the
# reader states after reading the titles, and passes to ensure-milestone.sh itself.
print("CANDIDATE-COUNT %d shown, which is NOT a count of related issues: read the "
      "titles and decide" % len(candidates))
print("DUPLICATE-COUNT %d" % len(dups))
' "$like" "$CATCH_ALL" "$show_max" "$limit" 2>"$gh_err")"
irc=$?
if [[ $irc -ne 0 ]]; then
  echo "Could not read the HOLDING PEN \"$CATCH_ALL\" in $repo: $(tr '\n' ' ' <"$gh_err")" >&2
  exit 6
fi

# --- report ---------------------------------------------------------------
milestone_count="$(printf '%s\n' "$milestones_out" | awk '/^MILESTONE-COUNT /{print $2}')"
candidate_count="$(printf '%s\n' "$siblings_out" | awk '/^CANDIDATE-COUNT /{print $2}')"

# Every candidate is REPORTED, whatever it scored. The caller may recognise a relation
# the word overlap cannot see, and it may reject one the overlap liked; both are its
# job rather than this script's (claude-config#265).
if [[ "${milestone_count:-0}" -eq 0 && "${candidate_count:-0}" -eq 0 ]]; then
  echo "NO-CANDIDATES $repo has no open milestone other than \"$CATCH_ALL\", and nothing in the pen shares words with this idea."
  exit 1
fi

echo "CANDIDATES-FOR $repo"
printf '%s\n' "$milestones_out"
printf '%s\n' "$siblings_out"
exit 0
