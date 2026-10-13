#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/ mods/
# No two file awk program may tell its files apart by COUNTING records (claude-config#1028).
#
# `awk 'NR == FNR { ...; next } { ... }' first second` reads "the record number overall equals the
# record number in this file" as "this is the first file". That holds only while the first file
# has at least one record. When it is EMPTY, NR and FNR stay equal all the way through the SECOND
# file, so every line of the second is taken for the first. In pr-review-report.sh that made a
# window with no openings read every review as an opening; in claude-sync it let core-set accept
# lesson numbers that are not lessons whenever the library rendered nothing. Both were correct on
# every input their authors tried, which always had something in the first file.
#
# The test that cannot be fooled names the file: FILENAME == ARGV[1]. Every site was converted to
# it, so this is a one way door rather than a ratchet: a new one anywhere fails on the day it
# lands (L30, L613). The comparisons that mean the same thing are caught too, either way round and
# with `!=`, `>` or `<`, because each spelling left out is a spelling exempt from the check (L217).
# Comment lines are skipped, or the prose explaining the rule counts as breaking it.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${TWO_FILE_AWK_ROOT:-$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# No repository here is not a failure of this suite's subject, it is a place this suite cannot be
# asked (claude-config#155), said in the one shape the runner reads as NOT RUN.
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  echo "test-two-file-awk: no repo above $DIR, so there were no files to read." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository to read its files, and there is none above $DIR"
  exit 2
fi

# The pattern, ASSEMBLED from pieces so this file holds no occurrence of the thing it forbids and
# cannot report itself (the trick check-style-guide.sh and the pipefail ratchet need).
_N="N""R"; _F="F""N""R"
_CMP='[[:space:]]*([!=]=|[<>])[[:space:]]*'
PATTERN="(^|[^A-Za-z0-9_])(${_N}${_CMP}${_F}|${_F}${_CMP}${_N})([^A-Za-z0-9_]|\$)"

# Every uncommented line holding one, as "<path>:<line>: <text>", for the files named on stdin
# relative to $1. One grep over all of them, never one per file (L297).
sites_in(){   # $1 = root; stdin = repo relative paths
  local root="$1" rel
  local files=()
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in *.sh|*.bash|*.awk|*.py|claude-sync|*/claude-sync) ;; *) continue ;; esac
    [ -f "$root/$rel" ] && files+=("$rel")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  # -H always, or a single file is printed without its name and the comment filter misreads it.
  (cd "$root" && grep -HnE "$PATTERN" -- "${files[@]}" 2>/dev/null) \
    | awk '{ t = $0; sub(/^[^:]*:[0-9]+:/, "", t); if (t !~ /^[[:space:]]*#/) print }'
  return 0
}

# ---------------------------------------------------------------------------
# The scan has to see one, every spelling of one, and not the fix, before the tree is asked (L1).
# ---------------------------------------------------------------------------
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/two-file-awk.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-two-file-awk: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT
{
  printf '#!/usr/bin/env bash\n'
  printf "awk '%s == %s { a[\$0] = 1; next } (\$0 in a)' one two\n" "$_N" "$_F"
  printf "awk '%s==%s { a[\$0] = 1; next } (\$0 in a)' one two\n" "$_F" "$_N"
  printf "awk '%s != %s { print }' one two\n" "$_N" "$_F"
  printf "awk '%s > %s { print }' one two\n" "$_N" "$_F"
  printf "  # awk '%s == %s' would be wrong here   <- a comment about one, not one\n" "$_N" "$_F"
  printf "awk 'FILENAME == ARGV[1] { a[\$0] = 1; next } (\$0 in a)' one two\n"
  printf "awk 'FNR == 1 && %s > 1 { print }' one\n" "$_N"
  printf "awk 'XNR == FNRX { print }' one\n"
} > "$TMPROOT/probe.sh"
probe="$(printf 'probe.sh\n' | sites_in "$TMPROOT")"
probe_n="$(printf '%s' "$probe" | awk 'END { print NR }')"
[ "$probe_n" = "4" ] \
  && check "the scan sees every spelling of the count test, and not a comment, the fix, or a longer name" ok \
  || check "the scan sees every spelling of the count test, and not a comment, the fix, or a longer name" "it found $probe_n of 4: $probe"

# And the hazard itself, on this machine's awk, so the rule rests on a measurement rather than a
# sentence (L82): with an empty first file the count test claims the second file's line, and the
# named test does not. If this ever stops being true the rule is still right, and the probe says so.
: > "$TMPROOT/empty"
printf 'second\n' > "$TMPROOT/second"
by_count="$(awk "$_N == $_F { print \"first: \" \$0; next } { print \"second: \" \$0 }" "$TMPROOT/empty" "$TMPROOT/second")"
by_name="$(awk 'FILENAME == ARGV[1] { print "first: " $0; next } { print "second: " $0 }' "$TMPROOT/empty" "$TMPROOT/second")"
[ "$by_name" = "second: second" ] \
  && check "naming the first file reads the second as the second when the first is empty" ok \
  || check "naming the first file reads the second as the second when the first is empty" "it read: $by_name"
case "$by_count" in
  "first: second") echo "test-two-file-awk: on this machine's awk, counting records read an empty first file's partner as the first file, which is the fault this guards." ;;
  *) echo "test-two-file-awk: on this machine's awk, counting records gave '$by_count' with an empty first file." ;;
esac
# The same, with the first file read from stdin as `-`, which is how most sites here pass it.
by_stdin="$(printf '' | awk 'FILENAME == ARGV[1] { print "first: " $0; next } { print "second: " $0 }' - "$TMPROOT/second")"
[ "$by_stdin" = "second: second" ] \
  && check "and so does naming it when the first file is stdin" ok \
  || check "and so does naming it when the first file is stdin" "it read: $by_stdin"

# ---------------------------------------------------------------------------
# The real tree: none at all, anywhere.
# ---------------------------------------------------------------------------
FILES="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)"
# A listing that came back empty read nothing, and the check below would pass over it (L98).
[ -n "$FILES" ] \
  && check "the files to judge were listed" ok \
  || check "the files to judge were listed" "lib/repo-files.sh gave nothing for $ROOT, so nothing below was read"
found="$(printf '%s\n' "$FILES" | sites_in "$ROOT")"
[ -z "$found" ] \
  && check "no two file awk tells its files apart by counting records" ok \
  || check "no two file awk tells its files apart by counting records" "these do, and read an empty first file's partner as the first file:
$found
  Name the first file instead: FILENAME == ARGV[1]."

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
