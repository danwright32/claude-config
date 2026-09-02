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
#   SIBLING <score> #<num> <title>           an open pen issue sharing words, best first
#   SIBLING-TRUNCATED <shown> of <found>     only when more were found than printed
#   SIBLING-COUNT <n>                        every sibling found, not just those shown
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
limit=300          # gh issue list defaults to 30, and one real pen held 82 open.
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
issues_raw="$(gh issue list --repo "$repo" --milestone "$CATCH_ALL" --state open \
  --limit "$limit" --json number,title 2>"$gh_err")"
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

target = words(like)
scored = []
for it in issues:
    if not isinstance(it, dict) or not it.get("title"):
        continue
    shared = target & words(it["title"])
    if shared:
        scored.append((len(shared), it.get("number", 0), it["title"], sorted(shared)))

# Ranked by shared words, then by issue number descending so the newest of an equal
# pair comes first. A collection read from anywhere carries no order unless the read
# declares one (L343).
scored.sort(key=lambda r: (-r[0], -r[1]))

print("HOLDING-PEN %s open=%d" % (catch_all, len(issues)))
for score, num, title, shared in scored[:show_max]:
    print("SIBLING %d #%s %s [shares: %s]" % (score, num, title, ", ".join(shared)))
if len(scored) > show_max:
    print("SIBLING-TRUNCATED %d of %d shown" % (show_max, len(scored)))
print("SIBLING-COUNT %d" % len(scored))
' "$like" "$CATCH_ALL" "$show_max" 2>"$gh_err")"
irc=$?
if [[ $irc -ne 0 ]]; then
  echo "Could not read the HOLDING PEN \"$CATCH_ALL\" in $repo: $(tr '\n' ' ' <"$gh_err")" >&2
  exit 6
fi

# --- report ---------------------------------------------------------------
milestone_count="$(printf '%s\n' "$milestones_out" | awk '/^MILESTONE-COUNT /{print $2}')"
sibling_count="$(printf '%s\n' "$siblings_out" | awk '/^SIBLING-COUNT /{print $2}')"

if [[ "${milestone_count:-0}" -eq 0 && "${sibling_count:-0}" -eq 0 ]]; then
  echo "NO-CANDIDATES $repo has no open milestone other than \"$CATCH_ALL\", and nothing in the pen shares words with this idea."
  exit 1
fi

echo "CANDIDATES-FOR $repo"
printf '%s\n' "$milestones_out"
printf '%s\n' "$siblings_out"
exit 0
