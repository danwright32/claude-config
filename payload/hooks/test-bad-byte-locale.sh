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
# The checkout, as lib/checkout-root.sh finds it (#1663); installed in ~/.claude there is none, and
# the scan below reads the payload it sits in instead.
ROOT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null)" || ROOT="$(cd "$DIR/.." && pwd)"
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
for f in bad_byte_locale bad_byte_measured bad_byte_kinds; do
  declare -F "$f" >/dev/null && ok || bad "lib/test_bad_byte_locale.sh defines no $f"
done
# python is two kinds, because its two reads differ (claude-config#1957): under UTF-8 mode, which
# Python 3.15 turns on by default, stdin reads such a byte as a surrogate while open() still raises.
kinds="$(bad_byte_kinds 2>/dev/null)"
check_eq "the kinds bad_byte_measured knows" "python-stdin python-file awk grep sed regex" "$kinds"

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
if PATH="$WORK/bare:$PATH" bad_byte_locale >/dev/null; then bad "bad_byte_locale returned 0 with no UTF-8 locale to give"; else ok; fi

# On this machine, whatever it is, the answer is a locale locale -a lists, or C.
here="$(bad_byte_locale)" && have_utf8=yes || have_utf8=no
listed=$'\n'"$(locale -a 2>/dev/null)"$'\n'
if [ "$here" = C ] || [[ "$listed" == *$'\n'"$here"$'\n'* ]]; then ok
else bad "bad_byte_locale gave $here, which locale -a here does not list"; fi

# ---------------------------------------------------------------------------
echo "a fault that does not show under it is said, never passed in silence"

out="$(PATH="$WORK/bare:$PATH" bad_byte_measured python-stdin "#1923 probe" 2>&1)"; rc=$?
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

# Whether python3 should trip is read from what python3 reports for that read, its encoding and its
# error handler, never from the read raising, which is what the probe itself measures (L721). A
# strict UTF-8 or ASCII read raises on such a byte; surrogateescape reads it as a surrogate. Which
# one stdin gets is not a version number: UTF-8 mode, on by default from Python 3.15 and by
# PYTHONUTF8=1 before it, gives stdin surrogateescape and leaves open() strict.
python_reads(){ # python_reads <stdin|file> [VAR=value]... -> "<codec> <errors>" for that read here
  local read="$1"; shift
  case "$read" in
    stdin) printf 'x' | env LC_ALL="$here" "$@" python3 -c 'import codecs, sys; print(codecs.lookup(sys.stdin.encoding).name, sys.stdin.errors)' 2>/dev/null ;;
    file)  env LC_ALL="$here" "$@" python3 -c 'import codecs, os; f = open(os.devnull); print(codecs.lookup(f.encoding).name, f.errors)' 2>/dev/null ;;
  esac
}
python_trips(){ # python_trips "<codec> <errors>" -> 0 to expect a trip, 1 not; returns 1 when unknown
  case "$1" in
    'utf-8 strict'|'ascii strict') printf '0\n' ;;
    *' surrogateescape') printf '1\n' ;;
    *) return 1 ;;
  esac
}

# Each kind either trips here or says so: a quiet 1 would drop the cases with nothing printed.
for kind in $kinds; do
  out="$(bad_byte_measured "$kind" "#1923 $kind" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok
  elif [ "$rc" -eq 1 ] && [ "${out#SUITE-PART-UNMEASURED }" != "$out" ]; then ok
  else bad "bad_byte_measured $kind neither tripped quietly nor said UNMEASURED: rc=$rc said: $out"; fi
  case "$out" in *"does not know how to measure"*) bad "bad_byte_kinds lists $kind, which bad_byte_measured does not know how to measure" ;; esac
  case "$kind" in
    python-*)
      # Wherever the machine has a UTF-8 locale, the probe agrees with what python3 says of the read.
      [ "$have_utf8" = yes ] || continue
      READS="$(python_reads "${kind#python-}")"
      if want="$(python_trips "$READS")"; then
        check_eq "$kind trips exactly when python3 reports a strict read for it here ($READS)" "$want" "$rc"
      else
        echo "SUITE-PART-UNMEASURED #1957 $kind: python3 reports '$READS' for the read under $here, which this suite has no expectation for"
      fi
      ;;
    *)
      # On the Mac each of these trips under en_US.UTF-8: that is the fault each set of cases guards.
      if [ "$(uname -s)" = Darwin ] && [ "$here" = en_US.UTF-8 ]; then
        check_eq "on this Mac, $kind trips on a byte that is not UTF-8 under en_US.UTF-8" 0 "$rc"
      fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
echo "python's two reads, with UTF-8 mode off and on, whatever this Python's default is"

# Python 3.15 turned UTF-8 mode on by default and the suite failed on the work MacBook, written where
# it was off (claude-config#1957). Each arm is set here by PYTHONUTF8, so both run on every machine.
if [ "$have_utf8" = yes ]; then
  check_eq "with UTF-8 mode off, python3 reads stdin strictly" "utf-8 strict" "$(python_reads stdin PYTHONUTF8=0)"
  check_eq "with UTF-8 mode on, python3 reads stdin with surrogateescape" "utf-8 surrogateescape" "$(python_reads stdin PYTHONUTF8=1)"
  check_eq "with UTF-8 mode on, python3 still opens a file strictly" "utf-8 strict" "$(python_reads file PYTHONUTF8=1)"
  out="$(PYTHONUTF8=0 bad_byte_measured python-stdin "#1957 stdin off" 2>&1)"; rc=$?
  check_eq "with UTF-8 mode off, the stdin read trips" 0 "$rc"
  out="$(PYTHONUTF8=1 bad_byte_measured python-stdin "#1957 stdin on" 2>&1)"; rc=$?
  check_eq "with UTF-8 mode on, the stdin read does not trip" 1 "$rc"
  case "$out" in "SUITE-PART-UNMEASURED #1957 stdin on: python-stdin under $here here reads"*) ok ;; *) bad "with UTF-8 mode on, the stdin read should be said UNMEASURED, said: $out" ;; esac
  out="$(PYTHONUTF8=1 bad_byte_measured python-file "#1957 file on" 2>&1)"; rc=$?
  check_eq "with UTF-8 mode on, the file read still trips, so its cases stay measured" 0 "$rc"
  check_eq "and says nothing" "" "$out"
  out="$(PYTHONUTF8=0 bad_byte_measured python-file "#1957 file off" 2>&1)"; rc=$?
  check_eq "with UTF-8 mode off, the file read trips" 0 "$rc"
else
  echo "SUITE-PART-UNMEASURED #1957 python with UTF-8 mode off and on: this machine has no UTF-8 locale to read under"
fi

# ---------------------------------------------------------------------------
echo "every suite with bad byte cases runs them under the helper's locale, and measures it"

# Suites anywhere in the repository, and their helpers, minus this suite and the helper itself.
# Each list is read into a variable first, never through process substitution, whose child bash 3.2
# never waits for and whose exit can cut short what this suite prints next (L1035, #1989).
suites=()
suite_list="$(find "$ROOT" \( -name .git -o -name worktrees -o -name node_modules \) -prune -o -type f \( -name 'test-*.sh' -o -name 'test_*.py' \) -print | sort)"
while IFS= read -r f; do [ -n "$f" ] && suites+=("$f"); done <<SUITE_LIST
$suite_list
SUITE_LIST
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
# A kind the helper does not know says UNMEASURED on every machine, so its cases never count, and the
# line reads like any honest UNMEASURED (#1957, where python became python-stdin and python-file).
unknown_kinds(){ # unknown_kinds <file>... -> file:kind for each bad_byte_measured naming a kind not in bad_byte_kinds
  local f k named
  for f in "$@"; do
    named="$(grep -o -E 'bad_byte_measured [A-Za-z0-9_-]+' "$f" 2>/dev/null | sed 's/^bad_byte_measured //')"
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      case " $kinds " in *" $k "*) ;; *) printf '%s:%s\n' "${f#"$ROOT"/}" "$k" ;; esac
    done <<NAMED
$named
NAMED
  done
}
others=()
for f in "${suites[@]}"; do [ "$f" = "$DIR/test-bad-byte-locale.sh" ] || others+=("$f"); done
strays="$(unknown_kinds "${others[@]}")"
if [ -z "$strays" ]; then ok; else bad "a suite asks bad_byte_measured about a kind it does not know, so those cases are UNMEASURED on every machine; use one of: $kinds
$strays"; fi
printf '%s\n' 'bad_byte_measured python "#x" || true' > "$WORK/probe-oldkind"
printf '%s\n' 'bad_byte_measured python-file "#x" || true' > "$WORK/probe-newkind"
[ -n "$(unknown_kinds "$WORK/probe-oldkind")" ] && ok || bad "the kind scan does not fire on a suite still asking about python"
[ -z "$(unknown_kinds "$WORK/probe-newkind")" ] && ok || bad "the kind scan fires on a suite asking about python-file"
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
