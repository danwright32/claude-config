#!/usr/bin/env bash
# A pull records each mod it replaced, for the sessions that loaded it (claude-config#2514).
#
# A running session keeps the mod code it loaded unless Claude Code reloads it, which a headless
# session never does by default (measured on Claude Code 2.1.322 on 2026-11-10) and an interactive
# one can hold or pause (read from the binary, not measured; README "Mods"). So claude-sync's apply records every mod one of whose files
# it wrote or removed (payload/hooks/lib/mods-replaced.sh, whose own suite holds the record's shape),
# and rule-files-changed.sh tells a session that loaded one to run /reload-plugins. This suite holds
# the wiring: a real pull, against a fixture home and repo, writes the record for the mod it changed
# and for no other, and a second pull that changes nothing leaves it as it was. Kept out of
# tests/test-claude-sync.sh, whose length and run time are open issues (#2463, #2091).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

SCRIPT="$ROOT/claude-sync"
pass=0; fail=0
check(){ # check <name> <command>
  if bash -c "$2" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sync-mods-replaced.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
H="$WORK/home"; R="$WORK/repo"
mkdir -p "$H/.claude"
C="$H/.claude"
for m in changed untouched; do
  mkdir -p "$C/mods/$m/.claude-plugin" "$C/mods/$m/hooks" "$R/payload/mods/$m/.claude-plugin" "$R/payload/mods/$m/hooks"
  printf '{ "name": "%s" }\n' "$m" > "$C/mods/$m/.claude-plugin/plugin.json"
  cp "$C/mods/$m/.claude-plugin/plugin.json" "$R/payload/mods/$m/.claude-plugin/plugin.json"
  printf 'export const v = 1\n' > "$C/mods/$m/hooks/register.ts"
  printf 'export const v = 1\n' > "$R/payload/mods/$m/hooks/register.ts"
done
printf 'export const v = 2\n' > "$R/payload/mods/changed/hooks/register.ts"
echo '{"hooks":{}}' > "$C/settings.json"

# No claude to validate the mods with: that check is not what this suite measures, and a real one
# would cost seconds per mod.
pull(){
  HOME="$H" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 SYNC_NO_SEND_TESTS=1 \
    SYNC_CLAUDE_BIN="$WORK/no-such-claude-here" CLAUDE_HOME="$C" SYNC_REPO="$R" bash "$SCRIPT" pull > "$WORK/pull.out" 2>&1
}
pull; rc_pull=$?
check "fixture: the pull applied the changed mod" "grep -q 'v = 2' '$C/mods/changed/hooks/register.ts'"
# What the pull said, indented under that FAIL so run-all-tests keeps it as the message's own
# continuation (it keeps a FAIL line and the lines indented past it, nothing else). Without this a
# red run on another machine shows four verdicts and none of the reason (L177).
if ! grep -q 'v = 2' "$C/mods/changed/hooks/register.ts" 2>/dev/null; then
  echo "    the pull exited $rc_pull and said:"
  sed -n '1,30p' "$WORK/pull.out" | cut -c1-300 | sed 's/^/      /'
fi
check "the pull recorded the mod it replaced" "grep -q '^changed	' '$C/state/mods-replaced.tsv'"
check "and not the mod it left alone" "[ -f '$C/state/mods-replaced.tsv' ] && ! grep -q '^untouched' '$C/state/mods-replaced.tsv'"
before="$(cat "$C/state/mods-replaced.tsv" 2>/dev/null)"
pull
check "a pull that replaced nothing leaves the record as it was" \
  "[ -n '$before' ] && [ \"\$(cat '$C/state/mods-replaced.tsv')\" = '$before' ]"

echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
