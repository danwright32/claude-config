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
#   * a command the gate refuses passes when the call is that wrapper and the command and nothing
#     else, with one `cd <folder> &&` in front at most, and its output, errors or input sent to a
#     file written out, each form of that by name;
#   * the refusal of a file whose imports reach code that posts names the route, and no other
#     refusal does;
#   * every other call is judged as it was before the rule, which for each case here is a refusal:
#     a copy elsewhere, a variable, a tilde, a program, an assignment, a redirection or a word of
#     the shell's own in front of the wrapper, such as time or if, any command before it but the one
#     cd, a loop, a function, a group, a script or a string around it, anything after its command
#     (a second command, a pipe, a command put in the background, a second line, a comment), any
#     other form of redirection, a word the shell itself works out or runs, and any character that
#     is not printable ASCII, a tab or a newline, each written here as an escape;
#   * the two checks no call can reach while nothing may stand before the wrapper but a cd and
#     nothing after it, each on its own, by handing one Judge two lines: that the call has not
#     written or built the wrapper's file, and that a pass leaves every file unread.
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

# A command holding a character this file must not hold. Each \uXXXX in the text handed over is that
# one character by the time the gate reads the payload, so none is written here.
esc_input() {
  python3 -c '
import json, re, sys
text = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), sys.argv[1])
print(json.dumps({"command": text, "description": "d"}))
' "$1"
}
run_esc() { run_raw "$(payload Bash "$(esc_input "$1")" "$RUN_IN")"; }
each_esc() { # as each, for commands written with \uXXXX
  local how="$1" label="$2" runs
  while IFS= read -r runs <&3; do
    [ -n "$runs" ] || continue
    run_esc "$runs"
    "$how" "$label: $runs"
  done
}
# A package script that is harmless as it stands, for a later command of a call that runs one.
printf '%s\n' '{ "scripts": { "x": "echo fine" } }' > "$P/package.json"

echo "slack drafts only: the installed no network wrapper and its command, as the whole call, pass (claude-config#3173)"

each read_allowed "#3173 the installed wrapper and its command, as the whole call, pass" 3<<EOF
$W node --test test/notify.test.js
'$W' node --test test/notify.test.js
"$W" node --test test/notify.test.js
$W npx playwright test test/notify.test.js
$W env NODE_ENV=test node --test test/notify.test.js
$W timeout 60 node --test test/notify.test.js
$W bash post.sh
$W bash -c '$POST'
$W sh -c 'node --test test/notify.test.js | tail -5; echo done'
$W node --test "\$FILE" "\${HOME}/x.test.js" test/*.test.js --name='a b'
cd $P && $W node --test test/notify.test.js
cd '$P' && "$W" node --test test/notify.test.js
EOF

# The redirections the rule takes after the wrapper's words, each form by name: the command's output
# or its errors written or added to a file written out, its input read from one, and one output
# joined to the other. The shell opens the file before the wrapper starts and nothing else.
each read_allowed "#3173 the wrapper's output, errors or input sent to a file written out passes" 3<<EOF
$W node --test test/notify.test.js > out.txt
$W node --test test/notify.test.js >> out.txt
$W node --test test/notify.test.js 1> out.txt
$W node --test test/notify.test.js 2> err.txt
$W node --test test/notify.test.js 2>> err.txt
$W node --test test/notify.test.js 2>/dev/null
$W node --test test/notify.test.js > out.txt 2>&1
$W node --test test/notify.test.js 2>&1
$W node --test test/notify.test.js 1>&2
$W node --test test/notify.test.js >&2
$W node --test test/notify.test.js < in.txt
$W node --test test/notify.test.js > 'out file.txt' 2> "err file.txt"
EOF

# Every other redirection leaves the command judged as it was: both outputs at once (bash 3.2, the
# one macOS ships, reads the adding form as a command put in the background and a second command),
# a forced overwrite, a file opened both ways, a descriptor past 2, one closed, a here document or
# string, a target the shell works out, a name bash opens as a connection, and one glued to a word.
each read_refused "#3173 any other redirection after the wrapper's words is judged as it was" 3<<EOF
$W node --test test/notify.test.js &> out.txt
$W node --test test/notify.test.js &>> out.txt
$W node --test test/notify.test.js >| out.txt
$W node --test test/notify.test.js >! out.txt
$W node --test test/notify.test.js <> in.txt
$W node --test test/notify.test.js 3> out.txt
$W node --test test/notify.test.js >&3
$W node --test test/notify.test.js 2>&-
$W node --test test/notify.test.js >& out.txt
$W node --test test/notify.test.js > "\$OUT"
$W node --test test/notify.test.js > \$OUT
$W node --test test/notify.test.js > out*.txt
$W node --test test/notify.test.js > ~/out.txt
$W node --test test/notify.test.js 0< in.txt
$W node --test test/notify.test.js 2< in.txt
$W node --test test/notify.test.js > /dev/tcp/127.0.0.1/9
$W node --test test/notify.test.js < /dev/tcp/127.0.0.1/9
$W node --test test/notify.test.js > /dev/udp/127.0.0.1/9
$W node --test test/notify.test.js 3<>/dev/tcp/127.0.0.1/9
$W node --test test/notify.test.js <<< "\$(bash post.sh)"
EOF
# One glued to the last word (`... notify.test.js>out.txt`) is asked of the rule below and not
# here: the gate passes that line while the rule says no (measured 2026-11-19), so the pass is a
# reading of the gate's own, of a word with a redirection glued to it, and not this rule's.

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

echo "slack drafts only: nothing stands in front of the wrapper but one cd (claude-config#3173)"

# Whatever the call runs before the wrapper could change what its path starts (a function or an
# alias of that name, in zsh an alias for every .sh file) or open a connection the command then
# inherits, which the sandbox does not close (test-no-network-run.sh, "held"). And a word of the
# shell's own in front of it is not safe to read past: zsh runs `time -p <words>` as a program
# named -p, outside the sandbox (measured 2026-11-19), and bash opens the redirection on a group or
# an if before it runs what is inside. So the one thing that may come first is `cd <folder> &&`.
# The lines that write, move, link or change the wrapper's file first were a group of their own,
# named for the check that the call has not written the file: they are turned away here, by there
# being a command in front, and that check is asked apart, below (one Judge handed two lines).
each read_refused "#3173 the wrapper after anything but one cd is judged as it was" 3<<EOF
echo start; $W node --test test/notify.test.js
true && $W node --test test/notify.test.js
ls | $W node --test test/notify.test.js
X=1; $W node --test test/notify.test.js
exec 3<>/dev/tcp/127.0.0.1/9; $W node --test test/notify.test.js
alias -s sh=bash; $W node --test test/notify.test.js
$W() { "\$@"; }; $W node --test test/notify.test.js
function $W { "\$@"; }; $W node --test test/notify.test.js
cd \$(pwd) && $W node --test test/notify.test.js
cd $P; $W node --test test/notify.test.js
cd $P || $W node --test test/notify.test.js
cd $P && cd $P && $W node --test test/notify.test.js
( $W node --test test/notify.test.js )
echo \$($W node --test test/notify.test.js)
time $W node --test test/notify.test.js
time -p $W node --test test/notify.test.js
! $W node --test test/notify.test.js
{ $W node --test test/notify.test.js; }
{ $W node --test test/notify.test.js; } 3<>/dev/tcp/127.0.0.1/9
if $W node --test test/notify.test.js; then echo passed; fi
if $W node --test test/notify.test.js; then :; fi 3<>/dev/tcp/127.0.0.1/9
cp $T/runner.sh $W && $W node --test test/notify.test.js
mv $T/runner.sh $W && $W node --test test/notify.test.js
ln -sf $T/runner.sh $W && $W node --test test/notify.test.js
echo 'exec "\$@"' > $W && $W node --test test/notify.test.js
sed -i '' 's/deny network/allow network/' $W && $W node --test test/notify.test.js
cp $W $T/made.sh && $T/made.sh node --test test/notify.test.js
ln -s $W $T/made-link.sh && $T/made-link.sh node --test test/notify.test.js
EOF

# A loop or a function runs the same words again, and a script or a string another program runs can
# be run in a loop by that program, so the wrapper passes only as the call itself.
each read_refused "#3173 the wrapper inside a loop, a function, a script or a string is judged as it was" 3<<EOF
for f in a b; do $W node --test test/notify.test.js; done
for f in a b; do echo "\$f"; $W node --test test/notify.test.js; done
while $W node --test test/notify.test.js; do echo again; done
until $W node --test test/notify.test.js; do echo again; done
run() { $W node --test test/notify.test.js; }; run; run
bash -c '$W node --test test/notify.test.js'
bash under.sh
EOF

echo "slack drafts only: nothing follows the wrapper's command in the call (claude-config#3173)"

# The gate has not read what ran under the wrapper, and that command can write any file: a package
# script, a program in a folder ahead of /usr/bin on the PATH, a git hook, a Makefile. The gate
# does not read every one of those as a file a later command runs, so nothing may follow: a later
# command, the other side of a pipe, a command put in the background, a second line, a comment.
# What an agent wants done afterwards goes inside the wrapped command, behind sh -c '...'.
each read_refused "#3173 anything after the wrapper's command leaves it judged as it was" 3<<EOF
$W node --test test/notify.test.js; npm run x
$W node --test test/notify.test.js; tail out.txt
$W node --test test/notify.test.js && cat out.txt
$W node --test test/notify.test.js || echo failed
$W node --test test/notify.test.js; echo done
$W node --test test/notify.test.js | tail -5
$W node --test test/notify.test.js |& tail -5
$W node --test test/notify.test.js | xargs -n1 tail
$W node --test test/notify.test.js &
$W node --test test/notify.test.js & tail out.txt
$W node --test test/notify.test.js; git status
$W node --test test/notify.test.js; make
$W node --test test/notify.test.js ;
$W node --test test/notify.test.js # and a note
$W node --test test/notify.test.js; $W node --test test/plain.test.js
$W node --test test/plain.test.js; $W node --test test/notify.test.js
$W node --test test/notify.test.js && $T/links/run.sh node --test test/notify.test.js
$W node --test test/notify.test.js; node --test test/plain.test.js
EOF

run_here "$W node --test test/notify.test.js
tail out.txt"
read_refused "#3173 a second line after the wrapper's is judged as it was"
run_here "# run the one test
$W node --test test/notify.test.js"
read_refused "#3173 the wrapper after a comment line is judged as it was"
run_here "$W node --test \\
test/notify.test.js"
read_refused "#3173 a command carried onto a second line by a backslash is judged as it was"
run_here "$W node --test test/notify.test.js <<EOF
\$(bash post.sh)
EOF"
read_refused "#3173 a here document, whose substitutions the shell runs itself, is judged as it was"

# The other command of such a call is judged as it always was, whatever the wrapper is doing there.
each read_refused "#3173 a command beside the wrapper's is judged as it was" 3<<EOF
$W node --test test/plain.test.js; node --test test/notify.test.js
$W node --test test/plain.test.js && bash post.sh
node --test test/notify.test.js; $W node --test test/notify.test.js
node --test test/notify.test.js | $W cat
$W node --test test/plain.test.js & bash post.sh
$W node --test test/plain.test.js || $POST
$W cat post.sh | bash
$W printf '%s\n' '$POST' | sh
bash <($W cat post.sh)
eval "\$($W cat post.sh)"
source <($W cat post.sh)
$W cp post.sh made.sh; bash made.sh
$W cat post.sh > made.sh; bash made.sh
EOF

echo "slack drafts only: the words after the wrapper are ones the shell hands on as they stand (claude-config#3173)"

# Plain characters, quoted text, a variable by its name. Anything the shell would work out or run
# itself before the wrapper starts (zsh runs the code in a pattern's (e:...:) and in a \${(e)NAME})
# is outside the sandbox.
each read_refused "#3173 a word the shell itself would work out or run is judged as it was" 3<<EOF
$W node --test test/notify.test.js *(e:'bash post.sh':)
$W node --test test/notify.test.js \${(e)CODE}
$W node --test test/notify.test.js \${CODE:-x}
$W node --test test/notify.test.js "\$CODE[1]"
$W node --test test/notify.test.js {a,b}
$W node --test test/notify.test.js a\\;b
$W node --test test/notify.test.js ~/x
$W echo \$(bash post.sh)
$W echo "\$(bash post.sh)"
$W echo \`bash post.sh\`
$W cat <(bash post.sh)
$W node --test \$(node --test test/notify.test.js)
$W node --test test/plain.test.js > >(bash post.sh)
2> >(bash post.sh) $W node --test test/plain.test.js
EOF

echo "slack drafts only: only a space, a tab and a newline are white space to the rule (claude-config#3173)"

# Python's strip, isspace and \s take a no break space, a line separator, a form feed and their like
# as white space, and zsh and bash keep each inside the word (measured 2026-11-19): with one in
# front of the wrapper's path the shell runs a file of another name, in the folder the call is in.
# So a call holding any character but printable ASCII, a tab and a newline is judged as it was.
for c in 00a0 2028 3000 000c 000b 000d 0000; do
  each_esc read_refused "#3173 U+$c in front of the wrapper leaves the call judged as it was" 3<<EOF
\\u$c$W node --test test/notify.test.js
cd $P && \\u$c$W node --test test/notify.test.js
EOF
done

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
# command of it and "no" where it held for none, then a tab and the line as it was handed over. A
# \uXXXX in a line is that one character by the time it is judged. For the shapes whose verdict
# cannot show the rule: a command that runs nothing was allowed before the rule and is allowed after
# it, and a wrapper run the gate refuses today is refused whichever part of the rule turned it away.
#
# With a third word it is handed pairs, FIRST<tab>SECOND, and one Judge reads both in turn, which no
# call can make it do: the rule lets nothing stand before the wrapper but a cd and nothing after
# it. It is the one way to ask the two checks that hold if that is ever widened, each on its own:
# that this call has not written the wrapper's file, and that a pass leaves every file unread. It
# prints whether the rule held for SECOND, then "refused: <why>" or "allowed", then the pair.
cat > "$T/rule.py" <<'PY'
import importlib.util
import os
import re
import sys

GATE = sys.argv[1]
CWD = sys.argv[2]
PAIRS = len(sys.argv) > 3
os.environ["GATE_DIR"] = os.path.dirname(GATE)
spec = importlib.util.spec_from_file_location("drafts_gate", GATE)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def written(text):
    return re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), text)


for line in sys.stdin:
    shown = line.rstrip("\n")
    if not shown:
        continue
    texts = [written(t) for t in (shown.split("\t") if PAIRS else [shown])]
    judge = gate.Judge(gate.load_reader())
    held = []
    rule = judge.no_network_run

    def asked(*args, rule=rule, held=held):
        got = rule(*args)
        held.append(bool(got))
        return got

    judge.no_network_run = asked
    judge.watch()
    reason = None
    try:
        for text in texts:
            del held[:]
            reason = judge.line(text, CWD, 0, text)
    finally:
        judge.unwatch()
    verdict = ("\t" + ("refused: " + reason if reason else "allowed")) if PAIRS else ""
    print(("yes" if any(held) else "no") + verdict + "\t" + shown)
PY

rule_says() { # rule_says <yes|no> <label>, the commands on descriptor 3, one per line
  # One start of the gate's code answers the whole list (L298), a line of output for each command
  # in turn. An answer that is missing or out of place fails the command it belongs to.
  local want="$1" label="$2" runs got i=0
  printf '' > "$T/rule.in"
  while IFS= read -r runs <&3; do
    [ -n "$runs" ] || continue
    printf '%s\n' "$runs" >> "$T/rule.in"
  done
  python3 "$T/rule.py" "$DIR/slack_drafts_only_gate.py" "$P" < "$T/rule.in" > "$T/rule.out" 2>&1
  exec 4< "$T/rule.out"
  while IFS= read -r runs; do
    i=$((i + 1))
    got=""
    IFS= read -r got <&4 || true
    if [ "$got" = "$want"$'\t'"$runs" ]; then check "$label: $runs" ok; else check "$label: $runs" "the rule said: ${got:0:300}"; fi
  done < "$T/rule.in"
  exec 4<&-
  if [ "$i" -eq 0 ]; then check "$label" "no command was handed over"; fi
}

rule_says yes "#3173 the rule holds for the wrapper and a command as the whole call" 3<<EOF
$W node --test test/notify.test.js
$W true
cd $P && $W node --test test/notify.test.js
cd '$P' && '$W' true
cd "$P"   &&   "$W"   true
  $W true
$W true\\u000a
\\u000a$W true
$W sh -c 'true | tail -5; echo done # a note'
$W sh -c 'true\\u000atail out.txt'
$W node -e 'fetch(u); console.log("a b")' "\$HOME/x" --flag=1 test/*.js > out.txt 2>&1
$W true > out.txt
$W true >> out.txt
$W true 1> out.txt
$W true 2> err.txt
$W true 2>> err.txt
$W true 2>/dev/null
$W true 2>&1
$W true 1>&2
$W true >&2
$W true < in.txt
$W true > 'out file.txt' 2> "err file.txt"
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
$W/ true
$W/. true
EOF

# A word of the shell's own in front of the wrapper: each is read past by one shell or reader and
# run as a program, or sets up a redirection first, by another.
rule_says no "#3173 the rule does not hold with any word in front of the wrapper" 3<<EOF
time $W true
time -p $W true
time -- $W true
! $W true
{ $W true; }
{ $W true; } 3<>/dev/tcp/127.0.0.1/9
if $W true; then echo ok; fi
if $W true; then :; fi 3<>/dev/tcp/127.0.0.1/9
then $W true
do $W true
coproc $W true
noglob $W true
nocorrect $W true
command $W true
builtin $W true
exec $W true
- $W true
eval $W true
( $W true )
($W true)
env $W node --test test/notify.test.js
xargs $W node --test
sudo $W node --test test/notify.test.js
A=1 $W node --test test/notify.test.js
2>/dev/null $W node --test test/notify.test.js
2> >(date) $W node --test test/notify.test.js
some-program $W node --test test/notify.test.js
>out.txt $W true
< /dev/null $W true
&>log.txt $W true
2>&1 $W true
EOF

rule_says no "#3173 the rule does not hold with any command before the wrapper but one cd" 3<<EOF
echo start; $W true
true && $W true
ls | $W cat
cd \$(pwd) && $W true
cd "\$HOME" && $W true
cd -P $P && $W true
cd - && $W true
cd ~ && $W true
cd $P; $W true
cd $P || $W true
cd $P | $W true
cd $P & $W true
cd $P &&\\u000a$W true
cd $P\\u000a$W true
cd $P && cd $P && $W true
cd $P $P && $W true
cd && $W true
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
if true; then $W true; fi
if false; then true; else $W true; fi
case x in x) $W true;; esac
repeat 2 $W true
for f (a b) $W true
eval '$W true'
# a note\\u000a$W true
EOF

# What the review of 2026-11-19 showed passing: a package script, a program run by its bare name, a
# git hook or a Makefile the wrapped command wrote, run by a later command of the same call, and the
# other side of a pipe, which can wait until the wrapped command has written.
rule_says no "#3173 the rule does not hold with anything after the wrapper's command" 3<<EOF
$W sh -c 'cp evil.json package.json'; npm run x
$W sh -c 'cp post.sh tail'; tail -5 out.txt
$W true; tail out.txt
$W true && cat out.txt
$W true || echo failed
$W true; echo done
$W true | tail -5
$W true |& tail -5
$W true | xargs -n1 tail
$W true | (sleep 5; tail)
$W true; git status
$W true; make
$W true; curl https://example.com/x
$W true &
$W true & tail out.txt
$W true ;
$W true;
$W true # a note
$W true; $W true
$W true && $T/links/run.sh true
$W true\\u000atail out.txt
$W true\\u000a$W true
$W true\\u000a# a note
$W true > out.txt; bash out.txt
EOF

rule_says no "#3173 the rule does not hold for any other redirection" 3<<EOF
$W true &> out.txt
$W true &>> out.txt
$W true >| out.txt
$W true >! out.txt
$W true <> in.txt
$W true 3> out.txt
$W true 12> out.txt
$W true >&3
$W true 2>&-
$W true >& out.txt
$W true > "\$OUT"
$W true > \$OUT
$W true > out*.txt
$W true > ~/out.txt
$W true 0< in.txt
$W true 2< in.txt
$W true>out.txt
$W node --test test/notify.test.js>out.txt
$W true > /dev/tcp/127.0.0.1/9
$W true < /dev/tcp/127.0.0.1/9
$W true > /dev/udp/127.0.0.1/9
$W true > '/dev/tcp/127.0.0.1/9'
$W true 3<>/dev/tcp/127.0.0.1/9
$W cat <<< "\$(date)"
$W cat <<WORDS
$W echo '/dev/udp/127.0.0.1/9'
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
$W echo \$(date)
$W cat <(date)
$W echo a#b
$W echo [ab]
$W echo a!b
EOF

# Each character Python reads as white space, or drops, and a shell keeps in the word, at each place
# it could change which file the shell starts or where a word ends: in front of the wrapper, in
# front of the cd, inside the wrapper's path, between its words, and at the end. And inside quotes,
# where it would change nothing: the rule reads no character it has to know the class of.
for c in 00a0 2028 3000 000c 000b 000d 0000 0085 2003 001f 007f 200b feff; do
  rule_says no "#3173 the rule does not hold for a call holding U+$c" 3<<EOF
\\u$c$W true
 \\u$c $W true
cd $P && \\u$c$W true
cd $P &&\\u$c$W true
\\u${c}cd $P && $W true
cd\\u$c$P && $W true
$DIR/\\u${c}no-network-run.sh true
$DIR\\u$c/no-network-run.sh true
$W\\u${c}true
$W true\\u${c}x
$W true \\u$c x
$W true\\u$c
$W echo 'a\\u${c}b'
EOF
done

echo "slack drafts only: the two checks no call can reach, asked of one Judge handed two lines (claude-config#3173)"

# pair_says <yes|no> <refused|allowed|any> <label> [says]: the pairs on descriptor 3, FIRST then a
# tab then SECOND, one Judge reading both: whether the rule held for SECOND and how SECOND was judged.
pair_says() {
  local rule="$1" verdict="$2" label="$3" want="${4:-}" runs got
  while IFS= read -r runs <&3; do
    [ -n "$runs" ] || continue
    got="$(printf '%s\n' "$runs" | python3 "$T/rule.py" "$DIR/slack_drafts_only_gate.py" "$RUN_IN" pairs 2>&1)"
    case "$got" in
      "$rule"$'\t'*$'\t'"$runs") check "$label (the rule): $runs" ok ;;
      *) check "$label (the rule): $runs" "the rule said: ${got:0:300}" ;;
    esac
    case "$verdict:$got" in
      any:*|refused:*$'\t'"refused: "*|allowed:*$'\t'allowed$'\t'*) check "$label (the verdict): $runs" ok ;;
      *) check "$label (the verdict): $runs" "it was judged: ${got:0:300}" ;;
    esac
    if [ -n "$want" ]; then
      case "$got" in *"$want"*) check "$label (and says so): $runs" ok ;; *) check "$label (and says so): $runs" "it said: ${got:0:400}" ;; esac
    fi
  done
}
TAB=$'\t'

# The control: a Judge that has read a harmless line first answers as a fresh one does.
pair_says yes allowed "#3173 after a line that writes nothing, the rule holds as it does alone" 3<<EOF
echo hi${TAB}$W node --test test/notify.test.js
EOF
pair_says no allowed "#3173 after a line that writes nothing, a test that imports nothing passes" 3<<EOF
echo hi${TAB}node --test test/plain.test.js
EOF

# The check that this call has not written, moved, linked or changed the wrapper's file, which is
# the test /nudge is let through by (is_installed).
pair_says no any "#3173 the rule does not hold for a wrapper the same Judge saw written" 3<<EOF
cp $T/runner.sh $W${TAB}$W node --test test/notify.test.js
mv $T/runner.sh $W${TAB}$W node --test test/notify.test.js
ln -sf $T/runner.sh $W${TAB}$W node --test test/notify.test.js
echo 'exec "\$@"' > $W${TAB}$W node --test test/notify.test.js
sed -i '' 's/deny network/allow network/' $W${TAB}$W node --test test/notify.test.js
EOF
# And that no build this call ran writes it, which that test does not ask.
RUN_IN="$B"
pair_says no any "#3173 the rule does not hold for a wrapper the same Judge saw a build write" 3<<EOF
esbuild esrc/post.ts --outfile=$W${TAB}$W node out.js
EOF
RUN_IN="$P"

# The record a pass leaves: every file is, from then on, one an unread program may have written.
pair_says no refused "#3173 after a pass, a file the same Judge is asked to run is unread" "the command run under the no network wrapper" 3<<EOF
$W node --test test/notify.test.js${TAB}node --test test/plain.test.js
$W cp post.sh made.sh${TAB}bash made.sh
EOF
pair_says no any "#3173 after a pass, the rule does not hold a second time" 3<<EOF
$W true${TAB}$W node --test test/notify.test.js
$W true${TAB}$T/links/run.sh node --test test/notify.test.js
EOF

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
