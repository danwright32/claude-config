#!/usr/bin/env bash
# Tests for the scan that finds a function answering into a global nobody can read
# (claude-config#372).
#
# lesson_index_entry_cap recorded "this hook exists but carries no cap" in a shared variable, while
# every call site read the function through a command substitution. That is a subshell, so the
# assignment was discarded on return and the warning it fed could never fire, with the code setting
# it reading as entirely correct. The tests caught it; inspection would not have.
#
# Driven against fixtures FIRST, so every outcome is produced rather than merely reachable (L151),
# and against the real tree at the end, because a scan proven only over files this suite wrote says
# nothing about the one anybody runs (L52).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/scan-subshell-globals.py"
# WHERE THIS IS RUNNING. Two copies of these hooks exist: the repo's payload/hooks, which sits
# beside a claude-sync and a payload/, and the INSTALLED copy under the config root, which does
# not. `$DIR/../..` is the repo in the first and the HOME DIRECTORY in the second, so a suite that
# assumes the first walks all of $HOME in the second. Measured 2026-09-11: that is what made
# `claude-sync recheck` exceed its 30 minute ceiling and report the whole config unverified.
#
# Said in the one agreed shape the runner reads, so it is reported as NOT RUN rather than as broken
# code, and never as a pass: this suite is about the repo, and the installed copy is not one.
REPO="$(cd "$DIR/../.." && pwd)"
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-scan-subshell-globals: $REPO is not a checkout of this repo (no claude-sync and payload/ in it), so there was nothing here to scan." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $REPO is not one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says(){ case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3'" ;; esac; }

[ -f "$SCAN" ] || { echo "FAIL: no scan at $SCAN"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/scan-subshell.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT
printf '# empty\n' > "$FIX/baseline.txt"

RC=0; OUT=""
run(){ OUT="$(python3 "$SCAN" --root "$FIX" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?; }

echo "scan subshell globals: the fault it was written for"

# The incident, in miniature: the answer is recorded in a global, and the one caller reads the
# function through a command substitution, so the assignment is gone by the time it returns.
cat > "$FIX/a.sh" <<'EOF'
ANSWER=""
read_cap(){
  ANSWER="hook present but carrying no cap"
  printf '%s' "160"
}
cap="$(read_cap)"
[ -n "$ANSWER" ] && echo "$ANSWER"
EOF
run
check "a function whose global every caller reads in a subshell is reported" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC")"
says "and the finding names the function" "$OUT" "read_cap"
says "and the name it sets" "$OUT" "ANSWER"

echo "scan subshell globals: and nothing it should leave alone"

# Called plainly SOMEWHERE is not condemned: answering into a global is a legitimate design when
# the caller is in the same shell, and this repo has such functions on purpose.
cat > "$FIX/a.sh" <<'EOF'
ANSWER=""
read_cap(){
  ANSWER="something"
  printf '%s' "160"
}
read_cap
cap="$(read_cap)"
EOF
run
check "a function also called plainly is not condemned" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# An env PREFIX assigns nothing in this shell. It is the commonest line shape in these suites, and
# counting it made the first measurement of this scan four times too large.
cat > "$FIX/a.sh" <<'EOF'
run_it(){
  CLAUDE_HOME="$fix" SYNC_REPO="$repo" bash "$prog" status
}
out="$(run_it)"
EOF
run
check "an env prefix on a command is not an assignment" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# A local is not a global, which is the whole remedy.
cat > "$FIX/a.sh" <<'EOF'
read_cap(){
  local answer
  answer="something"
  printf '%s' "$answer"
}
cap="$(read_cap)"
EOF
run
check "a variable declared local is not a global" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# A heredoc body is another language's code, not this shell's.
cat > "$FIX/a.sh" <<'OUTER'
convert(){
  python3 - <<'PY'
tzinfo = 1
print(tzinfo)
PY
}
x="$(convert)"
OUTER
run
check "an assignment inside a heredoc is not this shell's" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

echo "scan subshell globals: the baseline is a ratchet in both directions"

cat > "$FIX/a.sh" <<'EOF'
ANSWER=""
read_cap(){
  ANSWER="x"
  printf 'y'
}
cap="$(read_cap)"
EOF
printf 'a.sh: 1\n' > "$FIX/baseline.txt"
run
check "a finding the baseline already records does not fail the scan" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
printf 'a.sh: 2\n' > "$FIX/baseline.txt"
run
check "a baseline claiming more than the file has is refused" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC")"
says "and says the number is stale" "$OUT" "stale"

# A file this cannot OPEN is not a file with nothing in it. Returning "nothing judged, no
# findings" would make an unreadable file indistinguishable from a clean one, and the count it
# feeds is the whole verdict (L10, L11, L215).
UNREAD="$FIX/unreadable"; mkdir -p "$UNREAD"
printf 'echo hi\n' > "$UNREAD/x.sh"
chmod 000 "$UNREAD/x.sh"
printf '# empty\n' > "$UNREAD/baseline.txt"
OUT="$(python3 "$SCAN" --root "$UNREAD" --baseline "$UNREAD/baseline.txt" 2>&1)"; RC=$?
chmod 644 "$UNREAD"/*.sh 2>/dev/null || true
check "a file it cannot read is a finding, not a clean result" "$([ "$RC" -ne 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and it says the file could not be read" "$OUT" "could not be read"

EMPTY="$FIX/empty"; mkdir -p "$EMPTY"
OUT="$(python3 "$SCAN" --root "$EMPTY" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?
check "a run that found no sources refuses rather than passing" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC")"
OUT="$(python3 "$SCAN" --root "$FIX" --baseline "$FIX/no-such-baseline.txt" 2>&1)"; RC=$?
check "a missing baseline refuses rather than treating every finding as new" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC")"

echo "scan subshell globals: one verdict whatever --root names (claude-config#443)"

# #443 was reported as this scan being red on one Mac and green in CI. It was not the Mac: the
# report ran it with `--root payload`, the suite runs it with `--root .`, and the findings were
# keyed relative to whatever --root named while the baseline is written relative to the checkout.
# So the SAME tree gave two verdicts: every recorded file read as newly grown under one spelling
# of its path and as stale under the other. Reproduced identically on python 3.9, 3.11 and 3.14.
# A mini checkout, marked by `.git` the way a real one is, with a finding in each of two folders.
MINI="$FIX/mini"; mkdir -p "$MINI/.git" "$MINI/sub" "$MINI/other"
cat > "$MINI/sub/a.sh" <<'EOF'
ANSWER=""
read_cap(){
  ANSWER="x"
  printf 'y'
}
cap="$(read_cap)"
EOF
cp "$MINI/sub/a.sh" "$MINI/other/b.sh"
printf 'sub/a.sh: 1\nother/b.sh: 1\n' > "$MINI/baseline.txt"
OUT="$(python3 "$SCAN" --root "$MINI" --baseline "$MINI/baseline.txt" 2>&1)"; RC=$?
check "the whole checkout agrees with its baseline" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
OUT="$(python3 "$SCAN" --root "$MINI/sub" --baseline "$MINI/baseline.txt" 2>&1)"; RC=$?
check "and so does one folder of it, scanned alone" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and it names the finding by its path in the checkout" "$OUT" "sub/a.sh:2"
# The entry for the folder it did NOT read was not measured, so it may be neither passed nor
# called stale; it is said out loud as not judged (L11).
says "and says which baseline entry it did not judge" "$OUT" "not judged: other/b.sh"
# Scoping must not swallow the finding it exists for: the folder scanned alone still fails when
# its own file grows past the baseline.
printf 'sub/a.sh: 0\nother/b.sh: 1\n' > "$MINI/baseline.txt"
OUT="$(python3 "$SCAN" --root "$MINI/sub" --baseline "$MINI/baseline.txt" 2>&1)"; RC=$?
check "a folder scanned alone still fails on its own growth" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC: $OUT")"

echo "scan subshell globals: and the real tree it ships to guard"

# The exact command #443 reported, against the real tree.
OUT="$(cd "$REPO" && python3 "$SCAN" --root payload --baseline payload/hooks/subshell-globals.txt 2>&1)"; RC=$?
check "the real tree scanned as payload/ alone agrees with the baseline" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

OUT="$(cd "$REPO" && python3 "$SCAN" --root . 2>&1)"; RC=$?
check "the real tree agrees with its own baseline" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
_considered="$(printf '%s\n' "$OUT" | sed -n 's/^scan-subshell-globals: \([0-9]*\) function.*/\1/p')"
check "and it really considered the repo's functions, rather than none" "$([ "${_considered:-0}" -gt 20 ] && echo ok || echo "considered ${_considered:-0}")"
# The defect this scan found on the day it shipped must stay fixed: tip_payload_dir recorded its
# answer in a global its only caller read through a command substitution, so the cleanup that reads
# that variable could never fire and every comparison left a copy of the whole shared payload
# behind. Asserted here rather than only in the sync suite, because this is the scan that found it.
# Matched with `case` over a variable, never piped into `grep -q`: under pipefail a short
# circuiting consumer kills its producer and the pipeline reports a failure that never happened
# (L183), and this repo ratchets the count of such pipelines down rather than up.
case "$OUT" in
  *"claude-sync:"*) check "and claude-sync no longer holds the finding it found there" "claude-sync is flagged again" ;;
  *) check "and claude-sync no longer holds the finding it found there" ok ;;
esac

echo
# A NESTED CHECKOUT IS A SECOND COPY OF THE SAME TREE (claude-config#504, L234). This walk prunes
# .git, node_modules and __pycache__ and nothing else, so a worktree under .claude/worktrees is
# counted as though its files were the repository's own. Measured 2026-09-19 with two worktrees
# open: 166 shell files became 498, every tree wide count roughly tripled, and both ratchets went
# red on a tree nobody had changed. That is what made `claude-sync recheck` record this Mac as
# broken from one checkout and healthy from another, because only one of them had worktrees in it.
NEST="$FIX/nested"
mkdir -p "$NEST/payload/hooks" "$NEST/.claude/worktrees/copy/payload/hooks"
cat > "$NEST/payload/hooks/test-outer.sh" <<'NESTEOF'
#!/usr/bin/env bash
out="$(some_command)"
! grep -q 'a needle that is present here' <<< "$out" && echo ok
echo 'a needle that is present here'
NESTEOF
cp "$NEST/payload/hooks/test-outer.sh" "$NEST/.claude/worktrees/copy/payload/hooks/test-outer.sh"
nest_out="$(python3 "$SCAN" --root "$NEST" --baseline /dev/null 2>&1 || true)"
# Parameter expansion, not a pipeline: a short circuiting consumer like `head -1` kills the
# producer feeding it under pipefail, and the pipeline then reports a failure that never happened
# (L183). test-pipefail-shortcircuit.sh caught this exact line, and it is the second time today.
nest_n="${nest_out#*across }"
nest_n="${nest_n%% *}"
case "$nest_n" in ''|*[!0-9]*) nest_n=0 ;; esac
[ "$nest_n" = "1" ] \
  && check "a nested checkout is not scanned as part of the tree above it" ok \
  || check "a nested checkout is not scanned as part of the tree above it" "it counted $nest_n file(s), so the copy under .claude/worktrees was counted too: $nest_out"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
