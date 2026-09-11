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

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/scan-subshell-globals.py"
REPO="$(cd "$DIR/../.." && pwd)"

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

EMPTY="$FIX/empty"; mkdir -p "$EMPTY"
OUT="$(python3 "$SCAN" --root "$EMPTY" --baseline "$FIX/baseline.txt" 2>&1)"; RC=$?
check "a run that found no sources refuses rather than passing" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC")"
OUT="$(python3 "$SCAN" --root "$FIX" --baseline "$FIX/no-such-baseline.txt" 2>&1)"; RC=$?
check "a missing baseline refuses rather than treating every finding as new" "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC")"

echo "scan subshell globals: and the real tree it ships to guard"

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
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
