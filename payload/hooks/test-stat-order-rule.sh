#!/usr/bin/env bash
# The stat order rule in lib/stat-order.sh, against fixtures built to hold each answer
# (claude-config#2003). The rule is only real once seen to fail (L1), so every form it must refuse
# is shown refused, and every GNU first form it must accept is shown passing.
#
# It sits beside the hooks, rather than in the repository's tests/, so the rule is covered wherever
# the hooks are installed. tests/test-stat-order.sh runs the same rule over the whole repository.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

. "$DIR/lib/stat-order.sh" || { check "the stat order rule loads" "lib/stat-order.sh did not load"; finish; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/stat-order-rule.XXXXXXXX")" || { check "a scratch directory" "mktemp failed"; finish; }
case "${TMP%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}") echo "test-stat-order-rule: refusing to run: scratch came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

# BSD's flag, spelled so this file holds no literal BSD first stat for the guard to read in itself.
BSD="stat -""f"

printf '%s\n' \
  "m=\"\$($BSD %m \"\$1\" 2>/dev/null || stat -c %Y \"\$1\")\"" \
  "z=\$($BSD %z \"\$1\")" \
  "if $BSD %z / >/dev/null 2>&1; then a=1; else a=2; fi" \
  "if stat -c '%d:%i' / >/dev/null 2>&1; then" \
  "  $BSD '%d:%i' \"\$1\"" \
  "else" \
  "  stat -c '%d:%i' \"\$1\"" \
  "fi" \
  "x=1 # $BSD %m after code is still read as code" > "$TMP/bad.sh"
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
check "a BSD read behind code on its line is refused, since only a whole comment line is skipped" "$(has "$bad" "bad.sh:9: ")"
check "and nothing else in that file is refused" "$([ "$(grep -c . <<< "$bad")" = 5 ] && echo ok || echo "refused: $bad")"
good="$(stat_order_scan "$TMP/good.sh")"
check "GNU first on one line, a comment, and BSD in the else branch of a GNU probe, on its own line or after a one line then, all pass" \
  "$([ -z "$good" ] && echo ok || echo "refused: $good")"
# Each file starts with no probe open, so a probe left open at the end of one file cannot excuse a
# BSD read at the top of the next.
printf '%s\n' "if stat -c '%d:%i' / >/dev/null 2>&1; then" "else" > "$TMP/open.sh"
printf '%s\n' "z=\$($BSD %z \"\$1\")" > "$TMP/next.sh"
check "a probe open at the end of one file does not carry into the next" \
  "$(has "$(stat_order_scan "$TMP/open.sh" "$TMP/next.sh")" "next.sh:1: ")"

finish
