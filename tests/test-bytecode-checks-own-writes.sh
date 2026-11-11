#!/usr/bin/env bash
# The bytecode checks in test-shell-code-lines.sh (#2080) and test-work-names.sh (#2444) count only
# what their own suite's programs write (claude-config#2757), each seen both ways on a COPY of
# payload/hooks, never the tree being worked in:
#   - a bytecode file something else left in lib/__pycache__ (a probe run by hand, another suite at
#     the same moment, an older run) must not fail them, which it did while they counted the shared
#     folder;
#   - a writer in the suite's own programs must still fail them, with PYTHONDONTWRITEBYTECODE=1
#     handed down as the runner and arming hand it to every suite (#2751), which would otherwise
#     pass a writer unseen.
# The work names suite takes about ten seconds, so its two halves are read from one run: a writer
# planted in it, with a stray file present that the old count would also have named.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

W="$(mktemp -d "${TMPDIR:-/tmp}/bytecode-own-writes.XXXXXXXX")" || W=""
case "${W%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$W'" >&2; exit 2 ;; esac
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

HOOKS="$ROOT/payload/hooks"
TAG="$(python3 -c 'import sys; print(sys.implementation.cache_tag)')"

# A copy of hooks/lib and the two suites at <dest>/hooks, the layout test-work-names.sh's placement
# copy reads ("$HERE/.."), with no bytecode carried over.
copy_hooks(){   # $1 = destination
  mkdir -p "$1/hooks" && cp -R "$HOOKS/lib" "$1/hooks/lib" && rm -rf "$1/hooks/lib/__pycache__" \
    && cp "$HOOKS/test-shell-code-lines.sh" "$HOOKS/test-work-names.sh" "$1/hooks/"
}
# Runs a copied suite as the runner does, with bytecode turned off in what it is handed (#2751).
run_suite(){   # $1 = the suite's path
  env PYTHONDONTWRITEBYTECODE=1 bash "$1" 2>&1
}

# ------------------------------------------------- test-shell-code-lines.sh, a stray file present
SCL_CHECK='#2080 loading the reader leaves no shell-words bytecode'
copy_hooks "$W/stray" || check "the stray copy is made" "the copy failed"
mkdir -p "$W/stray/hooks/lib/__pycache__"
printf 'not bytecode\n' > "$W/stray/hooks/lib/__pycache__/shell-words.$TAG.pyc"
out="$(run_suite "$W/stray/hooks/test-shell-code-lines.sh")"; rc=$?
case "$out" in
  *"SUITE-RESULT passed="*) check "control: the copied shell code lines suite ran to its end" ok ;;
  *) check "control: the copied shell code lines suite ran to its end" "no SUITE-RESULT line: $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')" ;;
esac
case "$out" in
  *"FAIL: $SCL_CHECK"*) check "#2757 a shell-words bytecode file left in lib/ by something else does not fail the suite" "$(printf '%s\n' "$out" | grep -F "$SCL_CHECK")" ;;
  *) [ "$rc" -eq 0 ] && check "#2757 a shell-words bytecode file left in lib/ by something else does not fail the suite" ok \
       || check "#2757 a shell-words bytecode file left in lib/ by something else does not fail the suite" "exit $rc: $(printf '%s\n' "$out" | grep '^FAIL' | tr '\n' ' ')" ;;
esac
[ -f "$W/stray/hooks/lib/__pycache__/shell-words.$TAG.pyc" ] \
  && check "control: the stray file was still there when the suite ended" ok \
  || check "control: the stray file was still there when the suite ended" "it was gone, so it was never counted"

# ------------------------------------------------- test-shell-code-lines.sh, the reader made a writer
# The reader loads shell-words.py with bytecode off and puts the caller's setting back; this copy
# keeps the caller's setting for the load, so a caller writing bytecode leaves shell-words bytecode.
copy_hooks "$W/writer" || check "the writer copy is made" "the copy failed"
sed -i.orig 's/^    sys\.dont_write_bytecode = True$/    sys.dont_write_bytecode = _dont_write/' "$W/writer/hooks/lib/shell_code_lines.py"
if cmp -s "$W/writer/hooks/lib/shell_code_lines.py" "$W/writer/hooks/lib/shell_code_lines.py.orig"; then
  check "control: the reader in the writer copy was changed" "the edit matched nothing in lib/shell_code_lines.py"
else
  check "control: the reader in the writer copy was changed" ok
fi
out="$(run_suite "$W/writer/hooks/test-shell-code-lines.sh")"; rc=$?
case "$out" in
  *"FAIL: $SCL_CHECK"*) [ "$rc" -ne 0 ] && check "#2757 a reader that writes shell-words bytecode still fails the suite" ok \
                          || check "#2757 a reader that writes shell-words bytecode still fails the suite" "the check failed but the suite exited 0" ;;
  *) check "#2757 a reader that writes shell-words bytecode still fails the suite" "exit $rc, no failing '$SCL_CHECK' line: $(printf '%s\n' "$out" | tail -3 | tr '\n' ' ')" ;;
esac

# ------------------------------------------------- test-work-names.sh, a writer and a stray file
# The budget checks load lib/work-names.py by path with -B; this copy drops it, so the suite's own
# program writes work-names bytecode. The stray carries a time after the run started, so a count of
# the shared folder by time would name it as this run's.
copy_hooks "$W/names" || check "the work names copy is made" "the copy failed"
sed -i.orig 's/python3 -B -c "\$BUDGET_PY"/python3 -c "$BUDGET_PY"/' "$W/names/hooks/test-work-names.sh"
if cmp -s "$W/names/hooks/test-work-names.sh" "$W/names/hooks/test-work-names.sh.orig"; then
  check "control: the budget loads in the work names copy were changed" "the edit matched nothing in test-work-names.sh"
else
  check "control: the budget loads in the work names copy were changed" ok
fi
rm -f "$W/names/hooks/test-work-names.sh.orig"
mkdir -p "$W/names/hooks/lib/__pycache__"
printf 'not bytecode\n' > "$W/names/hooks/lib/__pycache__/stray-probe.$TAG.pyc"
touch -t 203001010000 "$W/names/hooks/lib/__pycache__/stray-probe.$TAG.pyc"
out="$(run_suite "$W/names/hooks/test-work-names.sh")"; rc=$?
case "$out" in
  *"FAIL: #2444 nothing this suite runs leaves work-names bytecode"*"work-names.$TAG.pyc"*)
    [ "$rc" -ne 0 ] && check "#2757 a work names load writing bytecode still fails the suite" ok \
      || check "#2757 a work names load writing bytecode still fails the suite" "the check failed but the suite exited 0" ;;
  *) check "#2757 a work names load writing bytecode still fails the suite" "exit $rc: $(printf '%s\n' "$out" | grep -e '^FAIL' -e 'SUITE-RESULT' | tr '\n' ' ')" ;;
esac
case "$out" in
  *stray-probe*) check "#2757 a bytecode file another program left in lib/ is not counted as the work names suite's" "$(printf '%s\n' "$out" | grep -F stray-probe)" ;;
  *) check "#2757 a bytecode file another program left in lib/ is not counted as the work names suite's" ok ;;
esac

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
