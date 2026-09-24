#!/usr/bin/env bash
# Tests for the guard that every headless `claude -p` launch decides what config it loads
# (claude-config#538).
#
# A headless run started by a hook inherits the whole global CLAUDE.md and all twelve lessons index
# files unless something says otherwise, and nothing in the call shows it. Measured 2026-09-23: the
# findings harvester took 64,868 input tokens with them and 29,663 without, on every harvest, and
# answered a question about lesson L1001 by quoting it. So each launch either switches the config
# off (CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 on the launch itself) or says why it keeps it or already
# excludes it, with a `# claude-mds-ok: <reason>` comment directly above the statement.
#
# Driven against fixtures FIRST, so every outcome is produced rather than merely reachable (L151),
# then against the real tree, because a scan proven only over files this suite wrote says nothing
# about the one anybody runs (L52).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/lib/headless-claude-config.py"
# The installed copy of these hooks has no repository above it, and this suite is about the
# repository (see test-scan-subshell-globals.sh for what walking $HOME instead cost).
REPO="$(cd "$DIR/../.." && pwd)"
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-headless-claude-config: $REPO is not a checkout of this repo (no claude-sync and payload/ in it), so there was nothing here to scan." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $REPO is not one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
says() { case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3': $2" ;; esac; }
silent_on() { case "$2" in *"$3"*) check "$1" "named '$3': $2" ;; *) check "$1" ok ;; esac; }

[ -f "$SCAN" ] || { echo "FAIL: no scan at $SCAN"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/headless-claude.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

RC=0; OUT=""
run() { OUT="$(python3 "$SCAN" "$FIX" 2>&1)"; RC=$?; }
fresh() { rm -rf "$FIX"/*; }

echo "headless claude config: what it must catch"

# The incident: the harvester's launch, as it stood, with nothing said about config.
fresh
cat > "$FIX/harvest.sh" <<'EOF'
out=$(printf '%s' "$PROMPT" \
  | CLAUDE_DETACHED_RUN=1 with_deadline 60 claude -p --model haiku)
EOF
run
check "an unmarked shell launch fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"
says "and names the file and line" "$OUT" "harvest.sh:2"

# The long option is the same launch.
fresh
printf 'claude --print --model haiku < prompt.txt\n' > "$FIX/long.sh"
run
check "a --print launch is a launch too" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"

# Python builds its argv as a list, where the words sit apart in quotes.
fresh
cat > "$FIX/review.py" <<'EOF'
import subprocess
cmd = ["env", "-u", "CLAUDECODE", "claude", "-p", prompt, "--model", model]
subprocess.run(cmd)
EOF
run
check "an unmarked python argv launch fails the scan" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"
says "and names it" "$OUT" "review.py:2"

# A marker whose reason is only punctuation is not a reason (L675).
fresh
cat > "$FIX/empty-reason.sh" <<'EOF'
# claude-mds-ok: -
claude -p --model haiku < prompt.txt
EOF
run
check "a marker with no worded reason does not count" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"

# A marker above a DIFFERENT statement does not carry down past code to this one.
fresh
cat > "$FIX/far.sh" <<'EOF'
# claude-mds-ok: this one is measured
first=$(claude -p --setting-sources local < a.txt)
second=$(claude -p < b.txt)
EOF
run
check "a marker covers only the statement directly beneath it" "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC")"
says "and the uncovered one is named" "$OUT" "far.sh:3"
silent_on "and the covered one is not" "$OUT" "far.sh:2"

echo "headless claude config: what it must leave alone"

# Switched off on the launch itself.
fresh
cat > "$FIX/off.sh" <<'EOF'
out=$(printf '%s' "$PROMPT" \
  | CLAUDE_DETACHED_RUN=1 CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 with_deadline 60 claude -p --model haiku)
EOF
cat > "$FIX/off.py" <<'EOF'
cmd = ["env", "-u", "CLAUDECODE", "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p", prompt]
EOF
run
check "a launch that switches the config off passes" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# Marked, with the marker above a statement that continues over several lines, and with another
# comment line between the marker and the code.
fresh
cat > "$FIX/marked.sh" <<'EOF'
if true; then
  # claude-mds-ok: --setting-sources local keeps the config out, measured.
  # A second comment line explaining something else.
  envelope="$(printf '%s' "$x" | ( cd "$J" && \
    claude -p --model sonnet --output-format json \
      --setting-sources local ) )"
fi
EOF
run
check "a marked multi line launch passes" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"

# Talking ABOUT the command is not running it: shell comments, and prose in a python docstring.
fresh
cat > "$FIX/talk.sh" <<'EOF'
# Detached-run guard: a headless `claude -p` launched by an app has nobody to reflect TO.
echo done  # after which claude -p runs elsewhere
EOF
cat > "$FIX/talk.py" <<'EOF'
"""It runs EXACTLY `env -u CLAUDECODE claude -p <prompt> --model <model>` with the diff on stdin."""
EOF
# One real, switched off launch beside them, so a clean exit means they were not counted rather
# than that nothing was found at all.
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p < p.txt\n' > "$FIX/real.sh"
run
check "a comment or docstring naming the command is not a launch" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and only the real launch was counted" "$OUT" "checked 1 headless"

# A test suite's stubs are not launches, and this suite's own fixtures above are exactly that.
fresh
printf 'claude -p --model haiku < prompt.txt\n' > "$FIX/test-something.sh"
printf 'CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p < p.txt\n' > "$FIX/real.sh"
run
check "a test suite is not scanned" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
says "and its stub was not counted" "$OUT" "checked 1 headless"

# Finding NO launches at all is its own answer, never a pass: a scan that stopped matching would
# otherwise report the tree clean forever (L98).
fresh
printf 'echo hello\n' > "$FIX/nothing.sh"
run
check "a tree with no launches at all is refused, not passed" "$([ "$RC" -eq 3 ] && echo ok || echo "exit $RC")"
says "and says it found none" "$OUT" "no headless"

echo "headless claude config: the real tree"

OUT="$(python3 "$SCAN" "$REPO/payload" "$REPO/tools" "$REPO/claude-sync" 2>&1)"; RC=$?
check "every headless launch in this repository decides its config" "$([ "$RC" -eq 0 ] && echo ok || echo "exit $RC: $OUT")"
# The four known launches (the harvester, the judge twice, the PR review) must be among what was checked, so a scan that silently stopped
# seeing one of them fails here rather than passing on the others (L63).
count="$(printf '%s' "$OUT" | sed -n 's/.*checked \([0-9][0-9]*\) headless.*/\1/p')"
check "and it saw at least the four known launches" "$([ "${count:-0}" -ge 4 ] && echo ok || echo "saw ${count:-none}: $OUT")"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
