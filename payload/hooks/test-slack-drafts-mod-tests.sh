#!/usr/bin/env bash
# Tests for the sentence the Slack drafts gate adds when it cannot follow a `bun test` typed in a
# mod's folder (claude-config#3356). On 2026-11-20 a builder typed `bun test tests/rules.test.ts
# tests/register.test.ts` inside payload/mods/design-round-guard and was refused ("which imports
# ./card.ts, a module the gate cannot find"), with no word of how the mod's tests are run instead:
# `claude plugin test <mod folder>`, which the gate lets through. The refusal now names that
# command with the mod's folder written out. Only the words change: what is refused is refused as
# before, and a test that posts is never pointed at the other command.
# Kept apart from test-slack-drafts-only-gate.sh and test-slack-drafts-code-loaders.sh so neither
# grows past its wall clock; the helpers below are copied from test-slack-drafts-made-lines.sh as
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
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:1200}" ;; esac; }
lacks() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:1200}" ;; *) check "$1" ok ;; esac; }

# A small checkout: two mods (a folder is a mod's where it holds .claude-plugin/plugin.json, as every
# folder of payload/mods does), one whose test imports a module that is nowhere, one whose test
# posts; the first mod's files again in a folder that is no mod's; and a mod in a folder whose name
# holds a space.
S="$(cd "$T" && pwd -P)/src"  # by its real path, as a checkout is: on macOS the temp folder is behind a link
mod() { # mod <folder>: a mod's folder with one test that imports a module the gate cannot find
  mkdir -p "$1/.claude-plugin" "$1/tests" "$1/hooks"
  printf '%s\n' '{"name": "alpha", "version": "1.0.0"}' > "$1/.claude-plugin/plugin.json"
  printf '%s\n' "import { expect, test } from 'claude-code/testing'" "import { held } from './nowhere-3356.ts'" \
    "test('holds', () => { expect(held()).toBe(true) })" > "$1/tests/a.test.ts"
  printf '%s\n' 'export const rule = 1' > "$1/hooks/rules.ts"
}
mod "$S/mods/alpha"
mod "$S/mods/with space"
mod "$S/plain"
rm -rf "$S/plain/.claude-plugin"
mod "$S/mods/beta"
printf '%s\n' "import { expect, test } from 'claude-code/testing'" \
  "test('posts', async () => { await fetch('https://slack.com/api/chat.postMessage', { method: 'POST', body: 'text=hi' }) })" \
  > "$S/mods/beta/tests/a.test.ts"
printf '%s\n' '#!/bin/bash' "cd '$S/mods/alpha' && bun test tests/a.test.ts" > "$S/run-tests.sh"
run_s() { run_raw "$(payload Bash "$(bash_input "$1")" "${2:-$S}")"; }
ROUTE="claude plugin test"
NOTFOUND="a module the gate cannot find"

echo "slack drafts mod tests: a bun test the gate cannot follow in a mod's folder is told how the mod's tests are run (claude-config#3356)"

# The call of 2026-11-20: a cd into the mod's folder, then bun test with the test files named.
run_s "cd $S/mods/alpha && bun test tests/a.test.ts"
refused "#3356 bun test with a file named, in a mod's folder, is still refused"
says "#3356 and for the reason it was: a module the gate cannot find" "$NOTFOUND"
says "#3356 and the refusal names the command that runs the mod's tests, with the mod's folder written out" "\`$ROUTE $S/mods/alpha\`"
says "#3356 and says it is not a finding that the command posts, as before" "This is not a finding that it posts"

# The same from the mod's folder with no cd, by a cd written from the checkout's root, with the
# output piped on, and from a folder inside the mod: the folder named is always the mod's own.
run_s "bun test tests/a.test.ts" "$S/mods/alpha"
refused "#3356 the same typed with the mod's folder as the call's own is refused"
says "#3356 and names the mod's folder" "\`$ROUTE $S/mods/alpha\`"
run_s "cd mods/alpha && bun test tests/a.test.ts 2>&1 | tail -5"
refused "#3356 the same behind a cd written from the checkout's root, its output piped on, is refused"
says "#3356 and names the mod's folder in full" "\`$ROUTE $S/mods/alpha\`"
run_s "cd $S/mods/alpha/tests && bun test a.test.ts"
refused "#3356 the same typed in the mod's tests folder is refused"
says "#3356 and names the mod's folder, not the folder inside it" "\`$ROUTE $S/mods/alpha\`"
lacks "#3356 and never the folder inside it" "$ROUTE $S/mods/alpha/tests"
run_s "cd '$S/mods/with space' && bun test tests/a.test.ts"
refused "#3356 the same in a mod whose folder's name holds a space is refused"
says "#3356 and names that folder in quotes, as it must be typed" "\`$ROUTE '$S/mods/with space'\`"

# The command the refusal names is one the gate lets through (L111), alone or behind a cd.
run_s "$ROUTE $S/mods/alpha"
allowed "#3356 claude plugin test with the mod's folder is allowed"
run_s "cd $S/mods/alpha && $ROUTE"
allowed "#3356 claude plugin test typed in the mod's folder is allowed"

# Where the sentence must not appear. A folder that is no mod's has no such command to run.
run_s "cd $S/plain && bun test tests/a.test.ts"
refused "#3356 bun test with a file named, in a folder that is no mod's, is refused as before"
says "#3356 and for the same reason" "$NOTFOUND"
lacks "#3356 and is not told to run a mod's tests" "$ROUTE"
# A test that posts is refused as a post, and is never pointed at a command the gate does not read.
run_s "cd $S/mods/beta && bun test tests/a.test.ts"
refused "#3356 bun test of a file that posts, in a mod's folder, is refused"
says "#3356 and the refusal is the posting" "chat.postMessage"
lacks "#3356 and it is not told to run the mod's tests another way" "$ROUTE"
# A command that names a posting endpoint itself is told to save a draft, and nothing else.
run_s "cd $S/mods/alpha && bun test tests/a.test.ts && curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"
refused "#3356 bun test in a mod's folder chained with a command that posts is refused"
lacks "#3356 and it is not told to run the mod's tests another way" "$ROUTE"
# Any other bun command, and any other test runner, in the mod's folder: the sentence is about bun
# test alone, the command the builder typed.
run_s "cd $S/mods/alpha && bun run tests/a.test.ts"
refused "#3356 bun run of the same file in the mod's folder is refused"
lacks "#3356 and is not told to run the mod's tests" "$ROUTE"
run_s "cd $S/mods/alpha && node --test tests/a.test.ts"
refused "#3356 node --test of the same file in the mod's folder is refused"
lacks "#3356 and is not told to run the mod's tests" "$ROUTE"
# A script that runs bun test in the mod's folder: the call typed no bun test, so the sentence would
# name a command in place of one the session did not type.
run_s "bash run-tests.sh"
refused "#3356 a script that runs bun test in the mod's folder is refused"
says "#3356 and for the same reason" "$NOTFOUND"
lacks "#3356 and the call that ran the script is not told to run the mod's tests" "$ROUTE"
# A folder the gate cannot be certain of (a cd through a variable nothing sets) is not named.
run_s "cd \"\$WHERE_3356\" && bun test tests/a.test.ts" "$S/mods/alpha"
lacks "#3356 bun test behind a cd the gate cannot work out names no folder" "$ROUTE"
# bun test with no file named reads no file, so it is allowed, as before.
run_s "cd $S/mods/alpha && bun test"
allowed "#3356 bun test with no file named, in a mod's folder, is allowed as before"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
