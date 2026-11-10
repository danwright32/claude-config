#!/bin/bash
# The area check lets the installed spool helper's project folder argument go unjudged for the
# subcommands in SPOOL_KEY_COMMANDS (payload/mods/area-check/hooks/rules.ts, claude-config#2636),
# because those read only a spool key from that folder and write under the spool root. That is a
# claim about the helper's own text, so this suite holds it there, against the real helper:
#   - The list is exactly the dispatch lines of payload/hooks/lib/issue-spool.sh that hand
#     "${1:-$PWD}" on as the folder, so a subcommand added to the helper, or one the list names that
#     the helper does not, turns red here (L96).
#   - Each one, run against a throwaway checkout with records pending in a throwaway spool, leaves
#     every file in that checkout as it was and adds none (L1: each check is seen to fail by the
#     control at the end, a subcommand made to write into its folder).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so the area check's list could not be read"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

HELPER="$ROOT/payload/hooks/lib/issue-spool.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-area-check-spool-key-only.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# The list as the area check holds it.
cat >"$TMP/list.mjs" <<'JS'
const { SPOOL_KEY_COMMANDS } = await import(process.argv[2])
console.log([...SPOOL_KEY_COMMANDS].sort().join('\n'))
JS
listed="$(node --experimental-strip-types --no-warnings "$TMP/list.mjs" "$ROOT/payload/mods/area-check/hooks/rules.ts" 2>&1)" || {
  check "rules.ts's SPOOL_KEY_COMMANDS is read" "$listed"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
}
# The helper's dispatch lines handing "${1:-$PWD}" on as the folder.
dispatched="$(sed -n '/^if \[ "\${BASH_SOURCE\[0\]}" = "\${0}" \]; then/,/^fi$/p' "$HELPER" \
  | grep -F '"${1:-$PWD}"' | sed -E 's/^[[:space:]]*([a-z-]+)\).*/\1/' | sort)"
[ -n "$dispatched" ] && [ "$(printf '%s\n' "$dispatched" | wc -l | tr -d ' ')" -ge 10 ] \
  && check "the helper's dispatch is found" ok || check "the helper's dispatch is found" "found: $dispatched"
[ "$listed" = "$dispatched" ] && check "SPOOL_KEY_COMMANDS is exactly the subcommands handed a project folder" ok \
  || check "SPOOL_KEY_COMMANDS is exactly the subcommands handed a project folder" "rules.ts lists: $(echo $listed); the helper hands the folder in: $(echo $dispatched)"

# A throwaway checkout and spool, and a HOME of its own, so nothing real is read or written.
REPO="$TMP/repo"; SPOOL="$TMP/spool"; ELSEWHERE="$TMP/elsewhere"
mkdir -p "$REPO/src" "$SPOOL" "$ELSEWHERE" "$TMP/home"
printf 'export const a = 1\n' >"$REPO/src/a.ts"
git -C "$REPO" init -q >/dev/null 2>&1
git -C "$REPO" -c user.email=t@example.com -c user.name=t add src/a.ts >/dev/null 2>&1
git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q -m init >/dev/null 2>&1
snapshot(){ (cd "$REPO" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(shasum "$f" | cut -c1-40)" "$f"; done); }
spool(){ (cd "$ELSEWHERE" && HOME="$TMP/home" CLAUDE_ISSUE_SPOOL_DIR="$SPOOL" bash "$1" "${@:2}" >/dev/null 2>&1) || true; }
before="$(snapshot)"
# A record pending for the checkout, so the subcommands that move records have records to move.
spool "$HELPER" append "$REPO" '{"kind":"finding","text":"a pending finding"}'
spool "$HELPER" note "$REPO" "a noted finding" "spool key suite"
[ -n "$(ls -A "$SPOOL" 2>/dev/null)" ] && check "the throwaway spool holds the pending records" ok || check "the throwaway spool holds the pending records" "nothing was written under $SPOOL"

for cmd in $listed; do
  case "$cmd" in
    append) spool "$HELPER" append "$REPO" '{"kind":"finding","text":"another"}' ;;
    note) spool "$HELPER" note "$REPO" "another finding" "spool key suite" ;;
    pending) spool "$HELPER" pending "$REPO" "" "$TMP/stamp" ;;
    clear) spool "$HELPER" clear "$REPO" "" "$TMP/stamp" ;;
    *) spool "$HELPER" "$cmd" "$REPO" ;;
  esac
  after="$(snapshot)"
  [ "$after" = "$before" ] && check "$cmd leaves the folder it is handed as it was" ok \
    || check "$cmd leaves the folder it is handed as it was" "before: $before; after: $after"
done

# The control: a copy of the helper whose clear writes into the folder it is handed is caught.
sed 's|^    clear)        issue_spool_clear |    clear)        printf x >"${1}/src/a.ts"; issue_spool_clear |' "$HELPER" >"$TMP/writing-spool.sh"
grep -q 'printf x >"${1}/src/a.ts"' "$TMP/writing-spool.sh" && check "the control copy writes into its folder" ok || check "the control copy writes into its folder" "the clear dispatch line was not found to change"
spool "$TMP/writing-spool.sh" clear "$REPO" "" "$TMP/stamp"
[ "$(snapshot)" != "$before" ] && check "a clear that writes into its folder is seen by the snapshot" ok || check "a clear that writes into its folder is seen by the snapshot" "the snapshot did not change"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
