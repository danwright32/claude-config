#!/usr/bin/env bash
# A comment, or a document, that quotes a measured number says when it was measured (#140, #145, #148).
# send-gate: scans hooks/run-all-tests.sh
#
# This scan was one section of tests/test-claude-sync.sh until claude-config#2033, and it is the
# only check in that suite that reads this repository's own files, so the scanners gate before a
# push ran that one section of it. That suite takes a machine wide lock, so that two of its runs
# never compete for the machine, and every full run holds the lock for minutes. Builders run a full
# suite just before they push, so on 2026-11-01 the section kept refusing on the lock while another
# builder's run held it, and all seven of the gate's refusals for time that day after #1997 (load
# averages 21 to 95) named only that section, running for 1 or 2 seconds, still waiting its turn.
# Here it takes no lock, needs none of that suite's prelude, and still runs before every push.
#
# Do not move it back, and do not add a check that lists this repository's files to
# test-claude-sync.sh: the gate would run that section under the lock again, and
# test-scanners-before-push.sh fails if any scanner it selects belongs to a suite that takes it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# What the scan reads is found from the repository root, which the section found as the folder
# holding claude-sync, and the positive control further down plants a number in a copy of a real
# file, which is this one.
SCRIPT="$ROOT/claude-sync"
SCRIPT_SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"

# Its own wall clock, however it was started (claude-config#444, #465).
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
# The form the section was written in: the second argument is an expression, evaluated.
check(){   # $1 = name  $2 = an expression that succeeds when the check holds
  if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 (expr: $2)"; fi
}
dbg(){ [ -n "${SUITE_DEBUG:-}" ] && printf '  [debug] %s\n' "$1"; return 0; }

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/undated-measurements.XXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "test-undated-measurements: refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# Six comments and one CI step quoted how many sections test-claude-sync.sh has, and every number was from
# an earlier week. Each had been measured to justify a decision (where the prelude ends, whether
# sharding was worth it, how long the changed-section audit costs), so a stale one makes the
# reasoning beside it read as current when it is not, and a passing suite makes those sentences
# MORE trusted rather than less (L210).
#
# #140 covered ONE kind of number, a count of the sync suite's sections, and the same comments quoted
# durations and counts of other things that are just as perishable and had no reviewer at all
# (#145, L129). So the rule is the same and the scope is wider: a comment block that quotes a
# measured quantity says WHEN, and the date is one date anywhere in the same BLOCK, which is the
# unit a reader takes in and the reason the block rather than the line is scanned. These sentences
# wrap, and the number and its date routinely sit on different lines of one paragraph.
#
# What counts as a measured quantity, and what does not, because a regex cannot tell a number
# somebody MEASURED from a number somebody CHOSE and pretending otherwise would put dates on
# settings that never go stale:
#
#   a duration           200 seconds, 1192s, 8.4 seconds, 3 hours
#   a count of the       38 suites, 82 sections, 233 checks, 800 files, 6500 lines
#     things this repo
#     is made of
#
# and two ways out, both of them visible at the site rather than in a list somewhere else:
#
#   a date              anywhere in the block, in the form 2026-08-21
#   "not measured"      for a number the code SETS, which cannot go stale because the code beside
#     or "not a           it is the authority. A deadline of 900s, a 90s cooldown and a size a
#     measurement"        fixture builds are facts about the program, not observations of it.
#
# A number inside a code span is code and not a claim, so `head -20 file` is left alone.
#
# Zero is not a measurement of anything. Sections legitimately read 0s, and a broken timer reads 0s
# everywhere too, which is why SUITE_SLOW_IN exists; dating those sentences would say nothing.
#
# What it still cannot see, said plainly: a quantity written in words rather than digits, and a
# count of something this list does not name. It narrows how a perishable number can be written
# down rather than proving nobody can write one (L11).
#
# Markdown needs a different block rule, because the rule here is "a run of lines beginning with
# #" and in markdown that character starts a HEADING. It has one, further down (#148), and this
# part reads shell and workflows only.
_SC_MEASURED='(^|[^#[:alnum:]=.])[1-9][0-9]*(,[0-9][0-9][0-9])*([.][0-9]+)? *(s|ms|secs?|seconds?|mins?|minutes?|hours?)([^A-Za-z=]|$)|(^|[^#[:alnum:]=.])[1-9][0-9]*(,[0-9][0-9][0-9])* +([a-z-]+ +)?(sections?|suites?|checks?|files?|lines?|director(y|ies))([^A-Za-z=]|$)|(^|[^#[:alnum:]=.])[0-9]+ +(after|before) +the +prelude'
_SC_AWK="$WORK/stale-counts.awk"
cat > "$_SC_AWK" <<'SCAWK'
function flush() {
  t = buf
  gsub(/`[^`]*`/, " ", t)
  if (t != "" && t ~ COUNT && t !~ /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ && t !~ /not( a)? measure/) printf "%s:%d: %s\n", FILENAME, start, buf
  buf = ""; start = 0
}
/^[[:space:]]*#/ {
  line = $0
  sub(/^[[:space:]]*#[[:space:]]?/, "", line)
  if (buf == "") { start = FNR; buf = line } else { buf = buf " " line }
  next
}
{ flush() }
END { flush() }
SCAWK
# One file per invocation, deliberately. A block is ended by the first line that is not a comment,
# so two files read in one pass can have the tail of one joined to the head of the next, and the
# report would name a line in the wrong file.
_sc_scan(){   # _sc_scan <file>... -> the undated measurements, one block per line
  for _sc_f in "$@"; do awk -v COUNT="$_SC_MEASURED" -f "$_SC_AWK" "$_sc_f"; done
}
# How a `<path>:<line>: text` row is SHOWN, written once for the shell and the markdown report
# (#525). The path is made relative to the repo and never cut, and only the quoted text is held to
# a budget, with the cut marked. Cutting the whole row let a long worktree path spend the budget on
# its own, so the refusal named neither the line nor what it objected to (L11).
_sc_show(){   # rows on stdin -> indented rows, each keeping its file and line whatever their length
  awk -v root="${_sc_root:-}/" '{
    if (root != "/" && index($0, root) == 1) $0 = substr($0, length(root) + 1)
    if (match($0, /:[0-9]+: /)) {
      head = substr($0, 1, RSTART + RLENGTH - 1); text = substr($0, RSTART + RLENGTH)
      if (length(text) > 120) text = substr(text, 1, 120) "..."
      $0 = head text
    }
    print "    " $0
  }'
}
_sc_root="$(cd "$(dirname "$SCRIPT")" && pwd)"
# Every shell script and workflow the repo HOLDS, asked of git rather than named here. #140 read
# three files, chosen because they were the three that talked about this suite's sections. That is
# the hand written list this repo keeps removing: a file missing from it is exempt from the very
# check meant to catch it, and the numbers #145 was opened about were in a fourth file nobody had
# added (L96, L41).
# Committed or not (#522): the file just written is the one most likely to carry an undated number,
# and a scan of tracked files only would speak about it after it was committed rather than before.
_sc_files="$(bash "$_sc_root/payload/hooks/lib/repo-files.sh" "$_sc_root" '*.sh' '*.yml' '*.yaml' 2>/dev/null)"
_sc_n_files="$(printf '%s' "$_sc_files" | grep -c . || true)"
# A scan handed no files reports nothing and reads as a clean tree (L98). The floor is a real
# count rather than "more than zero", because one file coming back would also read as clean.
check "#145 the scan has the repo's shell and workflow files to read" \
  "[ \"\${_sc_n_files:-0}\" -gt 30 ]"
# And the files the rule was WRITTEN about are actually among them, so a pathspec that quietly
# stopped matching workflows could not leave the scan looking healthy (L100).
for _sc_want in tests/test-claude-sync.sh .github/workflows/tests.yml tests/audit-changed-sections.sh payload/hooks/run-all-tests.sh; do
  check "#145 and $_sc_want is one of them" \
    "grep -qx '$_sc_want' <<< \"\$_sc_files\""
done
_sc_bad="$(printf '%s\n' "$_sc_files" | while IFS= read -r _sc_one; do
  [ -n "$_sc_one" ] || continue
  _sc_scan "$_sc_root/$_sc_one"
done)"
if [ -n "$_sc_bad" ]; then
  echo "  (#145 comment blocks quoting a measured number without saying when:)"
  printf '%s\n' "$_sc_bad" | _sc_show
  echo "    Either say when it was measured, or say it is not measured if the code sets it."
fi
check "#145 no comment quotes a measured number without saying when" "[ -z \"\$_sc_bad\" ]"

# Both directions, on a fixture built for it: the scan has to LEAVE the dated, the set and the
# quoted-as-code alone as well as catch the undated. A scan that reported everything would also
# report nothing wrong once the files were clean, and the two are told apart only by the half that
# must stay silent (L104, L159).
_SCFIX="$WORK/stale-counts-fixture.txt"
{
  printf '# a dated block: measured on 2026-01-02, when the file held 12 sections\n'
  printf 'this line is not a comment, so it ends the block\n'
  printf '# an undated block: the file has 12 sections, of which 3 are slow\n'
  printf 'and this one ends that block\n'
  printf '# a third block: 12 after the prelude, the other spelling, undated\n'
  printf 'ends it\n'
  printf '# an undated duration: the whole thing took 200 seconds\n'
  printf 'ends it\n'
  printf '# a duration written against the number: it fired at 1192s\n'
  printf 'ends it\n'
  printf '# an undated count of another thing: the repo holds 38 suites\n'
  printf 'ends it\n'
  printf '# a number this code sets: it gives up after 900s, not measured\n'
  printf 'ends it\n'
  printf '# a number quoted as code: run `head -20 file` to see the frontmatter\n'
  printf 'ends it\n'
  printf '# a degenerate reading: most sections read 0s and a broken timer reads 0s too\n'
} > "$_SCFIX"
_sc_fix="$(_sc_scan "$_SCFIX")"
dbg "#145 fixture scan: $(printf '%s' "$_sc_fix" | tr '\n' '|')"
# Counted, not matched with `grep -q`: that leaves on its first hit and can kill its own producer
# under pipefail (#132, L183).
for _sc_hit in 3 5 7 9 11; do
  check "#145 the scan catches the undated block on line $_sc_hit" \
    "[ \"\$(printf '%s' \"\$_sc_fix\" | grep -c ':$_sc_hit:' | tr -d ' ')\" = 1 ]"
done
for _sc_quiet in 1 13 15 17; do
  check "#145 and leaves the block on line $_sc_quiet alone" \
    "[ \"\$(printf '%s' \"\$_sc_fix\" | grep -c ':$_sc_quiet:' | tr -d ' ')\" = 0 ]"
done
# And nothing else at all, so a scan that reported every block would fail here even though each
# check above passed (L178).
check "#145 and reports those five and nothing else" \
  "[ \"\$(printf '%s' \"\$_sc_fix\" | grep -c . | tr -d ' ')\" = 5 ]"

# The report has to name the line and quote the text under ANY path, because a refusal that cannot
# say where it objected sends the reader to reverse engineer it (#525, L11). It used to cut each
# whole `<path>:<line>: text` row to 160 characters, and from a worktree under a scratch folder the
# path alone used the budget, so neither the line nor the text survived. The fixture lives under a
# directory name long enough to spend that whole budget on its own.
_SCLONG="$WORK/$(printf 'a-worktree-path-long-enough-to-spend-the-whole-budget-%.0s' 1 2 3 4)"
mkdir -p "$_SCLONG"
cp "$_SCFIX" "$_SCLONG/fixture.sh"
_sc_long_shown="$(_sc_scan "$_SCLONG/fixture.sh" | _sc_show)"
dbg "#525 long path report: $(printf '%s' "$_sc_long_shown" | tr '\n' '|')"
check "#525 a report under a long path still names the line and quotes the text" \
  "[ \"\$(printf '%s\n' \"\$_sc_long_shown\" | grep -c ':3: an undated block: the file has 12 sections' | tr -d ' ')\" = 1 ]"
# And a path inside the repo is shown relative to it, which is the path a reader can open.
_sc_rel_shown="$(printf '%s\n' "$_sc_root/tests/x.sh:7: some text" | _sc_show)"
check "#525 a path inside the repo is shown relative to it" \
  "[ \"\$(printf '%s' \"\$_sc_rel_shown\" | sed 's/^ *//')\" = 'tests/x.sh:7: some text' ]"
# The TEXT is what gets cut, and it says so, so a long block is not mistaken for a complete one.
_sc_cut_shown="$(printf 'f.sh:2: %s\n' "$(printf 'word %.0s' $(seq 1 60))" | _sc_show)"
case "$_sc_cut_shown" in *"f.sh:2: word word"*"...") _sc_cut_ok=1 ;; *) _sc_cut_ok=0 ;; esac
check "#525 only the quoted text is cut, and the cut is marked" "[ \"\$_sc_cut_ok\" = 1 ]"
rm -rf "$_SCLONG"

# And on a real file, because a scanner alive on a fixture it was handed can still be blind to the
# files it actually reads: the zero above is only a measurement if planting one moves it (L182,
# L171). Prefixed and stripped so the plant lives here without the scan finding it.
_SCPOS="$WORK/stale-counts-positive-control.sh"
cp "$SCRIPT_SELF" "$_SCPOS"
sed 's/^@@//' >> "$_SCPOS" <<'SCPLANT'
@@echo "zzz this line ends whatever block came before it"
@@# zzz planted: this run took 999 seconds and nothing here says when
SCPLANT
_sc_self_n="$(_sc_scan "$SCRIPT_SELF" | grep -c . || true)"
_sc_pos="$(_sc_scan "$_SCPOS" | grep -c . || true)"
dbg "#145 control: the real file reports $_sc_self_n, the planted copy reports $_sc_pos"
# One MORE than the same file unplanted, never a flat 1: written as an absolute it would also fail
# whenever the file really did carry an undated measurement, and a run reporting two failures for
# one defect makes the reader look for two (L11).
check "#145 the count above is a live measurement, not a scan reading nothing" \
  "[ \"\${_sc_pos:-0}\" -eq \$(( _sc_self_n + 1 )) ]"
rm -f "$_SCPOS"

# ---- the same rule over this repo's own markdown (#148) ----
# #145 read shell and workflows and left markdown out, because the block rule there is a run of
# lines beginning with #, and in markdown that character starts a HEADING: every heading would
# read as a one line block and every paragraph as the thing that ends one. The exemption was named
# rather than left silent (L129), and this is it being closed.
#
# Markdown needs its own idea of a block, and it is not the same idea:
#
#   a paragraph      a run of non-blank lines, ended by a blank one
#   a table row      its own block, because a table is not a paragraph and a date in one row says
#                    nothing about the row under it
#   a list item      its own block, continuing over the lines that wrap it
#   a fenced block   skipped entirely, for the same reason a code span is: it is code, not a claim
#
# Scoped to markdown at the REPO ROOT, which is this repo's own documentation. Everything under
# payload/ is content this repo FERRIES to other machines rather than writes, and most of it is
# third party skills whose numbers are somebody else's claims to date or not: measured on
# 2026-08-21, 76 blocks across the tracked markdown, 52 of them in vendored skills. LESSONS.md is
# deliberately outside it too, and for a better reason than volume: every lesson carries the issue
# it came from, which is provenance a date cannot improve on.
_SC_MD_AWK="$WORK/stale-counts-md.awk"
cat > "$_SC_MD_AWK" <<'SCMDAWK'
function flush() {
  t = buf
  gsub(/`[^`]*`/, " ", t)
  if (t != "" && t ~ COUNT && t !~ /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ && t !~ /not( a)? measure/) printf "%s:%d: %s\n", FILENAME, start, buf
  buf = ""; start = 0
}
/^[[:space:]]*```/ { flush(); fence = !fence; next }
fence { next }
/^[[:space:]]*$/ { flush(); next }
/^[[:space:]]*[|]/ { flush(); start = FNR; buf = $0; flush(); next }
/^[[:space:]]*([-*+]|[0-9]+[.])[[:space:]]/ { flush(); start = FNR; buf = $0; next }
{ if (buf == "") { start = FNR; buf = $0 } else { buf = buf " " $0 } }
END { flush() }
SCMDAWK
_sc_md_scan(){   # _sc_md_scan <file>... -> the undated measurements, one block per line
  for _sc_mf in "$@"; do awk -v COUNT="$_SC_MEASURED" -f "$_SC_MD_AWK" "$_sc_mf"; done
}
# Root level markdown, asked of git and filtered by having no directory in its path, so a document
# added beside README.md is covered on the day it lands and nothing here needs maintaining.
_sc_md_files="$(bash "$_sc_root/payload/hooks/lib/repo-files.sh" "$_sc_root" '*.md' 2>/dev/null | grep -v /)"
_sc_md_n="$(printf '%s' "$_sc_md_files" | grep -c . || true)"
check "#148 the markdown scan has this repo's own documents to read" \
  "[ \"\${_sc_md_n:-0}\" -ge 3 ]"
for _sc_md_want in README.md DESIGN.md SETUP.md; do
  check "#148 and $_sc_md_want is one of them" \
    "grep -qx '$_sc_md_want' <<< \"\$_sc_md_files\""
done
_sc_md_bad="$(printf '%s\n' "$_sc_md_files" | while IFS= read -r _sc_md_one; do
  [ -n "$_sc_md_one" ] || continue
  _sc_md_scan "$_sc_root/$_sc_md_one"
done)"
if [ -n "$_sc_md_bad" ]; then
  echo "  (#148 markdown blocks quoting a measured number without saying when:)"
  printf '%s\n' "$_sc_md_bad" | _sc_show
fi
check "#148 no document quotes a measured number without saying when" "[ -z \"\$_sc_md_bad\" ]"

# Both directions again, on a fixture shaped like markdown rather than like shell, because the
# block rule is the thing that changed and the shell fixture says nothing about it.
_SCMDFIX="$WORK/stale-counts-md-fixture.md"
{
  printf '# A heading\n\n'
  printf 'A dated paragraph: measured on 2026-01-02, the run took 200 seconds.\n\n'
  printf 'An undated paragraph, wrapped the way these actually are, saying the run\n'
  printf 'took 200 seconds and nothing about when.\n\n'
  printf '| setting | default | what it does |\n'
  printf '| --- | --- | --- |\n'
  printf '| `A` | `1` | dated: on 2026-01-02 a full run took 30 seconds |\n'
  printf '| `B` | `2` | undated: a full run took 30 seconds |\n\n'
  printf -- '- a list item that is dated: 2026-01-02, 12 sections\n'
  printf -- '- a list item that is not: 12 sections\n\n'
  printf 'A number this code sets: it gives up after 900s, not measured.\n\n'
  printf '```\n'
  printf 'inside a fence: the run took 200 seconds with no date anywhere\n'
  printf '```\n'
} > "$_SCMDFIX"
_sc_md_fix="$(_sc_md_scan "$_SCMDFIX")"
dbg "#148 markdown fixture scan: $(printf '%s' "$_sc_md_fix" | tr '\n' '|')"
for _sc_md_hit in 5 11 14; do
  check "#148 the markdown scan catches the undated block on line $_sc_md_hit" \
    "[ \"\$(printf '%s' \"\$_sc_md_fix\" | grep -c ':$_sc_md_hit:' | tr -d ' ')\" = 1 ]"
done
for _sc_md_quiet in 3 10 13 16 19; do
  check "#148 and leaves the block on line $_sc_md_quiet alone" \
    "[ \"\$(printf '%s' \"\$_sc_md_fix\" | grep -c ':$_sc_md_quiet:' | tr -d ' ')\" = 0 ]"
done
# A table row dated in ONE row must not excuse the row beneath it, which is the whole reason a row
# is its own block. Asserted by the pair above and by the count here: three and no more.
check "#148 and reports those three and nothing else" \
  "[ \"\$(printf '%s' \"\$_sc_md_fix\" | grep -c . | tr -d ' ')\" = 3 ]"

# And on a real document, so the zero above is a measurement rather than a scan reading nothing
# (L182, L171). README.md is the one every other check in this file already depends on being read.
_SCMDPOS="$WORK/stale-counts-md-positive-control.md"
cp "$_sc_root/README.md" "$_SCMDPOS"
printf '\nzzz planted: this run took 999 seconds and nothing here says when\n' >> "$_SCMDPOS"
_sc_md_self="$(_sc_md_scan "$_sc_root/README.md" | grep -c . || true)"
_sc_md_pos="$(_sc_md_scan "$_SCMDPOS" | grep -c . || true)"
dbg "#148 control: README.md reports $_sc_md_self, the planted copy reports $_sc_md_pos"
check "#148 the markdown count above is a live measurement, not a scan reading nothing" \
  "[ \"\${_sc_md_pos:-0}\" -eq \$(( _sc_md_self + 1 )) ]"
rm -f "$_SCMDPOS"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
