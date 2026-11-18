#!/usr/bin/env bash
# A whole tree scan: every tracked test-*.sh suite is committed as mode 100755 (claude-config#3180).
#
# #3142 added payload/hooks/test-slack-drafts-gate-qos.sh as 100644, the only one of 202 in
# payload/hooks that was not 100755. The installed copy was executable, so the sync watcher read the
# mode as a change to send on every pass, which is how #3175 surfaced. Nothing checked the mode of a
# suite, and a mode that is wrong looks like a file that is fine: run-all-tests starts every suite
# as `bash <suite>`, so a 100644 suite runs and passes (L100).
#
# The mode is read from `git ls-files -s`, which is what is committed, never from the working copy:
# a chmod on disk that was never staged makes a stat say 755 while the commit still says 644.
#
# Every tracked test-*.sh anywhere in the repository is judged, by the same name run-all-tests
# discovers suites by, and not other .sh files. How many other tracked .sh files under payload/hooks
# are not executable is printed as information only, so widening the scan stays a visible choice.
#
# Driven against a throwaway git repository FIRST, so the failure is produced rather than merely
# reachable (L1), with a control where every suite is 100755 that must pass, and against the real
# tree last, because a scan proven only over files this suite wrote says nothing about the one
# anybody runs (L52).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# WHERE THIS IS RUNNING. The repository's payload/hooks has a git checkout above it; the installed
# copy under the config root does not, and this suite is about the repository, so there it is
# reported as NOT RUN and never as a pass (claude-config#1567, #1663).
REPO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -z "$REPO" ]; then
  echo "test-suite-modes: $DIR/.. is not the payload of a claude-config checkout, so there was no commit to read modes from." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $DIR/.. is not the payload of one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says(){ case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3': $2" ;; esac; }
silentabout(){ case "$2" in *"$3"*) check "$1" "it named '$3'" ;; *) check "$1" ok ;; esac; }

# THE SCAN. suite_mode_report <repository> prints, on stdout:
#   JUDGED <n>              how many tracked test-*.sh files it read a mode for
#   BAD <mode> <path>       one line for each that is not 100755
#   OTHER <n>               tracked .sh files under payload/hooks, not test-*.sh, not 100755 (information)
# and exits 0 when none is bad, 1 when any is, 2 when the index could not be read. A run that judged
# nothing exits 2 as well: with no suite in sight, "none is bad" is a statement about an empty list.
suite_mode_report() {
  local repo="$1" listing rc
  listing="$(git -C "$repo" ls-files -s 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "suite-modes: git ls-files -s failed in $repo, so no mode was read: $listing" >&2
    return 2
  fi
  printf '%s\n' "$listing" | awk -F'\t' '
    NF >= 2 {
      split($1, a, " "); mode = a[1]; path = $2
      n = split(path, parts, "/"); base = parts[n]
      if (base ~ /^test-.*\.sh$/) {
        judged++
        if (mode != "100755") { bad++; print "BAD " mode " " path }
      } else if (base ~ /\.sh$/ && path ~ /^payload\/hooks\// && mode != "100755") {
        other++
      }
    }
    END {
      print "JUDGED " judged + 0
      print "OTHER " other + 0
      exit (judged + 0 == 0) ? 2 : (bad > 0 ? 1 : 0)
    }'
}

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/suite-modes.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

# A throwaway repository holding the given suites. mk_repo <dir> <path:mode>...; mode is 755 or 644.
# Committed, then the modes read back, so what the fixture holds is the committed state.
mk_repo() {
  local d="$1" spec p m
  shift
  mkdir -p "$d"
  git -C "$d" init -q || return 1
  for spec in "$@"; do
    p="${spec%:*}"; m="${spec##*:}"
    mkdir -p "$d/$(dirname "$p")"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$p"
    git -C "$d" add -- "$p"
    if [ "$m" = "755" ]; then git -C "$d" update-index --chmod=+x -- "$p"; else git -C "$d" update-index --chmod=-x -- "$p"; fi
  done
  git -C "$d" -c user.name=fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null \
    commit -q --no-gpg-sign -m fixture || return 1
}

RC=0; OUT=""
run() { OUT="$(suite_mode_report "$1" 2>&1)"; RC=$?; }

echo "suite modes: the fault it was written for"

# The incident in miniature: one suite committed 100644 among executable ones, in three different
# folders, because the scan covers the tree and not one directory.
mk_repo "$FIX/bad" \
  payload/hooks/test-ok.sh:755 \
  payload/hooks/test-not-executable.sh:644 \
  tests/test-also-ok.sh:755 \
  tools/test-tools-not-executable.sh:644 \
  || check "the throwaway repository was built" "git refused"
run "$FIX/bad"
check "a suite committed as 100644 fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
says "and it names the suite under payload/hooks" "$OUT" "BAD 100644 payload/hooks/test-not-executable.sh"
says "and one under tools, so the whole tree is covered" "$OUT" "BAD 100644 tools/test-tools-not-executable.sh"
silentabout "and does not name an executable suite" "$OUT" "test-ok.sh"
silentabout "and not one in tests/ that is executable" "$OUT" "test-also-ok.sh"
says "and it says how many it judged" "$OUT" "JUDGED 4"

# What is committed, not what is on disk: the working copy made executable without staging it.
chmod +x "$FIX/bad/payload/hooks/test-not-executable.sh"
run "$FIX/bad"
check "a chmod on disk that was never committed does not satisfy it" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"
says "and the suite is still named" "$OUT" "payload/hooks/test-not-executable.sh"

echo "suite modes: and nothing it should leave alone"

# The control: every suite 100755, plus a non-suite .sh that is 100644. It must pass, and the
# non-suite file is information, never a failure.
mk_repo "$FIX/good" \
  payload/hooks/test-a.sh:755 \
  tests/test-b.sh:755 \
  tools/test-c.sh:755 \
  payload/hooks/helper-not-a-suite.sh:644 \
  || check "the control repository was built" "git refused"
run "$FIX/good"
check "control: every suite at 100755 passes" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "control: and it judged all three" "$OUT" "JUDGED 3"
says "control: and counts the other non-executable hook file as information" "$OUT" "OTHER 1"
silentabout "control: and does not fail on it" "$OUT" "BAD"

# A file that merely has the suite name inside a longer name or another extension is not a suite.
mk_repo "$FIX/names" \
  tests/test-real.sh:755 \
  tests/test-notes.txt:644 \
  tests/not-a-test-x.sh:644 \
  || check "the names repository was built" "git refused"
run "$FIX/names"
check "only test-*.sh names are judged" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and exactly one was judged" "$OUT" "JUDGED 1"

# A repository with no suite at all must refuse, not read as a clean tree (L98).
mk_repo "$FIX/none" payload/hooks/helper.sh:644 || check "the empty repository was built" "git refused"
run "$FIX/none"
check "a repository with no suite refuses rather than passing" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC: $OUT")"

# A folder that is not a repository cannot be read, and says so.
mkdir -p "$FIX/plain"
run "$FIX/plain"
check "a folder with no git index refuses rather than passing" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC: $OUT")"
says "and says no mode was read" "$OUT" "no mode was read"

echo "suite modes: and the real tree it ships to guard"

run "$REPO"
check "every tracked test-*.sh in this repository is committed as 100755" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
_judged="$(printf '%s\n' "$OUT" | sed -n 's/^JUDGED \([0-9]*\)$/\1/p')"
# A scan that judged nothing agrees with everything (L98); the tree has well over 300 suites.
check "and it really judged the repository's suites, rather than few or none" "$([ "${_judged:-0}" -gt 300 ] && echo ok || echo "judged ${_judged:-0}")"
printf 'info: %s other tracked .sh files under payload/hooks are not 100755 and are not judged here\n' \
  "$(printf '%s\n' "$OUT" | sed -n 's/^OTHER \([0-9]*\)$/\1/p')"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
