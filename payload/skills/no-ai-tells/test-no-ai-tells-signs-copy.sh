#!/usr/bin/env bash
# Tests for signs-copy.sh, the one dated copy of the AI writing signs that lets a session skip reading
# the Wikipedia page again (claude-config#3480).
#
# On 2026-11-22 a check of a short email took nine reads of the page's source before any output, and
# nothing carried a read to the next session. Dan asked for one kept copy that expires, "so that way
# we get an updated list fairly regularly". The rule for when a copy may stand in for the page is code
# here rather than prose in the skill, because a rule that lives only in a prompt is a hope (L27).
#
# What this holds the script to:
#   1. no copy, and no folder, is reported as none, and the check writes nothing;
#   2. a whole copy within its age is offered as fresh, with the signs exactly as saved;
#   3. the age line is crossed both ways with the clock given to the script, never a sleep (L524),
#      and an expired copy is named with its read date;
#   4. a copy that did not reach "See also" is never offered as whole, however new;
#   5. a partial read never replaces a whole copy, fresh or expired (L5);
#   6. a copy whose record cannot be read is reported unusable, never fresh (L50);
#   7. a save that is refused leaves the copy as it was;
#   8. two saves at once leave one whole copy and no half written file;
#   9. the copy's default home is this Mac's own state folder, which the sync does not carry.
#
# NO_AI_TELLS_COPY_SCRIPT points the suite at another copy of the script, which is how a broken
# script is shown to fail. No network: the page is never fetched here.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${NO_AI_TELLS_COPY_SCRIPT:-$DIR/signs-copy.sh}"
SYNCED_TREES_LIB="$DIR/../../hooks/lib/synced-trees.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
holds() { # holds <text> <fixed words>
  case "$1" in *"$2"*) echo ok ;; *) echo "missing '$2' in: $1" ;; esac
}
lacks() { # lacks <text> <fixed words>
  case "$1" in *"$2"*) echo "still says '$2' in: $1" ;; *) echo ok ;; esac
}
is() { # is <actual> <expected>
  [ "$1" = "$2" ] && echo ok || echo "got '$1', expected '$2'"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/no-ai-tells-signs-copy.XXXXXXXX")" || {
  echo "FAIL: no scratch folder could be made"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
trap 'rm -rf "$TMP"' EXIT
# HOME and CLAUDE_HOME both point into scratch for every run, so no fallback in the script can reach
# this Mac's real copy.
FAKEHOME="$TMP/home"
mkdir -p "$FAKEHOME"

# run <copy folder> <now, epoch seconds> <args...>: the script with its folder and clock given.
run() {
  local d="$1" n="$2"; shift 2
  HOME="$FAKEHOME" CLAUDE_HOME="$FAKEHOME/.claude" NO_AI_TELLS_COPY_DIR="$d" NO_AI_TELLS_NOW="$n" bash "$SCRIPT" "$@" 2>&1
}
first_line() { printf '%s\n' "$1" | head -n 1; }

READ=1795000000          # 2026-11-18 6:06 AM ET
READ_ET="2026-11-18 6:06 AM ET"
days="$(awk -F= '/^SIGNS_COPY_MAX_AGE_DAYS=/ { print $2; exit }' "$SCRIPT" 2>/dev/null)"
case "$days" in
  ''|*[!0-9]*) check "the script holds its age limit in one SIGNS_COPY_MAX_AGE_DAYS line" "read '$days'"; days=7 ;;
  *) check "the script holds its age limit in one SIGNS_COPY_MAX_AGE_DAYS line" ok ;;
esac
LINE=$((days * 86400))

# The signs a session would have written. Its body carries lines shaped like the copy's own record,
# so a parser that read past the record into the signs would be caught.
SIGNS_A="$TMP/signs-a.md"
printf '%s\n' '## Language and tone' '- delve, tapestry, pivotal' 'read-epoch: 1' 'reached-see-also: yes' 'signs:' '## Style' '- the em dash habit' > "$SIGNS_A"
SIGNS_B="$TMP/signs-b.md"
printf '%s\n' '## Content' '- undue emphasis on significance' > "$SIGNS_B"

# ---- 1. no copy at all ----
D1="$TMP/c1/never-made"
out="$(run "$D1" "$READ" check)"; rc=$?
check "no folder: reported as none" "$(holds "$(first_line "$out")" "none:")"
check "no folder: exit 12" "$(is "$rc" 12)"
check "no folder: names where the copy would be" "$(holds "$out" "$D1/signs.md")"
check "no folder: the check made no folder (an inspection writes nothing)" "$([ ! -e "$D1" ] && echo ok || echo "the check created $D1")"
mkdir -p "$TMP/c1/empty"
out="$(run "$TMP/c1/empty" "$READ" check)"; rc=$?
check "empty folder: reported as none" "$(is "$rc" 12)"

# ---- 2. a whole copy within its age ----
D2="$TMP/c2"
out="$(run "$D2" "$READ" save --signs "$SIGNS_A" --parts 19 --reached-see-also yes --revision 1387041075)"; rc=$?
check "whole save: exit 0" "$(is "$rc" 0)"
check "whole save: says it saved" "$(holds "$(first_line "$out")" "saved:")"
check "whole save: the copy exists" "$([ -s "$D2/signs.md" ] && echo ok || echo "no $D2/signs.md")"
out="$(run "$D2" "$READ" check)"; rc=$?
check "fresh: first line names the copy" "$(is "$(first_line "$out")" "fresh: $D2/signs.md")"
check "fresh: exit 0" "$(is "$rc" 0)"
check "fresh: gives the read date in ET" "$(holds "$out" "$READ_ET")"
check "fresh: gives the revision" "$(holds "$out" "1387041075")"
body="$(awk 'f { print } /^signs:$/ && !f { f = 1 }' "$D2/signs.md")"
check "fresh: the signs are kept exactly as the session wrote them" "$(is "$body" "$(cat "$SIGNS_A")")"
check "the copy records the parts read" "$(holds "$(cat "$D2/signs.md")" "parts-read: 19")"
check "the copy records that See also was reached" "$(holds "$(cat "$D2/signs.md")" "reached-see-also: yes")"

# ---- 3. the age line, crossed both ways ----
out="$(run "$D2" "$((READ + LINE - 1))" check)"; rc=$?
check "one second before the line: still fresh" "$(is "$rc" 0)"
out="$(run "$D2" "$((READ + LINE))" check)"; rc=$?
check "at the line: expired" "$(holds "$(first_line "$out")" "expired: $D2/signs.md")"
check "at the line: exit 10" "$(is "$rc" 10)"
check "expired: names the read date in ET" "$(holds "$out" "read $READ_ET")"
out="$(run "$D2" "$((READ + LINE + 86400 * 30))" check)"; rc=$?
check "a month past the line: expired, not fresh" "$(is "$rc" 10)"
# The clock moved back: a copy read just now on a clock a little ahead is fine, one read well in the
# future is not a reading anybody can trust.
out="$(run "$D2" "$((READ - 30))" check)"; rc=$?
check "clock 30 seconds behind the read: still fresh" "$(is "$rc" 0)"
out="$(run "$D2" "$((READ - LINE))" check)"; rc=$?
check "clock a week behind the read: never fresh" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0 for a copy read in the future")"
check "clock a week behind the read: reported unusable" "$(holds "$(first_line "$out")" "unusable:")"

# ---- 4. a partial copy is never offered as whole ----
D4="$TMP/c4"
out="$(run "$D4" "$READ" save --signs "$SIGNS_B" --parts 6 --reached-see-also no)"; rc=$?
check "partial save with no copy before: saved" "$(is "$rc" 0)"
check "the partial copy records See also was not reached" "$(holds "$(cat "$D4/signs.md" 2>/dev/null)" "reached-see-also: no")"
out="$(run "$D4" "$READ" check)"; rc=$?
check "partial: reported as partial the moment it is saved" "$(holds "$(first_line "$out")" "partial: $D4/signs.md")"
check "partial: exit 11" "$(is "$rc" 11)"
check "partial: never says fresh" "$(lacks "$out" "fresh:")"
check "partial: the revision left out is recorded as unknown" "$(holds "$(cat "$D4/signs.md" 2>/dev/null)" "revision: unknown")"

# ---- 5. a partial read never replaces a whole copy ----
D5="$TMP/c5"
run "$D5" "$READ" save --signs "$SIGNS_A" --parts 19 --reached-see-also yes >/dev/null
before="$(cat "$D5/signs.md")"
out="$(run "$D5" "$((READ + 60))" save --signs "$SIGNS_B" --parts 3 --reached-see-also no)"; rc=$?
check "partial over a fresh whole copy: the whole copy is kept" "$(is "$(cat "$D5/signs.md")" "$before")"
check "partial over a fresh whole copy: says it kept it" "$(holds "$(first_line "$out")" "kept:")"
out="$(run "$D5" "$((READ + LINE + 3600))" save --signs "$SIGNS_B" --parts 3 --reached-see-also no)"; rc=$?
check "partial over an expired whole copy: the whole copy is kept" "$(is "$(cat "$D5/signs.md")" "$before")"
out="$(run "$D5" "$((READ + LINE + 3600))" check)"; rc=$?
check "after a refused partial, the old whole copy reads as expired" "$(is "$rc" 10)"
out="$(run "$D5" "$((READ + LINE + 3600))" save --signs "$SIGNS_B" --parts 19 --reached-see-also yes)"; rc=$?
out="$(run "$D5" "$((READ + LINE + 3600))" check)"; rc=$?
check "a new whole read replaces an expired copy and is fresh" "$(is "$rc" 0)"
body="$(awk 'f { print } /^signs:$/ && !f { f = 1 }' "$D5/signs.md")"
check "the new whole read's signs are the ones kept" "$(is "$body" "$(cat "$SIGNS_B")")"

# ---- 6. a copy whose record cannot be read ----
D6="$TMP/c6"; mkdir -p "$D6"
printf 'just some notes\n' > "$D6/signs.md"
out="$(run "$D6" "$READ" check)"; rc=$?
check "no record line: unusable" "$(holds "$(first_line "$out")" "unusable:")"
check "no record line: exit 13" "$(is "$rc" 13)"
sed 's/^read-epoch: .*/read-epoch: soon/' "$D2/signs.md" > "$D6/signs.md"
out="$(run "$D6" "$READ" check)"; rc=$?
check "a read time that is not a number: unusable, never fresh" "$(is "$rc" 13)"
sed 's/^parts-read: .*/parts-read: many/' "$D2/signs.md" > "$D6/signs.md"
out="$(run "$D6" "$READ" check)"; rc=$?
check "a parts count that is not a number: unusable" "$(is "$rc" 13)"
awk '{ print } /^signs:$/ { exit }' "$D2/signs.md" > "$D6/signs.md"
out="$(run "$D6" "$READ" check)"; rc=$?
check "a record with no signs under it: unusable" "$(is "$rc" 13)"

# ---- 7. a refused save leaves the copy as it was ----
D7="$TMP/c7"
run "$D7" "$READ" save --signs "$SIGNS_A" --parts 19 --reached-see-also yes >/dev/null
before="$(cat "$D7/signs.md")"
: > "$TMP/empty.md"
printf '  \n\n' > "$TMP/blank.md"
out="$(run "$D7" "$READ" save --signs "$TMP/missing.md" --parts 19 --reached-see-also yes)"; rc=$?
check "save from a missing file: refused" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0")"
out="$(run "$D7" "$READ" save --signs "$TMP/empty.md" --parts 19 --reached-see-also yes)"; rc=$?
check "save from an empty file: refused" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0")"
out="$(run "$D7" "$READ" save --signs "$TMP/blank.md" --parts 19 --reached-see-also yes)"; rc=$?
check "save from a file of blank lines: refused" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0")"
out="$(run "$D7" "$READ" save --signs "$SIGNS_B" --parts some --reached-see-also yes)"; rc=$?
check "save with a parts count that is not a number: refused" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0")"
out="$(run "$D7" "$READ" save --signs "$SIGNS_B" --parts 0 --reached-see-also yes)"; rc=$?
check "save with no parts read: refused" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0")"
out="$(run "$D7" "$READ" save --signs "$SIGNS_B" --parts 19 --reached-see-also maybe)"; rc=$?
check "save with See also neither yes nor no: refused" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0")"
out="$(run "$D7" "$READ" save --signs "$SIGNS_B" --parts 19)"; rc=$?
check "save that does not say whether See also was reached: refused" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0")"
out="$(run "$D7" "$READ" save --signs "$SIGNS_B" --parts 19 --reached-see-also yes --revision "$(printf '1\nreached-see-also: yes')")"; rc=$?
check "save with a revision over two lines: refused" "$([ "$rc" -ne 0 ] && echo ok || echo "exit 0")"
check "after every refused save, the copy is as it was" "$(is "$(cat "$D7/signs.md")" "$before")"
check "no refused save left a temporary file" "$(is "$(ls -A "$D7")" "signs.md")"
out="$(run "$D7" soon check)"; rc=$?
check "a clock that is not a number: refused" "$(is "$rc" 2)"
out="$(run "$D7" "$READ" peek)"; rc=$?
check "an unknown command: refused" "$(is "$rc" 2)"

# ---- 8. two saves at once leave one whole copy ----
# Each body is large enough that a write in place would be seen half done.
D8="$TMP/c8"
awk 'BEGIN { for (i = 0; i < 40000; i++) print "- sign A number " i }' > "$TMP/big-a.md"
awk 'BEGIN { for (i = 0; i < 40000; i++) print "- sign B number " i }' > "$TMP/big-b.md"
run "$D8" "$READ" save --signs "$TMP/big-a.md" --parts 19 --reached-see-also yes > "$TMP/save-a.out" &
pa=$!
run "$D8" "$READ" save --signs "$TMP/big-b.md" --parts 19 --reached-see-also yes > "$TMP/save-b.out" &
pb=$!
wait "$pa"; ra=$?
wait "$pb"; rb=$?
check "two saves at once: both finished" "$([ "$ra" -eq 0 ] && [ "$rb" -eq 0 ] && echo ok || echo "exits $ra and $rb")"
body="$(awk 'f { print } /^signs:$/ && !f { f = 1 }' "$D8/signs.md")"
if [ "$body" = "$(cat "$TMP/big-a.md")" ] || [ "$body" = "$(cat "$TMP/big-b.md")" ]; then
  check "two saves at once: the copy is exactly one of them, never a mix" ok
else
  check "two saves at once: the copy is exactly one of them, never a mix" "the copy holds $(printf '%s\n' "$body" | wc -l | tr -d ' ') lines matching neither"
fi
check "two saves at once: no temporary file left behind" "$(is "$(ls -A "$D8")" "signs.md")"
# Two saves at once rarely overlap long enough to show a write in place, so the rename is also proved
# directly: a save that renames a new file over the copy leaves a different file (inode) there, and a
# reader that had the old copy open keeps reading the old one whole. A write in place keeps the inode.
inode_before="$(ls -i "$D8/signs.md" | awk '{ print $1 }')"
run "$D8" "$READ" save --signs "$SIGNS_A" --parts 19 --reached-see-also yes >/dev/null
inode_after="$(ls -i "$D8/signs.md" | awk '{ print $1 }')"
check "a save replaces the copy by renaming a new file over it, never by writing in place" \
  "$([ -n "$inode_before" ] && [ "$inode_before" != "$inode_after" ] && echo ok || echo "inode $inode_before before and $inode_after after")"
out="$(run "$D8" "$READ" check)"; rc=$?
check "two saves at once: the result is fresh" "$(is "$rc" 0)"

# ---- 9. the default home is this Mac's state folder, which the sync does not carry ----
out="$(HOME="$FAKEHOME" CLAUDE_HOME="$FAKEHOME/.claude" NO_AI_TELLS_NOW="$READ" bash "$SCRIPT" check 2>&1)"; rc=$?
check "default: the copy lives under the config's state folder" "$(holds "$out" "$FAKEHOME/.claude/state/no-ai-tells/signs.md")"
out="$(env -u CLAUDE_HOME HOME="$FAKEHOME" NO_AI_TELLS_NOW="$READ" bash "$SCRIPT" check 2>&1)"; rc=$?
check "default with no CLAUDE_HOME: under ~/.claude/state" "$(holds "$out" "$FAKEHOME/.claude/state/no-ai-tells/signs.md")"
# The sync mirrors the trees synced-trees.sh lists (test-synced-trees.sh holds that list to
# claude-sync's own MIRROR_DIRS) plus the top level files CLAUDE.md imports. state/ must be neither.
if ( . "$SYNCED_TREES_LIB" ) 2>/dev/null; then
  trees="$( . "$SYNCED_TREES_LIB"; printf ' %s ' "${SYNCED_TREES[@]}" )"
  check "the sync's trees are read" "$(holds "$trees" " hooks ")"
  check "state is not a tree the sync carries" "$(lacks "$trees" " state ")"
else
  check "the sync's trees are read" "cannot source $SYNCED_TREES_LIB"
fi

# ---- control: the boundary checks above can fail ----
# A copy of the script whose limit is one day must call the seven day old copy expired; if the
# checks above passed whatever the limit, this would read fresh.
sed 's/^SIGNS_COPY_MAX_AGE_DAYS=.*/SIGNS_COPY_MAX_AGE_DAYS=1/' "$SCRIPT" > "$TMP/short-limit.sh"
out="$(HOME="$FAKEHOME" NO_AI_TELLS_COPY_DIR="$D2" NO_AI_TELLS_NOW="$((READ + 86400))" bash "$TMP/short-limit.sh" check 2>&1)"; rc=$?
check "control: a one day limit makes a day old copy expired" "$(is "$rc" 10)"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
