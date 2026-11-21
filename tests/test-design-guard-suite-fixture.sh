#!/usr/bin/env bash
# The design round guard's SUITE_2991 fixture is the excerpt of the adapter suite it says it is
# (claude-config#3231).
#
# payload/mods/design-round-guard/tests/register.test.ts carries part of
# payload/skills/design-rounds/score/test-score-adapters.sh as a fixture, so the guard's verdict on
# that suite (#2991) is tested on the suite's own text. Until #3231 the fixture said it was lines 46
# to 48 and 166 to 315 word for word, which it was, and left out lines 41 to 45, which set SKILL and
# ADAPTER: so the excerpt ran make-settled.py and the adapter through variables it never set, while
# the real suite sets both, and any rule keyed on whether a script sets a variable was judged
# differently on the fixture than on the file it stands in for.
#
# A mod's test cannot read a repository file (measured for #3231: its test runner refuses an import
# of node:fs, of a file outside the mod's folder and of a file that is not code, gives no Bun,
# process, require or fetch, and answers no fs.read beneath the plugins), so the fixture carries the
# lines and this suite compares them with the real file on every run:
#   1. each line of the fixture is the real suite's line, at the lines the fixture's own
#      SUITE_2991-LINES comment names, word for word;
#   2. no variable the fixture runs a script through (python3 "$SKILL/make-settled.py", node
#      "$ADAPTER") is set by the real suite on a line the fixture leaves out, nor is any variable
#      such a line uses in turn.
# A missing file, comment, fixture or line is a failure that says so, never a skip. Both checks are
# seen to fail here on throwaway files first (L1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TEST_FILE="$ROOT/payload/mods/design-round-guard/tests/register.test.ts"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed -n '1,12p' | sed 's/^/    /'; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# fixture_check <test file> <repository root>: prints nothing and returns 0 where the fixture in the
# test file is the excerpt it says it is; otherwise prints why, one reason a line, and returns 1.
fixture_check() {
  local test_file="$1" root="$2" marker rel real ranges total body want r a b out="" name line seen todo n used u held
  [ -f "$test_file" ] || { echo "the test file is missing: $test_file"; return 1; }
  marker="$(grep -E '^// SUITE_2991-LINES ' "$test_file")"
  [ -n "$marker" ] || { echo "no SUITE_2991-LINES comment in $test_file, so which lines the fixture is cannot be read"; return 1; }
  [ "$(printf '%s\n' "$marker" | wc -l | tr -d ' ')" = 1 ] || { echo "more than one SUITE_2991-LINES comment in $test_file"; return 1; }
  rel="$(printf '%s\n' "$marker" | awk '{ print $3 }')"
  ranges="$(printf '%s\n' "$marker" | awk '{ for (i = 4; i <= NF; i++) print $i }')"
  real="$root/$rel"
  [ -n "$rel" ] && [ -f "$real" ] || { echo "the suite the fixture is taken from is missing: $real"; return 1; }
  [ -n "$ranges" ] || { echo "the SUITE_2991-LINES comment names no lines"; return 1; }
  total="$(awk 'END { print NR }' "$real")"
  # The fixture's own lines: between the line opening the template and the line closing it, with
  # the one spelling a template needs for a dollar sign and brace put back.
  body="$(awk '
    /^const SUITE_2991 = String\.raw`$/ { opened++; on = 1; next }
    on && /^`$/ { closed = 1; exit }
    on { print }
    END { if (opened != 1 || !closed) exit 3 }
  ' "$test_file")" || { echo "the SUITE_2991 fixture was not found whole in $test_file (one line opening it with String.raw and one closing it)"; return 1; }
  body="$(printf '%s\n' "$body" | sed "s/\${'\\\$'}{/\${/g")"
  want=""
  for r in $ranges; do
    case "$r" in
      *[!0-9-]*|-*|*-|*-*-*) echo "the SUITE_2991-LINES comment names lines the check cannot read: $r"; return 1 ;;
    esac
    a="${r%-*}"; b="${r#*-}"
    [ "$a" -ge 1 ] 2>/dev/null && [ "$b" -ge "$a" ] 2>/dev/null || { echo "the SUITE_2991-LINES comment names lines the check cannot read: $r"; return 1; }
    [ "$b" -le "$total" ] || { echo "the fixture says it holds lines $r of $rel, which has only $total lines"; return 1; }
    want="$want$(sed -n "${a},${b}p" "$real")
"
  done
  want="${want%
}"
  # 1. Word for word.
  if [ "$body" != "$want" ]; then
    out="the fixture is not lines $(printf '%s' "$ranges" | tr '\n' ' ') of $rel word for word; the first lines that differ (the real suite's, then the fixture's):
$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$body") | grep -E '^[<>]' | sed -n '1,4p')"
  fi
  # 2. Each variable the fixture runs a script through, and each variable a line setting one uses
  # in turn, is set by the real suite only on lines the fixture holds.
  todo="$(printf '%s\n' "$body" | grep -oE '(^|[^[:alnum:]_.-])(python3?|node|bash|sh|zsh|source|\.)[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*"?\$\{?[A-Za-z_][A-Za-z0-9_]*' | sed -E 's/.*\$\{?//' | sort -u)"
  seen=" "
  while [ -n "$todo" ]; do
    name="$(printf '%s\n' "$todo" | sed -n '1p')"
    todo="$(printf '%s\n' "$todo" | sed '1d')"
    case "$seen" in *" $name "*) continue ;; esac
    seen="$seen$name "
    case "$name" in HOME|PWD|BASH_SOURCE|TMPDIR) continue ;; esac
    for n in $(grep -nE "^[[:space:]]*(export[[:space:]]+|local[[:space:]]+)?$name=" "$real" | cut -d: -f1); do
      line="$(sed -n "${n}p" "$real")"
      held=0
      for r in $ranges; do
        [ "$n" -ge "${r%-*}" ] && [ "$n" -le "${r#*-}" ] && held=1
      done
      [ "$held" = 1 ] || out="$out${out:+
}the fixture runs a script through \$$name, or through a variable set from it, and leaves out line $n of $rel, which sets it: $line"
      used="$(printf '%s\n' "$line" | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' | sed -E 's/\$\{?//' | sort -u)"
      for u in $used; do
        case "$seen" in *" $u "*) ;; *) todo="$todo${todo:+
}$u" ;; esac
      done
    done
  done
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"
  return 1
}

# --- the check itself, on throwaway files (L1) -----------------------------------------------------
mk() {   # mk <name> <lines comment> <fixture body>: a repository holding a ten line suite and a test file
  local d="$tmp/$1"
  mkdir -p "$d/tests" "$d/suite"
  printf '%s\n' '#!/bin/bash' 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' 'TOOL="$HERE/tool.py"' 'T="$(mktemp -d)"' 'echo one' 'python3 "$TOOL" "$T/out"' 'echo two' 'echo three' 'rm -rf "$T"' 'echo done' > "$d/suite/run.sh"
  { printf '%s\n' 'const before = 1' "$2" 'const SUITE_2991 = String.raw`'; printf '%s\n' "$3"; printf '%s\n' '`' 'const after = 2'; } > "$d/tests/register.test.ts"
}
HERE_LINE='HERE="$(cd "$(dirname "${'"'"'$'"'"'}{BASH_SOURCE[0]}")" && pwd)"'
mk right '// SUITE_2991-LINES suite/run.sh 2-4 6-7' "$HERE_LINE"'
TOOL="$HERE/tool.py"
T="$(mktemp -d)"
python3 "$TOOL" "$T/out"
echo two'
got="$(fixture_check "$tmp/right/tests/register.test.ts" "$tmp/right")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$got" ]; then ok "a fixture that is its lines word for word, holding every line that sets its script's variable, passes"; else bad "a fixture that is its lines word for word passes (rc=$rc)" "$got"; fi

mk changed '// SUITE_2991-LINES suite/run.sh 2-4 6-7' "$HERE_LINE"'
TOOL="$HERE/tool.py"
T="$(mktemp -d)"
python3 "$TOOL" "$T/other"
echo two'
got="$(fixture_check "$tmp/changed/tests/register.test.ts" "$tmp/changed")"; rc=$?
case "$got" in *"not lines 2-4 6-7 of suite/run.sh word for word"*'"$T/out"'*'"$T/other"'*) [ "$rc" -eq 1 ] && ok "a fixture with one line changed fails, showing the real line and the fixture's" || bad "a fixture with one line changed fails (rc=$rc)" "$got" ;; *) bad "a fixture with one line changed fails, showing the real line and the fixture's (rc=$rc)" "$got" ;; esac

# The shape of #3231: every line the fixture holds is the suite's, and the line setting TOOL is left out.
mk leftout '// SUITE_2991-LINES suite/run.sh 4-4 6-7' 'T="$(mktemp -d)"
python3 "$TOOL" "$T/out"
echo two'
got="$(fixture_check "$tmp/leftout/tests/register.test.ts" "$tmp/leftout")"; rc=$?
case "$got" in *"word for word"*) bad "a fixture leaving out the line that sets its script's variable is still word for word" "$got" ;; *'leaves out line 3 of suite/run.sh, which sets it: TOOL="$HERE/tool.py"'*) [ "$rc" -eq 1 ] && ok "a fixture leaving out the line that sets its script's variable fails, naming the line" || bad "a fixture leaving out the line that sets its script's variable fails (rc=$rc)" "$got" ;; *) bad "a fixture leaving out the line that sets its script's variable fails, naming the line (rc=$rc)" "$got" ;; esac

# And the line a held line's own variable is set on.
mk chained '// SUITE_2991-LINES suite/run.sh 3-4 6-7' 'TOOL="$HERE/tool.py"
T="$(mktemp -d)"
python3 "$TOOL" "$T/out"
echo two'
got="$(fixture_check "$tmp/chained/tests/register.test.ts" "$tmp/chained")"; rc=$?
case "$got" in *'leaves out line 2 of suite/run.sh, which sets it: HERE='*) [ "$rc" -eq 1 ] && ok "a fixture leaving out the line that sets a variable its script's variable is built from fails" || bad "a fixture leaving out the line a variable is built from fails (rc=$rc)" "$got" ;; *) bad "a fixture leaving out the line that sets a variable its script's variable is built from fails (rc=$rc)" "$got" ;; esac

# Nothing to compare is a failure that says so.
mk nomark '// no comment naming lines' 'echo two'
got="$(fixture_check "$tmp/nomark/tests/register.test.ts" "$tmp/nomark")"; rc=$?
case "$got" in *"no SUITE_2991-LINES comment"*) [ "$rc" -eq 1 ] && ok "a test file with no comment naming the lines fails" || bad "a test file with no comment naming the lines fails (rc=$rc)" "$got" ;; *) bad "a test file with no comment naming the lines fails (rc=$rc)" "$got" ;; esac
mk nosuite '// SUITE_2991-LINES suite/gone.sh 2-4' 'echo two'
got="$(fixture_check "$tmp/nosuite/tests/register.test.ts" "$tmp/nosuite")"; rc=$?
case "$got" in *"the suite the fixture is taken from is missing"*) [ "$rc" -eq 1 ] && ok "a fixture taken from a suite that is not there fails" || bad "a fixture taken from a suite that is not there fails (rc=$rc)" "$got" ;; *) bad "a fixture taken from a suite that is not there fails (rc=$rc)" "$got" ;; esac
mk short '// SUITE_2991-LINES suite/run.sh 8-12' 'echo three'
got="$(fixture_check "$tmp/short/tests/register.test.ts" "$tmp/short")"; rc=$?
case "$got" in *"which has only 10 lines"*) [ "$rc" -eq 1 ] && ok "a fixture naming lines past the end of the suite fails" || bad "a fixture naming lines past the end of the suite fails (rc=$rc)" "$got" ;; *) bad "a fixture naming lines past the end of the suite fails (rc=$rc)" "$got" ;; esac
mk nofixture '// SUITE_2991-LINES suite/run.sh 5-5' 'echo one'
sed 's/^const SUITE_2991 = String\.raw`$/const OTHER = String.raw`/' "$tmp/nofixture/tests/register.test.ts" > "$tmp/nofixture/tests/register.test.ts.new" && mv "$tmp/nofixture/tests/register.test.ts.new" "$tmp/nofixture/tests/register.test.ts"
got="$(fixture_check "$tmp/nofixture/tests/register.test.ts" "$tmp/nofixture")"; rc=$?
case "$got" in *"the SUITE_2991 fixture was not found whole"*) [ "$rc" -eq 1 ] && ok "a test file with no fixture fails" || bad "a test file with no fixture fails (rc=$rc)" "$got" ;; *) bad "a test file with no fixture fails (rc=$rc)" "$got" ;; esac
got="$(fixture_check "$tmp/none/tests/register.test.ts" "$tmp/none")"; rc=$?
case "$got" in *"the test file is missing"*) [ "$rc" -eq 1 ] && ok "a missing test file fails" || bad "a missing test file fails (rc=$rc)" "$got" ;; *) bad "a missing test file fails (rc=$rc)" "$got" ;; esac

# --- the real fixture against the real suite -------------------------------------------------------
got="$(fixture_check "$TEST_FILE" "$ROOT")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$got" ]; then
  ok "SUITE_2991 in the design round guard's tests is the lines of test-score-adapters.sh it names, word for word, and leaves out no line that sets a variable it runs a script through"
else
  bad "SUITE_2991 in the design round guard's tests is the excerpt of test-score-adapters.sh it says it is. To put it right, copy the named lines from the suite into the fixture again (a dollar sign before a brace is written \${'\$'}{ there), or name the lines it now holds in its SUITE_2991-LINES comment, then run the mod's tests" "$got"
fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
