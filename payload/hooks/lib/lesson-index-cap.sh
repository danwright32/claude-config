#!/usr/bin/env bash
# The ONE rule deciding whether a rendered lessons index line is too long (claude-config#370).
#
# It was written twice. payload/hooks/test-rule-file-budget.sh fails a push on an over-cap entry;
# over_cap_lesson_entries in claude-sync holds an over-cap lessons file back at send time, because
# a lesson is written in whatever project the session happens to be in and the push that would
# catch it happens in the config repo. Both were correct, and each read as correct on its own,
# which is exactly the condition L370 names: sharing the rule's DATA, here the cap, while copying
# the code that APPLIES it is not consolidation. A change to how the rule is applied lands in one
# copy and the other goes on answering the old question, with no symptom.
#
# The second copy existed for one reason: the budget hook carries a floor of 100 entries, so that a
# scan matching nothing cannot read as an index where every line is short (L98). That floor is
# right against the real index and makes the code unusable against a fixture holding one lesson, so
# here it is an ARGUMENT rather than baked in.
#
# The CAP ITSELF is deliberately NOT here. It lives in test-rule-file-budget.sh beside the two
# other thresholds its header explains, and claude-sync reads it out of that file. One number, one
# home, read by everybody who needs it.
#
# Sourced, never executed: it defines one function and runs nothing.

# Decide the over-cap entries in a rendered lessons index.
#
# Reads the index lines on STDIN, so the caller may hand it a file on disk (what the budget hook
# has) or a body rendered on the fly from LESSONS.md (what the send has), and the rule cannot see
# the difference.
#
# Prints a report, one fact per line, and the caller writes its own message from it, because the
# two sites speak to different people about different remedies (L11):
#
#   ENTRIES <count>              how many index entries were measured at all
#   LONGEST <length> <Lnnn>      the longest line seen, or "LONGEST 0 -" when there were none
#   UNDERFLOOR <count> <floor>   present ONLY when fewer entries were found than the caller expects
#   OVER <Lnnn> <length>         one per over-cap entry, in the order they appear
#
# A cap that is not a whole number is REFUSED (returns 2, prints nothing on stdout), never treated
# as no cap. claude-sync's reader can answer "UNREADABLE:<path>" when the hook carries no cap line,
# and a caller that passed that straight in and got back a clean report would have a check that is
# inert while reading as active, which is the state that hook's own comment was added to prevent.
lesson_index_cap_scan(){   # $1 = cap in characters, $2 = fewest entries the caller expects
  local cap="${1-}" floor="${2-0}"
  case "$cap" in ''|*[!0-9]*)
    echo "lesson_index_cap_scan: the cap must be a whole number of characters, got '$cap'. Nothing was measured." >&2
    return 2 ;;
  esac
  case "$floor" in ''|*[!0-9]*)
    echo "lesson_index_cap_scan: the entry floor must be a whole number, got '$floor'. Nothing was measured." >&2
    return 2 ;;
  esac
  # One awk over the stream. Length is counted the same way for every caller, which is the point:
  # the budget hook used to count in bash and the send in awk, so two locales could have given two
  # answers about one line with nothing anywhere comparing them.
  awk -v cap="$cap" -v floor="$floor" '
    /^- L[0-9]+\./ {
      entries++
      num = $0; sub(/^- /, "", num); sub(/\..*$/, "", num)
      len = length($0)
      if (len > longest) { longest = len; longest_num = num }
      if (len > cap) { over[++nover] = num " " len }
    }
    END {
      printf "ENTRIES %d\n", entries + 0
      printf "LONGEST %d %s\n", longest + 0, (longest_num == "" ? "-" : longest_num)
      if (entries + 0 < floor + 0) printf "UNDERFLOOR %d %d\n", entries + 0, floor + 0
      for (i = 1; i <= nover; i++) printf "OVER %s\n", over[i]
    }'
}
