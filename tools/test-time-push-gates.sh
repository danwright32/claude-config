#!/usr/bin/env bash
# Tests for time-push-gates.sh, which times every gate a `git push` waits on (claude-config#523).
#
# Four hooks declare timeouts of 30, 120, 180 and 300 seconds and only one of them had ever been
# measured, so the real cost of pushing was a sum of guesses. A gate's own guards are an untimed
# pipeline (L300), and a declared timeout is evidence of what somebody feared, not of what it costs.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$DIR/time-push-gates.sh"
pass=0; fail=0
check(){ if [[ "$2" == "ok" ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-config-time-gates.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-time-push-gates: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# A fixture config: two quick gates, one that overruns its declared timeout, and one that is not
# run for Bash at all. Every hook is a stub, so this suite pays no real gate's cost (L143).
HOME_DIR="$TMPROOT/home"
mkdir -p "$HOME_DIR/hooks"
mk(){ printf '#!/usr/bin/env bash\ncat >/dev/null\n%s\n' "$2" > "$HOME_DIR/hooks/$1"; chmod +x "$HOME_DIR/hooks/$1"; }
mk quick.sh 'exit 0'
mk speaks.sh 'echo "a line"; exit 0'
mk slow.sh 'sleep 30; exit 0'
mk writes.sh 'exit 0'
cat > "$HOME_DIR/settings.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "__CLAUDE_HOME__/hooks/quick.sh", "timeout": 30 },
          { "type": "command", "command": "__CLAUDE_HOME__/hooks/speaks.sh", "timeout": 60 },
          { "type": "command", "command": "__CLAUDE_HOME__/hooks/slow.sh", "timeout": 1 }
        ]
      },
      {
        "matcher": "Write",
        "hooks": [ { "type": "command", "command": "__CLAUDE_HOME__/hooks/writes.sh" } ]
      }
    ]
  }
}
JSON

out="$(GATE_TIMING_HOME="$HOME_DIR" bash "$T" --repo "$TMPROOT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && check "it runs and reports" ok || check "it runs and reports" "rc=$rc out=$out"
for want in quick.sh speaks.sh slow.sh; do
  case "$out" in *"$want"*) check "it times $want" ok ;; *) check "it times $want" "out=$out" ;; esac
done
case "$out" in
  *writes.sh*) check "a hook that is not run for Bash is left out" "out=$out" ;;
  *) check "a hook that is not run for Bash is left out" ok ;;
esac
# The overrunning gate is KILLED at its declared timeout and said to have been, never reported as a
# duration somebody could mistake for a measurement (L11).
case "$out" in
  *"slow.sh"*"timed out"*|*"slow.sh"*"KILLED"*) check "a gate past its declared timeout is killed and named as such" ok ;;
  *) check "a gate past its declared timeout is killed and named as such" "out=$out" ;;
esac
# A total, because what a push waits on is the sum, and that is the number the issue is about.
case "$out" in *TOTAL*) check "it reports the total a push waits" ok ;; *) check "it reports the total a push waits" "out=$out" ;; esac
# Every duration is a real reading: the fixture's slow gate must be the slowest of the three.
_slow_s="$(printf '%s\n' "$out" | awk '/slow[.]sh/ { print $1 + 0 }')"
_quick_s="$(printf '%s\n' "$out" | awk '/quick[.]sh/ { print $1 + 0 }')"
awk -v a="${_slow_s:-0}" -v b="${_quick_s:-0}" 'BEGIN { exit !(a > b) }' \
  && check "the durations are measured, not printed from the config" ok \
  || check "the durations are measured, not printed from the config" "slow=$_slow_s quick=$_quick_s"

# A settings file it cannot read is a refusal, never an empty table that reads as no gates (L98).
out2="$(GATE_TIMING_HOME="$TMPROOT/nowhere" bash "$T" --repo "$TMPROOT" 2>&1)"; rc2=$?
[ "$rc2" -ne 0 ] && case "$out2" in *"could not read"*) true ;; *) false ;; esac \
  && check "a settings file it cannot read is refused by name" ok \
  || check "a settings file it cannot read is refused by name" "rc=$rc2 out=$out2"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
