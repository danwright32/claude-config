#!/usr/bin/env bash
# Tests for the one route the Slack drafts gate gives a command it would refuse: run it under the
# installed no network wrapper (claude-config#3173; Dan, 2026-11-18: "Yes, any command"). The rule is
# in lib/no-network-route.py and the wrapper is no-network-run.sh, whose own suite is
# test-no-network-run.sh. Kept apart from test-slack-drafts-only-gate.sh as
# test-slack-drafts-unread-shapes.sh is, so that suite does not grow past its wall clock; the helpers
# below are copied from that one as they are, so a case here is driven the same way: a hook payload
# piped into slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr. Nothing a
# case names is ever run.
#
# The installed wrapper, to the gate, is the no-network-run.sh beside it, so here it is the one
# beside this suite. What is held:
#   * a command the gate refuses passes with that wrapper as the first word of the command;
#   * the refusal of a file whose imports reach code that posts names the route, and no other
#     refusal does;
#   * every other way of naming the wrapper is judged as it was before the rule, which for each
#     case here is a refusal: a copy elsewhere, a wrapper the same command wrote, moved, linked or
#     changed, a variable, a tilde, a program in front of it, a variable assignment in front of it;
#   * everything else on the line is still judged: a command before or after it, either side of a
#     pipe, and a substitution among its words, which the shell runs outside the wrapper.
# Where a shape cannot be told apart by the gate's verdict (the wrapper with nothing after it runs
# nothing, so it was never refused), the rule itself is asked, through the gate's own code.
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
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }
says_not() { case "$ERR" in *"$2"*) check "$1" "stderr said '$2': ${ERR:0:400}" ;; *) check "$1" ok ;; esac; }
read_refused() {
  refused "$1"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}
read_allowed() {
  allowed "$1"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}
POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"

# each <helper> <label> [says text]: one command per line of the heredoc on descriptor 3, judged in
# the folder run_in names. The commands are data here, read a line at a time and handed to the gate
# as a payload; none is run.
RUN_IN="$T"
run_here() { run_raw "$(payload Bash "$(bash_input "$1")" "$RUN_IN")"; }
each() {
  local how="$1" label="$2" want="${3:-}" runs
  while IFS= read -r runs <&3; do
    [ -n "$runs" ] || continue
    run_here "$runs"
    "$how" "$label: $runs"
    if [ -n "$want" ]; then says "$label, and the refusal says so: $runs" "$want"; fi
  done
}

W="$DIR/no-network-run.sh"
if [ ! -f "$W" ]; then
  echo "FAIL: there is no no-network-run.sh beside this suite at $DIR, so the gate has no installed wrapper to let through."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# A project whose one test file imports a module that reads the webhook, which is what the gate
# refuses (#3173), beside a test that imports nothing, a script that posts, and a script that only
# runs the words it is handed.
P="$T/proj"
mkdir -p "$P/test" "$P/lib" "$T/copy" "$T/links" "$T/tilde"
printf '%s\n' 'const url = process.env.SLACK_WEBHOOK;' \
  'module.exports.notify = (text) => fetch(url, { method: "POST", body: text });' > "$P/lib/notify.js"
printf '%s\n' 'const test = require("node:test");' 'const { notify } = require("../lib/notify.js");' \
  'test("is driven through a fake", () => notify);' > "$P/test/notify.test.js"
printf '%s\n' 'const test = require("node:test");' 'test("adds", () => 1 + 1);' > "$P/test/plain.test.js"
printf '%s\n' "$POST" > "$P/post.sh"
printf '%s\n' '#!/bin/bash' 'exec "$@"' > "$T/runner.sh"
chmod +x "$T/runner.sh"
printf '%s\n' "$W node --test test/notify.test.js" > "$P/under.sh"
printf '%s\n' "timeout 60 $W node --test test/notify.test.js" > "$P/behind.sh"
cp "$W" "$T/copy/no-network-run.sh"
ln -s "$W" "$T/links/run.sh"
ln -s "$DIR" "$T/links/hooks"
ln -s "$W" "$T/tilde/run.sh"
RUN_IN="$P"

echo "slack drafts only: a refusal for what a file imports names the no network route (claude-config#3173)"

run_here "node --test test/notify.test.js"
read_refused "#3173 one test file whose imports reach code that posts is refused"
says "#3173 and the refusal says which import" "which imports ../lib/notify.js"
says "#3173 and names the installed wrapper by its path" "$W"
says "#3173 and says where the wrapper goes" "as the first word of the command"
says "#3173 and says what the wrapper takes away" "no network access"
says "#3173 and carries the decision" "claude-config#3173"
run_here "node --test test/plain.test.js"
read_allowed "#3173 a test file that imports nothing is allowed, as it was"
run_here "bash post.sh"
read_refused "#3173 a script that posts is refused"
says_not "#3173 and a refusal that is not about an import names no route" "no network wrapper"
run_here "$POST"
read_refused "#3173 a request to the endpoint itself is refused"
says_not "#3173 and that refusal names no route" "no network wrapper"

echo "slack drafts only: a command run under the installed no network wrapper passes (claude-config#3173)"

each read_allowed "#3173 the installed wrapper as the command's first word passes" 3<<EOF
$W node --test test/notify.test.js
'$W' node --test test/notify.test.js
"$W" node --test test/notify.test.js
$W npx playwright test test/notify.test.js
$W env NODE_ENV=test node --test test/notify.test.js
$W timeout 60 node --test test/notify.test.js
$W bash post.sh
$W node --test test/notify.test.js > out.txt 2>&1
$W node --test "\$FILE"
cd $P && $W node --test test/notify.test.js
time $W node --test test/notify.test.js
! $W node --test test/notify.test.js
if $W node --test test/notify.test.js; then echo passed; fi
$W node --test test/notify.test.js; $W node --test test/plain.test.js
$W node --test test/notify.test.js | tail -5
$W node --test test/notify.test.js || echo failed
bash -c '$W node --test test/notify.test.js'
bash under.sh
EOF

# A link that resolves to the installed wrapper passes, as a link to the installed nudge.py does:
# both are judged by the real path. So does the wrapper reached through a linked folder.
each read_allowed "#3173 a path whose real path is the installed wrapper passes" 3<<EOF
$T/links/run.sh node --test test/notify.test.js
$T/links/hooks/no-network-run.sh node --test test/notify.test.js
$DIR/../hooks/no-network-run.sh node --test test/notify.test.js
EOF

echo "slack drafts only: any other way of naming the wrapper is judged as it was (claude-config#3173)"

each read_refused "#3173 a copy of the wrapper anywhere else is refused" 3<<EOF
$T/copy/no-network-run.sh node --test test/notify.test.js
EOF

each read_refused "#3173 a wrapper the same command wrote, moved, linked or changed is refused" 3<<EOF
cp $T/runner.sh $W && $W node --test test/notify.test.js
mv $T/runner.sh $W && $W node --test test/notify.test.js
ln -sf $T/runner.sh $W && $W node --test test/notify.test.js
echo 'exec "\$@"' > $W && $W node --test test/notify.test.js
echo 'exec "\$@"' >> $W; $W node --test test/notify.test.js
cat $T/runner.sh | tee $W; $W node --test test/notify.test.js
sed -i '' 's/deny network/allow network/' $W && $W node --test test/notify.test.js
cp $W $T/made.sh && $T/made.sh node --test test/notify.test.js
ln -s $W $T/made-link.sh && $T/made-link.sh node --test test/notify.test.js
cp -R $T/copy $T/made-dir && $T/made-dir/no-network-run.sh node --test test/notify.test.js
EOF

each read_refused "#3173 the wrapper named through a variable is refused" 3<<EOF
RUN=$W; \$RUN node --test test/notify.test.js
HOOKS=$DIR; \$HOOKS/no-network-run.sh node --test test/notify.test.js
HOOKS=$DIR; "\$HOOKS/no-network-run.sh" node --test test/notify.test.js
EOF

each read_refused "#3173 the wrapper behind another program, or a variable assignment, is refused" 3<<EOF
$T/runner.sh $W node --test test/notify.test.js
timeout 60 $W node --test test/notify.test.js
env NODE_ENV=test $W node --test test/notify.test.js
nohup $W node --test test/notify.test.js
NODE_ENV=test $W node --test test/notify.test.js
BASH_ENV=post.sh $W node --test test/notify.test.js
2>/dev/null $W node --test test/notify.test.js
bash $W node --test test/notify.test.js
bash behind.sh
EOF

each read_refused "#3173 the wrapper with nothing after it lets nothing else through" 3<<EOF
$W; node --test test/notify.test.js
$W && node --test test/notify.test.js
$W | node --test test/notify.test.js
$W > out.txt; node --test test/notify.test.js
EOF

echo "slack drafts only: everything else on the wrapper's line is still judged (claude-config#3173)"

each read_refused "#3173 a command beside the wrapper's is judged as it was" 3<<EOF
$W node --test test/plain.test.js; node --test test/notify.test.js
$W node --test test/plain.test.js && bash post.sh
node --test test/notify.test.js; $W node --test test/notify.test.js
node --test test/notify.test.js | $W cat
$W node --test test/plain.test.js & bash post.sh
$W node --test test/plain.test.js || $POST
EOF

# A substitution among the wrapper's words is run by the shell before the wrapper starts, outside
# the sandbox, so a command holding one is judged as it was before the rule.
each read_refused "#3173 a substitution among the wrapper's words is judged as it was" 3<<EOF
$W echo \$(bash post.sh)
$W echo "\$(bash post.sh)"
$W echo \`bash post.sh\`
$W cat <(bash post.sh)
$W node --test \$(node --test test/notify.test.js)
$W node --test test/plain.test.js > >(bash post.sh)
2> >(bash post.sh) $W node --test test/plain.test.js
EOF

echo "slack drafts only: a tilde path to the wrapper is not the installed path (claude-config#3173)"

# With HOME holding a link to the wrapper, ~/run.sh resolves to it for the gate, and the shell
# expands the tilde with whatever HOME the line has set by then: the rule takes no path it has to
# work out.
SAVED_HOME="$HOME"
export HOME="$T/tilde"
run_here "~/run.sh node --test test/notify.test.js"
read_refused "#3173 the wrapper named through a tilde is refused"
export HOME="$SAVED_HOME"

echo "slack drafts only: a pass by a link is not kept once the link points elsewhere (claude-config#3173)"

ln -s "$W" "$T/links/swap.sh"
run_here "$T/links/swap.sh node --test test/notify.test.js"
read_allowed "#3173 a link to the installed wrapper passes"
run_here "$T/links/swap.sh node --test test/notify.test.js"
read_allowed "#3173 and passes again from the judgement cache"
ln -sf "$T/copy/no-network-run.sh" "$T/links/swap.sh"
run_here "$T/links/swap.sh node --test test/notify.test.js"
read_refused "#3173 the same words once the link points at a copy are refused"

echo "slack drafts only: the rule itself, asked through the gate's own code (claude-config#3173)"

# rule.py <the gate's .py>: for each line on its input, "yes" or "no", a tab and the line, by
# Judge.no_network_run. For the shapes whose verdict cannot show the rule: a command that runs
# nothing was allowed before the rule and is allowed after it.
cat > "$T/rule.py" <<'PY'
import importlib.util
import os
import sys

GATE = sys.argv[1]
os.environ["GATE_DIR"] = os.path.dirname(GATE)
spec = importlib.util.spec_from_file_location("drafts_gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
judge = gate.Judge(gate.load_reader())
for line in sys.stdin:
    text = line.rstrip("\n")
    if text:
        print(("yes" if judge.no_network_run(text) else "no") + "\t" + text)
PY

rule_says() { # rule_says <yes|no> <label>, the commands on descriptor 3, one per line
  local want="$1" label="$2" runs got
  while IFS= read -r runs <&3; do
    [ -n "$runs" ] || continue
    got="$(printf '%s\n' "$runs" | python3 "$T/rule.py" "$DIR/slack_drafts_only_gate.py" 2>&1)"
    if [ "$got" = "$want"$'\t'"$runs" ]; then check "$label: $runs" ok; else check "$label: $runs" "the rule said: ${got:0:300}"; fi
  done
}

rule_says yes "#3173 the rule holds for the wrapper and a command" 3<<EOF
$W node --test test/notify.test.js
time $W true
EOF

rule_says no "#3173 the rule does not hold for the wrapper with nothing after it" 3<<EOF
$W
$W > out.txt
$W 2>&1
EOF

rule_says no "#3173 the rule does not hold for a path the gate would have to work out" 3<<EOF
\$(echo $W) node --test test/notify.test.js
\$RUN node --test test/notify.test.js
"\$HOME/run.sh" node --test test/notify.test.js
~/run.sh node --test test/notify.test.js
$DIR/no-network-r*.sh node --test test/notify.test.js
$DIR/{no-network-run.sh,x} node --test test/notify.test.js
no-network-run.sh node --test test/notify.test.js
./no-network-run.sh node --test test/notify.test.js
EOF

rule_says no "#3173 the rule does not hold with anything in front of the wrapper or run beside it" 3<<EOF
env $W node --test test/notify.test.js
xargs $W node --test
sudo $W node --test test/notify.test.js
exec $W node --test test/notify.test.js
command $W node --test test/notify.test.js
A=1 $W node --test test/notify.test.js
2>/dev/null $W node --test test/notify.test.js
2> >(date) $W node --test test/notify.test.js
some-program $W node --test test/notify.test.js
$W echo \$(date)
$W cat <(date)
EOF

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
