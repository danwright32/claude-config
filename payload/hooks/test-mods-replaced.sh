#!/usr/bin/env bash
# test-mods-replaced.sh: lib/mods-replaced.sh, the record of which mods claude-sync replaced on this
# Mac (claude-config#2514). claude-sync writes it after a pull's mirror; rule-files-changed.sh reads
# it on every prompt to tell a running session that a mod it loaded was replaced underneath it. A
# writer that misses a mod leaves that session running old code with nothing said, and a reader that
# names a mod nobody replaced tells every session to reload for nothing (L36), so both are held here.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/mods-replaced.sh" || {
  echo "FAIL: lib/mods-replaced.sh is missing"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

pass=0; fail=0
check_eq(){ # check_eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); { echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; } | sed '2,$s/^/  /'; fi
}
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"
mkmod(){ mkdir -p "$H/mods/$1/.claude-plugin" "$H/mods/$1/hooks"; printf '{ "name": "%s" }\n' "$1" > "$H/mods/$1/.claude-plugin/plugin.json"; }
mkmod alpha; mkmod beta; mkmod gamma
T=$'\t'

# Nothing recorded yet: the reader prints nothing and succeeds.
out="$(mods_replaced_lines "$H")"; rc=$?
check_eq "with no record the reader prints nothing" "" "$out"
check_eq "and succeeds" 0 "$rc"

# A pull's applied list: alpha had a file updated and one added, beta one removed, a hook outside the
# mods tree changed, and gamma nothing. Only the mods a file of which the pull wrote or removed.
printf 'updated\tmods/alpha/hooks/register.ts\nadded\tmods/alpha/hooks/new.ts\nremoved\tmods/beta/hooks/old.ts\nupdated\thooks/some-hook.sh\n' > "$TMP/applied"
mods_replaced_note "$H" "$TMP/applied" s1; rc=$?
check_eq "the writer succeeds" 0 "$rc"
check_eq "it records each mod the pull wrote into, once, with the stamp" "alpha${T}s1
beta${T}s1" "$(sort "$H/state/mods-replaced.tsv")"
check_eq "the reader prints one line per recorded mod" "@replaced${T}alpha${T}s1
@replaced${T}beta${T}s1" "$(mods_replaced_lines "$H" | sort)"

# A later pull replacing alpha again moves only alpha's stamp; beta keeps the one it had.
printf 'updated\tmods/alpha/hooks/register.ts\n' > "$TMP/applied2"
mods_replaced_note "$H" "$TMP/applied2" s2
check_eq "a second pull moves only the stamp of the mod it replaced" "alpha${T}s2
beta${T}s1" "$(sort "$H/state/mods-replaced.tsv")"

# A pull replacing SEVERAL mods over a record that holds others keeps the others: the names it
# replaced reach the rewrite as a list, which must not be lost on the way in.
mkmod delta
printf 'gamma\tg0\ndelta\td0\n' >> "$H/state/mods-replaced.tsv"
printf 'updated\tmods/alpha/hooks/register.ts\nupdated\tmods/beta/hooks/register.ts\n' > "$TMP/applied-two"
mods_replaced_note "$H" "$TMP/applied-two" s2b; rc=$?
check_eq "a pull replacing two mods succeeds" 0 "$rc"
check_eq "and keeps every mod it did not replace" "alpha${T}s2b
beta${T}s2b
delta${T}d0
gamma${T}g0" "$(sort "$H/state/mods-replaced.tsv")"
printf 'alpha\ts2\nbeta\ts1\n' > "$H/state/mods-replaced.tsv"
rm -rf "$H/mods/delta"

# A pull that wrote nothing under mods leaves the record exactly as it was.
printf 'updated\thooks/other.sh\n' > "$TMP/applied3"
before="$(cat "$H/state/mods-replaced.tsv")"
mods_replaced_note "$H" "$TMP/applied3" s3
check_eq "a pull that touched no mod changes nothing" "$before" "$(cat "$H/state/mods-replaced.tsv")"
mods_replaced_note "$H" "$TMP/does-not-exist" s3; rc=$?
check_eq "nor does a missing applied list, which is no failure" "0 $before" "$rc $(cat "$H/state/mods-replaced.tsv")"

# A mod that is gone (no manifest) is never read back as replaced, and the next write drops it.
rm -rf "$H/mods/beta"
check_eq "a recorded mod that is no longer on disk is not read back" "@replaced${T}alpha${T}s2" "$(mods_replaced_lines "$H")"
mods_replaced_note "$H" "$TMP/applied2" s4
check_eq "and the next write drops its line" "alpha${T}s4" "$(cat "$H/state/mods-replaced.tsv")"

# A line naming something that cannot be a mod folder (a path, a dot name) or carrying no stamp is
# never read back, whatever wrote it.
printf 'alpha\ts4\n../alpha\tx\n.hidden\tx\ngamma\t\nnot a line\n' > "$H/state/mods-replaced.tsv"
check_eq "only well formed lines naming a mod on disk are read" "@replaced${T}alpha${T}s4" "$(mods_replaced_lines "$H")"

# The record lives in state/, which this Mac never syncs, so it cannot travel to the other Mac.
check_eq "the record's path is under state/" "$H/state/mods-replaced.tsv" "$(mods_replaced_file "$H")"

# A record that cannot be written is a failure the caller can say, never a silent success.
H2="$TMP/ro"; mkdir -p "$H2/mods/alpha/.claude-plugin"; printf '{}\n' > "$H2/mods/alpha/.claude-plugin/plugin.json"
printf 'x\n' > "$H2/state"   # a file where the folder must go
mods_replaced_note "$H2" "$TMP/applied2" s5 2>/dev/null; rc=$?
check_eq "a record that cannot be written fails" 1 "$rc"

echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
