#!/usr/bin/env bash
# The close this session card's quiet period outlasts the subagent harvest's limit by its margin
# (claude-config#3770).
#
# The goal box waits QUIET_MS (payload/mods/goal-box/hooks/close.ts) after a turn ends before the
# card can go up, so that the subagent harvest, an async end of turn hook whose limit is the
# "timeout" of hooks/subagent-issue-harvest.sh in payload/settings.hooks.json, has finished first.
# A mod cannot read a file outside its own folder, so the period is a literal there; this suite is
# what holds the two together, and fails when the harvest's limit grows past the period less its
# 30 second margin, or when either value can no longer be read. Seen to fail on fixtures (L1).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
MARGIN=30
pass=0
fail=0

# $1 = close.ts, $2 = settings.hooks.json -> prints "ok" or why not, one line.
judge() {
  python3 -I - "$1" "$2" "$MARGIN" <<'PY'
import json, re, sys
close, settings, margin = sys.argv[1], sys.argv[2], int(sys.argv[3])
m = re.search(r'^export const QUIET_MS = ([0-9_]+)$', open(close).read(), re.M)
if not m:
    print('QUIET_MS is not a plain literal in close.ts, so it cannot be read'); sys.exit()
quiet = int(m.group(1).replace('_', '')) / 1000
limits = [h.get('timeout') for blocks in json.load(open(settings)).get('hooks', {}).values() for b in blocks for h in b.get('hooks', []) if h.get('command', '').endswith('/hooks/subagent-issue-harvest.sh')]
if len(limits) != 1 or not isinstance(limits[0], (int, float)):
    print(f'the subagent harvest hook has {len(limits)} timeouts in the settings, not one number'); sys.exit()
if quiet < limits[0] + margin:
    print(f'the quiet period is {quiet:g} seconds, under the harvest limit of {limits[0]:g} plus {margin}'); sys.exit()
print('ok')
PY
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fixture() {   # $1 = name, $2 = QUIET_MS literal, $3 = harvest timeout
  printf 'export const QUIET_MS = %s\n' "$2" > "$tmp/$1.ts"
  printf '{"hooks":{"SubagentStop":[{"hooks":[{"type":"command","command":"__CLAUDE_HOME__/hooks/subagent-issue-harvest.sh","timeout":%s,"async":true}]}]}}\n' "$3" > "$tmp/$1.json"
}
fixture equal 180_000 180
fixture margin 210_000 180
fixture short 209_000 180
check() {   # $1 = fixture, $2 = expected pattern, $3 = what it shows
  got="$(judge "$tmp/$1.ts" "$tmp/$1.json")"
  if printf '%s' "$got" | grep -q -- "$2"; then
    pass=$((pass + 1)); echo "PASS: $3"
  else
    fail=$((fail + 1)); echo "FAIL: $3 (got: $got)"
  fi
}
check equal 'under the harvest limit' 'a period equal to the harvest limit fails'
check short 'under the harvest limit' 'a period one second short of the margin fails'
check margin '^ok$' 'a period of the limit plus the margin passes'

got="$(judge "$ROOT/payload/mods/goal-box/hooks/close.ts" "$ROOT/payload/settings.hooks.json")"
if [ "$got" = ok ]; then
  pass=$((pass + 1)); echo "PASS: the close card's quiet period outlasts the subagent harvest's limit by $MARGIN seconds"
else
  fail=$((fail + 1)); echo "FAIL: $got"
fi

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
