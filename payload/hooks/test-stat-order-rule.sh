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

# ================================================================================================
# A stat command line built in TypeScript or JavaScript (claude-config#2016)
# ================================================================================================
# A mod runs a process from an argument list, so BSD stat there is the words 'stat' and '-f' as two
# quoted items, which the shell form never matched: job-watcher and scope-modes ran it unseen. The
# same rule reads those lists, in any quote, and reads a `??` between two of them as the shell's
# `||`. A comment line in either language is not code.
Q="'"; BQ='`'
printf '%s\n' \
  "const a = await run(\$, [${Q}stat${Q}, ${Q}-f${Q}, ${Q}%z${Q}, p])" \
  "const b = await \$.process.run([\"stat\", \"-f\", \"%m\", p])" \
  "const c = await run([${BQ}stat${BQ},${BQ}-f${BQ}, ${BQ}%m${BQ}, p])" \
  "const d = await run(['bash', '-c', ${BQ}$BSD %m \${p}${BQ}])" \
  "const e = (await run([${Q}stat${Q}, ${Q}-f${Q}, ${Q}%z${Q}, p])) ?? (await run([${Q}stat${Q}, ${Q}-c${Q}, ${Q}%s${Q}, p]))" > "$TMP/bad.ts"
printf '%s\n' \
  "const s = await \$.fs.stat(p)" \
  "// run([${Q}stat${Q}, ${Q}-f${Q}, ${Q}%z${Q}, p]) in a comment is not code" \
  "  * [${Q}stat${Q}, ${Q}-f${Q}] inside a block comment is not code either" \
  "const g = await run([${Q}stat${Q}, ${Q}-c${Q}, ${Q}%s${Q}, p])" \
  "const h = (await run([${Q}stat${Q}, ${Q}-c${Q}, ${Q}%s${Q}, p])) ?? (await run([${Q}stat${Q}, ${Q}-f${Q}, ${Q}%z${Q}, p]))" \
  "const i = [${Q}stat${Q}, ${Q}-L${Q}, p]" > "$TMP/good.ts"
badts="$(stat_order_scan "$TMP/bad.ts")"
check "a TypeScript argument list asking BSD stat in single quotes is refused" "$(has "$badts" "bad.ts:1: ")"
check "in double quotes" "$(has "$badts" "bad.ts:2: ")"
check "in backquotes with no space after the comma" "$(has "$badts" "bad.ts:3: ")"
check "a shell line built in a template string is refused as the shell rule refuses it" "$(has "$badts" "bad.ts:4: ")"
check "BSD first with GNU after a ?? is refused" "$(has "$badts" "bad.ts:5: ")"
check "and nothing else in that file is refused" "$([ "$(grep -c . <<< "$badts")" = 5 ] && echo ok || echo "refused: $badts")"
goodts="$(stat_order_scan "$TMP/good.ts")"
check "\$.fs.stat, comments, GNU alone, GNU first with BSD after a ??, and other stat flags all pass in TypeScript" \
  "$([ -z "$goodts" ] && echo ok || echo "refused: $goodts")"
for ext in tsx js mjs cjs; do
  cp "$TMP/bad.ts" "$TMP/bad.$ext"
  check "a .$ext file is read as TypeScript is" "$(has "$(stat_order_scan "$TMP/bad.$ext")" "bad.$ext:1: ")"
done
# The argument list form is read in script files only: in a shell file the words are a quoted list
# the shell never runs as stat, and a ?? there is no fallback.
printf '%s\n' "words=(${Q}stat${Q} ${Q}-f${Q})" "z=\$($BSD %z \"\$1\" ?? stat -c %s \"\$1\")" > "$TMP/words.sh"
words="$(stat_order_scan "$TMP/words.sh")"
check "a shell file's quoted words are not read as a stat, and a ?? there excuses nothing" \
  "$([ "$(grep -c . <<< "$words")" = 1 ] && grep -q "words.sh:2: " <<< "$words" && echo ok || echo "said: $words")"

finish
