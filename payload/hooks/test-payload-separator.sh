#!/usr/bin/env bash
#
# test-payload-separator.sh: a command holding the unit separator byte is judged whole by every gate
# that reads it through ps_parse_payload (claude-config#2055).
#
# THE FAULT. ps_parse_payload prints the command, a unit separator (0x1f), then the working folder,
# and about 35 gates take the command as everything before the FIRST separator. A command that held
# a 0x1f of its own was cut at that byte, so whatever followed it was never judged by any of them.
# Measured before the fix: every gate below refused its gated command and passed the same command
# placed after a harmless word holding the byte.
#
# THE FIX lives in the reader, never at the call sites: the reader writes each 0x1f inside the
# command as U+FFFD, the character this library already uses for what it cannot carry (#1900,
# #1944). U+FFFD is no word separator to the shell or to the shell reader, and no shell syntax, so
# the command keeps the words and the shape the shell itself gives it, and the first separator in
# the output is always the one that ends the command. A folder holding the byte is carried whole.
#
# So this suite proves two things: the reader's contract, under jq alone and under python3 alone,
# and the verdict, through each family of gate that reads the command this way (push, merge, the
# Monitor merge, branch delete, wrapped commands, rtk, gh watchers), each with an ordinary gated
# command as its control and an ordinary harmless command holding the byte that must still pass.
# The issue field gate reads its payload with its own python3 and only asks the reader whether the
# payload parses, so it is here as the family that was never cut, to keep it so.
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

# shellcheck source=lib/push-scope.sh
. "$DIR/lib/push-scope.sh" || { echo "FAIL: cannot source lib/push-scope.sh"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

US=$'\x1f'
FFFD=$'\xef\xbf\xbd'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/payload-sep.XXXXXXXX")"
case "${WORK%/}" in ''|/|"${HOME%/}") echo "refusing: throwaway came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT

payload_for() { # payload_for <tool> <command> <cwd>: the JSON Claude Code sends, the byte escaped as \u001f
  python3 -c '
import json, sys
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}, "cwd": sys.argv[3], "session_id": "payload-separator-suite"}))' \
    "$1" "$2" "$3"
}
seps() { local s="${1//[!$US]/}"; printf '%s' "${#s}"; }

# ---------------------------------------------------------------------------
# The reader's contract, under each reader alone: a machine holding only jq and one holding only
# python3 both read payloads, so neither half may carry the fault (ps_reader_missing jq python3).
# ---------------------------------------------------------------------------
mkdir -p "$WORK/jq-only" "$WORK/py-only"
ln -s "$(command -v jq)" "$WORK/jq-only/jq"
ln -s "$(command -v python3)" "$WORK/py-only/python3"
reader_cases() { # reader_cases <label> <PATH>
  local label="$1" p="$2" out mode
  for mode in raw segmented; do
    out="$(PATH="$p" ps_parse_payload "$(payload_for Bash "echo a${US}b; gh pr merge 5" /tmp/folder)" "$mode")"
    [ "$(seps "$out")" = 1 ] \
      && check "#2055 ($label, $mode) a command holding the byte comes out with exactly one separator" ok \
      || check "#2055 ($label, $mode) a command holding the byte comes out with exactly one separator" "$(seps "$out") separators in [$out]"
    [ "${out%%"$US"*}" = "echo a${FFFD}b; gh pr merge 5" ] \
      && check "#2055 ($label, $mode) the command before the first separator is the whole command, the byte as U+FFFD" ok \
      || check "#2055 ($label, $mode) the command before the first separator is the whole command, the byte as U+FFFD" "got [${out%%"$US"*}]"
    [ "${out#*"$US"}" = "/tmp/folder" ] \
      && check "#2055 ($label, $mode) the folder after it is untouched" ok \
      || check "#2055 ($label, $mode) the folder after it is untouched" "got [${out#*"$US"}]"
    out="$(PATH="$p" ps_parse_payload "$(payload_for Bash "gh pr merge 5" "/tmp/odd${US}folder")" "$mode")"
    [ "${out%%"$US"*}" = "gh pr merge 5" ] && [ "${out#*"$US"}" = "/tmp/odd${US}folder" ] \
      && check "#2055 ($label, $mode) a folder holding the byte is carried whole after the first separator" ok \
      || check "#2055 ($label, $mode) a folder holding the byte is carried whole after the first separator" "got [$out]"
  done
  out="$(PATH="$p" ps_parse_payload "$(payload_for Bash "$(printf 'echo one\necho two')" /tmp/folder)" raw)"
  [ "$out" = "$(printf 'echo one\necho two')${US}/tmp/folder" ] \
    && check "#2055 ($label) an ordinary command is read exactly as before" ok \
    || check "#2055 ($label) an ordinary command is read exactly as before" "got [$out]"
}
reader_cases "default PATH" "$PATH"
reader_cases "jq alone" "$WORK/jq-only"
reader_cases "python3 alone" "$WORK/py-only"
# python3 under a locale that cannot write U+FFFD wrote a question mark in its place, which is a
# glob character to the shell reading the command, not the stand in for the byte.
ascii_out="$(LC_ALL=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 PATH="$WORK/py-only" ps_parse_payload "$(payload_for Bash "echo a${US}b" /tmp/folder)" raw)"
[ "${ascii_out%%"$US"*}" = "echo a${FFFD}b" ] \
  && check "#2055 (python3 alone, C locale) the byte is written as U+FFFD, never a question mark" ok \
  || check "#2055 (python3 alone, C locale) the byte is written as U+FFFD, never a question mark" "got [${ascii_out%%"$US"*}]"

# ---------------------------------------------------------------------------
# The verdict, through the real gates. Each runs from a folder of its own under a throwaway HOME, so
# nothing here reads or writes the state of the Mac running it.
# ---------------------------------------------------------------------------
GHOME="$WORK/home"; mkdir -p "$GHOME"
PLAIN="$WORK/plain"; mkdir -p "$PLAIN"
# verdict <gate> <tool> <command> <cwd>: prints "refused" or "passed", from the exit code and any
# deny decision the gate printed.
verdict() {
  local out rc
  out="$(payload_for "$2" "$3" "$4" | (cd "$4" && HOME="$GHOME" PUSH_GATE_LEDGER_DIR="$WORK/ledger" bash "$DIR/$1" 2>/dev/null))"; rc=$?
  if [ "$rc" -eq 2 ]; then printf refused; return; fi
  case "$out" in *'"permissionDecision"'*'"deny"'*|*'"decision"'*'"block"'*) printf refused ;; *) printf passed ;; esac
}
# family <name> <gate> <tool> <gated command> <cwd>
family() {
  local name="$1" gate="$2" tool="$3" cmd="$4" cwd="$5" got
  got="$(verdict "$gate" "$tool" "$cmd" "$cwd")"
  [ "$got" = refused ] \
    && check "#2055 $name ($gate): control, the gated command is refused" ok \
    || check "#2055 $name ($gate): control, the gated command is refused" "$got"
  got="$(verdict "$gate" "$tool" "echo a${US}b; $cmd" "$cwd")"
  [ "$got" = refused ] \
    && check "#2055 $name ($gate): the same command after a word holding the byte is judged whole and refused" ok \
    || check "#2055 $name ($gate): the same command after a word holding the byte is judged whole and refused" "$got"
  got="$(verdict "$gate" "$tool" "echo a${US}b" "$cwd")"
  [ "$got" = passed ] \
    && check "#2055 $name ($gate): an ordinary command holding the byte still passes" ok \
    || check "#2055 $name ($gate): an ordinary command holding the byte still passes" "$got"
}

family "merge" pr-review-gate.sh Bash "gh pr merge 5 --squash" "$PLAIN"
family "merge" block-red-merge.sh Bash "gh pr merge 5 --squash" "$PLAIN"
family "merge" check-closing-merge.sh Bash "gh pr merge 5 --squash" "$PLAIN"
family "Monitor merge" monitor-action-gate.sh Monitor "gh pr merge 7 --squash" "$PLAIN"
family "branch delete" stacked-branch-delete-gate.sh Bash "git push origin --delete somebranch" "$PLAIN"
family "wrapped commands" check-wrapped-commands.sh Bash 'bash -c "$CMD git"' "$PLAIN"
family "rtk" check-rtk-init.sh Bash "rtk init -g" "$PLAIN"
family "gh watchers" check-gh-watch-interval.sh Bash "gh pr checks 5 --watch" "$PLAIN"
family "issue fields" require-issue-fields.sh Bash "gh issue create --title x --body y" "$PLAIN"

# The push family, against a real repository holding an untested change, as test-push-scope.sh's
# end to end check builds it: a push refused there for carrying no test.
REPO="$WORK/repo"
(
  mkdir -p "$REPO/src" && cd "$REPO" || exit 1
  git init -q .
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf 'print("one")\n' > src/thing.py
  git add src/thing.py
  git -c user.email=t@t -c user.name=t commit -q -m seed
  git init -q --bare "$WORK/remote.git"
  git remote add origin "$WORK/remote.git"
  git push -q -u origin HEAD
  printf 'print("two")\n' >> src/thing.py
) >/dev/null 2>&1
family "push" require-tests-before-push.sh Bash "git add src/thing.py && git commit -q -m x && git push origin HEAD" "$REPO"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
