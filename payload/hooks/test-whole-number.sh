#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans hooks/ skills/
# lib/whole-number.sh, the one test of a whole number above zero, and the scan that keeps it the
# only one (claude-config#1948).
#
# About 45 settings and readings checked for a whole number above zero by hand, as a case pattern
# naming the empty string, anything but digits, and a bare 0. That refuses only a LITERAL 0, so 00
# passed as a number above zero: in lib/bounded-run.sh it reached perl's alarm, which reads it as 0
# and set no bound at all (claude-config#1931). #1931 fixed two sites by cutting leading zeros by
# hand, a third shape. Every site now asks whole_above_zero, and this fails the next copy of either
# shape on the day it lands (L613).
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
  for v in 1 5 05 007 10 100 300 21600; do
    whole_above_zero "$v" && check "'$v' is a whole number above zero" ok \
                          || check "'$v' is a whole number above zero" "refused"
  done
  # Zero however written is zero (#1948): 00 and 000 were read as numbers above zero.
  for v in 0 00 000 0000000000 '' ' ' abc 5s s5 -1 -0 +5 1.5 '1 2' ' 5' '5 ' $'5\n' 0x10; do
    if whole_above_zero "$v"; then
      check "'$v' is refused" "it passed"
    else
      check "'$v' is refused" ok
    fi
  done
  # No argument at all is the empty string, and under set -u is still a refusal rather than an error.
  if (set -u; whole_above_zero) 2>/dev/null; then
    check "no argument is refused" "it passed"
  else
    check "no argument is refused" ok
  fi
  # It decides; it never prints, so a caller can use it in a condition without its words leaking.
  said="$(whole_above_zero 00; whole_above_zero 5; whole_above_zero x)"
  [ -z "$said" ] && check "it prints nothing" ok || check "it prints nothing" "it said [$said]"
else
  check "lib/whole-number.sh loads and defines whole_above_zero" "missing or did not define it: $LIB"
fi

# ---------------------------------------------------------------------------
# The scan. It has to see every spelling of the old check, and none of the things that are not one,
# before the tree is asked (L1). The pieces are ASSEMBLED, so this file holds none for it to find.
# ---------------------------------------------------------------------------
SCAN="$(cat <<'PY'
import re, sys

root = sys.argv[1]
# One alternative of a case pattern: a quoted string, or a run with no separator in it.
ALT = r"(?:'[^']*'|\"[^\"]*\"|[^\s|()'\";]+)"
PATTERN = re.compile(r"(?:^|(?<=[\s(;]))(" + ALT + r"(?:\|" + ALT + r")*)\)")
CUT = re.compile(r"%%\[!0\]\*")
found = []
for rel in sys.stdin.read().split("\n"):
    if not rel:
        continue
    base = rel.rsplit("/", 1)[-1]
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
        # A bare 0 beside the whole number test in one pattern, or beside the empty string while
        # another arm of the same case on the line is the whole number test. A 0 beside '' alone is
        # a flag or an exit code read as a word (CI=0, a jq count of null), not this check; a test
        # with a dot in it is a decimal one, which this helper does not answer.
        digits_elsewhere = "[!0-9]*)" in line
        for m in PATTERN.finditer(line):
            alts = m.group(1).split("|")
            if "0" in alts and (any("[!0-9]" in a for a in alts)
                                or (digits_elsewhere and any(a in ("''", '""') for a in alts))):
                hit = "a case pattern refusing only a literal 0"
                break
        if not hit and CUT.search(line):
            hit = "leading zeros cut by hand"
        if hit:
            found.append(f"{rel}:{n}: {hit}: {line.strip()}")
print("\n".join(found))
sys.exit(1 if found else 0)
PY
)"

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/whole-number.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-whole-number: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

E="''"; N='*[!0-9]*'; Z='0'; C='%%[!''0]*'
mkdir -p "$TMPROOT/payload/hooks" "$TMPROOT/.github/workflows"
# Six that are, each on a line of its own so a finding names which, and a seventh in a workflow.
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "$x" in %s|%s|%s) x=5 ;; esac\n' "$E" "$N" "$Z"
  printf 'case "$x" in\n  %s|%s|%s)\n    x=5 ;;\nesac\n' "$E" "$N" "$Z"
  printf '    %s|%s) echo refused; exit 2 ;;\n' "$N" "$Z"
  printf 'case "${1:-}" in %s|%s|%s) return 0 ;; %s) return 0 ;; esac\n' "$E" "'?'" "$Z" "$N"
  printf 'case "$x" in %s|%s|%s) x=5 ;; esac\n' "$Z" "$E" "$N"
  printf 'x="${x#"${x%s}"}"\n' "$C"
} > "$TMPROOT/payload/hooks/probe.sh"
cp "$TMPROOT/payload/hooks/probe.sh" "$TMPROOT/claude-sync"
printf 'jobs:\n  a:\n    steps:\n      - run: case "$n" in %s|%s|%s) n=1 ;; esac\n' "$E" "$N" "$Z" > "$TMPROOT/.github/workflows/w.yml"
# And ten that are not.
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "$x" in %s|%s) x=5 ;; esac\n' "$E" "$N"
  printf 'case "$gf" in %s) a ;; 1) b ;; %s|%s) c ;; esac\n' "$Z" "$E" "$N"
  printf '# case "$x" in %s|%s|%s) was the old check\n' "$E" "$N" "$Z"
  printf 'whole_above_zero "$x" || x=5\n'
  printf 'case "$x" in %s|%s|1%s) x=5 ;; esac\n' "$E" "$N" "$Z"
  printf 'case "$x" in %s) zero ;; *) many ;; esac\n' "$Z"
  printf 'y="${x%%%%.*}"\n'
  printf 'case "$rc" in %s|%s|null) : ;; esac\n' "$E" "$Z"
  printf 'case "${CI:-}" in %s|false|%s) ;; *) under_ci ;; esac\n' "$E" "$Z"
  printf 'case "$p" in %s|%s|.|%s|0.0) exit 4 ;; esac\n' "$E" '*[!0-9.]*' "$Z"
} > "$TMPROOT/payload/hooks/clean.sh"
# The same text in a file that is not shell is not judged.
cp "$TMPROOT/payload/hooks/probe.sh" "$TMPROOT/payload/hooks/notes.md"

probe="$(printf 'payload/hooks/probe.sh\nclaude-sync\n.github/workflows/w.yml\npayload/hooks/notes.md\n' | python3 -c "$SCAN" "$TMPROOT")"; probe_rc=$?
[ "$probe_rc" = 1 ] && check "the scan fails on the old check" ok || check "the scan fails on the old check" "exit $probe_rc"
for l in 2 4 7 8 9 10; do
  case "$probe" in *"payload/hooks/probe.sh:$l:"*) check "and finds the shape on line $l of the probe" ok ;;
    *) check "and finds the shape on line $l of the probe" "it said: $probe" ;; esac
done
[ "$(printf '%s\n' "$probe" | grep -c '^payload/hooks/probe.sh:')" = 6 ] \
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
