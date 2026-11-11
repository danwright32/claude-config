#!/usr/bin/env bash
# test-shoot-web.sh: the drive helper contract of shoot_web.mjs (claude-config#2516), whose node
# tests live in test_shoot_web.mjs beside it.
#
# The TAP reporter is named on purpose: node's default reporter differs by version and by whether
# the output is a terminal (node 24's default prints its counts behind an info sign, with no "# pass"
# line at all, which is how CI run 42931345332 failed), and its counts
# are what is read here. The exit code is read as well, never the counts alone (L184). Where node is
# missing the part is said by name as unmeasured, never a pass (L411).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed -n '1,30p' | sed 's/^/    /'; }

if command -v node >/dev/null 2>&1; then
  node --test --test-reporter=tap "$SKILL/scripts/test_shoot_web.mjs" > "$T/node.out" 2>&1
  node_rc=$?
  n_pass="$(sed -n 's/^# pass \([0-9]*\)$/\1/p' "$T/node.out")"
  n_fail="$(sed -n 's/^# fail \([0-9]*\)$/\1/p' "$T/node.out")"
  if [ "$node_rc" -eq 0 ] && [ -n "$n_pass" ] && [ "${n_fail:-1}" = 0 ] && [ "$n_pass" -gt 0 ]; then
    pass=$((pass + n_pass))
  else
    bad "shoot_web.mjs's node tests (node $(node --version) exited $node_rc, passed ${n_pass:-none}, failed ${n_fail:-unknown})" "$(tail -n 30 "$T/node.out")"
  fi
else
  echo "SUITE-PART-UNMEASURED node is not on PATH, so shoot_web.mjs's contract was not run"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
