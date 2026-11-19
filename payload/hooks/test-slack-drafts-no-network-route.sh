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
#   * a command the gate refuses passes with that wrapper as the first word of the call's first
#     command, with only a cd before it;
#   * the refusal of a file whose imports reach code that posts names the route, and no other
#     refusal does;
#   * every other way of naming the wrapper is judged as it was before the rule, which for each
#     case here is a refusal: a copy elsewhere, a wrapper the same command wrote, moved, linked or
#     changed, a variable, a tilde, a program, an assignment or a redirection in front of it, any
#     command but a cd before it, a loop, a function, a script or a string around it, a second
#     wrapper run in the same call, and a word after it that the shell itself works out or runs;
#   * everything else on the line is still judged, and never better for the wrapper being there:
#     a command after it, the other side of a pipe, a second line, and a file a later command runs
#     that the wrapped command could have written, which the gate has not read.
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
# For a later command that runs a file an earlier one wrote: a script that is harmless as it
# stands, a program that writes the posting script over it, and a build whose source posts beside
# an output that is harmless as it stands (as test-slack-drafts-only-gate.sh sets up #2852).
printf '%s\n' 'echo fine' > "$P/made.sh"
printf '%s\n' 'open("made.sh", "w").write(open("post.sh").read())' > "$P/gen.py"
B="$T/build"
mkdir -p "$B/esrc"
printf '%s\n' "fetch('https://slack.com/api/chat.postMessage');" > "$B/esrc/post.ts"
printf '%s\n' "console.log('old');" > "$B/out.js"
printf '%s\n' '{ "scripts": { "build": "esbuild esrc/post.ts --outfile=out.js" } }' > "$B/package.json"
printf '%s\n' 'print("not the nudge script")' > "$T/e.py"
NUDGE="$(cd "$DIR/.." && pwd)/skills/nudge/nudge.py"
NUDGE_TO='https://example.slack.com/archives/C0TEST1/p1730000000000100'
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

each read_allowed "#3173 the installed wrapper as the first word of the call's first command passes" 3<<EOF
$W node --test test/notify.test.js
'$W' node --test test/notify.test.js
"$W" node --test test/notify.test.js
$W npx playwright test test/notify.test.js
$W env NODE_ENV=test node --test test/notify.test.js
$W timeout 60 node --test test/notify.test.js
$W bash post.sh
$W bash -c '$POST'
$W node --test test/notify.test.js > out.txt 2>&1
$W node --test test/notify.test.js 2>/dev/null
$W node --test "\$FILE" "\${HOME}/x.test.js" test/*.test.js --name='a b'
cd $P && $W node --test test/notify.test.js
cd '$P'; $W node --test test/notify.test.js
time $W node --test test/notify.test.js
! $W node --test test/notify.test.js
if $W node --test test/notify.test.js; then echo passed; fi
{ $W node --test test/notify.test.js; }
$W node --test test/notify.test.js | tail -5
$W node --test test/notify.test.js || echo failed
$W node --test test/notify.test.js; echo done
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

echo "slack drafts only: the wrapper passes only as the call's own first command (claude-config#3173)"

# Whatever the call runs before the wrapper could change what its path starts (a function or an
# alias of that name, in zsh an alias for every .sh file) or open a connection the command then
# inherits, which the sandbox does not close (test-no-network-run.sh, "held"). So only a cd to a
# folder written out may come first, and the wrapper is not inside a subshell or a substitution.
each read_refused "#3173 the wrapper after any command but a cd is judged as it was" 3<<EOF
echo start; $W node --test test/notify.test.js
true && $W node --test test/notify.test.js
ls | $W node --test test/notify.test.js
X=1; $W node --test test/notify.test.js
exec 3<>/dev/tcp/127.0.0.1/9; $W node --test test/notify.test.js
alias -s sh=bash; $W node --test test/notify.test.js
$W() { "\$@"; }; $W node --test test/notify.test.js
function $W { "\$@"; }; $W node --test test/notify.test.js
cd \$(pwd) && $W node --test test/notify.test.js
( $W node --test test/notify.test.js )
echo \$($W node --test test/notify.test.js)
EOF

# A loop or a function runs the same words again, and the second time the wrapper's path starts
# whatever the first run left there: the sandbox does not stop a command writing a file. A script
# or a string another program runs can be run in a loop by that program, so the wrapper passes only
# on the call's own line.
each read_refused "#3173 the wrapper inside a loop, a function, a script or a string is judged as it was" 3<<EOF
for f in a b; do $W node --test test/notify.test.js; done
for f in a b; do echo "\$f"; $W node --test test/notify.test.js; done
while $W node --test test/notify.test.js; do echo again; done
until $W node --test test/notify.test.js; do echo again; done
run() { $W node --test test/notify.test.js; }; run; run
bash -c '$W node --test test/notify.test.js'
bash under.sh
EOF

# Only the first wrapper run of a call passes: the first could have rewritten the wrapper's file,
# or any link to it, and the gate has not read what it ran.
each read_refused "#3173 a second wrapper run in one call is judged as it was" 3<<EOF
$W node --test test/plain.test.js; $W node --test test/notify.test.js
$W node --test test/notify.test.js; $W node --test test/plain.test.js
$W sh -c 'cp $T/runner.sh $W'; $W node --test test/notify.test.js
$W node --test test/notify.test.js && $T/links/run.sh node --test test/notify.test.js
EOF

# The words after the wrapper are ones the shell hands on as they are: plain characters, quoted
# text, a variable by its name. Anything the shell would work out or run itself before the wrapper
# starts (zsh runs the code in a pattern's (e:...:) and in a \${(e)NAME}) is outside the sandbox,
# and so is a connection the shell opens for a redirection.
each read_refused "#3173 a word the shell itself would work out or run is judged as it was" 3<<EOF
$W node --test test/notify.test.js *(e:'bash post.sh':)
$W node --test test/notify.test.js \${(e)CODE}
$W node --test test/notify.test.js \${CODE:-x}
$W node --test test/notify.test.js "\$CODE[1]"
$W node --test test/notify.test.js {a,b}
$W node --test test/notify.test.js a\\;b
$W node --test test/notify.test.js ~/x
$W node --test test/notify.test.js <<< "\$(bash post.sh)"
$W node --test test/notify.test.js > /dev/tcp/127.0.0.1/9
$W node --test test/notify.test.js 3<>/dev/tcp/127.0.0.1/9
$W node --test test/notify.test.js > "\$OUT"
$W node --test test/notify.test.js >&3
EOF

run_here "$W node --test test/notify.test.js <<EOF
\$(bash post.sh)
EOF"
read_refused "#3173 a here document, whose substitutions the shell runs itself, is judged as it was"
run_here "$W node --test \\
test/notify.test.js"
read_refused "#3173 a command carried onto a second line by a backslash is judged as it was"
run_here "# run the one test
$W node --test test/notify.test.js"
read_refused "#3173 the wrapper after a comment line is judged as it was"

echo "slack drafts only: everything else on the wrapper's line is still judged (claude-config#3173)"

each read_refused "#3173 a command beside the wrapper's is judged as it was" 3<<EOF
$W node --test test/plain.test.js; node --test test/notify.test.js
$W node --test test/plain.test.js && bash post.sh
node --test test/notify.test.js; $W node --test test/notify.test.js
node --test test/notify.test.js | $W cat
$W node --test test/plain.test.js & bash post.sh
$W node --test test/plain.test.js || $POST
EOF

run_here "$W node --test test/plain.test.js
bash post.sh"
read_refused "#3173 a second line after the wrapper's is judged as it was"

# What the wrapped command prints is not read, so a shell that is fed it is refused.
each read_refused "#3173 a shell fed what the wrapped command prints is refused" 3<<EOF
$W cat post.sh | bash
$W printf '%s\n' '$POST' | sh
bash <($W cat post.sh)
eval "\$($W cat post.sh)"
source <($W cat post.sh)
EOF

echo "slack drafts only: a file the wrapped command could have written is not read as it stands (claude-config#3173)"

# The sandbox takes the network away and nothing else, so the wrapped command can write any file,
# and the gate has not read what it ran. A later command of the same call that runs a file gets
# no better a verdict for the wrapper being in front of the earlier one.
# later_refused <label> <earlier> <later>: <later> alone passes as the files stand; after <earlier>
# it is refused today, with no wrapper; and it is refused with the wrapper in front of <earlier>.
later_refused() {
  local label="$1" earlier="$2" later="$3"
  run_here "$later"
  read_allowed "$label: alone, as the files stand, it passes: $later"
  run_here "$earlier; $later"
  read_refused "$label: after it with no wrapper it is refused: $earlier; $later"
  run_here "$W $earlier; $later"
  read_refused "$label: after it under the wrapper it is refused too: $W $earlier; $later"
}
later_refused "#3173 a script copied over" "cp post.sh made.sh" "bash made.sh"
later_refused "#3173 a script copied over inside a string" "bash -c 'cp post.sh made.sh'" "bash made.sh"
# A script file on disk that writes the posting script over another: with no wrapper the gate
# passes `python3 gen.py; bash made.sh` today, since it does not follow what a script on disk
# writes (measured 2026-11-19 and reported apart from #3173). Under the wrapper nothing is read at
# all, so the later command is refused.
run_here "$W python3 gen.py; bash made.sh"
read_refused "#3173 a script the wrapped program writes over is refused"
if [ -f "$NUDGE" ]; then
  later_refused "#3173 the installed nudge script written over" "bash -c 'cp $T/e.py $NUDGE'" "python3 $NUDGE '$NUDGE_TO'"
else
  check "nudge.py is where the gate expects it, beside the hooks" "missing $NUDGE"
fi
RUN_IN="$B"
later_refused "#3173 a build's output" "npm run build" "node out.js"
RUN_IN="$P"
run_here "$W cat post.sh > made.sh; bash made.sh"
read_refused "#3173 a script the wrapped command's output is written to is refused"
run_here "$W cp post.sh newtool; ./newtool"
read_refused "#3173 a file that is not there yet, which the wrapped command could make, is refused"
# The cost of that, said plainly: after a wrapper run, the same call cannot run any other file.
run_here "$W node --test test/notify.test.js; node --test test/plain.test.js"
read_refused "#3173 after a wrapper run, a later command of the same call that runs a file is refused"
says "#3173 and the refusal names the wrapper run as what may have written it" "the command run under the no network wrapper"

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

# rule.py <the gate's .py> <folder>: for each line on its input, read as a call made in that folder
# and walked as the gate walks one (Judge.line), "yes" where Judge.no_network_run held for a
# command of it and "no" where it held for none, then a tab and the line. For the shapes whose
# verdict cannot show the rule: a command that runs nothing was allowed before the rule and is
# allowed after it, and a wrapper run the gate refuses today is refused whichever part of the rule
# turned it away.
cat > "$T/rule.py" <<'PY'
import importlib.util
import os
import sys

GATE = sys.argv[1]
CWD = sys.argv[2]
os.environ["GATE_DIR"] = os.path.dirname(GATE)
spec = importlib.util.spec_from_file_location("drafts_gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
for line in sys.stdin:
    text = line.rstrip("\n")
    if not text:
        continue
    judge = gate.Judge(gate.load_reader())
    held = []
    rule = judge.no_network_run

    def asked(*args, rule=rule, held=held):
        got = rule(*args)
        held.append(bool(got))
        return got

    judge.no_network_run = asked
    judge.watch()
    try:
        judge.line(text, CWD, 0, text)
    finally:
        judge.unwatch()
    print(("yes" if any(held) else "no") + "\t" + text)
PY

rule_says() { # rule_says <yes|no> <label>, the commands on descriptor 3, one per line
  local want="$1" label="$2" runs got
  while IFS= read -r runs <&3; do
    [ -n "$runs" ] || continue
    got="$(printf '%s\n' "$runs" | python3 "$T/rule.py" "$DIR/slack_drafts_only_gate.py" "$P" 2>&1)"
    if [ "$got" = "$want"$'\t'"$runs" ]; then check "$label: $runs" ok; else check "$label: $runs" "the rule said: ${got:0:300}"; fi
  done
}

rule_says yes "#3173 the rule holds for the wrapper and a command" 3<<EOF
$W node --test test/notify.test.js
time $W true
time -p $W true
cd $P && $W node --test test/notify.test.js
if $W true; then echo ok; fi
{ $W true; }
$W node -e 'fetch(u); console.log("a b")' "\$HOME/x" --flag=1 test/*.js > out.txt 2>&1
$W true | tail -5
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
echo start; $W true
true && $W true
ls | $W cat
cd \$(pwd) && $W true
cd "\$HOME" && $W true
cd -P $P && $W true
( $W true )
echo \$($W true)
for f in a b; do $W true; done
for f in a b; do echo "\$f"; $W true; done
while $W true; do echo again; done
until $W true; do echo again; done
run() { $W true; }; run
$W() { "\$@"; }; $W true
alias -s sh=bash; $W true
bash -c '$W true'
bash under.sh
>out.txt $W true
< /dev/null $W true
&>log.txt $W true
2>&1 $W true
coproc $W true
if true; then $W true; fi
if false; then true; else $W true; fi
case x in x) $W true;; esac
repeat 2 $W true
for f (a b) $W true
eval '$W true'
EOF

# Two lines the gate passes with or without the rule, because it cannot work out the file they
# name (the folder, or the loop's variable): the rule is not what passes them.
rule_says no "#3173 the rule does not hold where the gate passes the line for a reason of its own" 3<<EOF
cd "\$HOME" && $W node --test test/notify.test.js
for f in test/notify.test.js; do $W node --test "\$f"; done
EOF

rule_says no "#3173 the rule does not hold for a word the shell itself would work out or run" 3<<EOF
$W echo *(e:'date':)
$W echo \${(e)CODE}
$W echo \${CODE:-x}
$W echo "\$CODE[1]"
$W echo \$CODE[1]
$W echo "\${CODE[1]}"
$W echo {a,b}
$W echo a\\;b
$W echo ~/x
$W echo "a\\nb"
$W echo "\`date\`"
$W cat <<< "\$(date)"
$W cat <<WORDS
$W echo hi > /dev/tcp/127.0.0.1/9
$W echo hi 3<>/dev/tcp/127.0.0.1/9
$W echo hi > "\$OUT"
$W echo hi >&3
$W echo '/dev/udp/127.0.0.1/9'
EOF

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
