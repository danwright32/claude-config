#!/usr/bin/env bash
# A command the segmented form hides is judged by a second run of the hook, and the two readings
# never change each other (lib/push-scope.sh ps_both_readings, claude-config#3739).
#
# Two things are held here:
#   1. THE SCAN. Every hook that reads the segmented form calls ps_both_readings once, at its top
#      level, before its first such read. A hook that reads the form without it judges the first
#      reading alone, and what the form hides goes unjudged with nothing said.
#   2. THE HELPER, against a stand in hook whose answer is a function of the text it is handed:
#      the first reading is judged first, alone and as it always was; the second is judged only
#      once the first has passed, and can only refuse; who says which reading a run is.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/both-readings.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT

echo "both readings: the scan"

# ---------------------------------------------------------------------------
# 1. The scan
# ---------------------------------------------------------------------------
# scan_file <file>: prints why the file breaks the rule, or nothing. A read of the segmented form
# is a call of ps_parse_payload that does not ask for raw (segmented is the default mode).
scan_file() {
  awk '
    /^[[:space:]]*#/ { next }
    /^ps_both_readings "\$payload"[[:space:]]*$/ { calls++; if (!read_at) before = 1; next }
    /ps_both_readings/ { stray = NR }
    /ps_parse_payload[[:space:]]+"/ && !/ps_parse_payload[[:space:]]+"[^"]*"[[:space:]]+raw/ { if (!read_at) read_at = NR }
    END {
      if (!read_at) exit 0
      if (stray) { printf "line %d names ps_both_readings in a form that is not the one call at the top level", stray; exit 0 }
      if (calls == 0) { printf "it reads the segmented form at line %d and never calls ps_both_readings", read_at; exit 0 }
      if (calls > 1) { printf "it calls ps_both_readings %d times", calls; exit 0 }
      if (!before) { printf "it reads the segmented form at line %d before it calls ps_both_readings", read_at; exit 0 }
    }' "$1"
}
reads_segmented() { # reads_segmented <file>: whether the file reads the segmented form at all
  awk '/^[[:space:]]*#/ { next }
       /ps_parse_payload[[:space:]]+"/ && !/ps_parse_payload[[:space:]]+"[^"]*"[[:space:]]+raw/ { found = 1 }
       END { exit found ? 0 : 1 }' "$1"
}

# The scan is seen to fail on each way of getting it wrong, and to pass the right form.
mkdir -p "$T/scan"
printf '%s\n' 'payload="$(cat)"' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/none.sh"
printf '%s\n' 'payload="$(cat)"' 'parsed="$(ps_parse_payload "$payload")"' > "$T/scan/default-mode.sh"
printf '%s\n' 'payload="$(cat)"' 'parsed="$(ps_parse_payload "$payload" segmented)"' 'ps_both_readings "$payload"' > "$T/scan/after.sh"
printf '%s\n' 'payload="$(cat)"' 'if true; then' '  ps_both_readings "$payload"' 'fi' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/nested.sh"
printf '%s\n' 'payload="$(cat)"' 'ps_both_readings "$payload"' 'ps_both_readings "$payload"' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/twice.sh"
printf '%s\n' 'payload="$(cat)"' '# ps_both_readings "$payload"' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/commented.sh"
printf '%s\n' 'payload="$(cat)"' 'ps_both_readings "$payload"' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/right.sh"
printf '%s\n' 'payload="$(cat)"' 'parsed="$(ps_parse_payload "$payload" raw)"' 'declare -F ps_parse_payload >/dev/null' > "$T/scan/raw.sh"
for f in none default-mode after nested twice commented; do
  why="$(scan_file "$T/scan/$f.sh")"
  [ -n "$why" ] && check "the scan fails a hook that gets it wrong ($f)" ok || check "the scan fails a hook that gets it wrong ($f)" "it passed"
done
for f in right raw; do
  why="$(scan_file "$T/scan/$f.sh")"
  [ -z "$why" ] && check "the scan passes a hook that has it right ($f)" ok || check "the scan passes a hook that has it right ($f)" "$why"
done

# Every hook and library here, the library that holds the helper aside.
readers=0
seen_style=no
for f in "$DIR"/*.sh "$DIR"/lib/*.sh; do
  case "${f##*/}" in test-*|test_*) continue ;; esac
  [ "$f" = "$DIR/lib/push-scope.sh" ] && continue
  reads_segmented "$f" || continue
  readers=$((readers + 1))
  [ "${f##*/}" = check-style-guide.sh ] && seen_style=yes
  why="$(scan_file "$f")"
  [ -z "$why" ] && check "${f##*/} judges both readings" ok || check "${f##*/} judges both readings" "$why"
done
# A scan that found no reader would pass every file by finding none (L100).
[ "$seen_style" = yes ] && [ "$readers" -ge 2 ] && check "the scan found the hooks that read the segmented form, check-style-guide.sh among them" ok \
  || check "the scan found the hooks that read the segmented form, check-style-guide.sh among them" "it found $readers, check-style-guide.sh among them: $seen_style"

# ---------------------------------------------------------------------------
# 2. The helper, against a stand in hook
# ---------------------------------------------------------------------------
echo "both readings: the helper"
command -v python3 >/dev/null 2>&1 || { check "python3 is here to make the payloads and the second reading" "python3 is not on PATH"; }

# The stand in refuses a text that runs a push, says a note for one that runs `note`, and exits 3
# for one that runs `crash`. Every run writes which reading it was told it is and what it read.
HOOK="$T/stand-in.sh"
cat > "$HOOK" <<HOOKEND
#!/bin/bash
. "$DIR/lib/push-scope.sh" || exit 9
payload="\$(ps_read_payload)"
echo "start" >> "\$BR_LOG"
ps_both_readings "\$payload"
parsed="\$(ps_parse_payload "\$payload" segmented)" || { echo "the stand in could not parse its payload" >&2; exit 2; }
cmd="\${parsed%%\$'\\x1f'*}"
printf 'judged|%s|%s|%s\\n' "\${PS__READING:-alone}" "\${PS_READING-unset}" "\$cmd" >> "\$BR_LOG"
if ps__runs_git_sub "\$cmd" gc; then echo "crashed on the \${PS__READING:-alone} reading" >&2; exit 3; fi
if ps__runs_git_sub "\$cmd" status; then echo "a note from the \${PS__READING:-alone} reading"; fi
if ps_is_git_push "\$cmd"; then echo "refused on the \${PS__READING:-alone} reading" >&2; exit 2; fi
exit 0
HOOKEND

payload_for() { # payload_for <command text>
  python3 -c 'import json, sys
sys.stdout.write(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": "/w"}))' "$1"
}
RC=0; OUT=""; ERR=""
run_hook() { # run_hook <command text>: sets RC, OUT, ERR and leaves the log in $T/log
  : > "$T/log"
  payload_for "$1" | BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
starts() { grep -c '^start$' "$T/log" || true; }
judged() { grep '^judged|' "$T/log" | cut -d'|' -f2 | tr '\n' ' ' | sed 's/ $//'; }

NL=$'\n'
PAIR=$'\\\n'
PUSH="git push"
HIDDEN="cat <<EOF; $PUSH${NL}body${NL}EOF"

run_hook "echo one${NL}echo two"
[ "$RC" = 0 ] && [ "$(starts)" = 1 ] && [ "$(judged)" = alone ] && check "a command with no second reading is judged once, by the hook itself, with nothing started" ok \
  || check "a command with no second reading is judged once, by the hook itself, with nothing started" "exit $RC, starts $(starts), judged [$(judged)]"
run_hook "git commit -F - <<EOF${NL}a message; with a separator in it${NL}EOF${NL}echo done"
[ "$RC" = 0 ] && [ "$(starts)" = 1 ] && check "and so is a heredoc with nothing after its opener" ok \
  || check "and so is a heredoc with nothing after its opener" "exit $RC, starts $(starts)"
run_hook "$PUSH"
[ "$RC" = 2 ] && [ "$(starts)" = 1 ] && [ "$ERR" = "refused on the alone reading" ] && check "a push typed in the open is refused as it always was, in one run" ok \
  || check "a push typed in the open is refused as it always was, in one run" "exit $RC, starts $(starts), said [$ERR]"

run_hook "$HIDDEN"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "a push after a heredoc's opener on its line is refused, by the second reading" ok \
  || check "a push after a heredoc's opener on its line is refused, by the second reading" "exit $RC, said [$ERR]"
[ "$(judged)" = "first second" ] && check "there the first reading is judged first and the second after it" ok \
  || check "there the first reading is judged first and the second after it" "judged [$(judged)]"
grep -q "^judged|first|unset|cat <<EOF; $PUSH; body; EOF$" "$T/log" && check "the first run is handed the text as it always was, with nothing before or after it" ok \
  || check "the first run is handed the text as it always was, with nothing before or after it" "the log holds [$(grep '^judged|first' "$T/log")]"
grep -q "^judged|second|unset|cat <<EOF; body; EOF; $PUSH$" "$T/log" && check "the second run is handed the second reading alone" ok \
  || check "the second run is handed the second reading alone" "the log holds [$(grep '^judged|second' "$T/log")]"
grep '^judged|' "$T/log" | cut -d'|' -f3 | grep -qv '^unset$' && check "neither run leaves PS_READING in the environment of what it starts" "one did: [$(grep '^judged|' "$T/log")]" \
  || check "neither run leaves PS_READING in the environment of what it starts" ok

run_hook "bash -c 'git ${PAIR}push'"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "a push across the pair in a wrapper's string is refused, by the second reading" ok \
  || check "a push across the pair in a wrapper's string is refused, by the second reading" "exit $RC, said [$ERR]"

# The first reading's refusal stands whatever the second holds, and the second is never started.
for c in "cat <<EOF; cd docs${NL}body${NL}EOF${NL}$PUSH" "bash -c 'git com${PAIR}mit -m x'; $PUSH" \
         "cat <<EOF; SKIP_STYLE_CHECK=1 true${NL}body${NL}EOF${NL}$PUSH" "cat <<EOF; exit 0${NL}body${NL}EOF${NL}$PUSH"; do
  run_hook "$c"
  [ "$RC" = 2 ] && [ "$ERR" = "refused on the first reading" ] && [ "$(judged)" = first ] \
    && check "a refusal of the first reading is the answer, and the second reading is never started: ${c%%$NL*}" ok \
    || check "a refusal of the first reading is the answer, and the second reading is never started: ${c%%$NL*}" "exit $RC, said [$ERR], judged [$(judged)]"
done

# What is said.
run_hook "git status; cat <<EOF; echo hidden${NL}body${NL}EOF"
[ "$RC" = 0 ] && [ "$OUT" = "a note from the first reading" ] && [ "$(judged)" = "first second" ] && check "when both pass, what the first run said is what the hook says" ok \
  || check "when both pass, what the first run said is what the hook says" "exit $RC, said [$OUT], judged [$(judged)]"
run_hook "cat <<EOF; git status${NL}body${NL}EOF"
[ "$RC" = 0 ] && [ "$OUT" = "a note from the second reading" ] && check "when both pass and the first said nothing, what the second said is said" ok \
  || check "when both pass and the first said nothing, what the second said is said" "exit $RC, said [$OUT]"
run_hook "cat <<EOF; git gc${NL}body${NL}EOF"
[ "$RC" = 3 ] && [ "$ERR" = "crashed on the second reading" ] && check "a second run that fails is not a pass: its exit and its words are the hook's" ok \
  || check "a second run that fails is not a pass: its exit and its words are the hook's" "exit $RC, said [$ERR]"
run_hook "git gc; cat <<EOF; echo hidden${NL}body${NL}EOF"
[ "$RC" = 3 ] && [ "$ERR" = "crashed on the first reading" ] && [ "$(judged)" = first ] && check "a first run that fails is the answer, as it was" ok \
  || check "a first run that fails is the answer, as it was" "exit $RC, said [$ERR], judged [$(judged)]"

# Who says which reading a run is.
: > "$T/log"
payload_for "$HIDDEN" | PS_READING="second:1" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
ERR="$(cat "$T/err")"
case "$RC:$ERR" in
  2:BLOCKED*"PS_READING is already set"*) check "PS_READING set by anything but the hook that started this run is not believed, and a command with two readings is refused saying so" ok ;;
  *) check "PS_READING set by anything but the hook that started this run is not believed, and a command with two readings is refused saying so" "exit $RC, said [$ERR]" ;;
esac
grep -q '^judged|' "$T/log" && check "and nothing was judged on its word" "the log holds [$(grep '^judged|' "$T/log")]" || check "and nothing was judged on its word" ok
: > "$T/log"
payload_for "$PUSH" | PS_READING="second:1" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 2 ] && [ "$(judged)" = alone ] && check "with it set so, a push typed in the open is still judged by the first reading and refused" ok \
  || check "with it set so, a push typed in the open is still judged by the first reading and refused" "exit $RC, judged [$(judged)]"
: > "$T/log"
payload_for "$PUSH; cat <<EOF; echo hidden${NL}body${NL}EOF" | PS__READING=second BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 2 ] && [ "$(cat "$T/err")" = "refused on the first reading" ] && check "the library's own variable is not taken from the environment either" ok \
  || check "the library's own variable is not taken from the environment either" "exit $RC, said [$(cat "$T/err")], judged [$(judged)]"

# A long command with a second reading is refused unread, at once.
long="$(python3 -c 'import sys; sys.stdout.write("x" * 17000)')"
run_hook "cat <<EOF; echo done${NL}${long}${NL}EOF"
case "$RC:$ERR" in
  2:BLOCKED*"longer than the 16384"*) check "a command longer than the library reads twice within a hook's time limit, that has a second reading, is refused saying so" ok ;;
  *) check "a command longer than the library reads twice within a hook's time limit, that has a second reading, is refused saying so" "exit $RC, said [${ERR:0:200}]" ;;
esac
[ "$(starts)" = 1 ] && [ -z "$(judged)" ] && check "and it starts no run to say so" ok || check "and it starts no run to say so" "starts $(starts), judged [$(judged)]"
run_hook "cat <<EOF${NL}${long}${NL}EOF${NL}echo done"
[ "$RC" = 0 ] && [ "$(judged)" = alone ] && check "the same length with nothing after the opener is judged once, as it always was" ok \
  || check "the same length with nothing after the opener is judged once, as it always was" "exit $RC, judged [$(judged)]"
short="$(python3 -c 'import sys; sys.stdout.write("x" * 12000)')"
run_hook "cat <<EOF; $PUSH${NL}${short}${NL}EOF"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "under that length the hidden push is read and refused" ok \
  || check "under that length the hidden push is read and refused" "exit $RC, said [${ERR:0:200}]"

# Where the second reading cannot be made, the hook is what it always was, and says so where it must.
mkdir -p "$T/no-python"
for t in bash cat grep cut tr sed mktemp rm jq dirname basename; do
  p="$(command -v "$t" 2>/dev/null)" && [ -n "$p" ] && ln -s "$p" "$T/no-python/$t"
done
if [ -x "$T/no-python/jq" ]; then
  : > "$T/log"
  payload_for "cat <<EOF; echo hidden${NL}body${NL}EOF" | PATH="$T/no-python" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
  [ "$RC" = 0 ] && [ "$(judged)" = alone ] && check "with no python3 there is no second reading, and the hook judges the first as it always did" ok \
    || check "with no python3 there is no second reading, and the hook judges the first as it always did" "exit $RC, judged [$(judged)], said [$(cat "$T/err")]"
else
  echo "UNMEASURED: jq is not on PATH, so the hook with no python3 has no reader left to run with"
fi
: > "$T/log"
payload_for "$HIDDEN" | TMPDIR="$T/absent/" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
ERR="$(cat "$T/err")"
case "$RC:$ERR" in
  2:BLOCKED*"no working folder could be made"*) check "with nowhere to keep the two answers the command is refused saying so, never passed on the first reading alone" ok ;;
  *) check "with nowhere to keep the two answers the command is refused saying so, never passed on the first reading alone" "exit $RC, said [$ERR]" ;;
esac
leftover="$(find "$T" -maxdepth 1 -name 'ps-readings.*' | wc -l | tr -d ' ')"
: > "$T/log"
payload_for "$HIDDEN" | TMPDIR="$T/" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
after="$(find "$T" -maxdepth 1 -name 'ps-readings.*' | wc -l | tr -d ' ')"
[ "$RC" = 2 ] && [ "$after" = "$leftover" ] && check "the working folder of the two runs is gone when the hook ends" ok \
  || check "the working folder of the two runs is gone when the hook ends" "exit $RC, $after left where $leftover were"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
