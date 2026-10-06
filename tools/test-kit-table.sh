#!/usr/bin/env bash
# Tests for tools/kit-table.py (#760 item 7): the collision guard's table of mod-kit answers is
# carried into mod-kit's own tests, where each answer is asked of the real reader, and the carried
# copy must be current with the table.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

TOOL="$ROOT/tools/kit-table.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '  output: %s\n' "$2"; return 0; }

# 1. The real tree: the carried test is current with the table.
out="$(python3 "$TOOL" "$ROOT" --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "mod-kit's kit-table.test.ts is current with the collision guard's table (rc $rc)" "$out"
grep -q '[1-9][0-9]* entries' <<< "$out" && ok || bad "and it names how many entries it carries" "$out"

# A copy of the two files the tool reads and writes, to change without touching the tree.
mk() {
  local d="$TMP/$1"
  mkdir -p "$d/payload/mods/collision-guard/tests" "$d/payload/mods/mod-kit/tests"
  cp "$ROOT/payload/mods/collision-guard/tests/register.test.ts" "$d/payload/mods/collision-guard/tests/"
  cp "$ROOT/payload/mods/mod-kit/tests/kit-table.test.ts" "$d/payload/mods/mod-kit/tests/"
  printf '%s' "$d"
}

# 2. A table entry changed and the carried test not regenerated: refused, with the remedy.
D="$(mk changed)"
python3 - "$D/payload/mods/collision-guard/tests/register.test.ts" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '["git {\\"words\\":[\\"git\\",\\"checkout\\",\\"main\\"]}", {"sub":"checkout","args":["main"]}]'
assert old in s, 'fixture entry missing'
s = s.replace(old, '["git {\\"words\\":[\\"git\\",\\"checkout\\",\\"main\\"]}", {"sub":"switch","args":["main"]}]')
open(p, 'w').write(s)
PY
out="$(python3 "$TOOL" "$D" --check 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'not current' <<< "$out" && grep -q 'python3 tools/kit-table.py' <<< "$out" && ok \
  || bad "a table changed without regenerating is refused with the command that fixes it (rc $rc)" "$out"
# The remedy works: running it makes the check pass, and the new answer is in the carried test.
out="$(python3 "$TOOL" "$D" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || bad "the tool writes the carried test (rc $rc)" "$out"
out="$(python3 "$TOOL" "$D" --check 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -q '"sub":"switch"' "$D/payload/mods/mod-kit/tests/kit-table.test.ts" && ok \
  || bad "after the remedy the check passes and carries the changed answer (rc $rc)" "$out"

# 3. A table the tool cannot read is a refusal, never an empty pass.
D="$(mk broken)"
printf 'const nothing = 1\n' > "$D/payload/mods/collision-guard/tests/register.test.ts"
out="$(python3 "$TOOL" "$D" --check 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'cannot read the table' <<< "$out" && ok || bad "a missing table is refused (rc $rc)" "$out"
D="$(mk unknown)"
python3 - "$D/payload/mods/collision-guard/tests/register.test.ts" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('const KIT = new Map<string, unknown>([\n', 'const KIT = new Map<string, unknown>([\n  ["paths {\\"x\\":1}", null],\n', 1)
open(p, 'w').write(s)
PY
out="$(python3 "$TOOL" "$D" --check 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'unknown reader: paths' <<< "$out" && ok || bad "an entry for a reader the tool does not know is refused by name (rc $rc)" "$out"
out="$(python3 "$TOOL" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && grep -qi 'usage' <<< "$out" && ok || bad "no arguments prints usage (rc $rc)" "$out"

# 4. Every entry in the table is carried: the counts agree.
n_table="$(awk '/^const KIT = new Map/,/^\]\)/' "$ROOT/payload/mods/collision-guard/tests/register.test.ts" | grep -c '^  \["')"
n_carried="$(grep -c '^  {"method"' "$ROOT/payload/mods/mod-kit/tests/kit-table.test.ts")"
[ "$n_table" = "$n_carried" ] && [ "$n_table" -gt 0 ] && ok || bad "every table entry is carried ($n_table in the table, $n_carried carried)"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
