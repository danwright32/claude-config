#!/usr/bin/env bash
# A command the segmented form hides is judged by a second run of the hook, and the two readings
# never change each other (lib/push-scope.sh ps_both_readings, claude-config#3739).
#
# Two things are held here:
#   1. THE SCAN. Every hook that reads the segmented form calls ps_both_readings once, at its top
#      level, before its first such read, and hands it the time limit its registration gives it.
#      A hook that reads the form without it judges the first reading alone, and what the form
#      hides goes unjudged with nothing said. Nor can a hook leave above that call on a test of
#      the raw payload, unless a payload holding a backslash and line break is excepted from it.
#   2. THE HELPER, against a stand in hook whose answer is a function of the text it is handed:
#      the first reading is judged first, alone and as it always was; the second is judged only
#      once the first has passed, in what the first left of the hook's time limit, and can only
#      refuse; who says which reading a run is.
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
    /^ps_both_readings "\$payload" [0-9]+( after)?[[:space:]]*$/ { calls++; if (!read_at) before = 1; next }
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
# A hook that can leave between reading the payload and its ps_both_readings line leaves on a test
# of the raw payload, where a word written across a backslash and line break is in two pieces:
# the command is never handed to the helper, and what it hides goes unjudged with nothing said.
# So the first line there that can exit has to stand below the arm that excepts a payload holding
# the pair, by each of the three ways JSON spells it. early_exit_fault <file>: prints why the file
# breaks that, or nothing. The body of a function defined there is not looked in: it is what a
# hook does once a library will not load, and then there is no reader to hand anything to.
# The arm as a hook writes it is  *'\\\n'*|*'\\\u000'[aA]*|*'\u005'[cC]*)  and each backslash of
# it is doubled here, inside double quotes.
PAIR_ARM="*'\\\\\\n'*|*'\\\\\\u000'[aA]*|*'\\u005'[cC]*)"
early_exit_fault() {
  ARM="$PAIR_ARM" awk '
    /^[[:space:]]*#/ { next }
    called { next }
    /^ps_both_readings "\$payload" [0-9]+( after)?[[:space:]]*$/ { called = 1; next }
    /^payload="\$\((cat|ps_read_payload)\)"[[:space:]]*$/ { if (!read_at) read_at = NR; next }
    !read_at { next }
    /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { if ($0 !~ /\}[[:space:]]*(#.*)?$/) in_fn = 1; next }
    in_fn { if ($0 ~ /^\}/) in_fn = 0; next }
    index($0, ENVIRON["ARM"]) && !exit_at { excepted = NR }
    /(^|[^A-Za-z0-9_])exit([^A-Za-z0-9_]|$)/ && !exit_at { exit_at = NR }
    END {
      if (!called) exit 0
      if (!read_at) { printf "no line above its ps_both_readings call reads the payload at its top level, so an exit above the call cannot be placed"; exit 0 }
      if (exit_at && !excepted) printf "line %d can exit before ps_both_readings is reached, and no line between the payload being read and that one excepts a payload that holds a backslash and line break, by each way JSON spells the pair", exit_at
    }' "$1"
}

# The scan is seen to fail on each way of getting it wrong, and to pass the right form.
mkdir -p "$T/scan"
printf '%s\n' 'payload="$(cat)"' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/none.sh"
printf '%s\n' 'payload="$(cat)"' 'parsed="$(ps_parse_payload "$payload")"' > "$T/scan/default-mode.sh"
printf '%s\n' 'payload="$(cat)"' 'parsed="$(ps_parse_payload "$payload" segmented)"' 'ps_both_readings "$payload" 30' > "$T/scan/after.sh"
printf '%s\n' 'payload="$(cat)"' 'if true; then' '  ps_both_readings "$payload" 30' 'fi' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/nested.sh"
printf '%s\n' 'payload="$(cat)"' 'ps_both_readings "$payload" 30' 'ps_both_readings "$payload" 30' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/twice.sh"
printf '%s\n' 'payload="$(cat)"' '# ps_both_readings "$payload" 30' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/commented.sh"
printf '%s\n' 'payload="$(cat)"' 'ps_both_readings "$payload"' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/no-limit.sh"
printf '%s\n' 'payload="$(cat)"' 'ps_both_readings "$payload" "$LIMIT"' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/limit-not-written.sh"
printf '%s\n' 'payload="$(cat)"' 'ps_both_readings "$payload" 30' 'parsed="$(ps_parse_payload "$payload" segmented)"' > "$T/scan/right.sh"
printf '%s\n' 'payload="$(cat)"' 'parsed="$(ps_parse_payload "$payload" raw)"' 'declare -F ps_parse_payload >/dev/null' > "$T/scan/raw.sh"
for f in none default-mode after nested twice commented no-limit limit-not-written; do
  why="$(scan_file "$T/scan/$f.sh")"
  [ -n "$why" ] && check "the scan fails a hook that gets it wrong ($f)" ok || check "the scan fails a hook that gets it wrong ($f)" "it passed"
done
for f in right raw; do
  why="$(scan_file "$T/scan/$f.sh")"
  [ -z "$why" ] && check "the scan passes a hook that has it right ($f)" ok || check "the scan passes a hook that has it right ($f)" "$why"
done
EARLY_TAIL='ps_both_readings "$payload" 30'
printf '%s\n' 'payload="$(cat)"' 'case "$payload" in *push*) ;; *) exit 0 ;; esac' "$EARLY_TAIL" > "$T/scan/early.sh"
printf '%s\n' 'payload="$(cat)"' 'case "$payload" in' '  *delete*) ;;' '  *) looks "$payload" || exit 0 ;;' 'esac' "$EARLY_TAIL" > "$T/scan/early-in-a-block.sh"
printf '%s\n' 'payload="$(ps_read_payload)"' '[ -n "$payload" ] || exit 0' 'case "$payload" in' "  $PAIR_ARM ;;" '  *) named || exit 0 ;;' 'esac' "$EARLY_TAIL" > "$T/scan/arm-below-an-exit.sh"
printf '%s\n' 'payload="$(cat)"' 'case "$payload" in' "  *'\\\\\\n'*) ;;" '  *) named || exit 0 ;;' 'esac' "$EARLY_TAIL" > "$T/scan/arm-of-one-spelling.sh"
printf '%s\n' 'payload="$(cat)"' 'leave() { [ -n "${x}" ] || true; }  # a note' 'exit 0' "$EARLY_TAIL" > "$T/scan/early-after-a-function.sh"
printf '%s\n' 'input="$(cat)"' 'payload="$input"' 'case "$payload" in *push*) ;; *) exit 0 ;; esac' "$EARLY_TAIL" > "$T/scan/read-not-found.sh"
printf '%s\n' 'payload="$(cat)"' 'case "$payload" in' "  $PAIR_ARM ;;" '  *) named || exit 0 ;;' 'esac' "$EARLY_TAIL" > "$T/scan/early-excepted.sh"
printf '%s\n' 'payload="$(cat)"' 'leave() {' '  exit 0' '}' 'refuse() { echo no >&2; exit 2; }' '. lib || leave' "$EARLY_TAIL" > "$T/scan/exit-in-a-function.sh"
printf '%s\n' '. lib || {' '  payload="$(cat)"' '  exit 2' '}' 'payload="$(ps_read_payload)"' '# never exit 0 here' "$EARLY_TAIL" '[ -n "$payload" ] || exit 0' > "$T/scan/exits-elsewhere.sh"
for f in early early-in-a-block arm-below-an-exit arm-of-one-spelling early-after-a-function read-not-found; do
  why="$(early_exit_fault "$T/scan/$f.sh")"
  [ -n "$why" ] && check "the scan fails a hook that can leave before the helper on a payload holding the pair ($f)" ok \
    || check "the scan fails a hook that can leave before the helper on a payload holding the pair ($f)" "it passed"
done
for f in early-excepted exit-in-a-function exits-elsewhere right; do
  why="$(early_exit_fault "$T/scan/$f.sh")"
  [ -z "$why" ] && check "the scan passes a hook that cannot leave before the helper on a payload holding the pair ($f)" ok \
    || check "the scan passes a hook that cannot leave before the helper on a payload holding the pair ($f)" "$why"
done

# The limit a hook hands over is the one its registration gives it, so the second run is given
# what is left of the time Claude Code really allows. limit_fault <hook file> <settings file>
# prints why it is not, or nothing. A hook whose registration sets no limit runs under Claude
# Code's own, and says UNSET_LIMIT, which is that limit as recalled from Claude Code's
# documentation and is measured nowhere here. A hook registered to run
# after the command, and only such a hook, says after: told that, the helper never says the
# command was refused or asks for it again, and told it wrongly a gate would stop refusing.
UNSET_LIMIT=60
limit_fault() {
  local said declared events says_after=no name="${1##*/}"
  said="$(sed -n 's/^ps_both_readings "\$payload" \([0-9][0-9]*\)\( after\)\{0,1\}[[:space:]]*$/\1/p' "$1")"
  grep -q '^ps_both_readings "\$payload" [0-9][0-9]* after[[:space:]]*$' "$1" && says_after=yes
  declared="$(jq -r --arg n "/$name" '[.hooks[][].hooks[]? | select((.command // "") | endswith($n)) | (.timeout // "none") | tostring] | unique | join(" ")' "$2" 2>/dev/null)" \
    || { printf 'the registration in %s could not be read' "$2"; return 0; }
  events="$(jq -r --arg n "/$name" '[.hooks | to_entries[] | .key as $e | .value[].hooks[]? | select((.command // "") | endswith($n)) | $e] | unique | join(" ")' "$2" 2>/dev/null)"
  case "$declared" in
    '') printf 'no registration names it, so there is no limit to hold the %s it says against' "${said:-nothing}"; return 0 ;;
    *' '*) printf 'it is registered with more than one limit (%s)' "$declared"; return 0 ;;
    none) [ "$said" = "$UNSET_LIMIT" ] || { printf 'its registration sets no limit, so it must say %s, and it says %s' "$UNSET_LIMIT" "${said:-nothing}"; return 0; } ;;
    *) [ "$said" = "$declared" ] || { printf 'its registration gives it %s seconds and it says %s' "$declared" "${said:-nothing}"; return 0; } ;;
  esac
  case "$events:$says_after" in
    PreToolUse:no|PostToolUse:yes) ;;
    PreToolUse:yes) printf 'it is registered to run before the command and says after, so it would never refuse where the second reading is not judged' ;;
    PostToolUse:no) printf 'it is registered to run after the command and does not say after, so it would say the command was refused and ask for it again' ;;
    *) printf 'it is registered under [%s], and only PreToolUse alone or PostToolUse alone is known here' "$events" ;;
  esac
  return 0
}
have_jq=no; command -v jq >/dev/null 2>&1 && have_jq=yes
if [ "$have_jq" = yes ]; then
  cat > "$T/scan/settings.json" <<'JSON'
{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
  {"type": "command", "command": "__CLAUDE_HOME__/hooks/right.sh", "timeout": 30},
  {"type": "command", "command": "__CLAUDE_HOME__/hooks/unset.sh"},
  {"type": "command", "command": "__CLAUDE_HOME__/hooks/unset-wrong.sh"},
  {"type": "command", "command": "__CLAUDE_HOME__/hooks/other.sh", "timeout": 45},
  {"type": "command", "command": "__CLAUDE_HOME__/hooks/before-says-after.sh", "timeout": 30},
  {"type": "command", "command": "__CLAUDE_HOME__/hooks/two.sh", "timeout": 30}]}],
 "PostToolUse": [{"matcher": "Bash", "hooks": [
  {"type": "command", "command": "__CLAUDE_HOME__/hooks/after-right.sh", "timeout": 15},
  {"type": "command", "command": "__CLAUDE_HOME__/hooks/after-unsaid.sh", "timeout": 30},
  {"type": "command", "command": "__CLAUDE_HOME__/hooks/two.sh", "timeout": 15}]}]}}
JSON
  printf '%s\n' 'ps_both_readings "$payload" 60' > "$T/scan/unset.sh"
  printf '%s\n' 'ps_both_readings "$payload" 15 after' > "$T/scan/after-right.sh"
  printf '%s\n' 'ps_both_readings "$payload" 30 after' > "$T/scan/before-says-after.sh"
  for f in unset-wrong other two stranger after-unsaid; do cp "$T/scan/right.sh" "$T/scan/$f.sh"; done
  for f in right unset after-right; do
    why="$(limit_fault "$T/scan/$f.sh" "$T/scan/settings.json")"
    [ -z "$why" ] && check "the limit check passes a hook that says its registered limit, and after where it runs after the command ($f)" ok \
      || check "the limit check passes a hook that says its registered limit, and after where it runs after the command ($f)" "$why"
  done
  for f in unset-wrong other two stranger no-limit after-unsaid before-says-after; do
    why="$(limit_fault "$T/scan/$f.sh" "$T/scan/settings.json")"
    [ -n "$why" ] && check "the limit check fails a hook that says another limit than its registered one, or after where it does not belong ($f)" ok \
      || check "the limit check fails a hook that says another limit than its registered one, or after where it does not belong ($f)" "it passed"
  done
fi
REG=""
# shellcheck source=/dev/null
. "$DIR/lib/settings-file.sh" 2>/dev/null && REG="$(hook_settings_file "$DIR/..")"

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
  why="$(early_exit_fault "$f")"
  [ -z "$why" ] && check "${f##*/} cannot leave before the helper on a payload holding a backslash and line break" ok \
    || check "${f##*/} cannot leave before the helper on a payload holding a backslash and line break" "$why"
  if [ "$have_jq" = yes ] && [ -n "$REG" ]; then
    why="$(limit_fault "$f" "$REG")"
    [ -z "$why" ] && check "${f##*/} gives the second reading what is left of its registered time limit" ok \
      || check "${f##*/} gives the second reading what is left of its registered time limit" "$why"
  fi
done
if [ "$have_jq" != yes ]; then
  echo "SUITE-PART-UNMEASURED each hook's limit against its registration: jq is not on PATH to read the registration with"
elif [ -z "$REG" ]; then
  echo "SUITE-PART-UNMEASURED each hook's limit against its registration: no settings.hooks.json or settings.json in $DIR/.. to read"
fi
# A scan that found no reader would pass every file by finding none (L100).
[ "$seen_style" = yes ] && [ "$readers" -ge 2 ] && check "the scan found the hooks that read the segmented form, check-style-guide.sh among them" ok \
  || check "the scan found the hooks that read the segmented form, check-style-guide.sh among them" "it found $readers, check-style-guide.sh among them: $seen_style"

# ---------------------------------------------------------------------------
# 2. The helper, against a stand in hook
# ---------------------------------------------------------------------------
echo "both readings: the helper"
command -v python3 >/dev/null 2>&1 || { check "python3 is here to make the payloads and the second reading" "python3 is not on PATH"; }

# The stand in refuses a text that runs a push, says a note for one that runs `git status`, says
# an object through the notice library for one that runs `git describe`, says a line that only
# opens like an object for one that runs `git blame`, exits 3 for one that runs `git gc`, and for
# one that runs `git fsck` sleeps in short steps, far longer than any row gives it, and then passes.
# Every run writes which reading it was told it is and what it read. Its time limit is BR_LIMIT
# where a row names one, and the time it has used is read from the file BR_CLOCK names where a
# row names one, so no row waits out a real limit. BR_LIB is the library it reads, BR_AFTER the
# word a hook that runs after the command hands over, and BR_NOTICE has it load the notice library.
HOOK="$T/stand-in.sh"
cat > "$HOOK" <<HOOKEND
#!/bin/bash
. "\${BR_LIB:-$DIR/lib}/push-scope.sh" || exit 9
[ -z "\${BR_CLOCK-}" ] || ps__elapsed() { cat "\$BR_CLOCK"; }
[ -z "\${BR_NOTICE-}" ] || . "$DIR/lib/hook-notice.sh" || exit 9
payload="\$(ps_read_payload)"
echo "start" >> "\$BR_LOG"
ps_both_readings "\$payload" "\${BR_LIMIT-600}" \${BR_AFTER-}
parsed="\$(ps_parse_payload "\$payload" segmented)" || { echo "the stand in could not parse its payload" >&2; exit 2; }
cmd="\${parsed%%\$'\\x1f'*}"
printf 'judged|%s|%s|%s\\n' "\${PS__READING:-alone}" "\${PS_READING-unset}" "\$cmd" >> "\$BR_LOG"
if ps__runs_git_sub "\$cmd" gc; then echo "crashed on the \${PS__READING:-alone} reading" >&2; exit 3; fi
if ps__runs_git_sub "\$cmd" status; then echo "a note from the \${PS__READING:-alone} reading"; fi
if ps__runs_git_sub "\$cmd" describe; then hook_notice_json "an object from the \${PS__READING:-alone} reading" PostToolUse; fi
if ps__runs_git_sub "\$cmd" blame; then echo "{an opening brace from the \${PS__READING:-alone} reading"; fi
if ps_is_git_push "\$cmd"; then echo "refused on the \${PS__READING:-alone} reading" >&2; exit 2; fi
if ps__runs_git_sub "\$cmd" fsck; then
  i=0; while [ "\$i" -lt 80 ]; do sleep 0.25; i=\$((i + 1)); done
  printf 'finished|%s\\n' "\${PS__READING:-alone}" >> "\$BR_LOG"
fi
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
left="$(grep '^judged|' "$T/log" | cut -d'|' -f3 | sort -u | tr '\n' ' ')"
[ "$left" = "unset " ] && check "neither run leaves PS_READING in the environment of what it starts" ok \
  || check "neither run leaves PS_READING in the environment of what it starts" "what each run found there: [$left]"

run_hook "bash -c 'git ${PAIR}push'"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "a push across the pair in a wrapper's string is refused, by the second reading" ok \
  || check "a push across the pair in a wrapper's string is refused, by the second reading" "exit $RC, said [$ERR]"

# A reading only the crude cut reads is a reading all the same. A quoted word that runs over the
# lines after an opener leaves the first reading one the crude cut alone reads, and an open
# parenthesis after a later opener leaves the second so; the push each hides is judged.
QUOTED_OVER="cat <<EOF; echo 'a${NL}b${NL}EOF${NL}'"
run_hook "$QUOTED_OVER; bash -c 'git ${PAIR}push origin feat'"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "a push across the pair in a wrapper's string, after a quoted word that runs over an opener's body, is refused by the second reading" ok \
  || check "a push across the pair in a wrapper's string, after a quoted word that runs over an opener's body, is refused by the second reading" "exit $RC, said [$ERR], judged [$(judged)]"
run_hook "$QUOTED_OVER; echo \`git ${PAIR}push origin feat\`"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "and so is one inside backquotes there" ok \
  || check "and so is one inside backquotes there" "exit $RC, said [$ERR], judged [$(judged)]"
run_hook "cat <<EOF; echo \"a${NL}b${NL}EOF${NL}\"; bash -c 'git ${PAIR}push origin feat'"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "and one after a double quoted word that runs over the body" ok \
  || check "and one after a double quoted word that runs over the body" "exit $RC, said [$ERR], judged [$(judged)]"
run_hook "cat <<EOF; $PUSH origin feat${NL}body${NL}EOF${NL}cat <<B; (${NL}B"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "a push after an opener, in a command whose last lines leave a parenthesis open, is refused by the second reading" ok \
  || check "a push after an opener, in a command whose last lines leave a parenthesis open, is refused by the second reading" "exit $RC, said [$ERR], judged [$(judged)]"

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
  2:BLOCKED*"longer than the 16384 set as the most"*"or outside the quoted string"*) check "a command longer than the limit set for a second reading, that has one, is refused, saying the limit is a set one and where to write the hidden command" ok ;;
  *) check "a command longer than the limit set for a second reading, that has one, is refused, saying the limit is a set one and where to write the hidden command" "exit $RC, said [${ERR:0:600}]" ;;
esac
[ "$(starts)" = 1 ] && [ -z "$(judged)" ] && check "and it starts no run to say so" ok || check "and it starts no run to say so" "starts $(starts), judged [$(judged)]"
run_hook "cat <<EOF${NL}${long}${NL}EOF${NL}echo done"
[ "$RC" = 0 ] && [ "$(judged)" = alone ] && check "the same length with nothing after the opener is judged once, as it always was" ok \
  || check "the same length with nothing after the opener is judged once, as it always was" "exit $RC, judged [$(judged)]"
short="$(python3 -c 'import sys; sys.stdout.write("x" * 12000)')"
run_hook "cat <<EOF; $PUSH${NL}${short}${NL}EOF"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "under that length the hidden push is read and refused" ok \
  || check "under that length the hidden push is read and refused" "exit $RC, said [${ERR:0:200}]"

# The second run is given what the first left of the hook's time limit, and no more.
run_timed() { # run_timed <seconds used, by the stand in's clock> <limit> <command text>
  : > "$T/log"
  printf '%s' "$1" > "$T/clock"
  payload_for "$3" | BR_CLOCK="$T/clock" BR_LIMIT="$2" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
SLOW="cat <<EOF; git fsck${NL}body${NL}EOF"
run_timed 500 600 "$HIDDEN"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && check "with time left of the hook's limit the second reading is judged, and its refusal is the answer" ok \
  || check "with time left of the hook's limit the second reading is judged, and its refusal is the answer" "exit $RC, said [${ERR:0:300}]"
run_timed 599 600 "$HIDDEN"
case "$RC:$ERR" in
  2:BLOCKED*"leaves too little"*"line of its own"*) check "when the first run leaves too little of the hook's time limit the command is refused, saying so and how to write it" ok ;;
  *) check "when the first run leaves too little of the hook's time limit the command is refused, saying so and how to write it" "exit $RC, said [${ERR:0:300}]" ;;
esac
[ "$(judged)" = first ] && check "and there the second run is never started" ok || check "and there the second run is never started" "judged [$(judged)]"
run_timed 700 600 "$HIDDEN"
case "$RC:$ERR" in
  2:BLOCKED*"leaves too little"*) check "a first run that says it used more than the limit is refused the same way" ok ;;
  *) check "a first run that says it used more than the limit is refused the same way" "exit $RC, said [${ERR:0:300}]" ;;
esac
run_timed 595 600 "$SLOW"
case "$RC:$ERR" in
  2:BLOCKED*"did not finish in the 2 seconds left"*"line of its own"*) check "a second run that does not finish in what is left is stopped, and the command refused saying so and how to write it" ok ;;
  *) check "a second run that does not finish in what is left is stopped, and the command refused saying so and how to write it" "exit $RC, said [${ERR:0:300}]" ;;
esac
[ "$(judged)" = "first second" ] && ! grep -q '^finished|' "$T/log" && check "there the second run was started and did not reach its end" ok \
  || check "there the second run was started and did not reach its end" "judged [$(judged)], finished [$(grep -c '^finished|' "$T/log")]"
[ "$ERR" = "${ERR#*Terminated}" ] && [ "$ERR" = "${ERR#*Killed}" ] && check "and the refusal is all that is said, with no line from the shell about the run it stopped" ok \
  || check "and the refusal is all that is said, with no line from the shell about the run it stopped" "said [${ERR:0:300}]"
run_timed "soon" 600 "$HIDDEN"
case "$RC:$ERR" in
  2:BLOCKED*"could not tell how long"*) check "a clock that answers with no number is a refusal, never time to spare" ok ;;
  *) check "a clock that answers with no number is a refusal, never time to spare" "exit $RC, said [${ERR:0:300}]" ;;
esac
for lim in "" soon 0; do
  run_timed 0 "$lim" "$HIDDEN"
  case "$RC:$ERR:$(judged)" in
    2:BLOCKED*"did not say how long"*:) check "a hook that hands over no time limit judges nothing of a command with two readings, and says so (limit '$lim')" ok ;;
    *) check "a hook that hands over no time limit judges nothing of a command with two readings, and says so (limit '$lim')" "exit $RC, said [${ERR:0:300}], judged [$(judged)]" ;;
  esac
done
run_timed 0 "" "$PUSH"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the alone reading" ] && check "with no limit handed over, a command with one reading is still judged as it always was" ok \
  || check "with no limit handed over, a command with one reading is still judged as it always was" "exit $RC, said [${ERR:0:300}]"

# A reader that fails is not a reader saying there is no second reading.
mkdir -p "$T/lib-fails"
cp -R "$DIR/lib/." "$T/lib-fails/"
cat > "$T/lib-fails/shell-words.py" <<PYEND
import os, sys
if sys.argv[1:2] == ["second"]:
    sys.exit(1)
os.execv(sys.executable, [sys.executable, "$DIR/lib/shell-words.py"] + sys.argv[1:])
PYEND
: > "$T/log"
payload_for "$HIDDEN" | BR_LIB="$T/lib-fails" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
ERR="$(cat "$T/err")"
case "$RC:$ERR:$(judged)" in
  2:BLOCKED*"failed with exit 1"*:) check "a reader that fails to say whether a command hides another is a refusal saying so, with nothing judged on the first reading alone" ok ;;
  *) check "a reader that fails to say whether a command hides another is a refusal saying so, with nothing judged on the first reading alone" "exit $RC, said [${ERR:0:300}], judged [$(judged)]" ;;
esac
: > "$T/log"
payload_for "$PUSH" | BR_LIB="$T/lib-fails" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
[ "$RC" = 2 ] && [ "$(cat "$T/err")" = "refused on the alone reading" ] && check "with that reader, a command that asks it nothing is judged as it always was" ok \
  || check "with that reader, a command that asks it nothing is judged as it always was" "exit $RC, said [$(cat "$T/err")]"

# A line with more commands after its heredoc openers than the reader rewrites is not judged as
# far as the reader got, which would pass whatever stands after that: it is refused, saying so.
openers_then_push() { # openers_then_push <how many>: that many openers on one line, a push, then their bodies
  python3 -c 'import sys
n, lt = int(sys.argv[1]), "<" * 2
sys.stdout.write("".join("cat %sE%d; " % (lt, k) for k in range(n)) + sys.argv[2] + " origin feat" + "".join("\nb\nE%d" % k for k in range(n)))' "$1" "$PUSH"
}
run_hook "$(openers_then_push 65)"
case "$RC:$ERR:$(judged)" in
  2:BLOCKED*"more than 64 commands"*"so what it hides was not judged"*"lines of their own"*:) check "a push after the 65th heredoc opener on one line is refused unread, saying the line holds more than the reader rewrites and how to write it" ok ;;
  *) check "a push after the 65th heredoc opener on one line is refused unread, saying the line holds more than the reader rewrites and how to write it" "exit $RC, said [${ERR:0:300}], judged [$(judged)]" ;;
esac
run_hook "$(openers_then_push 64)"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && [ "$(judged)" = "first second" ] && check "a push after the 64th is still read, and refused by the second reading" ok \
  || check "a push after the 64th is still read, and refused by the second reading" "exit $RC, said [${ERR:0:300}], judged [$(judged)]"

# An opener's line whose <, ; or blank is written as a JSON escape of its code point is the same
# command to the shell, so the look that starts the reader has to see it.
ESC_LT='\u00''3c'; ESC_SEMI='\u00''3b'; ESC_BLANK='\u00''20'
run_spelled() { # run_spelled <the command as written inside the JSON string> <what the row is>
  : > "$T/log"
  printf '{"tool_name": "Bash", "tool_input": {"command": "%s"}, "cwd": "/w"}' "$1" | BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
  ERR="$(cat "$T/err")"
  [ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && [ "$(judged)" = "first second" ] && check "$2" ok \
    || check "$2" "exit $RC, said [${ERR:0:300}], judged [$(judged)]"
}
run_spelled "cat ${ESC_LT}${ESC_LT}EOF; $PUSH\\nbody\\nEOF" "a push after an opener whose < are written as escapes is refused on the second reading"
run_spelled "cat <<EOF${ESC_SEMI} $PUSH\\nbody\\nEOF" "and so is one whose ; is written as an escape"
run_spelled "cat <<EOF;${ESC_BLANK}$PUSH\\nbody\\nEOF" "and one whose blank after the ; is written as an escape"

# A hook that runs after the command has nothing left to refuse, and asking for the command again
# would run it twice. Where the second reading cannot be judged it ends on a notice and exit 0,
# with the first reading judged as it always was.
run_after() { # run_after <seconds used> <limit> <command text> [yes to load the notice library]
  : > "$T/log"
  printf '%s' "$1" > "$T/clock"
  payload_for "$3" | BR_AFTER=after BR_NOTICE="${4-}" BR_CLOCK="$T/clock" BR_LIMIT="$2" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
after_notice() { # after_notice <what the row is> <words the notice must hold>
  case "$RC:$ERR" in
    0:*NOTICE*"has already run"*"$2"*"Do not run the command again"*)
      case "$ERR" in
        *BLOCKED*|*"send "*|*"refused on"*) check "$1" "it speaks of a refusal or of sending again: [${ERR:0:400}]" ;;
        *) check "$1" ok ;;
      esac ;;
    *) check "$1" "exit $RC, said [${ERR:0:400}]" ;;
  esac
}
NOTED="git status; cat <<EOF; echo hidden${NL}body${NL}EOF"
run_after 599 600 "$NOTED"
after_notice "a hook that runs after the command, with too little time left for the second reading, ends on a notice and exit 0" "leaves too little"
[ "$(judged)" = first ] && check "there the first reading was judged as it always was, and the second not started" ok \
  || check "there the first reading was judged as it always was, and the second not started" "judged [$(judged)]"
case "$OUT" in
  NOTICE*"The hook itself said: a note from the first reading") check "and the notice carries what the first run said" ok ;;
  *) check "and the notice carries what the first run said" "said [${OUT:0:400}]" ;;
esac
run_after 595 600 "$SLOW"
after_notice "such a hook whose second run does not finish in what is left ends on a notice and exit 0" "did not finish in the 2 seconds left"
run_after 0 600 "cat <<EOF; echo done${NL}${long}${NL}EOF"
after_notice "such a hook handed a command too long to read twice ends on a notice and exit 0" "longer than the 16384"
[ "$(judged)" = first ] && check "and there the first reading is still judged" ok || check "and there the first reading is still judged" "judged [$(judged)]"
run_after 0 "" "$HIDDEN"
after_notice "such a hook that hands over no time limit ends on a notice and exit 0" "did not say how long"
: > "$T/log"
payload_for "$HIDDEN" | BR_AFTER=after BR_LIB="$T/lib-fails" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
ERR="$(cat "$T/err")"
after_notice "such a hook whose reader fails ends on a notice and exit 0" "failed with exit 1"
run_after 0 600 "$(openers_then_push 65)"
after_notice "such a hook handed a line with more openers than the reader rewrites ends on a notice and exit 0" "more than 64 commands"
[ "$(judged)" = first ] && check "and there the first reading is still judged" ok || check "and there the first reading is still judged" "judged [$(judged)]"
: > "$T/log"
payload_for "$HIDDEN" | BR_AFTER=after TMPDIR="$T/absent/" BR_LOG="$T/log" bash "$HOOK" > "$T/out" 2> "$T/err"; RC=$?
OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
after_notice "such a hook with nowhere to keep the two answers says so in a notice" "no working folder could be made"
case "$OUT" in
  NOTICE*"did nothing else for this command"*) check "and the notice is on standard output, where a hook that exits 0 is heard, saying the hook did nothing else" ok ;;
  *) check "and the notice is on standard output, where a hook that exits 0 is heard, saying the hook did nothing else" "standard output held [${OUT:0:300}]" ;;
esac
[ -z "$(judged)" ] && check "and there it judges nothing, so nothing it says is left unheard beside the notice" ok \
  || check "and there it judges nothing, so nothing it says is left unheard beside the notice" "judged [$(judged)]"
run_after 0 600 "$HIDDEN"
[ "$RC" = 2 ] && [ "$ERR" = "refused on the second reading" ] && [ "$(judged)" = "first second" ] \
  && check "with time for both, a hook that runs after the command judges the second reading as any hook does" ok \
  || check "with time for both, a hook that runs after the command judges the second reading as any hook does" "exit $RC, said [${ERR:0:300}], judged [$(judged)]"
run_timed 599 600 "$HIDDEN"
case "$RC:$ERR" in
  2:BLOCKED*) check "control: the same command and clock in a hook that does not say after is a refusal" ok ;;
  *) check "control: the same command and clock in a hook that does not say after is a refusal" "exit $RC, said [${ERR:0:300}]" ;;
esac
# With the notice library loaded, the notice is the one object Claude Code shows.
if . "$DIR/lib/hook-notice.sh" 2>/dev/null && declare -F hook_notice_verdict >/dev/null; then
  run_after 599 600 "$NOTED" yes
  why="$(hook_notice_verdict "$OUT" "NOTICE.*has already run.*leaves too little.*The hook itself said: a note from the first reading")"
  [ "$RC" = 0 ] && [ -z "$why" ] && check "with the notice library loaded the notice is one object where Claude Code shows it" ok \
    || check "with the notice library loaded the notice is one object where Claude Code shows it" "exit $RC, $why, said [${OUT:0:300}]"
  # A first run that said an object of its own: the notice goes into that one object, since a
  # hook that exits 0 is heard on standard output alone.
  run_after 599 600 "git describe; cat <<EOF; echo hidden${NL}body${NL}EOF" yes
  why="$(hook_notice_verdict "$OUT" "NOTICE.*has already run.*leaves too little.*The hook itself said: an object from the first reading")"
  [ "$RC" = 0 ] && [ -z "$why" ] && check "a first run that said an object of its own has the notice put into that one object" ok \
    || check "a first run that said an object of its own has the notice put into that one object" "exit $RC, $why, said [${OUT:0:300}]"
  ctx="$(printf '%s' "$OUT" | python3 -c 'import json, sys
try: print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])
except Exception as e: print("unreadable: %s" % e)' 2>&1)"
  case "$ctx" in
    NOTICE*"leaves too little"*"an object from the first reading"*) check "and the session is handed the notice with what that object handed it" ok ;;
    *) check "and the session is handed the notice with what that object handed it" "the context was [${ctx:0:300}]" ;;
  esac
  run_after 599 600 "git blame; cat <<EOF; echo hidden${NL}body${NL}EOF" yes
  why="$(hook_notice_verdict "$OUT" "NOTICE.*has already run.*leaves too little.*The hook itself said: \{an opening brace from the first reading")"
  [ "$RC" = 0 ] && [ -z "$why" ] && check "a first run whose words only open like an object are carried inside the notice, as any words are" ok \
    || check "a first run whose words only open like an object are carried inside the notice, as any words are" "exit $RC, $why, said [${OUT:0:300}]"
else
  check "lib/hook-notice.sh is here to read the notice with" "it could not be loaded, or holds no hook_notice_verdict"
fi

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
  echo "SUITE-PART-UNMEASURED the hook with no python3: jq is not on PATH, so the hook has no reader left to run with"
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
