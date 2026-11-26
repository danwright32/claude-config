#!/usr/bin/env bash
# find-existing.sh: the open issues and pull requests that may already cover an item, for the
# orchestrate skill's intake (claude-config#3555).
#
#   find-existing.sh <owner/repo or a folder in the checkout> < item text
#
# A Slack alert somebody already filed, or a fix another session already has open as a pull
# request, was invisible to intake: the claim on an issue (claim-issue.sh) only ever runs for an item
# whose source is that issue. This is the look intake takes first, for every item whose source is
# not a GitHub issue.
#
# The match is NOT kept here. It is hooks/lib/match-open-issues.py's item mode, the one matcher the
# end of turn review also uses, so the two never drift into two rules (L263, L370). This script only
# finds it and turns any way it can stop into the could not look outcome.
#
# What it prints and how it exits:
#   0, nothing printed       it read the open issues and pull requests and none may cover the item
#   0, MAY ALREADY BE COVERED and one line per hit ("issue #N: title", "pull request #N: title
#                            (closes #M)" or "(names no issue)"), best first, at most three. It
#                            decides nothing: the orchestrating session reads each and judges.
#   0, READ ONLY THE NEWEST  a list filled the read limit, so older ones were not compared
#   2, COULD NOT LOOK: why   gh failed, gave something that is not a list, the repository has its
#                            issue tracker turned off, or the folder is not in a git repository.
#                            Never read as "nothing covers it".
set -uo pipefail

if [ $# -ne 1 ] || [ -z "${1:-}" ]; then
  echo "COULD NOT LOOK: usage: find-existing.sh <owner/repo or a folder in the checkout> < item text"
  exit 2
fi

# FIND_EXISTING_MATCHER is a test seam only, so the suite can see a crash and a missing matcher.
MATCHER="${FIND_EXISTING_MATCHER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/match-open-issues.py}"
if [ ! -f "$MATCHER" ]; then
  echo "COULD NOT LOOK: the matcher hooks/lib/match-open-issues.py is not beside this skill."
  exit 2
fi

python3 "$MATCHER" --item "$1"
rc=$?
case "$rc" in
  0) exit 0 ;;
  2) exit 2 ;;
  *)
    # A crash prints a traceback and no verdict, which must never read as "nothing covers it".
    echo "COULD NOT LOOK: the matcher stopped with exit $rc before it could answer."
    exit 2 ;;
esac
