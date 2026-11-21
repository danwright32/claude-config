#!/usr/bin/env bash
# Tests for the line the Slack drafts gate names when it refuses a script that an earlier command of
# the same call wrote (claude-config#3278). Such a script is read as everything it may now hold: each
# file the code that wrote it names, joined, then the file as it is on disk. A refusal about a line of
# that joined text named the script and the line's number in the join, which is a line of no file.
# Kept apart from test-slack-drafts-only-gate.sh and test-slack-drafts-code-loaders.sh so neither
# grows past its wall clock; the helpers below are copied from test-slack-drafts-unread-shapes.sh as
# they are, so a case here is driven the same way: a hook payload piped into
# slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr. Nothing a case names
# is ever run.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/slack-drafts-only-gate.sh"
unset SLACK_GATE_UNWORKED_PATHS

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite at $DIR, so no Slack send is refused."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
# Every case runs with a judgement cache of its own, never this Mac's (claude-config#2918).
export SLACK_GATE_CACHE_DIR="$T/gate-cache"
unset SLACK_GATE_CACHE_TRACE

# payload <tool name> <tool_input JSON> [cwd]: one PreToolUse payload in the measured shape.
payload() {
  python3 -c '
import json, sys
tool, inp, cwd = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": cwd,
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": inp, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "${3:-$T}"
}
bash_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1"; }

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:900}" ;; esac; }
lacks() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:900}" ;; *) check "$1" ok ;; esac; }

# A small repository shaped like this one where the call of 2026-11-18 was refused: a tool at its
# root that sources a library it finds beside itself (as claude-sync sources lesson-index-cap.sh, by
# a variable set from BASH_SOURCE and set again where the file is missing), a hook, and the hook's
# suite, which runs the hook.
S="$(cd "$T" && pwd -P)/src"  # by its real path, as a checkout is: on macOS the temp folder is behind a link
mkdir -p "$S/payload/hooks/lib"
printf '%s\n' '#!/bin/bash' '# Finds its library beside itself.' 'SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
  'CAP_LIB="$SELF/payload/hooks/lib/cap.sh"' '[ -f "$CAP_LIB" ] || CAP_LIB="$CLAUDE_HOME/hooks/lib/cap.sh"' \
  'if [ -f "$CAP_LIB" ]; then' '  . "$CAP_LIB"' 'fi' > "$S/tool"
printf '%s\n' 'cap() { echo 160; }' > "$S/payload/hooks/lib/cap.sh"
printf '%s\n' '#!/bin/bash' 'echo checked' > "$S/payload/hooks/hook.sh"
printf '%s\n' '#!/bin/bash' 'HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook.sh"' 'bash "$HOOK"' > "$S/payload/hooks/test-hook.sh"
# A second hook whose own third line sources a path nothing sets, its suite, and a file of notes.
printf '%s\n' '#!/bin/bash' 'echo first' '. "$NOWHERE_3278/x.sh"' > "$S/payload/hooks/hook2.sh"
printf '%s\n' '#!/bin/bash' 'HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hook2.sh"' 'bash "$HOOK"' > "$S/payload/hooks/test-hook2.sh"
printf '%s\n' '#!/bin/bash' 'echo one' 'echo two' 'echo three' > "$S/payload/hooks/notes.sh"
printf '%s\n' '#!/bin/bash' 'curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage' > "$S/payload/hooks/poster.sh"
run_s() { run_raw "$(payload Bash "$(bash_input "$1")" "$S")"; }
# edits <file>...: a python3 heredoc that edits each file where it stands, as a session writes one.
edits() {
  local list="" f
  for f in "$@"; do list="$list'$f', "; done
  printf '%s\n' "python3 - <<'PY'" "for p in (${list}):" '    s = open(p).read()' "    s = s.replace('echo', 'echo')" \
    "    open(p, 'w').write(s)" 'PY'
}
MADE="which the script is made from earlier in this command"

echo "slack drafts made lines: a refusal names the file that holds the line, and its line there (claude-config#3278)"

# What is allowed alone, each seen first: the suite, the tool from its own place, and the edit.
run_s "bash payload/hooks/test-hook.sh"
allowed "#3278 the hook's suite run alone"
run_s "bash tool"
allowed "#3278 the tool run from its own place, where its library is found"
run_s "$(edits tool payload/hooks/hook.sh)"
allowed "#3278 the edit of the tool and the hook, with nothing run after it"
run_s "$(edits payload/hooks/hook.sh)
bash payload/hooks/test-hook.sh"
allowed "#3278 an edit that names only the hook, then the hook's suite"

# The call that was refused: one heredoc edits the tool and the hook, then the hook's suite runs.
# The hook may now hold what the tool holds, and as a copy in the hook's folder the tool's library
# is not beside it, so the source cannot be followed and the call is still refused. It was said to
# be at line 7 of the hook, which has two lines; it is line 7 of the tool.
run_s "$(edits tool payload/hooks/hook.sh)
bash payload/hooks/test-hook.sh"
refused "#3278 an edit that names the tool and the hook, then the hook's suite, is still refused"
says "#3278 and the refusal names the file that holds the line" "hook.sh, line 7 of tool, $MADE, sources \"\$CAP_LIB\""
says "#3278 and names the same file where the variables stop being followed" "at line 6 of tool, $MADE: if [ -f"
lacks "#3278 and gives no line of the hook that the hook does not have" "hook.sh, line 7,"
says "#3278 and still says what the hook was judged by" "hook.sh is made from the code python3 is given and tool earlier in this command, and was judged by what those hold"

# A line of the script's own, read after what it is made from, keeps its own number: the notes hold
# four lines, so the hook's third line is the eighth of the joined text.
run_s "bash payload/hooks/test-hook2.sh"
refused "#3278 a hook whose own line sources a path nothing sets is refused when its suite runs alone"
says "#3278 and the refusal names the hook and its line, as before" "hook2.sh, line 3, sources \"\$NOWHERE_3278/x.sh\""
run_s "$(edits payload/hooks/notes.sh payload/hooks/hook2.sh)
bash payload/hooks/test-hook2.sh"
refused "#3278 the same hook after an edit that names the notes and the hook is still refused"
says "#3278 and the refusal gives the line as the hook has it" "hook2.sh, line 3 as it is on disk, sources \"\$NOWHERE_3278/x.sh\""
lacks "#3278 and not its place in the joined text" "line 8"

# What the edit names is still read: a file that posts, named beside the hook, refuses the suite.
run_s "$(edits payload/hooks/poster.sh payload/hooks/hook.sh)
bash payload/hooks/test-hook.sh"
refused "#3278 an edit that names a script that posts and the hook, then the hook's suite"
says "#3278 and the refusal is the posting, not a line" "chat.postMessage"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
