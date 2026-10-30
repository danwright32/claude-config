#!/usr/bin/env bash
# lib/test_bad_byte_locale.sh, and the scan keeping every bad byte case on it (claude-config#1923).
#
# The cases that feed a hook a byte that is not UTF-8 ran under en_US.UTF-8 by name. Where a machine
# does not have it, as Linux often does not, the locale falls back to C, where nothing trips on such
# a byte, so those cases passed with or without their fix and said nothing. The helper picks a UTF-8
# locale this machine has and measures that the fault shows under it, saying UNMEASURED when it does
# not (L411); the scan at the end fails on a suite that names en_US.UTF-8 itself again, or uses the
# helper's locale without measuring it.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bbl.XXXXXXXX")" || exit 1
case "${WORK%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [ "$2" = "$3" ]; then ok; else bad "$1: wanted '$2', got '$3'"; fi; }

if ! . "$DIR/lib/test_bad_byte_locale.sh"; then
  bad "lib/test_bad_byte_locale.sh did not load"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 1
fi
for f in bad_byte_locale bad_byte_measured; do
  declare -F "$f" >/dev/null && ok || bad "lib/test_bad_byte_locale.sh defines no $f"
done

# ---------------------------------------------------------------------------
echo "the locale is one this machine has, named by locale -a"

# A stand in for locale -a, listing what each kind of machine lists.
stub_locale(){ # stub_locale <dir> <line>... -> a locale command printing those lines for -a
  local d="$1" l
  shift
  mkdir -p "$d"
  { printf '#!/bin/sh\n'; for l in "$@"; do printf 'echo %s\n' "$l"; done; } > "$d/locale"
  chmod +x "$d/locale"
}
stub_locale "$WORK/mac" C POSIX en_US.UTF-8 C.UTF-8 fr_FR.UTF-8
stub_locale "$WORK/linux" C C.utf8 POSIX
stub_locale "$WORK/bare" C POSIX
check_eq "en_US.UTF-8 first where the machine has it" "en_US.UTF-8" "$(PATH="$WORK/mac:$PATH" bad_byte_locale)"
check_eq "a Linux machine with only C.utf8 gets C.utf8, not a locale it lacks" "C.utf8" "$(PATH="$WORK/linux:$PATH" bad_byte_locale)"
check_eq "a machine with no UTF-8 locale gets C" "C" "$(PATH="$WORK/bare:$PATH" bad_byte_locale)"
PATH="$WORK/bare:$PATH" bad_byte_locale >/dev/null && bad "bad_byte_locale returned 0 with no UTF-8 locale to give" || ok

# On this machine, whatever it is, the answer is a locale locale -a lists, or C.
here="$(bad_byte_locale)"
listed=$'\n'"$(locale -a 2>/dev/null)"$'\n'
if [ "$here" = C ] || [[ "$listed" == *$'\n'"$here"$'\n'* ]]; then ok
else bad "bad_byte_locale gave $here, which locale -a here does not list"; fi

# ---------------------------------------------------------------------------
echo "a fault that does not show under it is said, never passed in silence"

out="$(PATH="$WORK/bare:$PATH" bad_byte_measured python "#1923 probe" 2>&1)"; rc=$?
check_eq "with no UTF-8 locale, measured says no" 1 "$rc"
case "$out" in "SUITE-PART-UNMEASURED #1923 probe: "*"none of en_US.UTF-8"*) ok ;; *) bad "with no UTF-8 locale, it should say UNMEASURED naming the locales it looked for, said: $out" ;; esac

# A machine that lists a locale it cannot really load: the same fallback to C the old cases sat on.
stub_locale "$WORK/ghost" C en_US.utf8
if [ "$(uname -s)" = Darwin ]; then
  # The Mac has en_US.UTF-8 but no en_US.utf8, so naming that one falls back to C here.
  out="$(PATH="$WORK/ghost:$PATH" bad_byte_measured regex "#1923 ghost" 2>&1)"; rc=$?
  check_eq "a listed locale that falls back to C is measured as not tripping" 1 "$rc"
  case "$out" in "SUITE-PART-UNMEASURED #1923 ghost: regex under en_US.utf8 here reads"*) ok ;; *) bad "a locale that falls back to C should be said UNMEASURED, said: $out" ;; esac
fi

out="$(bad_byte_measured nosuch "#1923 kind" 2>&1)"; rc=$?
check_eq "a kind it cannot measure is not reported measured" 1 "$rc"
case "$out" in "SUITE-PART-UNMEASURED #1923 kind: "*"nosuch"*) ok ;; *) bad "an unknown kind should be said UNMEASURED, said: $out" ;; esac

# Each kind either trips here or says so: a quiet 1 would drop the cases with nothing printed.
for kind in python awk grep sed regex; do
  out="$(bad_byte_measured "$kind" "#1923 $kind" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok
  elif [ "$rc" -eq 1 ] && [ "${out#SUITE-PART-UNMEASURED }" != "$out" ]; then ok
  else bad "bad_byte_measured $kind neither tripped quietly nor said UNMEASURED: rc=$rc said: $out"; fi
  # On the Mac every one of them trips under en_US.UTF-8: that is the fault each set of cases guards.
  if [ "$(uname -s)" = Darwin ] && [ "$here" = en_US.UTF-8 ]; then
    check_eq "on this Mac, $kind trips on a byte that is not UTF-8 under en_US.UTF-8" 0 "$rc"
  fi
done

# ---------------------------------------------------------------------------
echo "every suite with bad byte cases runs them under the helper's locale, and measures it"

# Suites anywhere in the repository, and their helpers, minus this suite and the helper itself.
suites=()
while IFS= read -r f; do suites+=("$f"); done < <(
  find "$ROOT" \( -name .git -o -name worktrees -o -name node_modules \) -prune -o -type f \( -name 'test-*.sh' -o -name 'test_*.py' \) -print | sort)
[ "${#suites[@]}" -ge 100 ] && ok || bad "only ${#suites[@]} suites were found under $ROOT, so the scan is reading the wrong tree"
# Naming en_US.UTF-8, or picking a locale from locale -a by hand: the second is a copy of the helper
# that measures nothing, which two suites held (L613).
pinned_re='en_US\.(UTF-8|utf8)|locale -a'
pinned(){ # pinned <file>... -> file:line of each naming en_US.UTF-8 itself, or reading locale -a
  grep -n -E "$pinned_re" "$@" 2>/dev/null
}
hits=""
for f in "${suites[@]}"; do
  [ "$f" = "$DIR/test-bad-byte-locale.sh" ] && continue
  h="$(pinned "$f")" && hits="$hits${f#"$ROOT"/}: $h
"
done
if [ -z "$hits" ]; then ok; else bad "a suite names en_US.UTF-8 itself, or picks its own locale from locale -a, and a locale a machine lacks falls back to C on a machine without it, so its cases pass with or without their fix; take the locale from bad_byte_locale in lib/test_bad_byte_locale.sh:
$hits"; fi
unmeasured=""
for f in "${suites[@]}"; do
  [ "$f" = "$DIR/test-bad-byte-locale.sh" ] && continue
  grep -q 'BAD_BYTE_LOCALE' "$f" || continue
  grep -q 'bad_byte_measured' "$f" || unmeasured="$unmeasured ${f#"$ROOT"/}"
done
if [ -z "$unmeasured" ]; then ok; else bad "a suite runs cases under the helper's locale without measuring that the fault shows there, so on a machine where it does not they pass in silence:$unmeasured"; fi
# The scan is seen to fire on the form the suites held, and not on the one they hold now.
printf '%s\n' 'out="$(LC_ALL=en_US.UTF-8 run "$T_BYTE")"' > "$WORK/probe-pinned"
printf '%s\n' 'out="$(LC_ALL="$BAD_BYTE_LOCALE" run "$T_BYTE")"' > "$WORK/probe-helper"
printf '%s\n' "UTF8_1880=\"\$(locale -a 2>/dev/null | grep -i -m1 -E '^(en_US|C)\\.utf-?8\$')\"" > "$WORK/probe-own"
[ -n "$(pinned "$WORK/probe-own")" ] && ok || bad "the scan does not fire on a suite picking its own locale from locale -a"
[ -n "$(pinned "$WORK/probe-pinned")" ] && ok || bad "the scan does not fire on a case pinned to en_US.UTF-8"
[ -z "$(pinned "$WORK/probe-helper")" ] && ok || bad "the scan fires on a case using the helper's locale"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
