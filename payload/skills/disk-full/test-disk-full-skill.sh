#!/usr/bin/env bash
# Tests for the disk-full skill's own commands (claude-config#683).
#
# The skill is a sequence of commands Claude runs on a Mac whose disk is full, which is the worst
# moment to find one of them does not work. Step 2 computed its rate with awk strftime, which macOS
# awk does not have ("calling undefined function strftime"), and told Claude to wait five minutes
# in the foreground, which the Bash tool refuses. Step 4 ran sudo itself while step 5 said sudo is
# only ever Dan's to run. Each of those is checked here against the skill's text, and the rate
# command is RUN, on whatever awk, df and date this machine has, rather than read (L442).
#
# Nothing here measures this Mac's disk: the rate command is run with every reading supplied and a
# state directory of the suite's own, so the shared history the prompt warning keeps is untouched.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$DIR/SKILL.md"
HOOKS="$(cd "$DIR/../../hooks" && pwd)"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/disk-full-skill.XXXXXXXX")" || TMP=""
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "test-disk-full-skill: refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

check "the skill is there to read" "$([ -f "$SKILL" ] && echo ok || echo "no $SKILL")"

# Every line inside a fenced block, which is what Claude actually runs.
CODE="$(awk '/^```/ { inside = !inside; next } inside' "$SKILL")"

# ---- 1. no awk strftime, which macOS awk does not have ----
check "no command uses awk strftime, which macOS awk lacks" \
  "$(grep -q 'strftime' "$SKILL" && echo "strftime is still in $SKILL" || echo ok)"

# ---- 2. no foreground wait, which the Bash tool refuses ----
check "no command sleeps in the foreground" \
  "$(grep -qE '(^|[;&| ])sleep ' <<< "$CODE" && echo "a sleep is in a command block" || echo ok)"
check "no step tells Claude to wait minutes inside the session" \
  "$(grep -qiE 'wait (five|5|several|a few) minutes' "$SKILL" && echo "still says to wait minutes" || echo ok)"

# ---- 3. the rate comes from check-free-space.sh, and the command as written works ----
rate_line="$(grep -m 1 -F 'check-free-space.sh' <<< "$CODE")"
check "the rate step runs the free space check rather than measuring a second way" \
  "$([ -n "$rate_line" ] && echo ok || echo "no command in a block runs check-free-space.sh")"
check "and runs the installed copy, with --report so a disk with room still answers" \
  "$(grep -qF '~/.claude/hooks/check-free-space.sh --report' <<< "$rate_line" && echo ok || echo "the line is: $rate_line")"
check "and prints the exit code, which is the verdict (L184)" \
  "$(grep -qF 'echo "exit $?"' <<< "$rate_line" && echo ok || echo "the line is: $rate_line")"

# Run that exact line, pointed at this checkout's copy, with a reading three hours old already in
# the history: the command must state a rate and an exit code on this machine's own tools.
STATE="$TMP/state"; mkdir -p "$STATE"
GB=$((1024 * 1024 * 1024)); T0=1757500000
printf '%s %s\n' "$((T0 - 10800))" "$((300 * GB))" > "$STATE/_fixture"
runnable="${rate_line//\~\/.claude\/hooks\//$HOOKS/}"
out="$(FREE_SPACE_BYTES="$((240 * GB))" FREE_SPACE_NOW="$T0" FREE_SPACE_STATE_DIR="$STATE" \
  FREE_SPACE_PATH=/fixture FREE_SPACE_SYMBOL_CACHE="$TMP/no-symbol-cache" bash -c "$runnable" 2>&1)"
check "the rate command, run as written, states the rate it measured" \
  "$(grep -q 'about 20 GB per hour' <<< "$out" && echo ok || echo "said: $out")"
check "and the exit code beside it" \
  "$(grep -qx 'exit 0' <<< "$out" && echo ok || echo "said: $out")"

# ---- 4. every sudo command is handed to Dan, never run by Claude ----
# The prose paragraph introducing each block that holds a sudo command must say it is Dan's.
unhanded="$(awk '
  /^```/ { if (!inside) before = para; inside = !inside; next }
  inside { if ($0 ~ /^sudo /) { if (before !~ /Dan/) print $0 }; next }
  /^[[:space:]]*$/ { blank = 1; next }
  { if (blank) para = $0; else para = para " " $0; blank = 0 }
' "$SKILL")"
check "every sudo command is introduced as Dan's to run" \
  "$([ -z "$unhanded" ] && echo ok || echo "not handed to Dan: $unhanded")"
# The positive control: the scan finds the sudo commands that ARE there (L159).
n_sudo="$(grep -c '^sudo ' <<< "$CODE")"
check "and the scan saw the sudo commands the skill does hand over" \
  "$([ "${n_sudo:-0}" -ge 2 ] && echo ok || echo "only $n_sudo sudo line(s) found")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
