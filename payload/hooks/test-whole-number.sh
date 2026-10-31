#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/
# lib/whole-number.sh, the one test of a number above zero (whole_above_zero, and decimal_above_zero
# for a fraction of a second), and the scan that keeps it the only one (claude-config#1948).
#
# About 45 settings and readings checked for a number above zero by hand, as a case pattern naming
# the empty string, anything but digits, and a bare 0 (0.0 and 0.00 for the decimal two). That
# refuses only a LITERAL zero, so 00 passed as a number above zero: in lib/bounded-run.sh it reached
# perl's alarm, which reads it as 0 and set no bound at all (claude-config#1931). #1931 fixed two
# sites by cutting leading zeros by hand, a third shape. Every site now asks the helper and names the
# variable it hands the value back in, leading zeros cut, so bash arithmetic never reads it as octal.
# This fails the next hand written copy of any of those shapes, and a call naming no variable, on the
# day it lands (L613).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/whole-number.sh"
# The checkout this copy is the payload of, found by the one shared test (lib/checkout-root.sh,
# claude-config#1567): a repository above that is not this one is no checkout.
ROOT="${WHOLE_NUMBER_ROOT:-$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)}"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# ---------------------------------------------------------------------------
# The helper.
# ---------------------------------------------------------------------------
if [ -f "$LIB" ] && . "$LIB" && type whole_above_zero >/dev/null 2>&1; then
  check "lib/whole-number.sh loads and defines whole_above_zero" ok
  # A value that passes is handed back with its leading zeros cut, so bash arithmetic, which reads a
  # leading zero as octal, gets the number that was meant: 0500 was 320 there, and 08 an error.
  for pair in 1:1 5:5 05:5 007:7 08:8 09:9 0500:500 10:10 100:100 300:300 21600:21600; do
    in="${pair%%:*}"; want="${pair#*:}"; got=unset
    if whole_above_zero "$in" got; then
      [ "$got" = "$want" ] && check "'$in' is a whole number above zero, handed back as $want" ok \
                           || check "'$in' is a whole number above zero, handed back as $want" "handed back [$got]"
    else
      check "'$in' is a whole number above zero, handed back as $want" "refused"
    fi
  done
  check "and arithmetic on 08 handed back is 8, not an error" "$(whole_above_zero 08 got && [ "$((got + 1))" = 9 ] 2>/dev/null && echo ok || echo "got [$got]")"
  # Zero however written is zero (#1948): 00 and 000 were read as numbers above zero. A value that
  # fails leaves the name as it was, so the caller's own default or refusal is all that happens.
  for v in 0 00 000 0000000000 '' ' ' abc 5s s5 -1 -0 +5 1.5 '1 2' ' 5' '5 ' $'5\n' 0x10; do
    got=kept
    if whole_above_zero "$v" got; then
      check "'$v' is refused" "it passed"
    else
      [ "$got" = kept ] && check "'$v' is refused, and the name is left alone" ok \
                        || check "'$v' is refused, and the name is left alone" "it was set to [$got]"
    fi
  done
  # The value reaches the caller's variable whatever it is called, a local of the caller's own and
  # the names the helper might have used for itself included (printf -v writes the nearest one).
  scoped(){ local v w whole frac; whole_above_zero 07 v; whole_above_zero 0500 w; decimal_above_zero 00.5 whole; decimal_above_zero 3 frac; printf '%s|%s|%s|%s' "$v" "$w" "$whole" "$frac"; }
  [ "$(scoped)" = "7|500|0.5|3" ] && check "a caller's own locals receive the value, whatever they are called" ok \
                                  || check "a caller's own locals receive the value, whatever they are called" "got [$(scoped)]"
  # A name that is not one is refused rather than handed to printf -v, which would write elsewhere.
  for bad in '' 'a-b' '1x' 'x y' 'x[0]' '_wn_v'; do
    if whole_above_zero 5 "$bad" 2>/dev/null; then check "a name of '$bad' is refused" "it passed"
    else check "a name of '$bad' is refused" ok; fi
  done
  # No argument at all is the empty string, and under set -u is still a refusal rather than an error.
  if (set -u; whole_above_zero) 2>/dev/null; then
    check "no argument is refused" "it passed"
  else
    check "no argument is refused" ok
  fi
  # It decides; it never prints, so a caller can use it in a condition without its words leaking.
  said="$(whole_above_zero 00 got; whole_above_zero 5 got; whole_above_zero x got)"
  [ -z "$said" ] && check "it prints nothing" ok || check "it prints nothing" "it said [$said]"
else
  check "lib/whole-number.sh loads and defines whole_above_zero" "missing or did not define it: $LIB"
fi

# The decimal sibling, for the two settings that take a fraction of a second (#1948): they listed
# 0, 0.0 and 0.00 as the zeros, so 00 and 0.000 passed as a positive poll interval.
if type decimal_above_zero >/dev/null 2>&1; then
  check "lib/whole-number.sh defines decimal_above_zero" ok
  for pair in 2:2 0.5:0.5 00.5:0.5 .5:0.5 1.25:1.25 010:10 5.:5 0.05:0.05 007.10:7.10; do
    in="${pair%%:*}"; want="${pair#*:}"; got=unset
    if decimal_above_zero "$in" got; then
      [ "$got" = "$want" ] && check "'$in' is a number above zero, handed back as $want" ok \
                           || check "'$in' is a number above zero, handed back as $want" "handed back [$got]"
    else
      check "'$in' is a number above zero, handed back as $want" "refused"
    fi
  done
  for v in 0 00 0.0 0.00 0.000 00.000 .0 0. . '' abc 1.2.3 -1 -0.5 '1 ' 1e3 +1; do
    got=kept
    if decimal_above_zero "$v" got; then
      check "'$v' is refused as a decimal" "it passed"
    else
      [ "$got" = kept ] && check "'$v' is refused as a decimal, and the name is left alone" ok \
                        || check "'$v' is refused as a decimal, and the name is left alone" "it was set to [$got]"
    fi
  done
else
  check "lib/whole-number.sh defines decimal_above_zero" "missing: $LIB"
fi

# ---------------------------------------------------------------------------
# The scan. It has to see every spelling of the old check, and none of the things that are not one,
# before the tree is asked (L1). The pieces are ASSEMBLED, so this file holds none for it to find.
# ---------------------------------------------------------------------------
# Read by `read` rather than through a command substitution, which bash 3.2 parses for quotes even
# inside a heredoc (#1690). `read -d ""` stops at the end of input with status 1, by design.
SCAN=""
IFS= read -r -d "" SCAN <<'PY' || true
import re, sys

root = sys.argv[1]
# One alternative of a case pattern: a quoted string, or a run with no separator in it.
ALT = r"(?:'[^']*'|\"[^\"]*\"|[^\s|()'\";]+)"
PATTERN = re.compile(r"(?:^|(?<=[\s(;]))(" + ALT + r"(?:\|" + ALT + r")*)\)")
CUT = re.compile(r"%%\[!0\]\*")
# A call naming no variable to hand the value back in: the value is then used as written, leading
# zeros and all, and bash arithmetic reads those as octal. One way everywhere, so every call names one.
CALL = re.compile(r"(?<!-F )(?<!type )(?<!-v )\b(?:whole|decimal)_above_zero[ \t]+(\"(?:[^\"\\]|\\.)*\"|'[^']*'|[^\s;|&)\"']+)[ \t]*(?=$|[;|&)#}]|then\b)")
DIGITS_ARM = re.compile(r"\[!0-9\.?\]\*\)")
found = []
for rel in sys.stdin.read().split("\n"):
    if not rel:
        continue
    base = rel.rsplit("/", 1)[-1]
    # The helper is where the check and the cut live, so it is the one file they may be written in.
    if rel == "payload/hooks/lib/whole-number.sh":
        continue
    if not (base.endswith(".sh") or base == "claude-sync"
            or (rel.startswith(".github/workflows/") and base.endswith((".yml", ".yaml")))):
        continue
    try:
        with open(root + "/" + rel, encoding="utf-8", errors="replace") as f:
            lines = f.read().split("\n")
    except OSError as e:
        found.append(f"{rel}: could not be read ({e.strerror})")
        continue
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        hit = ""
        # A bare 0 beside the whole number or decimal test in one pattern, or beside the empty string
        # while another arm of the same case on the line is that test. A 0 beside '' alone is a flag
        # or an exit code read as a word (CI=0, a jq count of null), not this check.
        digits_elsewhere = DIGITS_ARM.search(line) is not None
        for m in PATTERN.finditer(line):
            alts = m.group(1).split("|")
            if "0" in alts and (any("[!0-9" in a for a in alts)
                                or (digits_elsewhere and any(a in ("''", '""') for a in alts))):
                hit = "a case pattern refusing only a literal 0"
                break
        if not hit and CUT.search(line):
            hit = "leading zeros cut by hand"
        if not hit and CALL.search(line):
            hit = "a call naming no variable to hand the value back in"
        if hit:
            found.append(f"{rel}:{n}: {hit}: {line.strip()}")
print("\n".join(found))
sys.exit(1 if found else 0)
PY
[ -n "$SCAN" ] || { echo "test-whole-number: the scan program came back empty, so nothing could be judged." >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/whole-number.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-whole-number: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

E="''"; N='*[!0-9]*'; ND='*[!0-9.]*'; Z='0'; C='%%[!''0]*'
W='whole''_above_zero'; D='decimal''_above_zero'
mkdir -p "$TMPROOT/payload/hooks" "$TMPROOT/.github/workflows"
# Nine that are, each on a line of its own so a finding names which, and a tenth in a workflow.
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "$x" in %s|%s|%s) x=5 ;; esac\n' "$E" "$N" "$Z"
  printf 'case "$x" in\n  %s|%s|%s)\n    x=5 ;;\nesac\n' "$E" "$N" "$Z"
  printf '    %s|%s) echo refused; exit 2 ;;\n' "$N" "$Z"
  printf 'case "${1:-}" in %s|%s|%s) return 0 ;; %s) return 0 ;; esac\n' "$E" "'?'" "$Z" "$N"
  printf 'case "$x" in %s|%s|%s) x=5 ;; esac\n' "$Z" "$E" "$N"
  printf 'x="${x#"${x%s}"}"\n' "$C"
  printf 'case "$p" in %s|%s|.|%s|0.0) exit 4 ;; esac\n' "$E" "$ND" "$Z"
  printf '%s "$x" || x=5\n' "$W"
  printf 'if %s "${1:-}"; then n=1; fi\n' "$D"
} > "$TMPROOT/payload/hooks/probe.sh"
cp "$TMPROOT/payload/hooks/probe.sh" "$TMPROOT/claude-sync"
printf 'jobs:\n  a:\n    steps:\n      - run: case "$n" in %s|%s|%s) n=1 ;; esac\n' "$E" "$N" "$Z" > "$TMPROOT/.github/workflows/w.yml"
# And thirteen that are not.
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "$x" in %s|%s) x=5 ;; esac\n' "$E" "$N"
  printf 'case "$gf" in %s) a ;; 1) b ;; %s|%s) c ;; esac\n' "$Z" "$E" "$N"
  printf '# case "$x" in %s|%s|%s) was the old check\n' "$E" "$N" "$Z"
  printf '%s "$x" x || x=5\n' "$W"
  printf 'if %s "${1:-}" n; then [ "$n" -ge 3 ]; fi\n' "$W"
  printf '%s "$p" p || exit 4\n' "$D"
  printf '%s() {\n' "$W"
  printf 'case "$x" in %s|%s|1%s) x=5 ;; esac\n' "$E" "$N" "$Z"
  printf 'case "$x" in %s) zero ;; *) many ;; esac\n' "$Z"
  printf 'y="${x%%%%.*}"\n'
  printf 'case "$rc" in %s|%s|null) : ;; esac\n' "$E" "$Z"
  printf 'case "${CI:-}" in %s|false|%s) ;; *) under_ci ;; esac\n' "$E" "$Z"
  printf 'case "$p" in %s|%s|.) exit 4 ;; esac\n' "$E" "$ND"
} > "$TMPROOT/payload/hooks/clean.sh"
# The same text in a file that is not shell is not judged.
cp "$TMPROOT/payload/hooks/probe.sh" "$TMPROOT/payload/hooks/notes.md"

probe="$(printf 'payload/hooks/probe.sh\nclaude-sync\n.github/workflows/w.yml\npayload/hooks/notes.md\n' | python3 -c "$SCAN" "$TMPROOT")"; probe_rc=$?
[ "$probe_rc" = 1 ] && check "the scan fails on the old check" ok || check "the scan fails on the old check" "exit $probe_rc"
for l in 2 4 7 8 9 10 11 12 13; do
  case "$probe" in *"payload/hooks/probe.sh:$l:"*) check "and finds the shape on line $l of the probe" ok ;;
    *) check "and finds the shape on line $l of the probe" "it said: $probe" ;; esac
done
[ "$(printf '%s\n' "$probe" | grep -c '^payload/hooks/probe.sh:')" = 9 ] \
  && check "and nothing else in the probe" ok \
  || check "and nothing else in the probe" "it said: $probe"
case "$probe" in *"claude-sync:2:"*) check "and reads claude-sync, which has no .sh" ok ;;
  *) check "and reads claude-sync, which has no .sh" "it said: $probe" ;; esac
case "$probe" in *".github/workflows/w.yml:4:"*) check "and reads a workflow's run steps" ok ;;
  *) check "and reads a workflow's run steps" "it said: $probe" ;; esac
case "$probe" in *notes.md*) check "and leaves a file that is not shell alone" "it said: $probe" ;;
  *) check "and leaves a file that is not shell alone" ok ;; esac
clean="$(printf 'payload/hooks/clean.sh\n' | python3 -c "$SCAN" "$TMPROOT")"; clean_rc=$?
[ "$clean_rc" = 0 ] && [ -z "$clean" ] && check "and passes every shape that is not one" ok \
  || check "and passes every shape that is not one" "exit $clean_rc: $clean"

# ---------------------------------------------------------------------------
# The real tree: none at all, anywhere.
# ---------------------------------------------------------------------------
if [ -z "$ROOT" ] || [ ! -d "$ROOT" ]; then
  # An installed copy has no repository to read. The helper above was still tested; only the scan
  # of the tree was not run, and that is said rather than passed (#1444).
  printf 'SUITE-PART-UNMEASURED %s\n' "the scan for hand written whole number checks: $DIR/.. is not the payload of a claude-config checkout, so there were no files of this repository to read"
else
  FILES="$(bash "$DIR/lib/repo-files.sh" "$ROOT" 2>/dev/null || true)"
  # A listing that came back empty, or without the files the old check lived in, read nothing (L98).
  case "$FILES" in
    *claude-sync*payload/hooks/run-all-tests.sh*|*payload/hooks/run-all-tests.sh*claude-sync*)
      check "the files to judge were listed" ok ;;
    *) check "the files to judge were listed" "lib/repo-files.sh did not list claude-sync and run-all-tests.sh for $ROOT" ;;
  esac
  # The two decimal settings, driven through the sync suite itself: each is paired with a later
  # setting refused on purpose, so the message says which check stopped the run. Both stop within a
  # second, before the suite takes its lock or runs anything. Before #1948 a 00 passed the first
  # check and the run was stopped by the second.
  SYNCSUITE="$ROOT/tests/test-claude-sync.sh"
  poll_out="$(SUITE_POLL_INTERVAL=00 SUITE_LOCK_WAIT=bogus bash "$SYNCSUITE" 2>&1)"; poll_rc=$?
  case "$poll_rc|$poll_out" in 4\|*"SUITE_POLL_INTERVAL='00'"*) check "the sync suite refuses a poll interval of 00 as zero" ok ;;
    *) check "the sync suite refuses a poll interval of 00 as zero" "exit $poll_rc: ${poll_out:0:200}" ;; esac
  poll_out="$(SUITE_POLL_INTERVAL=0.000 SUITE_LOCK_WAIT=bogus bash "$SYNCSUITE" 2>&1)"; poll_rc=$?
  case "$poll_rc|$poll_out" in 4\|*"SUITE_POLL_INTERVAL='0.000'"*) check "and one of 0.000" ok ;;
    *) check "and one of 0.000" "exit $poll_rc: ${poll_out:0:200}" ;; esac
  lp_out="$(SUITE_LOCK_WAIT_POLL=00 SUITE_LOCK_WAIT=0 HOOK_TESTS_SLOTS=bogus bash "$SYNCSUITE" 2>&1)"; lp_rc=$?
  case "$lp_rc|$lp_out" in 4\|*"SUITE_LOCK_WAIT_POLL='00'"*) check "and a lock poll of 00" ok ;;
    *) check "and a lock poll of 00" "exit $lp_rc: ${lp_out:0:200}" ;; esac
  # The control: a real interval passes the check and the run is stopped by the poisoned one.
  poll_out="$(SUITE_POLL_INTERVAL=0.5 SUITE_LOCK_WAIT=bogus bash "$SYNCSUITE" 2>&1)"; poll_rc=$?
  case "$poll_rc|$poll_out" in 4\|*"SUITE_LOCK_WAIT='bogus'"*) check "control: a poll interval of 0.5 passes that check" ok ;;
    *) check "control: a poll interval of 0.5 passes that check" "exit $poll_rc: ${poll_out:0:200}" ;; esac

  found="$(printf '%s\n' "$FILES" | python3 -c "$SCAN" "$ROOT")"; found_rc=$?
  [ "$found_rc" = 0 ] && [ -z "$found" ] \
    && check "nothing tests a whole number above zero by hand" ok \
    || check "nothing tests a whole number above zero by hand" "exit $found_rc; these do, and a value written 00 passes them as a number above zero:
$found
  Ask whole_above_zero from hooks/lib/whole-number.sh instead."
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
