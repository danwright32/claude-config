#!/usr/bin/env bash
# The order every disk-clean script and test asks stat in (claude-config#1874).
#
# GNU stat (the Ubuntu CI runner) reads -f as "report on the FILE SYSTEM" and prints its own lines
# before failing on the format it was handed as a path, while BSD stat (macOS) refuses GNU's -c. So a
# stat that asks BSD's -f first is right on the Mac and wrong on Linux, and nothing on the Mac can
# see it. Every stat therefore asks GNU's -c first, in one of two forms:
#
#   on one line        stat -c '%s' "$p" 2>/dev/null || stat -f '%z' "$p" 2>/dev/null
#   behind a probe     if stat -c '%d:%i' / >/dev/null 2>&1; then <GNU> else <BSD> fi
#
# This guard used to read disk-remove.sh alone (test-disk-remove.sh), so the same slip anywhere else
# was caught by nothing until a Linux run failed: test-disk-clean-categories.sh carried it until
# #1851. Fix the class (L30): the files are DERIVED, never listed (L96): every shell file in this
# skill, and every one under hooks/ whose name or text names disk-clean or disk-remove.
#
# One form is allowed on purpose and named here with its reason, and the suite fails when a named
# form is no longer met, so an allowance cannot outlive the line it was written for (L129, L346):
#
#   dcs_dataless       scan-lib.sh reads macOS's file flags with stat -f '%Xf'. There is no GNU
#                      equivalent to ask first, and off macOS stat fails on '%Xf' taken as a path,
#                      so the function returns, and the hex check refuses anything it printed.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): hooks/lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$(cd "$DIR/../.." && pwd)"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
finish() {
  echo ""
  echo "passed: $pass, failed: $fail"
  echo "SUITE-RESULT passed=$pass failed=$fail"
  [ "$fail" -eq 0 ]
  exit $?
}
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo "'$2' not in: $1"; }
hasnt() { grep -qF -- "$2" <<< "$1" && echo "'$2' should not be in: $1" || echo ok; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/disk-clean-stat-order.XXXXXXXX")" || { check "a scratch directory" "mktemp failed"; finish; }
trap 'rm -rf "$TMP"' EXIT

# BSD's flag, spelled so this file holds no literal BSD first stat for the guard to read in itself.
BSD="stat -""f"

# Prints "<file>:<line>: <text>" for every stat that asks BSD's -f without GNU's -c first, and
# "allowed <name>" for each named form it met. One awk pass over every file named (L297). Comment
# lines are not code and are skipped. A probe is open from its `if stat -c` to the next `fi`, and BSD
# is allowed only after its `else`: a nested if inside a probe closes it early, which refuses more,
# never less.
stat_order_scan() { # <file>...
  awk -v xf="$BSD '%Xf'" '
    FNR == 1 { probe = 0; inelse = 0 }
    /^[[:space:]]*#/ { next }
    {
      # Padded, so a word at either end of the line needs no anchor inside a group, which not
      # every awk reads alike (BSD awk here, gawk or mawk on Linux).
      l = " " $0 " "
      if (l ~ /[^[:alnum:]_]if stat -c /) { probe = 1; inelse = 0 }
      if (probe && l ~ /[;[:space:]]else[;[:space:]]/) inelse = 1
      if (l ~ /stat -[f]/) {
        if (l ~ /stat -c[^|]*\|\|[^|]*stat -[f]/) ;
        else if (probe && inelse) ;
        else if (FILENAME ~ /\/scan-lib\.sh$/ && index(l, xf)) print "allowed dcs_dataless"
        else print FILENAME ":" FNR ": " $0
      }
      if (probe && l ~ /[;[:space:]]fi[;[:space:]]/) { probe = 0; inelse = 0 }
    }' "$@"
}

# The files: derived, never listed (L96). Every shell file in this skill, and every one under hooks/
# whose name or text names disk-clean or disk-remove.
stat_order_files() {
  find "$PAYLOAD/skills/disk-clean" -type f -name '*.sh'
  grep -r -l --include='*.sh' -e 'disk-clean' -e 'disk-remove' "$PAYLOAD/hooks"
}

# ================================================================================================
# 1. The controls: the guard is only real once seen to fail (L1)
# ================================================================================================
printf '%s\n' \
  "m=\"\$($BSD %m \"\$1\" 2>/dev/null || stat -c %Y \"\$1\")\"" \
  "z=\$($BSD %z \"\$1\")" \
  "if $BSD %z / >/dev/null 2>&1; then a=1; else a=2; fi" \
  "if stat -c '%d:%i' / >/dev/null 2>&1; then" \
  "  $BSD '%d:%i' \"\$1\"" \
  "else" \
  "  stat -c '%d:%i' \"\$1\"" \
  "fi" \
  "f=\"\$($BSD '%Xf' \"\$1\" 2>/dev/null)\" || return 1" > "$TMP/bad.sh"
printf '%s\n' \
  "s=\"\$(stat -c '%s' \"\$1\" 2>/dev/null || $BSD '%z' \"\$1\" 2>/dev/null)\"" \
  "# $BSD %m in a comment is not code" \
  "if stat -c '%d:%i' / >/dev/null 2>&1; then" \
  "  xargs -0 stat -c '%d:%i' < \"\$l\"" \
  "else" \
  "  xargs -0 $BSD '%d:%i' < \"\$l\"" \
  "fi" \
  "if stat -c '%d:%i' / >/dev/null 2>&1; then xargs -0 stat -c '%b' < \"\$l\"" \
  "else xargs -0 $BSD '%b' < \"\$l\"; fi" > "$TMP/good.sh"
bad="$(stat_order_scan "$TMP/bad.sh")"
check "BSD first with GNU as the fallback is refused" "$(has "$bad" "bad.sh:1: ")"
check "BSD alone is refused" "$(has "$bad" "bad.sh:2: ")"
check "a probe that asks BSD is refused" "$(has "$bad" "bad.sh:3: ")"
check "BSD in the THEN branch of a GNU probe is refused" "$(has "$bad" "bad.sh:5: ")"
check "the macOS flags read is refused in any file but scan-lib.sh" "$(has "$bad" "bad.sh:9: ")"
good="$(stat_order_scan "$TMP/good.sh")"
check "GNU first on one line, a comment, and BSD in the else branch of a GNU probe all pass" "$([ -z "$good" ] && echo ok || echo "refused: $good")"
mkdir -p "$TMP/lib"
sed -n '9p' "$TMP/bad.sh" > "$TMP/lib/scan-lib.sh"
xf="$(stat_order_scan "$TMP/lib/scan-lib.sh")"
check "the macOS flags read in a file named scan-lib.sh is allowed, by name, and nothing else is said" "$([ "$xf" = "allowed dcs_dataless" ] && echo ok || echo "said: $xf")"

# The slip #1851 fixed, put back into a copy of the real file: its GNU first identity read swapped
# to ask BSD first. Its name is kept, so the copy is judged as the file itself is.
CAT="$DIR/test-disk-clean-categories.sh"
mkdir -p "$TMP/swapped"
sed "s/stat -c '%d:%i' \"\$H\/Downloads\/movie.mov\" 2>\/dev\/null || $BSD '%d:%i'/$BSD '%d:%i' \"\$H\/Downloads\/movie.mov\" 2>\/dev\/null || stat -c '%d:%i'/" \
  "$CAT" > "$TMP/swapped/test-disk-clean-categories.sh"
check "the copy really was swapped" "$(cmp -s "$CAT" "$TMP/swapped/test-disk-clean-categories.sh" && echo "sed changed nothing" || echo ok)"
check "the guard refuses the categories suite with its identity read asked BSD first" \
  "$(has "$(stat_order_scan "$TMP/swapped/test-disk-clean-categories.sh")" "test-disk-clean-categories.sh:")"

# ================================================================================================
# 2. The files it reads: every disk-clean script and test, derived
# ================================================================================================
set_list="$(stat_order_files)"
for want in hooks/lib/disk-remove.sh skills/disk-clean/scan-lib.sh skills/disk-clean/scan.sh \
  skills/disk-clean/test-disk-clean-categories.sh skills/disk-clean/categories/large-files.sh \
  hooks/test-disk-remove.sh hooks/check-free-space.sh skills/disk-clean/test-disk-clean-stat-order.sh; do
  check "the guard reads $want" "$(grep -qxF "$PAYLOAD/$want" <<< "$set_list" && echo ok || echo "not in its files")"
done
check "every file it reads is there" "$(while IFS= read -r f; do [ -f "$f" ] || echo "missing: $f"; done <<< "$set_list" | head -3 | grep . || echo ok)"

# ================================================================================================
# 3. The real files
# ================================================================================================
files=()
while IFS= read -r f; do files+=("$f"); done <<< "$set_list"
real="$(stat_order_scan "${files[@]}")"
check "every stat in every disk-clean script and test asks GNU's -c before BSD's -f" \
  "$(grep -v '^allowed ' <<< "$real" | grep . | sed 's/^/BSD first: /' || echo ok)"
check "the named form dcs_dataless is still met, so its allowance is still wanted" "$(has "$real" "allowed dcs_dataless")"

finish
