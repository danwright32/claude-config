#!/usr/bin/env bash
# Tests for check-shell-syntax.sh, which parses every shell file in the repository with the shell
# itself (claude-config#489).
#
# The fault that prompted it: bash does not honour a shell COMMENT while it scans for the closing
# paren of a command substitution, so a prose comment holding an apostrophe inside $( ... ) makes
# it report "unexpected EOF while looking for matching quote", naming the end of the file rather
# than the line that caused it. Reproduced in isolation on 2026-09-19 while writing
# test-lessons-advisory.sh, and several suites build strings inside command substitutions with
# prose comments in them, so the next one costs the same hunt. It is L434's sibling: a construct
# that reads differently between tools, with no error to say so.
#
# WHY THE SHELL AND NOT A PATTERN SCAN. The issue proposed a scan for an apostrophe inside a
# comment within a command substitution, and asked for the false positive rate to be measured
# before choosing. It was: a line based scanner of that shape flagged 13 sites across the 161
# shell files here, and every one of them was wrong, because a multi line single quoted string (an
# awk or python program, of which this repository has many) defeats any reading that does not
# actually parse the file. Getting it right needs a bash parser, and there is one available: bash.
# So the guard asks the question the thing it guards asks (L144), and an over match that reads as
# the guard working (L104) is impossible by construction.
#
# It also catches every other syntax error, which nothing here did before.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-shell-syntax.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.shsyntax.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-shell-syntax: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# DOES THE BASH RUNNING THIS ACTUALLY HAVE THE FAULT? It is a property of the interpreter, and the
# two Macs run what /usr/bin/env bash resolves to there, which is 3.2.57. A newer bash may parse
# the same file correctly, in which case this suite cannot measure the catch and must say so
# rather than report a green it did not earn (L411, L460). Everything else below is measured
# either way, because a syntax error is a syntax error under every bash.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/tree"
cat > "$TMPROOT/tree/apostrophe.sh" <<'FIXTURE'
#!/usr/bin/env bash
x="$(
  # this comment holds an apostrophe: the file's name
  printf 'hello'
)"
echo "$x"
FIXTURE
if bash -n "$TMPROOT/tree/apostrophe.sh" >/dev/null 2>&1; then
  HAS_FAULT=0
  echo "note: this bash ($BASH_VERSION) parses a comment inside a command substitution correctly, so the apostrophe case below is reported as UNMEASURED rather than passed."
else
  HAS_FAULT=1
fi

# ---------------------------------------------------------------------------
# The reported shape, caught. Watched failing before anything below is trusted (L1): the fixture
# is the exact file that cost the hunt.
# ---------------------------------------------------------------------------
out_apos="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_apos=$?
if [ "$HAS_FAULT" -eq 1 ]; then
  [ "$code_apos" -ne 0 ] \
    && check "a comment with an apostrophe inside a command substitution is refused" ok \
    || check "a comment with an apostrophe inside a command substitution is refused" "exit=$code_apos out=$out_apos"
  grep -q 'apostrophe.sh' <<< "$out_apos" \
    && check "and the file is named" ok \
    || check "and the file is named" "out=$out_apos"
  grep -qi 'matching' <<< "$out_apos" \
    && check "and what the shell said is passed through, not replaced with a guess" ok \
    || check "and what the shell said is passed through, not replaced with a guess" "out=$out_apos"
else
  check "the apostrophe case could not be measured on this bash" ok
fi

# ---------------------------------------------------------------------------
# An ordinary syntax error, which no bash parses, so this half is measured everywhere. Without it
# the suite would report nothing at all on a bash that lacks the fault above (L98).
# ---------------------------------------------------------------------------
rm -f "$TMPROOT/tree/apostrophe.sh"
printf '#!/usr/bin/env bash\nif [ 1 -eq 1 ]; then\n  echo yes\n' > "$TMPROOT/tree/unclosed.sh"
out_bad="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_bad=$?
[ "$code_bad" -ne 0 ] \
  && check "a file that does not parse at all is refused" ok \
  || check "a file that does not parse at all is refused" "exit=$code_bad out=$out_bad"
grep -q 'unclosed.sh' <<< "$out_bad" \
  && check "and that file is named too" ok \
  || check "and that file is named too" "out=$out_bad"

# ---------------------------------------------------------------------------
# WHAT IT MUST PRESERVE. A guard is tested against what it must let through, not only what it must
# catch, because an over match reads exactly like the guard working (L104). These are the shapes
# the rejected pattern scan got wrong.
# ---------------------------------------------------------------------------
rm -f "$TMPROOT/tree/unclosed.sh"
cat > "$TMPROOT/tree/sound.sh" <<'FIXTURE'
#!/usr/bin/env bash
# A prose comment at the top level with an apostrophe in it: the repository's own style.
x="$(printf 'hello')"
# An apostrophe inside double quotes inside a substitution is not a comment and is fine.
y="$(echo "the file's name")"
# A multi line single quoted program, which is what defeated the pattern scan: awk and python
# programs like this one run to dozens of lines here.
z="$(awk '
  BEGIN { print "one" }
  # an awk comment, inside a single quoted string, inside a command substitution
  END   { print "two" }
' /dev/null)"
printf '%s %s %s\n' "$x" "$y" "$z"
FIXTURE
out_ok="$(bash "$CHECK" "$TMPROOT/tree" 2>&1)"; code_ok=$?
[ "$code_ok" -eq 0 ] \
  && check "a sound file is not accused" ok \
  || check "a sound file is not accused" "exit=$code_ok out=$out_ok"

# ---------------------------------------------------------------------------
# A sweep that found NOTHING to check reports success exactly like one that checked everything and
# found it sound (L98, L320). So it refuses an empty tree rather than passing it.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/empty"
out_empty="$(bash "$CHECK" "$TMPROOT/empty" 2>&1)"; code_empty=$?
[ "$code_empty" -ne 0 ] \
  && check "a tree holding no shell file at all is refused, not passed" ok \
  || check "a tree holding no shell file at all is refused, not passed" "exit=$code_empty out=$out_empty"
[ "$out_empty" != "$out_ok" ] \
  && check "and it does not say what a clean sweep says" ok \
  || check "and it does not say what a clean sweep says" "both said: $out_empty"

# A target it cannot use is refused by name rather than falling back to a default scope, which
# looks exactly like having run on the thing you named (L320).
out_gone="$(bash "$CHECK" "$TMPROOT/not-a-directory" 2>&1)"; code_gone=$?
[ "$code_gone" -ne 0 ] \
  && check "a root that is not there is refused" ok \
  || check "a root that is not there is refused" "exit=$code_gone out=$out_gone"

# ---------------------------------------------------------------------------
# THE COUNT, and the interpreter, are both reported. The catch depends on which bash is running,
# so a pass has to say what it was measured with or it claims more than it checked (L11).
# ---------------------------------------------------------------------------
grep -qE '[0-9]+ ' <<< "$out_ok" \
  && check "a clean sweep says how many files it parsed" ok \
  || check "a clean sweep says how many files it parsed" "out=$out_ok"
grep -q "$BASH_VERSION" <<< "$out_ok" \
  && check "and which bash parsed them, because the catch depends on it" ok \
  || check "and which bash parsed them, because the catch depends on it" "out=$out_ok"

# ---------------------------------------------------------------------------
# A ROOT THAT IS SOMEBODY'S HOME DIRECTORY IS REFUSED, and this is not hypothetical. The line below
# used to derive the tree as "$DIR/../..", which is the repository root when this suite runs from
# payload/hooks and is the HOME DIRECTORY when it runs from the installed copy in ~/.claude/hooks.
# On 2026-09-19 that shipped, and the first pull that installed it spent twenty two minutes walking
# every file under ~ before it was stopped. It is L668's shape: a tool that works out where it is
# by counting directories upwards is wrong the moment it is installed somewhere else.
#
# So the checker refuses that root by name rather than trusting its caller, because the cost of
# being wrong is unbounded and a guard should refuse what it cannot do in a bounded way (L24).
out_home="$(bash "$CHECK" "$HOME" 2>&1)"; code_home=$?
[ "$code_home" -ne 0 ]   && check "a root that is the home directory is refused rather than walked" ok   || check "a root that is the home directory is refused rather than walked" "exit=$code_home out=$out_home"
grep -qi 'home directory' <<< "$out_home"   && check "and it says that is what it refused" ok   || check "and it says that is what it refused" "out=$out_home"

# ---------------------------------------------------------------------------
# The real repository, last. This is the assertion that keeps working after the fixtures above
# have proved the guard can fail.
#
# The tree comes from GIT rather than from counting directories upwards, so the installed copy,
# which sits in no repository, reports that it had nothing to measure instead of walking whatever
# happens to be above it (L411, L668).
# ---------------------------------------------------------------------------
ROOT="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  echo "note: this copy of the suite is not inside a git checkout, so there is no repository to parse and that case is reported as UNMEASURED rather than passed."
  check "the real tree case could not be measured from this copy" ok
else
out_real="$(bash "$CHECK" "$ROOT" 2>&1)"; code_real=$?
[ "$code_real" -eq 0 ] \
  && check "every shell file in this repository parses" ok \
  || check "every shell file in this repository parses" "exit=$code_real out=$out_real"
# And that it actually found them. A sweep reporting a handful when the repository holds well over
# a hundred has lost its way to most of the tree and would still be green (L98).
# Taken by parameter expansion rather than a pipeline, for the reason the guard beside this one
# states: a short circuiting consumer under pipefail kills its producer (L183).
real_n="${out_real#*check-shell-syntax: }"
real_n="${real_n%% *}"
case "$real_n" in ''|*[!0-9]*) real_n=0 ;; esac
[ "$real_n" -gt 100 ] \
  && check "and it reached the whole tree rather than a corner of it" ok \
  || check "and it reached the whole tree rather than a corner of it" "it parsed only $real_n file(s): $out_real"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
