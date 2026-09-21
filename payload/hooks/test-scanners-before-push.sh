#!/usr/bin/env bash
# Tests for scanners-before-push.sh, which runs this repo's whole tree scanners before a push
# rather than leaving CI as the first place they speak (claude-config#518).
#
# The gap it closes was measured on 2026-09-20: two defects went to main in one evening and the
# build went red twice, an undated measured number in a new comment and six pipelines ending in a
# consumer that leaves early. Neither is visible to a gate that reads the DIFF, because both were
# caught by guards that read every tracked file in the repository. The pre push test gate asks a
# model whether each change carries a test and runs no suite at all.
#
# The checks below care about the two ways a gate like this is worse than useless. It must not
# report a clean run when it found nothing to run (L98), and it must not block a push over
# anything other than a scanner that actually ran and actually failed, because a gate that fails
# closed on a machine that cannot ask the question stops work for no reason (L42 cuts the other
# way here: this protects a build, not a person).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/scanners-before-push.sh"

pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-scanner-gate.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-scanners-before-push: refusing to run: throwaway directory came back as '${TMPROOT}'." >&2
    exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A repository shaped like this one: the marker the hook keys on, plus whatever scanners the test
# wants. Everything happens in a throwaway git repo, never against the real one (L2).
mkrepo(){            # $1 = name  -> prints the repo path
  local r="$TMPROOT/$1"
  mkdir -p "$r/payload/hooks" "$r/tests"
  git -C "$r" init -q
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  printf '#!/usr/bin/env bash\necho runner\n' > "$r/payload/hooks/run-all-tests.sh"
  chmod +x "$r/payload/hooks/run-all-tests.sh"
  printf '%s' "$r"
}

# A scanner suite: one that reads the repository's own tracked files, which is the property that
# makes it invisible to a gate reading the diff.
add_scanner(){       # $1 = repo  $2 = name  $3 = exit code
  cat > "$1/payload/hooks/test-$2.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
echo "scanner $2 ran"
exit $3
EOF
  chmod +x "$1/payload/hooks/test-$2.sh"
}

# A suite that reads only what it was given, so it is NOT a scanner and must not be run here.
add_plain(){         # $1 = repo  $2 = name
  printf '#!/usr/bin/env bash\necho "plain %s ran"\nexit 0\n' "$2" > "$1/payload/hooks/test-$2.sh"
  chmod +x "$1/payload/hooks/test-$2.sh"
}

commit_all(){ git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -q -m "fixture" >/dev/null 2>&1; }

# The hook reads a Claude Code PreToolUse payload on stdin.
#
# The exit code comes back as this function's OWN status, never through a variable: every call
# below is inside a command substitution, which is a subshell, so a variable set in here never
# reaches the caller and every exit code read that way was the previous one (measured: three
# checks passed against a stale 0).
fire(){              # $1 = repo  $2 = the command  -> prints the hook's output, exits with its code
  local out rc
  out="$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$2" "$1" | bash "$H" 2>&1)"
  rc=$?
  printf '%s' "$out"
  return "$rc"
}

# --- a repository with a passing scanner: the push goes through, and the gate says what it ran,
#     because a gate nobody can see the coverage of is one nobody can trust (L400, L557).
R1="$(mkrepo pass)"; add_scanner "$R1" alpha 0; add_plain "$R1" beta; commit_all "$R1"
o1="$(fire "$R1" "git push")"; c1=$?
[ "$c1" -eq 0 ] && check "a passing scanner lets the push through" ok \
                || check "a passing scanner lets the push through" "exit=$c1 out=$o1"

# --- a failing scanner blocks it, and says which one.
R2="$(mkrepo block)"; add_scanner "$R2" alpha 0; add_scanner "$R2" gamma 1; commit_all "$R2"
o2="$(fire "$R2" "git push")"; c2=$?
[ "$c2" -eq 2 ] && check "a failing scanner blocks the push" ok \
                || check "a failing scanner blocks the push" "exit=$c2 out=$o2"
grep -q 'gamma' <<< "$o2" \
  && check "and names the scanner that failed" ok || check "and names the scanner that failed" "out=$o2"
grep -q 'alpha' <<< "$o2" \
  && check "and does not accuse the one that passed" "it named alpha too: $o2" \
  || check "and does not accuse the one that passed" ok

# --- a suite that reads only its own fixtures is not a scanner and must not be run, or this gate
#     becomes the whole suite and costs what the whole suite costs.
grep -q 'plain beta ran' <<< "$o1" \
  && check "a suite that scans nothing is left alone" "it ran beta: $o1" \
  || check "a suite that scans nothing is left alone" ok

# --- a repository with the marker and NO scanners has measured nothing. It must say so rather
#     than pass silently, because reading nothing and reading everything green look identical
#     otherwise (L98).
R3="$(mkrepo empty)"; add_plain "$R3" beta; commit_all "$R3"
o3="$(fire "$R3" "git push")"; c3=$?
[ "$c3" -eq 0 ] && check "no scanners does not block the push" ok \
                || check "no scanners does not block the push" "exit=$c3 out=$o3"
grep -qiE 'no scanner|found none|nothing to scan' <<< "$o3" \
  && check "but it says it found none rather than reporting a clean run" ok \
  || check "but it says it found none rather than reporting a clean run" "out=$o3"

# --- a repository that is not this one is left entirely alone, with nothing to say about it.
R4="$TMPROOT/notours"; mkdir -p "$R4"; git -C "$R4" init -q
git -C "$R4" config user.email t@t; git -C "$R4" config user.name t
printf 'x\n' > "$R4/file"; commit_all "$R4"
o4="$(fire "$R4" "git push")"; c4=$?
[ "$c4" -eq 0 ] && [ -z "$o4" ] \
  && check "a repository without the marker is not touched" ok \
  || check "a repository without the marker is not touched" "exit=$c4 out=$o4"

# --- anything that is not a push is none of this hook's business.
o5="$(fire "$R2" "git status")"; c5=$?
[ "$c5" -eq 0 ] && [ -z "$o5" ] \
  && check "a command that is not a push is ignored" ok \
  || check "a command that is not a push is ignored" "exit=$c5 out=$o5"

# --- the override, which exists for the same one time reason as every other gate here.
o6="$(fire "$R2" "SKIP_SCANNERS_CHECK=1 git push")"; c6=$?
[ "$c6" -eq 0 ] \
  && check "the override lets a blocked push through" ok \
  || check "the override lets a blocked push through" "exit=$c6 out=$o6"
grep -qi 'SKIP_SCANNERS_CHECK' <<< "$o2" \
  && check "and the block names the override" ok || check "and the block names the override" "out=$o2"

# --- a scanner that is TRACKED but only just written is still run: a gate that enumerates from
#     what git tracked at some earlier moment cannot see the file being added, which is the file
#     most likely to be wrong (L456).
R5="$(mkrepo fresh)"; add_scanner "$R5" delta 1; commit_all "$R5"
o7="$(fire "$R5" "git push")"; c7=$?
[ "$c7" -eq 2 ] && grep -q 'delta' <<< "$o7" \
  && check "a newly committed scanner is run like any other" ok \
  || check "a newly committed scanner is run like any other" "exit=$c7 out=$o7"

# --- a scanner that has NOT been committed is run too (claude-config#522). The gate used to pick its
#     subjects from what git tracks, so a scanner just written was not run until the push after the
#     one that added it, and a file just written was not read by the scanners that did run (L456).
R7="$(mkrepo uncommitted)"; add_scanner "$R7" alpha 0; commit_all "$R7"
add_scanner "$R7" epsilon 1
o9="$(fire "$R7" "git push")"; c9=$?
[ "$c9" -eq 2 ] && grep -q 'epsilon' <<< "$o9" \
  && check "a scanner not yet committed is run like any other" ok \
  || check "a scanner not yet committed is run like any other" "exit=$c9 out=$o9"

# --- a scanner that lists the repository through lib/repo-files.sh, the one way scanners here do
#     it now, is recognised as a scanner. Keyed only on the git command, the gate would stop seeing
#     every suite that was converted.
R8="$(mkrepo lister)"
printf '#!/usr/bin/env bash\nbash "$LIB/repo-files.sh" . >/dev/null\necho "scanner zeta ran"\nexit 1\n' > "$R8/payload/hooks/test-zeta.sh"
commit_all "$R8"
o10="$(fire "$R8" "git push")"; c10=$?
[ "$c10" -eq 2 ] && grep -q 'zeta' <<< "$o10" \
  && check "a scanner that lists through repo-files.sh is recognised" ok \
  || check "a scanner that lists through repo-files.sh is recognised" "exit=$c10 out=$o10"

# --- and it says how many uncommitted files it read, because none and some are different
#     situations that a bare pass line would make look the same.
grep -q '0 uncommitted' <<< "$o1" \
  && check "a clean tree's pass line says no uncommitted file was read" ok \
  || check "a clean tree's pass line says no uncommitted file was read" "out=$o1"
R9="$(mkrepo counted)"; add_scanner "$R9" alpha 0; commit_all "$R9"
printf 'x\n' > "$R9/draft.sh"; printf 'x\n' > "$R9/draft2.sh"
o11="$(fire "$R9" "git push")"; c11=$?
[ "$c11" -eq 0 ] && grep -q '2 uncommitted' <<< "$o11" \
  && check "and says how many it read when there are some" ok \
  || check "and says how many it read when there are some" "exit=$c11 out=$o11"
grep -q '2 uncommitted' <<< "$o9" \
  && check "and a block says it too, so a draft can be told from committed work" "out=$o9" \
  || { grep -q '1 uncommitted' <<< "$o9" \
       && check "and a block says it too, so a draft can be told from committed work" ok \
       || check "and a block says it too, so a draft can be told from committed work" "out=$o9"; }

# --- a scanner whose COMMENT mentions this gate is still one of its subjects. Only a suite whose
#     code names the gate drives it; a mention in prose used to drop the scanner silently.
R11="$(mkrepo mentions)"
printf '#!/usr/bin/env bash\n# written after %s went in\ngit ls-files >/dev/null\necho "scanner theta ran"\nexit 1\n' "$(basename "$H")" > "$R11/payload/hooks/test-theta.sh"
commit_all "$R11"
o12="$(fire "$R11" "git push")"; c12=$?
[ "$c12" -eq 2 ] && grep -q 'theta' <<< "$o12" \
  && check "a scanner that only mentions this gate in a comment is still run" ok \
  || check "a scanner that only mentions this gate in a comment is still run" "exit=$c12 out=$o12"

# --- listing the selection runs NONE of it. It used to be read after every scanner had already
#     run, so asking what the gate covers cost exactly what the gate costs (L102).
R10="$(mkrepo listonly)"
printf '#!/usr/bin/env bash\ngit ls-files >/dev/null\n: > "%s/ran"\nexit 0\n' "$R10" > "$R10/payload/hooks/test-eta.sh"
commit_all "$R10"
_l="$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"%s"}' "$R10" | SCANNERS_LIST=1 bash "$H" 2>&1)"
[ ! -e "$R10/ran" ] && grep -q '^SUITE payload/hooks/test-eta.sh$' <<< "$_l" \
  && check "listing the selection names it without running it" ok \
  || check "listing the selection names it without running it" "ran=$( [ -e "$R10/ran" ] && echo yes || echo no) out=$_l"

# --- the scanners run AT ONCE, not one after another. Five suites that share nothing are five
#     lots of wall clock a push waits through for no reason (L302). Measured on this Mac
#     2026-09-21: 27 seconds in sequence, of which 21 was those five, against 13 run at once.
#
#     Proved by RENDEZVOUS rather than by a stopwatch: each of the two fixture scanners raises its
#     own marker and then waits for the other's. Run at once they both see it and pass; run one
#     after another the first waits out its bound and fails, so the gate blocks. A timing
#     assertion here would be a claim about how busy the machine is (L290).
R6="$(mkrepo concurrent)"
_rv="$TMPROOT/rendezvous"
mkdir -p "$_rv"
for _peer in alpha:beta beta:alpha; do
  _me="${_peer%%:*}"; _other="${_peer#*:}"
  cat > "$R6/payload/hooks/test-$_me.sh" <<EOF
#!/usr/bin/env bash
git ls-files '*.sh' >/dev/null
: > "$_rv/$_me"
n=0
while [ ! -e "$_rv/$_other" ] && [ "\$n" -lt 400000 ]; do n=\$(( n + 1 )); done
[ -e "$_rv/$_other" ] || { echo "FAIL: $_me never saw $_other, so they ran one after another"; exit 1; }
exit 0
EOF
  chmod +x "$R6/payload/hooks/test-$_me.sh"
done
commit_all "$R6"
o8="$(fire "$R6" "git push")"; c8=$?
[ "$c8" -eq 0 ] \
  && check "the scanners run at once rather than in sequence" ok \
  || check "the scanners run at once rather than in sequence" "exit=$c8 out=$o8"

# --- the selection against THIS repository, read rather than assumed. Fixtures can only confirm
#     the rule as written; what matters is which real suites it picks, and above all that it never
#     picks the four minute suite as a whole (measured 2026-09-21: the selection below runs in 27
#     seconds, where running that suite whole would be 268).
REAL="$(cd "$DIR/../.." && pwd)"
if [ -f "$REAL/payload/hooks/run-all-tests.sh" ]; then
  _sel="$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"},"cwd":"%s"}' "$REAL" \
          | SCANNERS_LIST=1 bash "$H" 2>&1)"
  [ "$(grep -c '^SUITE ' <<< "$_sel")" -ge 5 ] \
    && check "the real repo's standalone scanners are all selected" ok \
    || check "the real repo's standalone scanners are all selected" "got=$_sel"
  for _want in test-pipefail-shortcircuit.sh test-repo-files.sh; do
    grep -q "^SUITE payload/hooks/$_want\$" <<< "$_sel" \
      && check "and $_want is among them" ok \
      || check "and $_want is among them" "got=$_sel"
  done
  grep -q '^SECTION .*#145' <<< "$_sel" \
    && check "and the section that scans comments for undated numbers is selected" ok \
    || check "and the section that scans comments for undated numbers is selected" "got=$_sel"
  grep -q "^SUITE .*$(basename "$H")$" <<< "$_sel" \
    && check "and the suite that drives this gate is not one of its own subjects" "it selected itself: $_sel" \
    || check "and the suite that drives this gate is not one of its own subjects" ok
  grep -q '^SUITE tests/test-claude-sync.sh$' <<< "$_sel" \
    && check "and the four minute suite is never selected whole" "it would run whole: $_sel" \
    || check "and the four minute suite is never selected whole" ok
else
  # The INSTALLED copy of these hooks sits in ~/.claude, where there is no repository and never
  # will be, so there is no selection to read and that is not a fault. Said out loud rather than
  # skipped in silence, because a suite that quietly checks less is how coverage disappears (L98).
  echo "  (no repository at $REAL, so the selection against a real tree was not checked here; it is checked where this repo is)"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
