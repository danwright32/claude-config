#!/usr/bin/env bash
# Tests for lib/draft-edit-diff.py (claude-config#3554): pairing each Slack draft a session saved
# with the post Dan made after it, and tallying the kinds of edit between the two.
#
# The records come from draft-edit-fixtures/build.py, whose message text, names and ids are all
# invented. Nothing here reads a real session record.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/lib/draft-edit-diff.py"
BUILD="$DIR/draft-edit-fixtures/build.py"
WORK="$(mktemp -d)"
# Folders are shut on purpose below, so they are opened again before the throwaway tree is removed.
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
pass=0; fail=0
check(){ if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:900}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected NOT to contain: $2"; echo "  actual: ${3:0:900}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '${3:0:300}')"; fi; }

ME=U0FIXTUREA
fixture(){ mkdir -p "$WORK/$1/project" && python3 -B "$BUILD" "$WORK/$1/project" "$1"; }
# HOME is a folder of this suite's, so the reader finds no decisions of Dan's own to leave a kind out by.
run(){ local which="$1"; shift; HOME="$WORK/user" python3 -B "$TOOL" --records "$WORK/$which" --author "$ME" "$@" 2>&1; }
for f in basics recurring lopsided few unknown; do fixture "$f" || { echo "FAIL: fixture $f could not be built"; fail=$((fail + 1)); }; done

# --- pairing -------------------------------------------------------------------------------------
out="$(run basics)"; rc=$?
check_eq "basics: the run succeeds" "0" "$rc"
check "basics: draft calls are counted once, though a resumed session and a request copy repeat them" "draft calls: 9 (saved: 7)" "$out"
check "basics: five pairs, one per thread" "pairs: 5 in 5 threads" "$out"
check "basics: a draft nothing read back after is left out and counted" "drafts with no post read back after them: 1" "$out"
check "basics: a draft replaced by a later one before any post is left out and counted" "drafts replaced by a later draft: 1" "$out"
check "basics: a post with no saved draft before it is left out and counted (a draft never saved is no draft)" "posts with no draft before them: 3" "$out"
check "basics: formatting, bullets, links, spacing and case are set aside" "sent as drafted: 2 of 5 pairs" "$out"
check "basics: heavily rewritten is the one post that shares nothing with its draft" "heavily rewritten: 1 of 5 pairs" "$out"
check "basics: figures cut rests on one pair and is too thin" "figures cut: 1 of 5 pairs, in 1 thread: too thin to offer a rule" "$out"
check "basics: the ask reworded" "the ask reworded: 1 of 5 pairs" "$out"
check "basics: the opening changed, and the heavily rewritten pair is not counted under it" "the opening changed: 1 of 5 pairs" "$out"
check "basics: length cut, and the heavily rewritten pair is not counted under it" "length cut: 2 of 5 pairs" "$out"
check "basics: how many pairs were kept out of the four kinds is printed" "kept out of the four kinds below and of the floor, as heavily rewritten: 1" "$out"
check "basics: the floor is stated beside a thin kind" "at least 10 pairs in at least 3 threads" "$out"
check_not "basics: no message text without the flag (draft)" "harbour" "$out"
check_not "basics: no message text without the flag (sent)" "fenders" "$out"
check_not "basics: no author name" "Ada" "$out"
check_not "basics: no channel id" "C0FIXTURE" "$out"

# The author by display name, whatever its case.
out="$(HOME="$WORK/user" python3 -B "$TOOL" --records "$WORK/basics" --author "ada example" 2>&1)"
check "the author can be named as Slack shows them" "pairs: 5 in 5 threads" "$out"
# Somebody else's posts are never paired with a draft.
out="$(HOME="$WORK/user" python3 -B "$TOOL" --records "$WORK/basics" --author "U0FIXTUREZ" 2>&1)"
check "an author with no posts pairs nothing" "pairs: 0" "$out"

# --- the floor -----------------------------------------------------------------------------------
out="$(run recurring)"
check "recurring: twelve pairs in three threads is recurring" "figures cut: 12 of 12 pairs, in 3 threads: recurring" "$out"
check "recurring: length cut too" "length cut: 12 of 12 pairs, in 3 threads: recurring" "$out"
check_not "recurring: still no message text without the flag" "Gauge" "$out"
out="$(run lopsided)"
check "lopsided: twelve pairs in two threads is too thin" "figures cut: 12 of 12 pairs, in 2 threads: too thin to offer a rule" "$out"
out="$(run few)"
check "few: nine pairs in three threads is too thin" "figures cut: 9 of 9 pairs, in 3 threads: too thin to offer a rule" "$out"

# --- a post that is not an edit of its draft (review M2) --------------------------------------------
# A draft Dan never sent, and a post of his about something else afterwards. Such a pair is heavily
# rewritten, and it is in none of the four kinds, so it can neither reach the floor nor be the example.
for f in strays late_strays few_strays tail_stray; do fixture "$f" || { echo "FAIL: fixture $f could not be built"; fail=$((fail + 1)); }; done
out="$(run strays)"
check "strays: every pair is heavily rewritten" "heavily rewritten: 12 of 12 pairs" "$out"
check "strays: how many were kept out of the four kinds is printed" "kept out of the four kinds below and of the floor, as heavily rewritten: 12" "$out"
for kind in "figures cut" "length cut" "the ask reworded" "the opening changed"; do
  check "strays: none is counted as $kind" "$kind: 0 of 12 pairs, in 0 threads: too thin to offer a rule" "$out"
done
check_not "strays: so no kind is recurring" "recurring" "$out"
check_not "strays: and no example is shown" "Example for" "$(run strays --examples)"
out="$(run few_strays)"
check "few strays: three strays do not lift nine edits over the floor" "figures cut: 9 of 12 pairs, in 3 threads: too thin to offer a rule" "$out"
out="$(run tail_stray --examples)"
check "tail stray: twelve edits are recurring beside one stray" "figures cut: 12 of 13 pairs, in 3 threads: recurring" "$out"
check "tail stray: an example is shown" "Example for figures cut" "$out"
check_not "tail stray: and the stray, the latest pair of all, is never it" "ferry" "$out"
# A post more than an hour after the draft before it is not paired with it at all. The hour is a
# setting, chosen from the work MacBook's pairs of 2026-11-27: 173 of 184 posts came within it.
out="$(run late_strays)"
check "late strays: a post thirty days after its draft makes no pair" "pairs: 0 in 0 threads" "$out"
check "late strays: and is counted as left out, with the limit named and the drafts counted" "posts more than 60 minutes after the draft before them: 12 (drafts: 12)" "$out"
check "late strays: those drafts are not also counted as never read back" "drafts with no post read back after them: 0" "$out"
check "strays within the half hour are inside the limit" "posts more than 60 minutes after the draft before them: 0 (drafts: 0)" "$(run strays)"
for f in hour_inside hour_outside; do fixture "$f" || { echo "FAIL: fixture $f could not be built"; fail=$((fail + 1)); }; done
check "a second short of the hour: paired" "pairs: 12 in 3 threads" "$(run hour_inside)"
check "a fraction of a second past the hour: not paired" "posts more than 60 minutes after the draft before them: 12 (drafts: 12)" "$(run hour_outside)"

# --- one example pair per kind, only when asked ----------------------------------------------------
out="$(run recurring --examples)"
check "examples: the kind is named over its pair" "Example for figures cut" "$out"
check "examples: the draft is shown" "against 38, 52 and 60 last week" "$out"
check "examples: what was sent is shown" "read 57 at noon and 63 at dusk." "$out"
check_eq "examples: one pair per kind, never more" "1" "$(printf '%s\n' "$out" | grep -c '^Example for figures cut')"
out="$(run lopsided --examples)"
check_not "examples: a kind under the floor shows no message text" "Gauge" "$out"
out="$(run recurring --examples --skip "figures cut")"
check "skip: a kind decided before is said as that" "figures cut: 12 of 12 pairs, in 3 threads: decided before, not offered" "$out"
check_not "skip: and shows no example" "Example for figures cut" "$out"
check "skip: the others still show theirs" "Example for length cut" "$out"
out="$(run recurring --skip "no such kind")"; rc=$?
check_eq "skip: a kind that does not exist is refused" "2" "$rc"
check "skip: and the kinds are named" "figures cut" "$out"

# --- failure paths ---------------------------------------------------------------------------------
out="$(HOME="$WORK/user" python3 -B "$TOOL" --records "$WORK/basics" 2>&1)"; rc=$?
check_eq "no author: refused" "2" "$rc"
check "no author: says what to pass" "--author" "$out"
out="$(HOME="$WORK/user" python3 -B "$TOOL" --records "$WORK/nowhere" --author "$ME" 2>&1)"; rc=$?
check_eq "no records folder: refused, never a clean zero" "3" "$rc"
check "no records folder: said" "could not be read" "$out"
if [ "$(id -u)" != 0 ]; then
  # A folder it cannot list: said and counted beside what it did read, and a failure when it is all there was.
  mkdir -p "$WORK/shut/closed" "$WORK/partly/closed" "$WORK/partly/project"
  python3 -B "$BUILD" "$WORK/partly/project" basics
  chmod 000 "$WORK/shut/closed" "$WORK/partly/closed"
  out="$(run shut)"; rc=$?
  check_eq "a records folder whose only folder is shut: refused, never a clean zero" "3" "$rc"
  check "and said as nothing measured" "nothing was measured" "$out"
  out="$(run partly)"; rc=$?
  check_eq "a shut folder beside readable records: measured" "0" "$rc"
  check "and the shut folder is counted" "folders that could not be read: 1" "$out"
  check "and said to be in none of the counts" "in none of the counts below" "$out"
  chmod 755 "$WORK/shut/closed" "$WORK/partly/closed"
fi
mkdir -p "$WORK/empty"
out="$(run empty)"; rc=$?
check_eq "records with no draft in them: measured, and zero" "0" "$rc"
check "records with no draft in them: the zero is said as nothing to compare, never as no edits" "No saved draft is in these records" "$out"
check_not "records with drafts in them never say so" "No saved draft" "$(run basics)"
out="$(run unknown)"; rc=$?
check_eq "a layout it cannot read is a failure, never zero pairs" "4" "$rc"
check "a layout it cannot read is counted" "read results in a layout this cannot read: 1" "$out"
check "and said as nothing measured" "Nothing was measured" "$out"
check_not "and none of its text is printed" "lock gates" "$out"
out="$(run unknown --shapes)"
check "shapes: says how many results it could not read" "in a layout this cannot read: 1" "$out"
check "shapes: names the result's own fields" "result field messages: 1" "$out"
check_not "shapes: prints no message text" "lock gates" "$out"
out="$(run basics --shapes)"
check "shapes: counts each heading it knows" "thread parent headings: 6" "$out"
check_not "shapes: prints no message text for a layout it can read" "harbour" "$out"

# --- where the TEXT of a message sits (review M1) ------------------------------------------------------
# Every heading, From line and Message TS line below is one the reader knows. Only the place of the
# text differs, and each of these twelve drafts was posted word for word, so any edit counted is false.
for f in wordforword body_first trailing labelled split some_labelled some_wordless; do fixture "$f" || { echo "FAIL: fixture $f could not be built"; fail=$((fail + 1)); }; done
out="$(run wordforword)"; rc=$?
check_eq "word for word, in the layout this knows: measured" "0" "$rc"
check "word for word: twelve of twelve are sent as drafted" "sent as drafted: 12 of 12 pairs" "$out"
check "word for word: every message found has its text" "messages found in them: 15 (no text under the Message TS line: 0;" "$out"
out="$(run body_first)"; rc=$?
check_eq "body first: text above the Message TS line is a failure, never a count" "4" "$rc"
check "body first: said as nothing measured" "Nothing was measured" "$out"
check "body first: with how many messages had no text" "no text under the Message TS line: 15" "$out"
check_not "body first: no kind is called recurring from text it did not read" "recurring" "$out"
check_not "body first: and no pair is counted" "pairs:" "$out"
check_not "body first: no example is shown either" "Example for" "$(run body_first --examples)"
out="$(run body_first --shapes)"
check "shapes: counts the lines of text under a Message TS line" "lines of text under a Message TS line: 0" "$out"
check "shapes: counts the lines above it that are neither From nor Time" "lines above a Message TS line that are neither From nor Time: 15" "$out"
check "shapes: counts the messages with no text" "messages with no text under the Message TS line: 15" "$out"
check_not "shapes: prints none of that text" "Gauge" "$out"
out="$(run wordforword --shapes)"
check "shapes: in the layout this knows, one line of text under each Message TS line" "lines of text under a Message TS line: 15" "$out"
check "shapes: and none above it" "lines above a Message TS line that are neither From nor Time: 0" "$out"
out="$(run labelled)"; rc=$?
check_eq "labelled: a label line nobody measured under every text is a failure, never twelve edits" "4" "$rc"
check "labelled: said as nothing measured" "Nothing was measured" "$out"
check "labelled: with how many messages end that way" "last line shaped like a label: 15" "$out"
check_not "labelled: and no pair is counted" "pairs:" "$out"
out="$(run labelled --shapes)"
check "shapes: a label from the fixed list is named, with where it sits and its count" "label lines last under a Message TS line, Attachments: 15" "$out"
check_not "shapes: and nothing of the message under it is printed" "Gauge" "$out"
out="$(run split)"; rc=$?
check_eq "split: text above the line and a label under it is a failure" "4" "$rc"
check "split: said as nothing measured" "Nothing was measured" "$out"
SET_ASIDE_FOR_LABEL="pairs whose post begins or ends in a line shaped like a label that its draft does not hold there"
out="$(run some_labelled)"; rc=$?
check_eq "some labelled: a label under a few messages is measured" "0" "$rc"
check "some labelled: those pairs are set aside and counted" "$SET_ASIDE_FOR_LABEL: 3" "$out"
check "some labelled: and the rest are read as they were sent" "sent as drafted: 9 of 9 pairs" "$out"

# --- a line of the connector's own RIGHT UNDER the Message TS line (second review, M2) ---------------------
# The same twelve word for word posts, each with a label line between its Message TS line and its text.
# Read as his words, that line made every opening look changed, and a rule was offered from it.
for f in first_label some_first_label above most_wordless unlisted own_drafted own_added; do fixture "$f" || { echo "FAIL: fixture $f could not be built"; fail=$((fail + 1)); }; done
out="$(run first_label)"; rc=$?
check_eq "first label: a label line right under every Message TS line is a failure, never twelve changed openings" "4" "$rc"
check "first label: said as nothing measured, with the reason" "Nothing was measured: most of the messages found begin with a line shaped like a label" "$out"
check "first label: with how many messages begin that way" "first line shaped like a label: 15" "$out"
check_not "first label: no kind is called recurring" "recurring" "$out"
check_not "first label: and no pair is counted" "pairs:" "$out"
check_not "first label: no example is shown either" "Example for" "$(run first_label --examples)"
out="$(run first_label --shapes)"
check "shapes: a label line is said to be first under its Message TS line" "label lines first under a Message TS line, Thread TS: 15" "$out"
check "shapes: the messages that begin with one are counted" "messages whose first line is shaped like a label: 15" "$out"
check "shapes: apart from the messages that end in one" "messages whose last line is shaped like a label: 0" "$out"
out="$(run labelled --shapes)"
check "shapes: and the other way about when the label is under the text" "messages whose first line is shaped like a label: 0" "$out"
out="$(run some_first_label)"; rc=$?
check_eq "some first label: a label over the text of a few messages is measured" "0" "$rc"
check "some first label: those pairs are set aside and counted" "$SET_ASIDE_FOR_LABEL: 3" "$out"
check "some first label: and the rest are read as they were sent" "sent as drafted: 9 of 9 pairs" "$out"
check "some first label: so no opening is counted as changed" "the opening changed: 0 of 9 pairs" "$out"
# His own line shaped like a label (second review, S3). A line the draft holds at the same end is his.
out="$(run own_drafted)"; rc=$?
check_eq "own lines the draft holds: measured" "0" "$rc"
check "own lines the draft holds: no pair is set aside for them" "$SET_ASIDE_FOR_LABEL: 0" "$out"
check "own lines the draft holds: all twelve are read as sent" "sent as drafted: 12 of 12 pairs" "$out"
out="$(run own_added)"
check "own lines he added by hand: set aside, since nothing can tell them from the connector's" "$SET_ASIDE_FOR_LABEL: 6" "$out"
check "own lines he added by hand: the other six are read as sent" "sent as drafted: 6 of 6 pairs" "$out"
# The two exits for text that is somewhere else, each reached with text in SOME messages (second review, S1).
out="$(run most_wordless)"; rc=$?
check_eq "most wordless: most messages with no text is a failure, though some have it" "4" "$rc"
check "most wordless: said with its own reason" "Nothing was measured: most of the messages found have no text under their Message TS line" "$out"
check "most wordless: with the count" "messages found in them: 33 (no text under the Message TS line: 18;" "$out"
check_not "most wordless: and no pair is counted" "pairs:" "$out"
out="$(run above)"; rc=$?
check_eq "above: a line nobody measured above most Message TS lines is a failure, though the text is in place" "4" "$rc"
check "above: said with its own reason" "Nothing was measured: most of the messages found hold a line above their Message TS line" "$out"
check "above: with the count" "a line above it that is neither From nor Time: 15" "$out"
check_not "above: and no pair is counted" "pairs:" "$out"
# A label that is in no fixed list is counted by its length and never printed (second review, S2).
out="$(run unlisted --shapes)"
check "unlisted: a label in no list is counted by its length, under the text" "label lines last under a Message TS line, not a known name, of 12 characters: 15" "$out"
check "unlisted: and above the Message TS line" "label lines above a Message TS line, not a known name, of 11 characters: 15" "$out"
check_not "unlisted: its name is never printed" "Harbour" "$out"
check_not "unlisted: nor the one above" "Quay" "$out"
check_not "unlisted: nor in the default run" "Harbour" "$(run unlisted)"

# --- only the field that holds messages is read (second review, M3) ---------------------------------------
# The same twelve word for word posts. The result's other fields hold text, which was joined onto the
# last message of each read and counted as his words.
for f in pagination no_messages_field odd_id other_mentions bands; do fixture "$f" || { echo "FAIL: fixture $f could not be built"; fail=$((fail + 1)); }; done
out="$(run pagination)"; rc=$?
check_eq "pagination: text in the result's other fields is measured" "0" "$rc"
check "pagination: and is no part of any message, so all twelve are read as sent" "sent as drafted: 12 of 12 pairs" "$out"
out="$(run pagination --shapes)"
check "shapes: one line of text under each Message TS line, and none from another field" "lines of text under a Message TS line: 15" "$out"
check "shapes: a listed field that holds text is counted" "result field pagination_info, holding text: 3" "$out"
check "shapes: and another" "result field next_cursor, holding text: 3" "$out"
check "shapes: a field in no list that holds text is counted by its length" "result fields not in the fixed list, holding text, of 29 characters: 3" "$out"
check_not "shapes: a field that is empty is not counted as holding text" "result field pagination, holding text" "$out"
check_not "shapes: none of the pagination text is printed" "lighthouse" "$out"
check_not "shapes: nor the cursor" "bGlnaHRob3VzZQ" "$out"
check_not "shapes: nor the key in no list" "keeper" "$out"
out="$(run no_messages_field)"; rc=$?
check_eq "no messages field: a result with its text under another key is a failure, never read by guess" "4" "$rc"
check "no messages field: counted as a layout this cannot read" "read results in a layout this cannot read: 1" "$out"
check "shapes: and counted under its own name" "read results whose JSON object has no messages string: 1" "$(run no_messages_field --shapes)"
# A tool_result whose tool_use_id is no string is passed over, never a crash (second review, S8).
out="$(run odd_id)"; rc=$?
check_eq "odd id: a result whose call id is a list does not stop the run" "0" "$rc"
check_not "odd id: with no traceback" "Traceback" "$out"
check "odd id: and the pair beside it is read" "sent as drafted: 1 of 1 pair" "$out"
# A channel, a group and a here mention with a name added are the same mention (second review, S5).
out="$(run other_mentions)"
check "other mentions: each draft posted word for word is sent as drafted" "sent as drafted: 3 of 3 pairs" "$out"
check "other mentions: and no opening is counted as changed" "the opening changed: 0 of 3 pairs" "$out"

# --- pairs by how like their draft they are (second review, the unexplained gap) --------------------------
# Ten drafts of fifty words, each posted with a known number of words swapped: 0, 1, 2, 3, 5, 6, 10, 11,
# 15 and 16, so the likeness is 1, 0.98, 0.96, 0.94, 0.90, 0.88, 0.80, 0.78, 0.70 and 0.68.
out="$(run bands --likeness)"; rc=$?
check_eq "likeness: the run succeeds" "0" "$rc"
check "likeness: the pairs it is counted over" "pairs by how like their draft they are: 10" "$out"
check "likeness: the same once formatting is set aside" "  the same once formatting is set aside: 1" "$out"
check "likeness: 0.98 itself is in the top band" "  not the same, 0.98 and over: 1" "$out"
check "likeness: 0.96" "  0.95 to under 0.98: 1" "$out"
check "likeness: 0.94, and 0.90 itself" "  0.90 to under 0.95: 2" "$out"
check "likeness: 0.88, and 0.80 itself" "  0.80 to under 0.90: 2" "$out"
check "likeness: 0.78, and 0.70 itself, which is not heavily rewritten" "  0.70 to under 0.80: 2" "$out"
check "likeness: 0.68 is heavily rewritten" "  under 0.70, heavily rewritten: 1" "$out"
check "likeness: the bottom band is the count the default run calls heavily rewritten" "heavily rewritten: 1 of 10 pairs" "$out"
check "likeness: and the top line is the count it calls sent as drafted" "sent as drafted: 1 of 10 pairs" "$out"
check "likeness: posts that were the last message of their read are counted, with how many of them were sent as drafted" "posts that were the last message of the read their text was taken from: 8 of 10 pairs (sent as drafted: 1 of those 8, and 0 of the other 2)" "$out"
check_not "likeness: counts only, no message text" "tide" "$out"
check_not "likeness: nor a swapped word" "ebb" "$out"
check_not "likeness: nothing of it without the flag" "pairs by how like their draft" "$(run bands)"
check "the default run says how many pairs changed in none of the four kinds, at zero too" "changed, in none of the four kinds: 0 of 12 pairs" "$(run recurring)"

# --- the layout as it was measured on the work MacBook on 2026-11-27 (pull request 3848) ----------------
# Counts, field names and the punctuation of headings were measured there. Every word below is invented.
for f in concise concise_beside_detailed headings mentions second_post second_post_late; do fixture "$f" || { echo "FAIL: fixture $f could not be built"; fail=$((fail + 1)); }; done
# A Reactions line under a message's text is the connector's, and is no part of what he sent.
out="$(run trailing)"; rc=$?
check_eq "trailing: a Reactions line under every text is measured" "0" "$rc"
check "trailing: and the twelve are read as they were sent" "sent as drafted: 12 of 12 pairs" "$out"
check "trailing: no pair is set aside for it" "$SET_ASIDE_FOR_LABEL: 0" "$out"
out="$(run trailing --shapes)"
check "shapes: the Reactions lines set aside are counted" "Reactions lines under a message, set aside: 15" "$out"
check_not "shapes: and what follows the label is not printed" "thumbsup" "$out"
# The Time line between From and Message TS is passed over, and the section heading over a thread's
# replies holds no message: neither is text, and neither is an unknown heading.
out="$(run wordforword --shapes)"
check "shapes: the Time lines are counted, and are no text" "Time lines: 15" "$out"
check "shapes: the heading over a thread's replies is a section heading" "section headings with no message under them: 3" "$out"
check_not "shapes: and is no longer an unknown heading" "other headings" "$out"
# A concise read has no heading and no time: its own kind, counted, and never called unreadable.
out="$(run concise_beside_detailed)"; rc=$?
check_eq "concise: beside a detailed read the run is measured" "0" "$rc"
check "concise: the concise reads are counted as their own kind" "concise reads, which carry no time and cannot be paired: 2" "$out"
check_not "concise: and are not called a layout it cannot read" "in a layout this cannot read" "$out"
check "concise: the thread read back in the detailed layout is paired" "pairs: 1 in 1 thread" "$out"
check "concise: the two drafts read back only that way are counted as unread" "drafts with no post read back after them: 2" "$out"
check "concise: and said to be where a concise read came afterwards" "of those, in a place a concise read read back afterwards: 2" "$out"
check_not "concise: none of the concise text is printed" "lock gates" "$out"
check "concise: --shapes counts them too" "concise reads, which carry no time and cannot be paired: 2" "$(run concise_beside_detailed --shapes)"
out="$(run concise)"; rc=$?
check_eq "concise: with no other read, nothing was measured" "4" "$rc"
check "concise: and it says why" "every thread or channel read in the records is a concise read" "$out"
check_not "concise: with no pair counted" "pairs:" "$out"
check "a draft nothing read back at all is not counted there" "of those, in a place a concise read read back afterwards: 0" "$(run basics)"
# A channel heading with no name, or with an address and more fields in its brackets, still holds a message.
out="$(run headings)"
check "headings: all three messages are read, and paired" "pairs: 3 in 1 thread" "$out"
check "headings: each as it was sent" "sent as drafted: 3 of 3 pairs" "$out"
out="$(run headings --shapes)"
check "headings: each is counted as a channel message heading" "channel message headings: 3" "$out"
check_not "headings: none is an unknown heading" "other headings" "$out"
check_not "headings: and the address is not printed" "example.invalid" "$out"
# A mention is <@id> in a draft and <@id|name> in a read: the same mention.
out="$(run mentions)"
check "mentions: a draft posted word for word is sent as drafted" "sent as drafted: 1 of 1 pair" "$out"
check "mentions: and its opening is not counted as changed" "the opening changed: 0 of 1 pair" "$out"
# The first post after a draft takes it. When a later one is more like the draft, that is counted.
out="$(run second_post)"
check "second post: the draft is paired with the first post after it" "heavily rewritten: 1 of 1 pair" "$out"
check "second post: and the later post that is more like the draft is counted" "of those, more like that draft than the post it was paired with: 1" "$out"
check "no such post in the basics" "of those, more like that draft than the post it was paired with: 0" "$(run basics)"
# A post past the hour could never have taken that draft, so it is no sign the pair made was wrong.
out="$(run second_post_late)"
check "late second post: the draft is still paired with the first post after it" "heavily rewritten: 1 of 1 pair" "$out"
check "late second post: one two hours after the draft is not counted as more like it" "of those, more like that draft than the post it was paired with: 0" "$out"
# --differences: what one more thing set aside would make a changed pair the same. Six guesses at
# what a read result adds or writes another way, none of them measured, and one real edit.
fixture differences || { echo "FAIL: fixture differences could not be built"; fail=$((fail + 1)); }
out="$(run differences --differences)"; rc=$?
check_eq "differences: the run succeeds" "0" "$rc"
check "differences: the pairs it is counted over" "pairs changed but not heavily rewritten: 7" "$out"
check "differences: other words inside a link's angle brackets" "the same once what is inside angle brackets is set aside (a mention, a group or a link with a name added): 1" "$out"
check "differences: a link written two ways, and that link with other words" "the same once how a link is written is set aside: 2" "$out"
# For each kind, how many of its pairs one of those things could explain: what the skill tells Dan
# beside a proposed rule, so a count that may be no edit of his is never put to him bare (M4).
check "differences: of the pairs under a kind, how many one of those things could explain" "  the opening changed: 1 of 2 pairs" "$out"
check "differences: a kind with no pair says so" "  figures cut: 0 of 0 pairs" "$out"
check "the default run says how many pairs changed in none of the four kinds" "changed, in none of the four kinds: 4 of 7 pairs" "$out"
check "differences: punctuation alone" "the same once punctuation, symbols and spacing are set aside: 1" "$out"
check "differences: an emoji as a name against a character" "the same once emoji are set aside (a :name: or a character): 1" "$out"
check "differences: a trailing edited mark" "the same once a trailing (edited) is set aside: 1" "$out"
check "differences: a line under the text" "the same once the last line of what was read back is set aside: 1" "$out"
check "differences: no line over the text here" "the same once the first line of what was read back is set aside: 0" "$out"
check "differences: and the one real edit is none of these" "none of these: 1" "$out"
check_not "differences: counts only, no message text" "harbour" "$out"
check_not "differences: nothing of it without the flag" "How the pairs changed" "$(run differences)"
out="$(run some_wordless)"; rc=$?
check_eq "some wordless: a few posts with no words are measured" "0" "$rc"
check "some wordless: they are counted" "no text under the Message TS line: 3" "$out"
check "some wordless: and are no post at all, so none is a post with no draft before it" "posts with no draft before them: 0" "$out"
check "some wordless: the twelve are still read as sent" "sent as drafted: 12 of 12 pairs" "$out"

# --- the review's should fix points -----------------------------------------------------------------
for f in nearly broadcast broadcast_channel_first untimed keys; do fixture "$f" || { echo "FAIL: fixture $f could not be built"; fail=$((fail + 1)); }; done
# S10: the example is the pair most like its draft, which here is the sixth of twelve.
out="$(run nearly --examples)"
check "nearly: the example is the pair that keeps most of its draft, not simply the latest" "SENT: Gauge 1 read 41 at dawn, 57 at noon and 63 at dusk, against 38 and 60 last week." "$out"
check_eq "nearly: and it is still the only one for its kind" "1" "$(printf '%s\n' "$out" | grep -c '^Example for figures cut')"
# S6: a reply Slack also shows in the channel is one post, whichever read came first.
for f in broadcast broadcast_channel_first; do
  out="$(run "$f")"
  check "$f: one post read back twice makes one pair" "pairs: 1 in 1 thread" "$out"
  check "$f: and it is read as it was sent" "sent as drafted: 1 of 1 pair" "$out"
  check "$f: the unsent draft for the top of the channel is paired with nothing" "drafts with no post read back after them: 1" "$out"
done
# S7: a saved draft with no time on its record is in a count.
out="$(run untimed)"
check "untimed: a saved draft with no time on its record is counted as left out" "saved drafts with no time on their record: 1" "$out"
check "untimed: and makes no pair" "pairs: 0 in 0 threads" "$out"
check "timed drafts are never counted there" "saved drafts with no time on their record: 0" "$(run basics)"
# S1: --shapes prints a key of a read result only when it is in the fixed list.
out="$(run keys --shapes)"
check "keys: a field in the fixed list is named" "result field messages: 1" "$out"
check "keys: and so is another" "result field pagination: 1" "$out"
check "keys: a key not in the list is counted by its length alone" "result fields not in the fixed list, of 362 characters: 1" "$out"
check_not "keys: and none of its text is printed" "lock gates" "$out"
check_not "keys: not even its first word" "sentence" "$out"

# --- what Dan decided is read by the reader itself (review S2) ----------------------------------------
# The file is the one the skill's decisions.py writes; the skill's own suite has that program write it.
decided(){ mkdir -p "$WORK/$1/.claude/state/draft-edit-review" && printf '%s\n' "$2" > "$WORK/$1/.claude/state/draft-edit-review/decisions.json"; }
as(){ local who="$1" which="$2"; shift 2; HOME="$WORK/$who" python3 -B "$TOOL" --records "$WORK/$which" --author "$ME" "$@" 2>&1; }
decided declined '{"version": 1, "decisions": {"figures cut": {"decision": "never", "at": 1793631600}, "length cut": {"decision": "not-now", "at": 1793631600}}}'
out="$(as declined recurring --examples)"; rc=$?
check_eq "decided: a run beside decisions succeeds" "0" "$rc"
check "decided: a kind Dan said never to offer is not offered, with nothing passed" "figures cut: 12 of 12 pairs, in 3 threads: decided before, not offered" "$out"
check_not "decided: and shows no example" "Example for figures cut" "$out"
check "decided: a kind he put off is offered again" "length cut: 12 of 12 pairs, in 3 threads: recurring" "$out"
decided took '{"version": 1, "decisions": {"the opening changed": {"decision": "accepted", "at": 1793631600, "where": "no-ai-tells"}}}'
check "decided: a kind he accepted is not offered again either" "the opening changed: 12 of 12 pairs, in 3 threads: decided before, not offered" "$(as took recurring)"
decided torn '{"decisions": {"figures cut": '
out="$(as torn recurring --examples)"; rc=$?
check_eq "decided: decisions that are not JSON are refused, never read as nothing decided" "3" "$rc"
check "decided: said" "could not be read" "$out"
check_not "decided: and no kind is offered" "recurring" "$out"
check_not "decided: nor any message text shown" "Gauge" "$out"
decided odd '{"version": 1, "decisions": {"figures cut": {"decision": "perhaps", "at": 1793631600}}}'
out="$(as odd recurring)"; rc=$?
check_eq "decided: an answer decisions.py never writes is refused" "3" "$rc"
if [ "$(id -u)" != 0 ]; then
  decided barred '{"version": 1, "decisions": {}}'
  chmod 000 "$WORK/barred/.claude/state/draft-edit-review/decisions.json"
  out="$(as barred recurring)"; rc=$?
  check_eq "decided: decisions that cannot be opened are refused" "3" "$rc"
  check_not "decided: with no traceback" "Traceback" "$out"
  chmod 644 "$WORK/barred/.claude/state/draft-edit-review/decisions.json"
fi
check_eq "decided: --shapes does not need the decisions, so it still prints" "0" "$(as torn recurring --shapes >/dev/null 2>&1; echo $?)"

# --- no run without --examples prints a word of a message, a name, an id or a field's text ---------------
# Every fixture built above, in each way of running that shows no example, searched for the words the
# fixtures are written in. One line of output with any of them is a failure of the whole point.
WORDS='harbour|Harbour|Gauge|gauge|tide|ebb|ferry|slipway|lighthouse|keeper|berth|mooring|lock gates|pilot boat|buoy|Quay|timetable|thumbsup|Ada|Ben Sample|U0FIXTURE|C0FIXTURE|S0FIXTURE|T0FIXTURE|example\.invalid|bGlnaHRob3VzZQ|toolu_fixture'
leaks=0; runs=0
for f in "$WORK"/*/project; do
  which="$(basename "$(dirname "$f")")"
  for mode in "" "--shapes" "--differences --likeness"; do
    # shellcheck disable=SC2086
    out="$(run "$which" $mode)"
    runs=$((runs + 1))
    if printf '%s\n' "$out" | grep -qE "$WORDS"; then
      leaks=$((leaks + 1)); echo "  a word of a fixture was printed by: $which $mode"
    fi
  done
done
check_eq "no run without --examples prints a word of any fixture" "0" "$leaks"
check_eq "and that was looked for over every fixture in three ways of running (a count that cannot quietly shrink)" "1" "$([ "$runs" -ge 120 ] && echo 1 || echo 0)"
check_eq "the search does see a fixture's words when they are printed" "1" "$(run recurring --examples | grep -cE "$WORDS" | sed 's/^[1-9][0-9]*$/1/')"

# --- it writes nothing, and holds no way to -----------------------------------------------------------
before="$(cd "$WORK" && find . -type f -exec cksum {} + | sort)"
run basics --examples >/dev/null; run recurring --examples >/dev/null; run bands --likeness --differences >/dev/null
check_eq "a run leaves every file as it was and makes none" "$before" "$(cd "$WORK" && find . -type f -exec cksum {} + | sort)"
static="$(python3 -B - "$TOOL" <<'PY'
import ast, sys
sys.stdout.reconfigure(errors="replace")
ALLOWED = {"argparse", "collections", "datetime", "difflib", "html", "json", "os.path", "re", "sys"}
OS_MAY = {"path", "walk"}  # all it may use os for: every other use of the name is a finding
WRITES = {"write", "writelines", "dump", "FileType"}  # what the modules above could write through
try:
    with open(sys.argv[1], "rb") as f:
        tree = ast.parse(f.read().decode("utf-8", "replace"))
except (OSError, SyntaxError) as e:
    print("unreadable: %s" % e)
    sys.exit(0)
bad = []
nodes = list(ast.walk(tree))
os_read = {id(n.value) for n in nodes if isinstance(n, ast.Attribute) and isinstance(n.value, ast.Name)
           and n.value.id == "os" and n.attr in OS_MAY}
opened = {id(n.func) for n in nodes if isinstance(n, ast.Call)}
for node in nodes:
    if isinstance(node, ast.Name) and node.id == "os" and id(node) not in os_read:
        bad.append("uses os for more than os.path and os.walk")
    if isinstance(node, ast.Name) and node.id == "open" and id(node) not in opened:
        bad.append("hands open on where its mode cannot be read")
    if isinstance(node, ast.Import):
        bad += ["imports " + a.name for a in node.names if a.name not in ALLOWED]
    elif isinstance(node, ast.ImportFrom):
        bad.append("imports from " + str(node.module))
    elif isinstance(node, ast.Attribute) and node.attr in WRITES:
        bad.append("names " + node.attr)
    elif isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "open":
        mode = node.args[1] if len(node.args) > 1 else None
        if not (isinstance(mode, ast.Constant) and mode.value == "rb") or node.keywords:
            bad.append("opens a file in a mode that is not rb")
    elif isinstance(node, ast.Name) and node.id in ("exec", "eval", "compile", "__import__", "getattr", "setattr"):
        bad.append("names " + node.id)
print("clean" if not bad else "; ".join(sorted(set(bad))))
PY
)"
check_eq "its source imports only what is listed, uses os only for os.path and os.walk, and opens files only to read" "clean" "$static"

# The hand reading above knows only what it lists (L96), so the claim rests on the Slack drafts gate's
# own judgement, the one a session's command meets: handed a record that names Slack's posting
# address, the reader is let through, and a copy of it that can write a file or start a program is
# refused. The address is written in two pieces here, so this suite's own text does not name it.
GATE="$DIR/slack-drafts-only-gate.sh"
if [ ! -f "$GATE" ]; then
  fail=$((fail + 1)); echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite, so nothing judged whether the reader can act"
else
  export SLACK_GATE_CACHE_DIR="$WORK/gate-cache"
  mkdir -p "$WORK/gate/writes" "$WORK/gate/runs"
  printf '{"type":"user","message":"a record naming %s.%s"}\n' chat postMessage > "$WORK/gate/record.jsonl"
  python3 -B "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$WORK/gate/writes" draft-edit-diff.py >/dev/null 2>&1
  python3 -B "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$WORK/gate/runs" draft-edit-diff.py >/dev/null 2>&1
  printf '\n\ndef keep(text):\n    with open("kept.txt", "w") as f:\n        f.write(text)\n' >> "$WORK/gate/writes/draft-edit-diff.py"
  printf '\n\ndef start(text):\n    return os.system(text)\n' >> "$WORK/gate/runs/draft-edit-diff.py"
  check_eq "the copies the gate is asked about hold the reader's own text" "2" "$(( $(grep -c 'def pair_up' "$WORK/gate/writes/draft-edit-diff.py" 2>/dev/null || true) + $(grep -c 'def pair_up' "$WORK/gate/runs/draft-edit-diff.py" 2>/dev/null || true) ))"
  judged(){ # judged <script>: the gate's exit code for running it over the record
    python3 -c '
import json, sys
sys.stdout.reconfigure(errors="replace")
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d", "transcript_path": "/tmp/transcript.jsonl",
                  "cwd": sys.argv[2], "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1], "description": "d"}, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "python3 $1 --records $WORK/gate/record.jsonl --author x" "$WORK/gate" | bash "$GATE" >/dev/null 2>"$WORK/gate/err"
    echo $?
  }
  check_eq "the Slack drafts gate lets the reader run over a record naming the posting address" "0" "$(judged "$TOOL")"
  check_eq "and refuses a copy of it that can write a file" "2" "$(judged "$WORK/gate/writes/draft-edit-diff.py")"
  check "saying that is why" "can write a file" "$(cat "$WORK/gate/err" 2>/dev/null)"
  check_eq "and refuses a copy of it that can start a program" "2" "$(judged "$WORK/gate/runs/draft-edit-diff.py")"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
