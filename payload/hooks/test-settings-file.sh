#!/usr/bin/env bash
# Tests for lib/settings-file.sh, the one lookup of the file that holds the hooks block
# (claude-config#1237), and the scan that keeps it the only one.
#
# Fifteen suites wrote the lookup out for themselves, and three named only the repository's
# spelling, so they failed (or declared themselves not run) from the installed copy the post sync
# suite runs (measured 2026-10-16). A shared helper ends the copies only with
# a scan that fails on the next one (L613), so the scan is here beside the helper's own cases.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/settings-file.sh" || {
  echo "FAIL: lib/settings-file.sh is missing beside $DIR"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# The two spellings, held in variables so no line here names either as a path, which is what the
# scan below looks for.
SHIPPED="settings.hooks.json"
INSTALLED="settings.json"

# ---- the lookup --------------------------------------------------------------------------------
mkdir -p "$T/checkout" "$T/deployed" "$T/both" "$T/neither"
: > "$T/checkout/$SHIPPED"
: > "$T/deployed/$INSTALLED"
: > "$T/both/$SHIPPED"; : > "$T/both/$INSTALLED"
got="$(hook_settings_file "$T/checkout")"
[ "$got" = "$T/checkout/$SHIPPED" ] && check "the checkout answers with the shipped settings" ok \
  || check "the checkout answers with the shipped settings" "got [$got]"
got="$(hook_settings_file "$T/deployed")"
[ "$got" = "$T/deployed/$INSTALLED" ] && check "an installed copy answers with the installed settings" ok \
  || check "an installed copy answers with the installed settings" "got [$got]"
got="$(hook_settings_file "$T/both/")"
[ "$got" = "$T/both/$SHIPPED" ] && check "where both exist the shipped settings win" ok \
  || check "where both exist the shipped settings win" "got [$got]"
got="$(hook_settings_file "$T/neither")"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$got" ] && check "neither is an answer of its own, not an empty path" ok \
  || check "neither is an answer of its own, not an empty path" "rc $rc, printed [$got]"

# ---- the scan ----------------------------------------------------------------------------------
# A suite that writes either spelling out as a path beside a directory, on a line that is not a
# comment, is a copy of the lookup. Read once per file (L297): grep picks the files that name one at
# all, then one awk pass over each prints file:line for every line that is code.
# Bracketed rather than backslashed, because awk -v turns "\." into a bare "." that matches anything.
COPY_RE='/settings[.]hooks[.]json|[.][.]/settings[.]json'
inline_copies() {   # $@ = directories to scan
  local f
  grep -rlE --include='test-*.sh' "$COPY_RE" "$@" 2>/dev/null | while IFS= read -r f; do
    awk -v re="$COPY_RE" -v f="$f" '$0 !~ /^[ \t]*#/ && $0 ~ re { print f ":" FNR ": " $0 }' "$f"
  done
}

# Seen to fail first (L1): a suite with its own copy is reported, one that asks the helper is not,
# and a comment or a message naming the spelling is not a copy.
mkdir -p "$T/scan/hooks"
printf 'SETTINGS="$DIR/../%s"\n[ -f "$SETTINGS" ] || SETTINGS="$DIR/../%s"\n' "$SHIPPED" "$INSTALLED" > "$T/scan/hooks/test-copy.sh"
cat > "$T/scan/hooks/test-helper.sh" <<'SH'
# In the repository the hooks block is payload/settings.hooks.json.
SETTINGS="$(hook_settings_file "$DIR/..")" || echo "neither settings.hooks.json nor settings.json beside $DIR"
SH
found="$(inline_copies "$T/scan")"
case "$found" in
  *test-copy.sh:1:*test-copy.sh:2:*) check "the scan reports both lines of an inline copy" ok ;;
  *) check "the scan reports both lines of an inline copy" "it found [$found]" ;;
esac
case "$found" in
  *test-helper.sh*) check "a suite asking the helper is not reported" "it was: [$found]" ;;
  *) check "a suite asking the helper is not reported" ok ;;
esac

# The real tree: every suite the payload ships, from wherever this copy of it is.
ROOTS=()
for d in "$DIR" "$DIR/../skills" "$DIR/../mods"; do [ -d "$d" ] && ROOTS+=("$d"); done
n_suites="$(find "${ROOTS[@]}" -name 'test-*.sh' 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_suites" -gt 50 ] && check "the scan reads the shipped suites ($n_suites of them)" ok \
  || check "the scan reads the shipped suites" "only $n_suites found under ${ROOTS[*]}, so a clean answer would mean nothing"
found="$(inline_copies "${ROOTS[@]}")"
[ -z "$found" ] && check "no suite carries its own copy of the settings lookup" ok \
  || check "no suite carries its own copy of the settings lookup" "ask lib/settings-file.sh (hook_settings_file) instead:
$found"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
